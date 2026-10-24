import Foundation
import XCTest
@testable import CrateKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fixtures are real answers from Crate's API (generated with FastAPI's test client against a
/// seeded database), so these tests catch the app and the server drifting apart.
func fixture(_ name: String) throws -> Data {
    // read from beside this file rather than as a bundle resource, so it works the same everywhere
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures").appendingPathComponent(name + ".json")
    return try Data(contentsOf: url)
}

final class DecodingTests: XCTestCase {
    let api = CrateAPI(baseURL: URL(string: "http://crate.local:8090")!, token: "tok")

    func testPingAndInfo() throws {
        let p: Ping = try api.decode(fixture("ping"))
        XCTAssertEqual(p.app, "crate")
        XCTAssertTrue(p.authRequired)
        let i: ServerInfo = try api.decode(fixture("info"))
        XCTAssertEqual(i.navidrome.url, "https://music.example.com")
        XCTAssertEqual(i.navidrome.user, "jared")
        XCTAssertEqual(i.jobs["release_radar"], "Release Radar")  // dictionary keys left alone
    }

    func testStatus() throws {
        let s: Status = try api.decode(fixture("status"))
        XCTAssertEqual(s.jobs["discover"]?.last?.summary, "30 tracks")
        XCTAssertNil(s.jobs["release_radar"]?.last)
        XCTAssertEqual(s.inbox.new, 1)
        XCTAssertEqual(s.busy.first?.kind, "prompt:1")
        XCTAssertNotNil(s.nextRun("discover"))
        XCTAssertNil(s.nextRun("daily_mix"))
    }

    func testPlaylists() throws {
        let pls: [Playlist] = try api.decode(fixture("playlists"))
        let discover = try XCTUnwrap(pls.first { $0.key == "discover_weekly" })
        XCTAssertEqual(discover.kind, .discover)
        XCTAssertEqual(discover.kind.job(key: discover.key), "discover")
        XCTAssertEqual(discover.tracks.count, 2)
        XCTAssertTrue(discover.tracks[0].starred)
        XCTAssertEqual(discover.tracks[0].rating, 4)
        XCTAssertEqual(discover.tracks[1].state, .new)
        XCTAssertEqual(discover.newCount, 1)
        let mix = try XCTUnwrap(pls.first { $0.key == "daily_mix_1" })
        XCTAssertEqual(mix.kind.job(key: mix.key), "daily_mix")
        XCTAssertTrue(mix.tracks[0].addedByYou)
    }

    func testSuggestions() throws {
        let s: Suggestions = try api.decode(fixture("suggestions"))
        XCTAssertEqual(s.items.count, 2)
        XCTAssertEqual(s.items[0].kind, .new)
        XCTAssertEqual(s.items[0].deezerId, 916424)
        XCTAssertEqual(s.items[1].kind, .library)
        XCTAssertEqual(s.items[1].feedback["song_id"], .string("s7"))
        XCTAssertNil(s.items[1].feedback["deezer_id"])
    }

    func testActivityShapes() throws {
        let runs: [Run] = try api.decode(fixture("runs"))
        XCTAssertTrue(runs.contains { $0.isActive })
        let prompts: [PromptPlaylist] = try api.decode(fixture("prompts"))
        XCTAssertEqual(prompts.first?.autoRefresh, true)
        XCTAssertEqual(prompts.first?.playlistKey, "prompt_1")
        let inbox: [InboxDecision] = try api.decode(fixture("inbox"))
        XCTAssertEqual(inbox.first?.status, "kept")
        let h: HistorySummary = try api.decode(fixture("history_summary"))
        XCTAssertEqual(h.inInbox, 1)
        let wants: [Want] = try api.decode(fixture("wants"))
        XCTAssertTrue(wants.first?.succeeded ?? false)
    }
}

final class URLTests: XCTestCase {
    func testNormalise() {
        XCTAssertEqual(CrateAPI.normalise("crate.local:8090/")?.absoluteString, "http://crate.local:8090")
        XCTAssertEqual(CrateAPI.normalise(" https://crate.example.com/sub/ ")?.absoluteString, "https://crate.example.com/sub")
        XCTAssertNil(CrateAPI.normalise(""))
    }

    func testURLs() {
        let api = CrateAPI(baseURL: URL(string: "https://x.example.com/crate")!, token: "a b+c")
        XCTAssertEqual(api.url("/api/playlists/\("nd:12 3".addingPathEscapes)/suggestions").absoluteString,
                       "https://x.example.com/crate/api/playlists/nd:12%203/suggestions")
        XCTAssertEqual(api.url("/api/search?q=\("AC/DC & co+".addingQueryEscapes)").absoluteString,
                       "https://x.example.com/crate/api/search?q=AC/DC%20%26%20co%2B")
        XCTAssertEqual(api.mediaURL("/api/preview/s1")?.absoluteString,
                       "https://x.example.com/crate/api/preview/s1?token=a%20b%2Bc")
        XCTAssertEqual(api.coverURL(songId: "s1", size: 100)?.absoluteString,
                       "https://x.example.com/crate/api/cover/s1?size=100&token=a%20b%2Bc")
        XCTAssertEqual(api.mediaURL("https://cdn.example.com/p.mp3")?.absoluteString, "https://cdn.example.com/p.mp3")
    }

    func testSubsonicAuth() {
        XCTAssertEqual(MD5.hex(""), "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(MD5.hex("abc"), "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(MD5.hex("The quick brown fox jumps over the lazy dog"), "9e107d9d372bb6826bd81d3542a419d6")
        // the example from the Subsonic API docs
        XCTAssertEqual(MD5.hex("sesame" + "c19b2d"), "26719a1196d2a940705a59634eb18eab")
        let nd = Subsonic(baseURL: URL(string: "https://music.example.com")!, user: "jared", password: "pw")
        let url = nd.streamURL(songId: "s1").absoluteString
        XCTAssertTrue(url.hasPrefix("https://music.example.com/rest/stream?u=jared&t="))
        XCTAssertTrue(url.contains("&format=raw&id=s1"))
        XCTAssertFalse(url.contains("pw"))
    }
}

/// Answers every request with one canned response, and remembers the last request.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    let status: Int
    let body: String
    var last: URLRequest?
    init(_ status: Int, _ body: String) { self.status = status; self.body = body }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        last = request
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

final class ClientTests: XCTestCase {
    func api(_ t: StubTransport) -> CrateAPI { CrateAPI(baseURL: URL(string: "http://c:8090")!, token: "tok", transport: t) }

    func testSendsTokenAndBody() async throws {
        let t = StubTransport(200, #"{"ok": true, "run_id": 7}"#)
        let started = try await api(t).like("s1", starred: true, rating: 5)
        XCTAssertEqual(started.runId, 7)
        XCTAssertEqual(t.last?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(t.last?.httpMethod, "POST")
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(t.last?.httpBody)) as? [String: Any]
        XCTAssertEqual(body?["starred"] as? Bool, true)
        XCTAssertEqual(body?["rating"] as? Int, 5)
    }

    func testErrors() async {
        do { _ = try await api(StubTransport(401, #"{"detail": "API token required"}"#)).status(); XCTFail() }
        catch { XCTAssertEqual(error as? CrateError, .unauthorized) }
        do { _ = try await api(StubTransport(400, #"{"detail": "Nothing to add"}"#)).keep("x"); XCTFail() }
        catch { XCTAssertEqual(error.localizedDescription, "Nothing to add") }
        do {
            _ = try await api(StubTransport(422, #"{"detail": [{"msg": "too short"}, {"msg": "too big"}]}"#))
                .createPrompt(NewPrompt(prompt: "x"))
            XCTFail()
        } catch { XCTAssertEqual(error.localizedDescription, "too short; too big") }
        do { _ = try await api(StubTransport(200, #"{"app": "jellyfin", "api": 1, "auth_required": false}"#)).ping(); XCTFail() }
        catch { XCTAssertEqual(error as? CrateError, .notCrate) }
    }

    func testAddToPlaylist() async throws {
        let t = StubTransport(200, #"{"added": false, "keeping": true, "run_id": 3}"#)
        let r = try await api(t).addLibrarySong("ib1", to: "nd:p9")
        XCTAssertEqual(r.keeping, true)
        XCTAssertEqual(t.last?.url?.path, "/api/playlists/nd:p9/add")
        let c = StubTransport(200, #"{"key": "nd:p9", "navidrome_id": "p9", "name": "Road trip", "added": true}"#)
        let made = try await api(c).createPlaylist(named: "Road trip", with: "s1")
        XCTAssertEqual(made.key, "nd:p9")
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(c.last?.httpBody)) as? [String: String]
        XCTAssertEqual(body, ["name": "Road trip", "song_id": "s1"])
    }

    func testRefreshSendsShownIds() async throws {
        let t = StubTransport(200, #"{"status": "working"}"#)
        let s: Suggestions = try api(t).decode(fixture("suggestions"))
        try await api(t).refreshSuggestions("discover_weekly", excluding: s.items)
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(t.last?.httpBody)) as? [String: [String]]
        XCTAssertEqual(body?["exclude"], ["916424", "s7"])
    }
}

final class QueueTests: XCTestCase {
    func items(_ n: Int) -> [PlayableItem] {
        (0..<n).map {
            PlayableItem(id: "t:\($0)", source: .library(songId: "\($0)"), title: "T\($0)", artist: "A", album: "",
                         duration: 100, streamURL: URL(string: "http://x/\($0)")!, artworkURL: nil, playlistKey: nil,
                         isInbox: false, starred: false, rating: 0)
        }
    }

    func testAdvanceAndRepeat() {
        var q = PlayQueue()
        q.replace(with: items(3), startAt: 1)
        XCTAssertEqual(q.current?.id, "t:1")
        XCTAssertEqual(q.advance(userInitiated: false)?.id, "t:2")
        XCTAssertNil(q.advance(userInitiated: false))
        q.repeatMode = .all
        XCTAssertEqual(q.advance(userInitiated: false)?.id, "t:0")
        q.repeatMode = .one
        XCTAssertEqual(q.advance(userInitiated: false)?.id, "t:0")
        XCTAssertEqual(q.advance(userInitiated: true)?.id, "t:1")
        XCTAssertEqual(q.back()?.id, "t:0")
    }

    func testShuffleKeepsCurrent() {
        var q = PlayQueue()
        q.replace(with: items(20), startAt: 5)
        q.setShuffle(true)
        XCTAssertEqual(q.current?.id, "t:5")
        XCTAssertEqual(q.items.count, 20)
        q.advance(userInitiated: true)
        let cur = q.current?.id
        q.setShuffle(false)
        XCTAssertEqual(q.current?.id, cur)
        XCTAssertEqual(q.items.map(\.id), items(20).map(\.id))
    }

    func testUpdateAndRemove() {
        var q = PlayQueue()
        q.replace(with: items(3))
        q.update(songId: "2") { $0.starred = true }
        XCTAssertTrue(q.items[2].starred)
        q.remove(id: "t:0")  // current: ignored
        XCTAssertEqual(q.items.count, 3)
        q.advance(userInitiated: true)
        q.remove(id: "t:0")
        XCTAssertEqual(q.current?.id, "t:1")
        XCTAssertEqual(q.items.count, 2)
    }
}
