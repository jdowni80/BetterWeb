import Foundation

/// Low-CPU background crawler (`betterweb-indexd`) owned by the Mac app.
final class IndexerProcess {
    private var process: Process?

    func start() {
        if let process, process.isRunning { return }
        guard let root = AppPaths.repoRoot else {
            AppLog.info("indexd skipped: repo root missing")
            return
        }
        let venvPython = root.appendingPathComponent(".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: venvPython.path) else {
            AppLog.info("indexd skipped: .venv python missing")
            return
        }
        let process = Process()
        process.executableURL = venvPython
        process.arguments = ["-m", "betterweb.indexd"]
        process.currentDirectoryURL = root
        var env = ProcessInfo.processInfo.environment
        env["BETTERWEB_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONPATH"] = root.appendingPathComponent("src").path
        process.environment = env
        let log = AppPaths.logHandle(named: "indexd.log") ?? FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        do {
            try process.run()
            self.process = process
            AppLog.info("indexd started pid=\(process.processIdentifier)")
        } catch {
            AppLog.info("indexd failed to start: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard let process, process.isRunning else { return }
        process.terminate()
        self.process = nil
    }

    deinit {
        process?.terminate()
    }
}
