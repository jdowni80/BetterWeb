import Foundation

struct EngineStatus: Identifiable, Decodable {
    let id: String
    let name: String
    let role: String
    let available: Bool
    let path: String?
    let detail: String
}

struct SearchHit: Identifiable, Decodable, Hashable {
    let id: String
    let title: String
    let url: String
    let snippet: String
    let relevance: Double
    let craft: Double
    let betterweb_score: Double
    let badges: [String]
    let fetch_engine: String
}

struct SearchResponse: Decodable {
    let query: String
    let mode: String
    let count: Int
    let ranking: String
    let hits: [SearchHit]
}

struct ResolvedMedia: Decodable, Equatable {
    let id: String
    let title: String
    let channel: String
    let duration: Double?
    let is_live: Bool
    let thumbnail: String?
    let hls_url: String?
    let progressive_url: String?
}

enum SearchClientError: LocalizedError {
    case badStatus(Int)
    case decode
    case unreachable
    case message(String)

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): return "HTTP \(code)"
        case .decode: return "Could not decode search response"
        case .unreachable: return "Search sidecar unreachable"
        case .message(let text): return text
        }
    }
}

final class SearchClient {
    var baseURL = URL(string: "http://127.0.0.1:8742")!

    func health() async throws -> Bool {
        let url = baseURL.appendingPathComponent("api/health")
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SearchClientError.badStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["ok"] as? Bool ?? false
    }

    func engines() async throws -> [EngineStatus] {
        let url = baseURL.appendingPathComponent("api/engines")
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SearchClientError.badStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        struct Wrap: Decodable { let engines: [EngineStatus] }
        return try JSONDecoder().decode(Wrap.self, from: data).engines
    }

    func search(query: String, mode: SearchMode, limit: Int = 8) async throws -> SearchResponse {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "mode", value: mode.rawValue),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let url = components.url else { throw SearchClientError.unreachable }
        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SearchClientError.badStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        do {
            return try JSONDecoder().decode(SearchResponse.self, from: data)
        } catch {
            throw SearchClientError.decode
        }
    }

    /// HLS master playlist filtered to renditions AVFoundation can decode.
    func nativePlaylistURL(videoID: String) -> URL {
        baseURL.appendingPathComponent("api/media/hls/\(videoID).m3u8")
    }

    func resolveMedia(pageURL: String) async throws -> ResolvedMedia {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/media/resolve"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "url", value: pageURL)]
        guard let url = components.url else { throw SearchClientError.unreachable }
        var request = URLRequest(url: url)
        request.timeoutInterval = 40
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            struct Detail: Decodable { let detail: String }
            if let detail = try? JSONDecoder().decode(Detail.self, from: data) {
                throw SearchClientError.message(detail.detail)
            }
            throw SearchClientError.badStatus(status)
        }
        return try JSONDecoder().decode(ResolvedMedia.self, from: data)
    }
}
