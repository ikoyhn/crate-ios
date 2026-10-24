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

    func call(_ method: String, _ params: [String: String] = [:]) async throws {
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
    }

    public func ping() async throws { try await call("ping") }

    /// submission false = "now playing"; true = a finished listen.
    public func scrobble(songId: String, submission: Bool, at: Date = Date()) async throws {
        try await call("scrobble", ["id": songId, "submission": String(submission),
                                    "time": String(Int64(at.timeIntervalSince1970 * 1000))])
    }
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
