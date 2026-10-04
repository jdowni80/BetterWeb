import Darwin
import Foundation

enum SidecarError: LocalizedError {
    case repoMissing
    case missingPython
    case exited(Int32)
    case unhealthy

    var errorDescription: String? {
        switch self {
        case .repoMissing: return "BetterWeb repo not found (needed for the CraftRank sidecar)"
        case .missingPython: return "Python for BetterWeb not found — run scripts/run_mac_app.sh once"
        case .exited(let code): return "Search engine exited (status \(code)) — see ~/Library/Logs/BetterWeb/sidecar.log"
        case .unhealthy: return "Search engine did not become healthy"
        }
    }
}

/// Runs the CraftRank + Lightpanda FastAPI sidecar as a child bound to a private
/// loopback port. The app always owns its sidecar, so a stale server left on
/// :8742 from an older checkout can never answer for it.
final class SidecarProcess {
    private var process: Process?
    private(set) var port: Int = 0

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    func start(client: SearchClient) async throws {
        if let process, process.isRunning, (try? await client.health()) == true { return }

        guard let root = AppPaths.repoRoot else { throw SidecarError.repoMissing }
        let venvPython = root.appendingPathComponent(".venv/bin/python")
        let python: String
        if FileManager.default.isExecutableFile(atPath: venvPython.path) {
            python = venvPython.path
        } else if let system = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            python = system
        } else {
            throw SidecarError.missingPython
        }

        port = Self.freePort() ?? 8752
        client.baseURL = baseURL

        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-m", "betterweb.app.main"]
        process.currentDirectoryURL = root
        var env = ProcessInfo.processInfo.environment
        env["BETTERWEB_PORT"] = String(port)
        env["BETTERWEB_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        env["BETTERWEB_LOG_LEVEL"] = "warning"
        env["LIGHTPANDA_DISABLE_TELEMETRY"] = "true"
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONPATH"] = root.appendingPathComponent("src").path
        process.environment = env
        let log = AppPaths.logHandle(named: "sidecar.log") ?? FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log

        try process.run()
        self.process = process
        AppLog.info("sidecar started pid=\(process.processIdentifier) port=\(port) python=\(python)")

        // First launch imports the ranking stack; give it a generous window.
        for _ in 0..<120 {
            try await Task.sleep(nanoseconds: 250_000_000)
            if !process.isRunning { throw SidecarError.exited(process.terminationStatus) }
            if (try? await client.health()) == true { return }
        }
        throw SidecarError.unhealthy
    }

    func stop() {
        guard let process, process.isRunning else { return }
        process.terminate()
        self.process = nil
    }

    deinit {
        process?.terminate()
    }

    private static func freePort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }
        var out = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &out) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard named == 0 else { return nil }
        return Int(UInt16(bigEndian: out.sin_port))
    }
}
