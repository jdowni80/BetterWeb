import AVFoundation
import Combine
import Foundation

/// Video pages whose in-page player needs Media Source Extensions, which Servo lacks.
enum NativeVideo {
    private static let youtubeHosts: Set<String> = ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"]

    static func videoID(for pageURL: String?) -> String? {
        guard let pageURL, let components = URLComponents(string: pageURL),
              let host = components.host?.lowercased() else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        var candidate: String?
        if host == "youtu.be" {
            candidate = parts.first
        } else if youtubeHosts.contains(host) {
            if components.path == "/watch" {
                candidate = components.queryItems?.first(where: { $0.name == "v" })?.value
            } else if parts.count >= 2, ["shorts", "live", "embed"].contains(parts[0]) {
                candidate = parts[1]
            }
        }
        guard let candidate, candidate.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return candidate
    }

    /// `t=90`, `t=1m30s`, or `t=1h2m3s`.
    static func startTime(for pageURL: String) -> Double? {
        guard let value = URLComponents(string: pageURL)?.queryItems?.first(where: { $0.name == "t" || $0.name == "start" })?.value,
              !value.isEmpty else { return nil }
        if let seconds = Double(value.trimmingCharacters(in: CharacterSet(charactersIn: "s"))) { return seconds }
        var total = 0.0
        var number = ""
        for ch in value {
            if ch.isNumber { number.append(ch); continue }
            let n = Double(number) ?? 0
            number = ""
            switch ch {
            case "h": total += n * 3600
            case "m": total += n * 60
            case "s": total += n
            default: return nil
            }
        }
        return total > 0 ? total : nil
    }
}

@MainActor
final class MediaSession: ObservableObject {
    enum Phase: Equatable {
        case resolving
        case ready
        case failed(String)
    }

    let tabID: UUID
    let videoID: String
    let pageURL: String
    let player = AVPlayer()
    @Published private(set) var phase: Phase = .resolving
    @Published private(set) var media: ResolvedMedia?

    private let client: SearchClient
    private let ready: () async throws -> Void
    private var task: Task<Void, Never>?
    private var statusObservation: NSKeyValueObservation?
    private var usingFallback = false

    init(tabID: UUID, videoID: String, pageURL: String, client: SearchClient, ready: @escaping () async throws -> Void) {
        self.tabID = tabID
        self.videoID = videoID
        self.pageURL = pageURL
        self.client = client
        self.ready = ready
        resolve()
    }

    func retry() {
        resolve()
    }

    func teardown() {
        task?.cancel()
        statusObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    private func resolve() {
        task?.cancel()
        phase = .resolving
        usingFallback = false
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.ready()
                let media = try await self.client.resolveMedia(pageURL: self.pageURL)
                guard !Task.isCancelled else { return }
                self.media = media
                let hls = media.hls_url == nil ? nil : self.client.nativePlaylistURL(videoID: media.id)
                guard let stream = hls ?? media.progressive_url.flatMap(URL.init(string:)) else {
                    self.phase = .failed("No playable stream for this video")
                    return
                }
                AppLog.info("media resolved id=\(media.id) hls=\(media.hls_url != nil)")
                self.play(stream, startAt: NativeVideo.startTime(for: self.pageURL))
            } catch {
                guard !Task.isCancelled else { return }
                AppLog.info("media resolve failed id=\(self.videoID): \(error.localizedDescription)")
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    private func play(_ url: URL, startAt: Double?) {
        let item = AVPlayerItem(url: url)
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let message = item.error?.localizedDescription
            Task { @MainActor [weak self] in self?.itemStatusChanged(status, error: message) }
        }
        player.replaceCurrentItem(with: item)
        if let startAt {
            player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600))
        }
        phase = .ready
        player.play()
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status, error: String?) {
        guard status == .failed else { return }
        AppLog.info("media playback failed id=\(videoID) fallback=\(usingFallback): \(error ?? "unknown")")
        if !usingFallback, media?.hls_url != nil,
           let fallback = media?.progressive_url.flatMap(URL.init(string:)) {
            usingFallback = true
            let position = player.currentTime().seconds
            play(fallback, startAt: position.isFinite && position > 0 ? position : NativeVideo.startTime(for: pageURL))
            return
        }
        phase = .failed(error ?? "Playback failed")
    }
}

/// One native player per tab showing a supported video page.
@MainActor
final class MediaController: ObservableObject {
    @Published private(set) var sessions: [UUID: MediaSession] = [:]

    private let client: SearchClient
    private let ready: () async throws -> Void

    init(client: SearchClient, ready: @escaping () async throws -> Void) {
        self.client = client
        self.ready = ready
    }

    func session(for tabID: UUID) -> MediaSession? {
        sessions[tabID]
    }

    /// Background tabs only get a player once they've been shown, so restoring
    /// a window full of video tabs doesn't start them all at once.
    func reconcile(tabs: [BrowserTab], activeTabID: UUID) {
        var next = sessions
        let live = Set(tabs.map(\.id))
        for (id, session) in sessions where !live.contains(id) {
            session.teardown()
            next[id] = nil
        }
        for tab in tabs {
            let existing = next[tab.id]
            guard let url = tab.pageURL, let videoID = NativeVideo.videoID(for: url) else {
                existing?.teardown()
                next[tab.id] = nil
                continue
            }
            if existing?.videoID == videoID { continue }
            guard tab.id == activeTabID || existing != nil else { continue }
            existing?.teardown()
            next[tab.id] = MediaSession(tabID: tab.id, videoID: videoID, pageURL: url, client: client, ready: ready)
        }
        if next.keys != sessions.keys || next.contains(where: { sessions[$0.key] !== $0.value }) {
            sessions = next
        }
    }

    func stopAll() {
        sessions.values.forEach { $0.teardown() }
        sessions = [:]
    }
}
