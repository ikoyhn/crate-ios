import Foundation

// Shapes of Crate's JSON API (see crate/app/main.py). Crate's JSON uses snake_case; the keys are
// mapped by hand rather than with .convertFromSnakeCase, because that strategy also rewrites
// dictionary keys ("release_radar" -> "releaseRadar") and Crate uses job names as keys.

// MARK: - Server

public struct Ping: Codable, Sendable {
    public let app: String
    public let api: Int
    public let authRequired: Bool
    enum CodingKeys: String, CodingKey { case app, api, authRequired = "auth_required" }
}

public struct ServerInfo: Codable, Sendable {
    public struct NavidromeInfo: Codable, Sendable {
        public let url: String
        public let user: String
        public let publicUrlSet: Bool
        enum CodingKeys: String, CodingKey { case url, user, publicUrlSet = "public_url_set" }
    }
    public struct Features: Codable, Sendable {
        public let radio: Bool
        public let soulseek: Bool
        public let deleteUnliked: Bool
        enum CodingKeys: String, CodingKey { case radio, soulseek, deleteUnliked = "delete_unliked" }
    }
    public let app: String
    public let api: Int
    public let navidrome: NavidromeInfo
    public let jobs: [String: String]
    public let features: Features
}

public struct Status: Codable, Sendable {
    public struct Library: Codable, Sendable {
        public let songs: Int
        public let embedded: Int
    }
    public struct Job: Codable, Sendable {
        public let label: String
        public let last: Run?
    }
    public struct Busy: Codable, Sendable, Hashable {
        public let kind: String
        public let status: String
        public let started: Double?
    }
    public struct Inbox: Codable, Sendable {
        public let new: Int
        public let kept30d: Int
        public let removed30d: Int
        enum CodingKeys: String, CodingKey { case new, kept30d = "kept_30d", removed30d = "removed_30d" }
    }
    public let library: Library
    public let jobs: [String: Job]
    public let next: [String: String?]
    public let busy: [Busy]
    public let inbox: Inbox
    public let radioConfigured: Bool
    enum CodingKeys: String, CodingKey { case library, jobs, next, busy, inbox, radioConfigured = "radio_configured" }

    /// When a scheduled job runs next, if it's scheduled.
    public func nextRun(_ kind: String) -> Date? {
        guard let iso = next[kind] ?? nil else { return nil }
        return ISO8601DateFormatter.crate.date(from: iso)
    }
}

public struct HealthCheck: Codable, Sendable {
    public let ok: Bool
    public let detail: String
    enum CodingKeys: String, CodingKey { case ok, detail }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decode(Bool.self, forKey: .ok)
        detail = (try? c.decode(LossyString.self, forKey: .detail))?.value ?? ""
    }
}

// MARK: - Runs

public struct Run: Codable, Sendable, Identifiable, Hashable {
    public let id: Int
    public let kind: String
    public let started: Double?
    public let finished: Double?
    public let status: String
    public let summary: String?
    public let log: String?

    /// Still waiting or going.
    public var isActive: Bool { ["queued", "running", "stopping"].contains(status) }
    public var startedDate: Date? { started.map { Date(timeIntervalSince1970: $0) } }
    public var finishedDate: Date? { finished.map { Date(timeIntervalSince1970: $0) } }
}

/// What every action that starts a job answers with.
public struct Started: Codable, Sendable {
    public let runId: Int?
    public let queued: Int?
    public let id: Int?
    /// Adding an inbox track: Crate keeps it first, then adds it (follow runId).
    public let keeping: Bool?
    enum CodingKeys: String, CodingKey { case runId = "run_id", queued, id, keeping }
    public init(runId: Int?) { self.runId = runId; queued = nil; id = nil; keeping = nil }
}

public struct CreatedPlaylist: Codable, Sendable {
    public let key: String
    public let navidromeId: String
    public let name: String
    public let added: Bool?
    public let keeping: Bool?
    public let runId: Int?
    enum CodingKeys: String, CodingKey { case key, name, added, keeping, navidromeId = "navidrome_id", runId = "run_id" }
}

// MARK: - Playlists

public struct Playlist: Codable, Sendable, Identifiable, Hashable {
    public let key: String
    public let name: String
    public let comment: String?
    public let updatedAt: Double?
    public let navidromeId: String?
    public var tracks: [Track]
    public var id: String { key }
    enum CodingKeys: String, CodingKey {
        case key, name, comment, tracks, updatedAt = "updated_at", navidromeId = "navidrome_id"
    }

    /// Which family it belongs to, for grouping and icons.
    public var kind: PlaylistKind { PlaylistKind(key: key) }
    public var newCount: Int { tracks.filter { $0.state == .new }.count }
}

public enum PlaylistKind: Sendable, Hashable {
    case discover, releaseRadar, dailyMix, prompt, own, other

    public init(key: String) {
        switch true {
        case key == "discover_weekly", key == "discover": self = .discover
        case key == "release_radar": self = .releaseRadar
        case key.hasPrefix("daily_mix_"): self = .dailyMix
        case key.hasPrefix("prompt_"): self = .prompt
        case key.hasPrefix("nd:"): self = .own
        default: self = .other
        }
    }

    /// The job that rebuilds it ("Run now"), if one does.
    public func job(key: String) -> String? {
        switch self {
        case .discover: "discover"
        case .releaseRadar: "release_radar"
        case .dailyMix: "daily_mix"
        default: nil
        }
    }

    /// Prompt playlists are keyed prompt_<id>.
    public static func promptId(key: String) -> Int? {
        key.hasPrefix("prompt_") ? Int(key.dropFirst("prompt_".count)) : nil
    }
}

public enum TrackState: String, Codable, Sendable {
    case new, kept, library
    public init(from decoder: Decoder) throws {
        self = TrackState(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .library
    }
}

public struct Track: Codable, Sendable, Identifiable, Hashable {
    public let pos: Int
    public let songId: String
    public let artist: String
    public let title: String
    public let album: String
    public var state: TrackState
    public var liked: Bool
    public var starred: Bool
    public var rating: Int
    public let plays: Int
    public let duration: Int
    public var addedByYou: Bool
    public var id: String { "\(pos)-\(songId)" }

    enum CodingKeys: String, CodingKey {
        case pos, artist, title, album, state, liked, starred, rating, plays, duration
        case songId = "song_id", addedByYou = "added_by_you"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pos = try c.decode(Int.self, forKey: .pos)
        songId = try c.decode(String.self, forKey: .songId)
        artist = try c.decodeIfPresent(String.self, forKey: .artist) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        album = try c.decodeIfPresent(String.self, forKey: .album) ?? ""
        state = try c.decodeIfPresent(TrackState.self, forKey: .state) ?? .library
        liked = try c.decodeIfPresent(Bool.self, forKey: .liked) ?? false
        // older Crate servers only send "liked"
        starred = try c.decodeIfPresent(Bool.self, forKey: .starred) ?? liked
        rating = try c.decodeIfPresent(Int.self, forKey: .rating) ?? 0
        plays = try c.decodeIfPresent(Int.self, forKey: .plays) ?? 0
        duration = try c.decodeIfPresent(Int.self, forKey: .duration) ?? 0
        addedByYou = try c.decodeIfPresent(Bool.self, forKey: .addedByYou) ?? false
    }
}

/// A playlist you made in Navidrome. Its key is "nd:<navidrome id>".
public struct OwnPlaylist: Codable, Sendable, Identifiable, Hashable {
    public let key: String
    public let navidromeId: String
    public let name: String
    public let count: Int
    public let updated: String?
    public let readonly: Bool
    public let comment: String?
    public var id: String { key }
    enum CodingKeys: String, CodingKey { case key, name, count, updated, readonly, comment, navidromeId = "navidrome_id" }
}

// MARK: - Suggestions

public struct Suggestions: Codable, Sendable {
    public let status: String  // none | working | ready | failed
    public var items: [Suggestion]
    public let at: Double?
    public let error: String?
    public let stale: Bool?
    public var isWorking: Bool { status == "working" }
}

public struct Suggestion: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable { case new, library }
    public let kind: Kind
    public let songId: String?
    public let deezerId: Int?
    public let title: String
    public let artist: String
    public let album: String
    public let duration: Int
    /// Library songs: a Crate path (/api/preview/<id>). New songs: Deezer's 30 s preview URL.
    public let preview: String
    public let cover: String
    public let reason: String
    public var id: String { kind == .library ? "l:\(songId ?? "")" : "n:\(deezerId ?? 0)" }

    enum CodingKeys: String, CodingKey {
        case kind, title, artist, album, duration, preview, cover, reason
        case songId = "song_id", deezerId = "deezer_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        songId = try c.decodeIfPresent(String.self, forKey: .songId)
        deezerId = try c.decodeIfPresent(Int.self, forKey: .deezerId)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        artist = try c.decodeIfPresent(String.self, forKey: .artist) ?? ""
        album = try c.decodeIfPresent(String.self, forKey: .album) ?? ""
        duration = try c.decodeIfPresent(Int.self, forKey: .duration) ?? 0
        preview = try c.decodeIfPresent(String.self, forKey: .preview) ?? ""
        cover = try c.decodeIfPresent(String.self, forKey: .cover) ?? ""
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
    }

    /// What the 👎 / undo endpoints expect back.
    var feedback: [String: JSONValue] {
        var out: [String: JSONValue] = ["kind": .string(kind.rawValue), "artist": .string(artist), "title": .string(title)]
        if let songId { out["song_id"] = .string(songId) }
        if let deezerId { out["deezer_id"] = .int(deezerId) }
        return out
    }
}

// MARK: - Search and adds

public struct SearchResults: Codable, Sendable {
    public let tracks: [CatalogTrack]
    public let albums: [CatalogAlbum]
}

/// A track from Deezer's catalogue (search, album pages).
public struct CatalogTrack: Codable, Sendable, Identifiable, Hashable {
    public let deezerId: Int
    public let title: String
    public let artist: String
    public let album: String
    public let albumId: Int?
    public let cover: String
    public let duration: Int
    public let preview: String
    public let owned: Bool
    public var id: Int { deezerId }
    enum CodingKeys: String, CodingKey {
        case title, artist, album, cover, duration, preview, owned
        case deezerId = "deezer_id", albumId = "album_id"
    }
}

public struct CatalogAlbum: Codable, Sendable, Identifiable, Hashable {
    public let deezerId: Int
    public let title: String
    public let artist: String
    public let cover: String
    public let tracks: Int
    public let type: String
    public var id: Int { deezerId }
    enum CodingKeys: String, CodingKey { case title, artist, cover, tracks, type, deezerId = "deezer_id" }
}

public struct AlbumDetail: Codable, Sendable {
    public let deezerId: Int
    public let title: String?
    public let artist: String
    public let cover: String
    public let year: String
    public let tracks: [CatalogTrack]
    enum CodingKeys: String, CodingKey { case title, artist, cover, year, tracks, deezerId = "deezer_id" }
}

/// A one-off add (from Search, or a new song added from suggestions).
public struct Want: Codable, Sendable, Identifiable, Hashable {
    public let id: Int
    public let deezerId: Int?
    public let artist: String
    public let title: String
    public let album: String?
    public let albumId: Int?
    public let cover: String?
    public let status: String  // queued | downloading | ok | exists | failed
    public let detail: String?
    public let created: Double?
    public let done: Double?
    public let via: String?
    public let playlistKey: String?
    enum CodingKeys: String, CodingKey {
        case id, artist, title, album, cover, status, detail, created, done, via
        case deezerId = "deezer_id", albumId = "album_id", playlistKey = "playlist_key"
    }
    public var isBusy: Bool { status == "queued" || status == "downloading" }
    public var succeeded: Bool { status == "ok" || status == "exists" }
}

// MARK: - Prompt playlists

public struct PromptPlaylist: Codable, Sendable, Identifiable, Hashable {
    public let id: Int
    public let prompt: String
    public let size: Int
    public let newTracks: Int
    public let autoRefresh: Bool
    public let name: String?
    public let createdAt: Double?
    public let lastRun: Double?
    public var playlistKey: String { "prompt_\(id)" }

    enum CodingKeys: String, CodingKey {
        case id, prompt, size, name
        case newTracks = "new_tracks", autoRefresh = "auto_refresh", createdAt = "created_at", lastRun = "last_run"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        size = try c.decodeIfPresent(Int.self, forKey: .size) ?? 0
        newTracks = try c.decodeIfPresent(Int.self, forKey: .newTracks) ?? 0
        autoRefresh = (try c.decodeIfPresent(Int.self, forKey: .autoRefresh) ?? 0) != 0  // SQLite 0/1
        name = try c.decodeIfPresent(String.self, forKey: .name)
        createdAt = try c.decodeIfPresent(Double.self, forKey: .createdAt)
        lastRun = try c.decodeIfPresent(Double.self, forKey: .lastRun)
    }
}

public struct NewPrompt: Codable, Sendable {
    public var prompt: String
    public var size: Int
    public var newTracks: Int
    public var autoRefresh: Bool
    public init(prompt: String, size: Int = 30, newTracks: Int = 0, autoRefresh: Bool = false) {
        self.prompt = prompt; self.size = size; self.newTracks = newTracks; self.autoRefresh = autoRefresh
    }
    enum CodingKeys: String, CodingKey { case prompt, size, newTracks = "new_tracks", autoRefresh = "auto_refresh" }
}

// MARK: - Activity

public struct InboxDecision: Codable, Sendable, Hashable {
    public let artist: String
    public let title: String
    public let album: String?
    public let kind: String?
    public let status: String  // kept | removed
    public let reason: String?
    public let addedAt: Double?
    public let decidedAt: Double?
    enum CodingKeys: String, CodingKey {
        case artist, title, album, kind, status, reason, addedAt = "added_at", decidedAt = "decided_at"
    }
}

public struct HistorySummary: Codable, Sendable {
    public let blockedTracks: Int
    public let inInbox: Int
    public let stranded: Int
    public let dislikes: Int
    public let kept: Int
    public let recent: Int
    public let blockedArtists: Int
    public let loweredArtists: Int
    enum CodingKeys: String, CodingKey {
        case stranded, dislikes, kept, recent
        case blockedTracks = "blocked_tracks", inInbox = "in_inbox"
        case blockedArtists = "blocked_artists", loweredArtists = "lowered_artists"
    }
}

public struct CancelResult: Codable, Sendable {
    public let cancelled: Int
    public let stopping: Int
}

// MARK: - helpers

/// Decodes a string, number or bool as text (Crate's health details aren't always strings).
struct LossyString: Decodable {
    let value: String
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let b = try? c.decode(Bool.self) { value = b ? "ok" : "" }
        else if let d = try? c.decode(Double.self) { value = String(d) }
        else { value = "" }
    }
}

/// Just enough JSON to send free-form bodies.
public enum JSONValue: Codable, Sendable, Hashable {
    case string(String), int(Int), bool(Bool), array([JSONValue]), null

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        case .bool(let b): try c.encode(b)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .null }
    }
}

extension ISO8601DateFormatter {
    /// APScheduler's next_run_time.isoformat(): "2026-10-26T03:00:00+00:00", sometimes with fractions.
    nonisolated(unsafe) static let crate: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
