import Foundation
import os.log

private let log = Logger(subsystem: "com.lstn2.app", category: "PythonManager")

final class PythonManager {
    private var process: Process?
    private let backendDirectory: String
    private let uvPath: String
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    /// Initializes the manager with the backend project directory and uv binary path.
    /// Uses `LSTN2_BACKEND_DIR` environment variable if set, otherwise derives from home directory.
    init(
        backendDirectory: String? = nil,
        uvPath: String = "\(NSHomeDirectory())/.local/bin/uv"
    ) {
        if let dir = backendDirectory {
            self.backendDirectory = dir
        } else if let envDir = ProcessInfo.processInfo.environment["LSTN2_BACKEND_DIR"] {
            self.backendDirectory = envDir
        } else {
            self.backendDirectory = "\(NSHomeDirectory())/Documents/LSTN2/backend"
        }
        self.uvPath = uvPath
    }

    func startBackend() throws {
        // Stop any previous instance first
        stopBackend()

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
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            for l in line.split(separator: "\n") {
                log.info("[backend:stdout] \(l)")
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

        // Monitor process termination
        proc.terminationHandler = { process in
            let status = process.terminationStatus
            let reason = process.terminationReason
            if reason == .uncaughtSignal {
                log.fault("Backend process crashed with signal \(status)")
            } else if status != 0 {
                log.error("Backend process exited with status \(status)")
            } else {
                log.info("Backend process exited normally")
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
    }

    var isRunning: Bool {
        process?.isRunning == true
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
            log.warning("Killing stale backend process on port 8765 (pid=\(pid))")
            kill(pid, SIGTERM)
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
