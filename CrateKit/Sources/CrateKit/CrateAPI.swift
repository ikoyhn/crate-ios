import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum CrateError: LocalizedError, Sendable, Equatable {
    case badURL
    case notCrate
    case unauthorized
    case server(status: Int, detail: String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .badURL: "That doesn't look like a web address."
        case .notCrate: "That address answered, but it isn't a Crate server."
        case .unauthorized: "Crate rejected the API token."
        case .server(_, let detail): detail
        case .transport(let message): message
        }
    }
}

/// Moves bytes. Swappable so tests can answer without a server.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CrateError.transport("No HTTP response") }
        return (data, http)
    }
}

/// Talks to a Crate server's /api. One per server; cheap to make.
public struct CrateAPI: Sendable {
    public let baseURL: URL
    public let token: String
    let transport: HTTPTransport

    public init(baseURL: URL, token: String = "", transport: HTTPTransport = URLSessionTransport()) {
        self.baseURL = baseURL
        self.token = token
        self.transport = transport
    }

    /// Accepts "crate.local:8090", "http://10.0.0.5:8090/", "https://crate.example.com".
    public static func normalise(_ text: String) -> URL? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), url.host != nil else { return nil }
        return url
    }

    // MARK: - plumbing

    /// `path` is already escaped (callers escape ids) and may carry its own query string.
    func url(_ path: String, query: [String: String] = [:]) -> URL {
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        var base = comps.percentEncodedPath
        if base.hasSuffix("/") { base.removeLast() }
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        comps.percentEncodedPath = base + parts[0]
        var q = parts.count > 1 ? [String(parts[1])] : []
        q += query.sorted { $0.key < $1.key }.map { "\($0.key.addingQueryEscapes)=\($0.value.addingQueryEscapes)" }
        comps.percentEncodedQuery = q.isEmpty ? nil : q.joined(separator: "&")
        return comps.url!
    }

    /// A URL for things that can't send headers (AVPlayer, image loaders): the token rides along
    /// as ?token=. Absolute URLs (Deezer previews and covers) are returned as they are.
    public func mediaURL(_ pathOrURL: String) -> URL? {
        guard !pathOrURL.isEmpty else { return nil }
        if pathOrURL.hasPrefix("http://") || pathOrURL.hasPrefix("https://") { return URL(string: pathOrURL) }
        return url(pathOrURL, query: token.isEmpty ? [:] : ["token": token])
    }

    public func coverURL(songId: String, size: Int = 300) -> URL? {
        mediaURL("/api/cover/\(songId.addingPathEscapes)?size=\(size)")
    }

    public func previewURL(songId: String) -> URL? {
        mediaURL("/api/preview/\(songId.addingPathEscapes)")
    }

    func request(_ method: String, _ path: String, body: (any Encodable & Sendable)? = nil) async throws -> Data {
        var req = URLRequest(url: url(path))
        req.httpMethod = method
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.httpBody = try JSONEncoder().encode(body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data, resp: HTTPURLResponse
        do {
            (data, resp) = try await transport.send(req)
        } catch let e as CrateError {
            throw e
        } catch {
            throw CrateError.transport(error.localizedDescription)
        }
        switch resp.statusCode {
        case 200..<300: return data
        case 401: throw CrateError.unauthorized
        default:
            let detail = (try? JSONDecoder().decode(Detail.self, from: data))?.text
                ?? HTTPURLResponse.localizedString(forStatusCode: resp.statusCode)
            throw CrateError.server(status: resp.statusCode, detail: detail)
        }
    }

    func get<T: Decodable>(_ path: String, as: T.Type = T.self) async throws -> T {
        try decode(try await request("GET", path))
    }

    func send<T: Decodable>(_ method: String, _ path: String, body: (any Encodable & Sendable)? = nil,
                            as: T.Type = T.self) async throws -> T {
        try decode(try await request(method, path, body: body))
    }

    func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw CrateError.transport("Unexpected answer from Crate (\(error))")
        }
    }

    // MARK: - server

    /// Is this Crate, and does it want a token? Works without one.
    public func ping() async throws -> Ping {
        do {
            let p: Ping = try await get("/api/ping")
            guard p.app == "crate" else { throw CrateError.notCrate }
            return p
        } catch CrateError.server(let status, _) where status == 404 {
            // Crate from before the companion app: no /api/ping, but /api/status exists
            throw CrateError.server(status: 404, detail: "This Crate server is too old for the app. Update it to the latest image.")
        }
    }

    public func info() async throws -> ServerInfo { try await get("/api/info") }
    public func status() async throws -> Status { try await get("/api/status") }
    public func health() async throws -> [String: HealthCheck] { try await get("/api/health") }

    // MARK: - playlists

    public func playlists() async throws -> [Playlist] { try await get("/api/playlists") }
    public func playlist(_ key: String) async throws -> Playlist { try await get("/api/playlists/\(key.addingPathEscapes)") }
    public func ownPlaylists() async throws -> [OwnPlaylist] { try await get("/api/own-playlists") }

    public func ownPlaylistTracks(_ navidromeId: String) async throws -> [Track] {
        try await get("/api/own-playlists/\(navidromeId.addingPathEscapes)")
    }

    /// Tracks for any playlist key: Crate's own, or "nd:<id>" for yours.
    public func tracks(forKey key: String) async throws -> [Track] {
        key.hasPrefix("nd:") ? try await ownPlaylistTracks(String(key.dropFirst(3))) : try await playlist(key).tracks
    }

    public func removeDuplicatePlaylists() async throws -> Started { try await send("POST", "/api/playlists/tidy") }

    // MARK: - suggestions

    /// Cached suggestions; asking also starts working them out if there are none or they're old.
    public func suggestions(_ key: String) async throws -> Suggestions {
        try await get("/api/playlists/\(key.addingPathEscapes)/suggestions")
    }

    /// A different batch: what's showing now is left out.
    public func refreshSuggestions(_ key: String, excluding shown: [Suggestion]) async throws {
        let ids = shown.map { $0.kind == .library ? ($0.songId ?? "") : String($0.deezerId ?? 0) }
        _ = try await request("POST", "/api/playlists/\(key.addingPathEscapes)/suggestions", body: ["exclude": ids])
    }

    /// Library songs go in straight away; new songs are downloaded first (follow the run).
    public func add(_ s: Suggestion, to key: String) async throws -> Started {
        let body: [String: JSONValue] = s.kind == .library
            ? ["song_id": .string(s.songId ?? "")] : ["deezer_id": .int(s.deezerId ?? 0)]
        return try await send("POST", "/api/playlists/\(key.addingPathEscapes)/add", body: body)
    }

    /// Add a song you have to any playlist. An inbox track is kept first (runId to follow).
    public func addLibrarySong(_ songId: String, to key: String) async throws -> Started {
        try await send("POST", "/api/playlists/\(key.addingPathEscapes)/add", body: ["song_id": songId])
    }

    /// A new song into a playlist: downloaded into your library, then added (follow the run).
    public func addNewSong(deezerId: Int, to key: String) async throws -> Started {
        try await send("POST", "/api/playlists/\(key.addingPathEscapes)/add", body: ["deezer_id": deezerId])
    }

    /// A new playlist of your own in Navidrome, optionally starting with a song you have or a new one.
    public func createPlaylist(named name: String, with songId: String? = nil, deezerId: Int? = nil) async throws -> CreatedPlaylist {
        var body: [String: JSONValue] = ["name": .string(name)]
        if let songId { body["song_id"] = .string(songId) }
        if let deezerId { body["deezer_id"] = .int(deezerId) }
        return try await send("POST", "/api/own-playlists", body: body)
    }

    /// Take a song you added back out ("Take out").
    public func takeOut(_ songId: String, from key: String) async throws {
        _ = try await request("POST", "/api/playlists/\(key.addingPathEscapes)/remove", body: ["song_id": songId])
    }

    /// 👎. New songs: never suggested again, artist ranked lower, similar sounds ranked lower.
    /// Library songs: hidden from this playlist's suggestions only.
    public func dislike(_ s: Suggestion, in key: String) async throws {
        _ = try await request("POST", "/api/playlists/\(key.addingPathEscapes)/dislike", body: s.feedback)
    }

    public func undoDislike(_ s: Suggestion, in key: String) async throws {
        _ = try await request("POST", "/api/playlists/\(key.addingPathEscapes)/undislike", body: s.feedback)
    }

    // MARK: - songs: keep, remove, like

    /// Star it; an inbox track also moves into your library.
    public func keep(_ songId: String) async throws -> Started { try await send("POST", "/api/songs/\(songId.addingPathEscapes)/keep") }

    /// Delete a song's file from your music library for good (follow the run). An inbox track
    /// is just removed.
    public func deleteFromLibrary(_ songId: String) async throws -> Started {
        try await send("POST", "/api/songs/\(songId.addingPathEscapes)/delete")
    }

    /// Delete an inbox track now.
    public func remove(_ songId: String) async throws -> Started { try await send("POST", "/api/songs/\(songId.addingPathEscapes)/remove") }

    /// Heart and stars. Set in Navidrome now; inbox tracks are kept (star, 4-5) or removed (1-2) by
    /// a job whose run id comes back.
    /// addTo: liking a song suggested for one of your playlists also adds it there.
    public func like(_ songId: String, starred: Bool? = nil, rating: Int? = nil, addTo playlistKey: String? = nil) async throws -> Started {
        var body: [String: JSONValue] = [:]
        if let starred { body["starred"] = .bool(starred) }
        if let playlistKey { body["playlist_key"] = .string(playlistKey) }
        if let rating { body["rating"] = .int(rating) }
        return try await send("POST", "/api/songs/\(songId.addingPathEscapes)/like", body: body)
    }

    // MARK: - jobs and runs

    /// Regenerate: discover, release_radar, daily_mix, library, likes, ...
    public func runNow(_ job: String) async throws -> Started { try await send("POST", "/api/run/\(job.addingPathEscapes)") }
    public func runs(limit: Int = 30) async throws -> [Run] { try await get("/api/runs?limit=\(limit)") }
    public func run(_ id: Int) async throws -> Run { try await get("/api/runs/\(id)") }
    public func stopAll() async throws -> CancelResult { try await send("POST", "/api/jobs/cancel") }

    /// Polls a run until it's finished (or the task is cancelled).
    public func waitFor(run id: Int, every seconds: Double = 2) async throws -> Run {
        while true {
            let r = try await run(id)
            if !r.isActive { return r }
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    }

    // MARK: - search and adds

    public func search(_ q: String) async throws -> SearchResults {
        try await get("/api/search?q=\(q.addingQueryEscapes)")
    }

    public func album(_ deezerId: Int) async throws -> AlbumDetail { try await get("/api/albums/\(deezerId)") }

    /// Download a song into your library; with a playlist key, it then goes into that playlist too.
    public func want(track deezerId: Int, playlistKey: String? = nil) async throws -> Started {
        var body: [String: JSONValue] = ["kind": .string("track"), "deezer_id": .int(deezerId)]
        if let playlistKey { body["playlist_key"] = .string(playlistKey) }
        return try await send("POST", "/api/wants", body: body)
    }

    public func want(album deezerId: Int) async throws -> Started {
        try await send("POST", "/api/wants", body: ["kind": JSONValue.string("album"), "deezer_id": .int(deezerId)])
    }

    public func wants(limit: Int = 100) async throws -> [Want] { try await get("/api/wants?limit=\(limit)") }

    // MARK: - prompt playlists

    public func prompts() async throws -> [PromptPlaylist] { try await get("/api/prompts") }
    public func createPrompt(_ p: NewPrompt) async throws -> Started { try await send("POST", "/api/prompts", body: p) }
    public func rerunPrompt(_ id: Int) async throws -> Started { try await send("POST", "/api/prompts/\(id)/run") }

    public func setAutoRefresh(_ id: Int, _ on: Bool) async throws {
        _ = try await request("PATCH", "/api/prompts/\(id)?auto_refresh=\(on)")
    }

    /// Stop managing it. The playlist stays in Navidrome; unliked new tracks are deleted.
    /// Stop managing it. The Navidrome playlist stays unless deletePlaylist is set.
    public func forgetPrompt(_ id: Int, deletePlaylist: Bool = false) async throws {
        _ = try await request("DELETE", "/api/prompts/\(id)" + (deletePlaylist ? "?delete_playlist=true" : ""))
    }

    /// Delete one of your own Navidrome playlists. The songs stay in your library.
    public func deleteOwnPlaylist(_ navidromeId: String) async throws {
        _ = try await request("DELETE", "/api/own-playlists/\(navidromeId.addingPathEscapes)")
    }

    // MARK: - activity

    public func inbox(limit: Int = 50) async throws -> [InboxDecision] { try await get("/api/inbox?limit=\(limit)") }
    public func historySummary() async throws -> HistorySummary { try await get("/api/history/summary") }

    public func clearHistory(keepDislikes: Bool) async throws -> Started {
        try await send("POST", "/api/history/reset", body: ["keep_dislikes": keepDislikes])
    }
}

private struct Detail: Decodable {
    let text: String
    enum CodingKeys: String, CodingKey { case detail }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .detail) { text = s; return }
        // FastAPI validation errors: [{"msg": ...}, ...]
        struct Item: Decodable { let msg: String }
        text = (try c.decode([Item].self, forKey: .detail)).map(\.msg).joined(separator: "; ")
    }
}

extension String {
    var addingPathEscapes: String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }

    var addingQueryEscapes: String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
