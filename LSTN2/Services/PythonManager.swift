import Foundation

final class PythonManager {
    private var process: Process?
    private let backendDirectory: String
    private let uvPath: String

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
            throw PythonManagerError.uvNotFound(uvPath)
        }

        guard FileManager.default.fileExists(atPath: backendDirectory) else {
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

        try proc.run()
        self.process = proc
    }

    func stopBackend() {
        guard let process else { return }

        if process.isRunning {
            process.terminate()
        }

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
