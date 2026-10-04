import Foundation

/// Locates the repo (Python sidecar) and per-user directories.
/// Works for the bundled `BetterWeb.app`, `swift run`, and a bare binary in `.build/`.
enum AppPaths {
    static let fm = FileManager.default

    static var repoRoot: URL? {
        if let env = ProcessInfo.processInfo.environment["BETTERWEB_ROOT"], isRepo(URL(fileURLWithPath: env)) {
            return URL(fileURLWithPath: env)
        }
        if let marker = Bundle.main.url(forResource: "repo-root", withExtension: "txt"),
           let text = try? String(contentsOf: marker, encoding: .utf8) {
            let url = URL(fileURLWithPath: text.trimmingCharacters(in: .whitespacesAndNewlines))
            if isRepo(url) { return url }
        }
        for start in searchStarts {
            var walk = start
            for _ in 0..<8 {
                if isRepo(walk) { return walk }
                let parent = walk.deletingLastPathComponent()
                if parent.path == walk.path { break }
                walk = parent
            }
        }
        return nil
    }

    static var logsDir: URL {
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/BetterWeb")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var profileDir: URL {
        let dir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BetterWeb/Ladybird")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Fresh, truncated log file handle for a child process's output.
    static func logHandle(named name: String) -> FileHandle? {
        let url = logsDir.appendingPathComponent(name)
        fm.createFile(atPath: url.path, contents: nil)
        return try? FileHandle(forWritingTo: url)
    }

    private static var searchStarts: [URL] {
        var starts: [URL] = []
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            starts.append(exe.deletingLastPathComponent())
        }
        starts.append(Bundle.main.bundleURL.deletingLastPathComponent())
        starts.append(URL(fileURLWithPath: fm.currentDirectoryPath))
        return starts
    }

    private static func isRepo(_ url: URL) -> Bool {
        fm.fileExists(atPath: url.appendingPathComponent("pyproject.toml").path)
            && fm.fileExists(atPath: url.appendingPathComponent("src/betterweb").path)
    }
}

enum AppLog {
    private static let queue = DispatchQueue(label: "betterweb.log")
    private static let handle: FileHandle? = AppPaths.logHandle(named: "BetterWeb.log")

    static func info(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        queue.async {
            handle?.write(Data(line.utf8))
        }
        #if DEBUG
        FileHandle.standardError.write(Data(line.utf8))
        #endif
    }
}
