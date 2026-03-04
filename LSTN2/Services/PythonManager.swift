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
    init(
        backendDirectory: String = "\(NSHomeDirectory())/Documents/LSTN2/backend",
        uvPath: String = "\(NSHomeDirectory())/.local/bin/uv"
    ) {
        self.backendDirectory = backendDirectory
        self.uvPath = uvPath
    }

    func startBackend() throws {
        // Stop any previous instance first
        stopBackend()

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
            process.waitUntilExit()
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
