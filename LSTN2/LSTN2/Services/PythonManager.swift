import Foundation
import os.log

private let log = Logger(subsystem: "com.lstn2.app", category: "PythonManager")

final class PythonManager {
    private var process: Process?
    private let backendDirectory: String
    private let uvPath: String
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    /// Set to `true` while an intentional stop is in progress, so the
    /// termination handler doesn't fire the unexpected-exit callback.
    private var _stoppingIntentionally = false

    /// Called on a background thread when the backend process exits
    /// unexpectedly (crash or non-zero exit). The app should use this
    /// to trigger a restart.
    var onUnexpectedExit: (() -> Void)?

    /// Set to `true` when the backend prints "READY" to stdout.
    private let readyLock = NSLock()
    private var _backendReady = false

    /// Initializes the manager with the backend project directory and uv binary path.
    /// Resolves the backend directory dynamically from the source tree location.
    init(
        backendDirectory: String? = nil,
        uvPath: String = "\(NSHomeDirectory())/.local/bin/uv"
    ) {
        self.backendDirectory = backendDirectory ?? SetupState.resolveBackendDirectory()
        self.uvPath = uvPath
    }

    func startBackend() throws {
        // Stop any previous instance first
        stopBackend()
        _stoppingIntentionally = false
        readyLock.withLock { _backendReady = false }

        // Kill any stale backend processes left from a previous app session
        killStaleBackend()

        guard FileManager.default.fileExists(atPath: uvPath) else {
            log.error("uv binary not found at \(self.uvPath)")
            throw PythonManagerError.uvNotFound(uvPath)
        }

        guard FileManager.default.fileExists(atPath: backendDirectory) else {
            log.error("Backend directory not found at \(self.backendDirectory)")
            throw PythonManagerError.backendNotFound(backendDirectory)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: uvPath)
        proc.arguments = ["run", "python", "-m", "listen.main"]
        proc.currentDirectoryURL = URL(fileURLWithPath: backendDirectory)

        // Inherit minimal environment so uv can resolve Python
        proc.environment = [
            "HOME": NSHomeDirectory(),
            "PATH": "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
        ]

        // Capture stdout
        let stdout = Pipe()
        proc.standardOutput = stdout
        stdoutPipe = stdout
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            for l in line.split(separator: "\n") {
                log.info("[backend:stdout] \(l)")
                if l.hasPrefix("READY ") {
                    self?.readyLock.withLock { self?._backendReady = true }
                }
            }
        }

        // Capture stderr
        let stderr = Pipe()
        proc.standardError = stderr
        stderrPipe = stderr
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            for l in line.split(separator: "\n") {
                log.error("[backend:stderr] \(l)")
            }
        }

        // Monitor process termination and auto-restart on unexpected exit
        proc.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            let reason = process.terminationReason
            if reason == .uncaughtSignal {
                log.fault("Backend process crashed with signal \(status)")
            } else if status != 0 {
                log.error("Backend process exited with status \(status)")
            } else {
                log.info("Backend process exited normally")
            }

            // Only fire callback for unexpected exits — not intentional stops
            guard let self, !self._stoppingIntentionally else { return }
            if reason == .uncaughtSignal || status != 0 {
                log.warning("Backend exited unexpectedly — notifying for restart")
                self.onUnexpectedExit?()
            }
        }

        log.info("Starting backend process: \(self.uvPath) run python -m listen.main")
        try proc.run()
        log.info("Backend process started (pid=\(proc.processIdentifier))")
        self.process = proc
    }

    func stopBackend() {
        guard let process else { return }

        if process.isRunning {
            _stoppingIntentionally = true
            log.info("Stopping backend process (pid=\(process.processIdentifier))")
            process.terminate()

            // Use a semaphore for bounded wait instead of blocking indefinitely
            let semaphore = DispatchSemaphore(value: 0)
            let previousHandler = process.terminationHandler
            process.terminationHandler = { proc in
                previousHandler?(proc)
                semaphore.signal()
            }
            let result = semaphore.wait(timeout: .now() + 5)
            if result == .timedOut {
                log.warning("Backend process did not exit within 5s, force killing")
                process.interrupt()
            }
            log.info("Backend process stopped (exit=\(process.terminationStatus))")
        }

        // Clean up pipe handlers
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil
        self.process = nil
        _stoppingIntentionally = false
    }

    var isRunning: Bool {
        process?.isRunning == true
    }

    /// Waits until the backend prints its "READY" marker to stdout,
    /// or until the timeout elapses. Returns `true` if the backend became ready.
    func waitUntilReady(timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if readyLock.withLock({ _backendReady }) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// Kill any stale backend processes listening on the WebSocket port (8765).
    /// This handles orphaned processes from a previous app session that crashed
    /// or was force-quit without cleanly terminating the backend.
    private func killStaleBackend() {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-ti", "tcp:8765"]
        let pipe = Pipe()
        lsof.standardOutput = pipe
        lsof.standardError = FileHandle.nullDevice

        do {
            try lsof.run()
            lsof.waitUntilExit()
        } catch {
            return
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty else { return }

        for pidStr in output.split(separator: "\n") {
            guard let pid = Int32(pidStr.trimmingCharacters(in: .whitespaces)) else { continue }

            // Verify the process is actually a Python/uv backend before killing
            let ps = Process()
            ps.executableURL = URL(fileURLWithPath: "/bin/ps")
            ps.arguments = ["-p", "\(pid)", "-o", "comm="]
            let psPipe = Pipe()
            ps.standardOutput = psPipe
            ps.standardError = FileHandle.nullDevice

            do {
                try ps.run()
                ps.waitUntilExit()
            } catch {
                continue
            }

            let psData = psPipe.fileHandleForReading.readDataToEndOfFile()
            guard let comm = String(data: psData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
                  !comm.isEmpty
            else { continue }

            if comm.contains("python") || comm.contains("uv") {
                log.warning("Killing stale backend process on port 8765 (pid=\(pid), comm=\(comm))")
                kill(pid, SIGTERM)
            } else {
                log.info("Skipping non-backend process on port 8765 (pid=\(pid), comm=\(comm))")
            }
        }

        // Brief wait for processes to exit
        Thread.sleep(forTimeInterval: 0.5)
    }
}

enum PythonManagerError: LocalizedError {
    case uvNotFound(String)
    case backendNotFound(String)

    var errorDescription: String? {
        switch self {
        case .uvNotFound(let path):
            "uv not found at \(path). Install it with: curl -LsSf https://astral.sh/uv/install.sh | sh"
        case .backendNotFound(let path):
            "Backend directory not found at \(path)"
        }
    }
}
