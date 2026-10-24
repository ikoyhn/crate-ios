import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The few Subsonic calls the app makes to Navidrome itself: full-quality streams, cover art, and
/// scrobbles so plays count. Everything about curation goes through Crate instead.
public struct Subsonic: Sendable {
    public let baseURL: URL
    public let user: String
    let password: String
    let transport: HTTPTransport
    let client = "crate-ios"

    public init(baseURL: URL, user: String, password: String, transport: HTTPTransport = URLSessionTransport()) {
        self.baseURL = baseURL
        self.user = user
        self.password = password
        self.transport = transport
    }

    /// Token auth (salted MD5 of the password), so the password itself never travels.
    func authItems(salt: String = Subsonic.newSalt()) -> [URLQueryItem] {
        [
            URLQueryItem(name: "u", value: user),
            URLQueryItem(name: "t", value: MD5.hex(password + salt)),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: "1.16.1"),
            URLQueryItem(name: "c", value: client),
            URLQueryItem(name: "f", value: "json"),
        ]
    }

    static func newSalt() -> String {
        (0..<12).map { _ in String("abcdefghijklmnopqrstuvwxyz0123456789".randomElement()!) }.joined()
    }

    public func url(_ method: String, _ params: [String: String] = [:]) -> URL {
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        var base = comps.path
        if base.hasSuffix("/") { base.removeLast() }
        comps.path = base + "/rest/" + method
        comps.queryItems = authItems() + params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        // "+" in a query item isn't escaped by URLComponents, but servers read it as a space
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return comps.url!
    }

    /// maxBitRate 0 = original file. format=raw keeps seeking fast.
    public func streamURL(songId: String, maxBitRate: Int = 0) -> URL {
        maxBitRate > 0 ? url("stream", ["id": songId, "maxBitRate": String(maxBitRate), "format": "mp3"])
                       : url("stream", ["id": songId, "format": "raw"])
    }

    public func coverURL(id: String, size: Int = 600) -> URL {
        url("getCoverArt", ["id": id, "size": String(size)])
    }

    @discardableResult
    func call(_ method: String, _ params: [String: String] = [:]) async throws -> Data {
        var req = URLRequest(url: url(method, params))
        req.timeoutInterval = 30
        let (data, resp) = try await transport.send(req)
        guard resp.statusCode == 200 else { throw CrateError.server(status: resp.statusCode, detail: "Navidrome answered \(resp.statusCode)") }
        struct Envelope: Decodable {
            struct Body: Decodable {
                struct Err: Decodable { let message: String? }
                let status: String
                let error: Err?
            }
            let body: Body
            enum CodingKeys: String, CodingKey { case body = "subsonic-response" }
        }
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw CrateError.transport("That address didn't answer like Navidrome")
        }
        guard env.body.status == "ok" else {
            throw CrateError.server(status: 200, detail: env.body.error?.message ?? "Navidrome refused")
        }
        return data
    }

    public func ping() async throws { try await call("ping") }

    /// submission false = "now playing"; true = a finished listen.
    public func scrobble(songId: String, submission: Bool, at: Date = Date()) async throws {
        try await call("scrobble", ["id": songId, "submission": String(submission),
                                    "time": String(Int64(at.timeIntervalSince1970 * 1000))])
    }

    /// Every song you've starred (♥), most recently starred first.
    public func starredSongs() async throws -> [Track] {
        struct Body: Decodable {
            struct Starred: Decodable { let song: [SubsonicSong]? }
            let starred2: Starred?
        }
        let songs = try await decode(Body.self, call("getStarred2")).starred2?.song ?? []
        // ISO 8601 dates in one format, so they sort as text
        return tracks(songs.sorted { ($0.starred ?? "") > ($1.starred ?? "") })
    }

    /// Albums for Home. type: recent (recently played), newest (recently added), frequent, random, highest.
    public func albums(_ type: String, size: Int = 20) async throws -> [NavidromeAlbum] {
        struct Body: Decodable {
            struct List: Decodable { let album: [NavidromeAlbum]? }
            let albumList2: List?
        }
        return try await decode(Body.self, call("getAlbumList2", ["type": type, "size": String(size)])).albumList2?.album ?? []
    }

    /// An album's songs, in disc and track order.
    public func albumSongs(_ albumId: String) async throws -> [Track] {
        struct Body: Decodable {
            struct Album: Decodable { let song: [SubsonicSong]? }
            let album: Album?
        }
        return tracks(try await decode(Body.self, call("getAlbum", ["id": albumId])).album?.song ?? [])
    }

    /// Songs like this one (needs an agent such as Last.fm set up in Navidrome; empty otherwise).
    public func similarSongs(_ songId: String, count: Int = 20) async throws -> [Track] {
        struct Body: Decodable {
            struct List: Decodable { let song: [SubsonicSong]? }
            let similarSongs2: List?
        }
        return tracks(try await decode(Body.self, call("getSimilarSongs2", ["id": songId, "count": String(count)])).similarSongs2?.song ?? [])
    }

    public func randomSongs(count: Int = 20) async throws -> [Track] {
        struct Body: Decodable {
            struct List: Decodable { let song: [SubsonicSong]? }
            let randomSongs: List?
        }
        return tracks(try await decode(Body.self, call("getRandomSongs", ["size": String(count)])).randomSongs?.song ?? [])
    }

    /// Cover art ids of the first `limit` different albums in a playlist, for its tiled icon.
    public func playlistCovers(_ playlistId: String, limit: Int = 4) async throws -> [String] {
        struct Body: Decodable {
            struct Playlist: Decodable { let entry: [SubsonicSong]? }
            let playlist: Playlist?
        }
        var seen = Set<String>(), covers: [String] = []
        for song in try await decode(Body.self, call("getPlaylist", ["id": playlistId])).playlist?.entry ?? [] {
            guard let cover = song.coverArt ?? song.albumId, seen.insert(song.albumId ?? cover).inserted else { continue }
            covers.append(cover)
            if covers.count == limit { break }
        }
        return covers
    }

    /// Your most played songs and the songs you played last. Subsonic has neither, so this uses
    /// Navidrome's own API (the one its web UI uses), signing in with the same user.
    public func playStats(count: Int = 20) async throws -> PlayStats {
        var login = URLRequest(url: baseURL.appendingPathComponent("auth/login"))
        login.httpMethod = "POST"
        login.timeoutInterval = 30
        login.setValue("application/json", forHTTPHeaderField: "Content-Type")
        login.httpBody = try JSONEncoder().encode(["username": user, "password": password])
        let (data, resp) = try await transport.send(login)
        struct Session: Decodable { let token: String }
        guard resp.statusCode == 200, let token = try? JSONDecoder().decode(Session.self, from: data).token else {
            throw CrateError.server(status: resp.statusCode, detail: "Navidrome didn't accept the sign-in for play history")
        }

        async let top = nativeSongs(token: token, sortedBy: "play_count", count: count)
        async let recent = nativeSongs(token: token, sortedBy: "play_date", count: count)
        func played(_ songs: [NativeSong]) -> [Track] {
            songs.filter { ($0.playCount ?? 0) > 0 }.enumerated().map { i, s in
                Track(pos: i, songId: s.id, artist: s.artist ?? "", title: s.title ?? "", album: s.album ?? "",
                      starred: s.starred ?? false, rating: s.rating ?? 0, plays: s.playCount ?? 0,
                      duration: Int(s.duration ?? 0))
            }
        }
        return PlayStats(top: played(try await top), recent: played(try await recent))
    }

    func nativeSongs(token: String, sortedBy sort: String, count: Int) async throws -> [NativeSong] {
        var comps = URLComponents(url: baseURL.appendingPathComponent("api/song"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "_sort", value: sort), URLQueryItem(name: "_order", value: "DESC"),
                            URLQueryItem(name: "_start", value: "0"), URLQueryItem(name: "_end", value: String(count))]
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 30
        req.setValue("Bearer \(token)", forHTTPHeaderField: "X-ND-Authorization")
        let (data, resp) = try await transport.send(req)
        guard resp.statusCode == 200 else {
            throw CrateError.server(status: resp.statusCode, detail: "Navidrome answered \(resp.statusCode)")
        }
        return try JSONDecoder().decode([NativeSong].self, from: data)
    }

    // MARK: - decoding

    func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        try JSONDecoder().decode(SubsonicEnvelope<T>.self, from: data).body
    }

    func tracks(_ songs: [SubsonicSong]) -> [Track] {
        songs.enumerated().map { i, s in
            Track(pos: i, songId: s.id, artist: s.artist ?? "", title: s.title ?? "", album: s.album ?? "",
                  starred: s.starred != nil, rating: s.userRating ?? 0, plays: s.playCount ?? 0, duration: s.duration ?? 0)
        }
    }
}

struct SubsonicEnvelope<T: Decodable>: Decodable {
    let body: T
    enum CodingKeys: String, CodingKey { case body = "subsonic-response" }
}

/// A song as Subsonic describes it.
struct SubsonicSong: Decodable {
    let id: String
    let title: String?
    let artist: String?
    let album: String?
    let albumId: String?
    let coverArt: String?
    let duration: Int?
    let starred: String?
    let userRating: Int?
    let playCount: Int?
}

/// A song from Navidrome's own API.
struct NativeSong: Decodable, Sendable {
    let id: String
    let title: String?
    let artist: String?
    let album: String?
    let duration: Double?
    let playCount: Int?
    let starred: Bool?
    let rating: Int?
}

public struct NavidromeAlbum: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let artist: String?
    public let coverArt: String?
    public let year: Int?
    public let songCount: Int?
}

public struct PlayStats: Sendable {
    public let top: [Track]
    public let recent: [Track]
}

/// RFC 1321 MD5, only for Subsonic's token auth (CryptoKit's Insecure.MD5 isn't on Linux).
enum MD5 {
    static func hex(_ string: String) -> String {
        digest(Array(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func digest(_ message: [UInt8]) -> [UInt8] {
        let s: [UInt32] = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
                           5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
                           4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
                           6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21]
        let k: [UInt32] = (0..<64).map { UInt32(truncatingIfNeeded: Int64(abs(sin(Double($0 + 1))) * 4294967296.0)) }
        var a0: UInt32 = 0x67452301, b0: UInt32 = 0xefcdab89, c0: UInt32 = 0x98badcfe, d0: UInt32 = 0x10325476

        var msg = message
        let bitLength = UInt64(message.count) &* 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in 0..<8 { msg.append(UInt8(truncatingIfNeeded: bitLength >> (8 * UInt64(i)))) }

        for chunk in stride(from: 0, to: msg.count, by: 64) {
            var m = [UInt32](repeating: 0, count: 16)
            for i in 0..<16 {
                let b = chunk + i * 4
                m[i] = UInt32(msg[b]) | UInt32(msg[b + 1]) << 8 | UInt32(msg[b + 2]) << 16 | UInt32(msg[b + 3]) << 24
            }
            var a = a0, b = b0, c = c0, d = d0
            for i in 0..<64 {
                var f: UInt32, g: Int
                switch i {
                case 0..<16: f = (b & c) | (~b & d); g = i
                case 16..<32: f = (d & b) | (~d & c); g = (5 * i + 1) % 16
                case 32..<48: f = b ^ c ^ d; g = (3 * i + 5) % 16
                default: f = c ^ (b | ~d); g = (7 * i) % 16
                }
                f = f &+ a &+ k[i] &+ m[g]
                a = d; d = c; c = b
                b = b &+ (f << s[i] | f >> (32 - s[i]))
            }
            a0 = a0 &+ a; b0 = b0 &+ b; c0 = c0 &+ c; d0 = d0 &+ d
        }
        return [a0, b0, c0, d0].flatMap { v in (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * UInt32($0))) } }
    }
}
