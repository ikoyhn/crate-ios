import CrateKit
import Foundation
import Observation

/// Where to find Crate and Navidrome. Secrets are kept in the Keychain, the rest in UserDefaults.
struct Connection: Codable, Equatable {
    var crateURL: String = ""
    var navidromeURL: String = ""
    var navidromeUser: String = ""
    /// Play from Navidrome (full quality, scrobbles). Off: stream through Crate at 128 kbps.
    var useNavidrome: Bool = true
    /// 0 = original quality.
    var maxBitRate: Int = 0

    static let key = "connection"

    static func load() -> Connection? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Connection.self, from: data)
    }

    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Connection.key) }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let text: String
    var undo: (@MainActor () -> Void)?
    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

/// A job started from the app (Run now, Add, Keep...), followed until it finishes.
struct TrackedRun: Identifiable, Equatable {
    let id: Int
    let label: String
}

@MainActor
@Observable
final class AppModel {
    var connection: Connection?
    private(set) var crate: CrateAPI?
    private(set) var resolver: MediaResolver?
    private(set) var info: ServerInfo?
    var status: Status?
    var toast: Toast?
    var tracked: [TrackedRun] = []
    /// Bumped whenever something finishes that could change what's on screen; views reload on it.
    var dataVersion = 0
    let player = AudioPlayer()

    @ObservationIgnored private var statusTask: Task<Void, Never>?

    init() {
        if let saved = Connection.load() {
            apply(saved, token: Keychain.get("crateToken") ?? "", password: Keychain.get("navidromePassword") ?? "")
        }
        player.onLike = { [weak self] item, starred in self?.setStar(item.songId, starred) }
    }

    var isConnected: Bool { crate != nil }

    // MARK: - connection

    func connect(_ c: Connection, token: String, password: String) {
        c.save()
        Keychain.set(token, for: "crateToken")
        Keychain.set(password, for: "navidromePassword")
        apply(c, token: token, password: password)
    }

    func signOut() {
        player.stop()
        statusTask?.cancel()
        UserDefaults.standard.removeObject(forKey: Connection.key)
        Keychain.set(nil, for: "crateToken")
        Keychain.set(nil, for: "navidromePassword")
        connection = nil; crate = nil; resolver = nil; info = nil; status = nil
    }

    private func apply(_ c: Connection, token: String, password: String) {
        guard let url = CrateAPI.normalise(c.crateURL) else { return }
        let api = CrateAPI(baseURL: url, token: token)
        var nd: Subsonic?
        if c.useNavidrome, let ndURL = CrateAPI.normalise(c.navidromeURL), !password.isEmpty {
            nd = Subsonic(baseURL: ndURL, user: c.navidromeUser, password: password)
        }
        connection = c
        crate = api
        resolver = MediaResolver(crate: api, navidrome: nd, maxBitRate: c.maxBitRate)
        player.navidrome = nd
        startStatusLoop()
        Task { info = try? await api.info() }
    }

    /// Keeps the busy banner and job list current: every 4 s while something runs, else every 30 s.
    private func startStatusLoop() {
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let api = self.crate else { return }
                if let s = try? await api.status() { self.status = s }
                let busy = !(self.status?.busy.isEmpty ?? true)
                try? await Task.sleep(nanoseconds: (busy ? 4 : 30) * 1_000_000_000)
            }
        }
    }

    func refreshStatus() async {
        if let api = crate, let s = try? await api.status() { status = s }
    }

    // MARK: - feedback

    func say(_ text: String, undo: (@MainActor () -> Void)? = nil) {
        toast = Toast(text: text, undo: undo)
    }

    /// Run an API call, showing any error as a toast. Returns nil on failure.
    @discardableResult
    func attempt<T>(_ what: String = "", _ body: (CrateAPI) async throws -> T) async -> T? {
        guard let api = crate else { return nil }
        do {
            return try await body(api)
        } catch {
            say((what.isEmpty ? "" : "\(what): ") + error.localizedDescription)
            return nil
        }
    }

    /// Follow a run and say how it went when it's done.
    func track(_ started: Started?, _ label: String) {
        guard let id = started?.runId, let api = crate else { dataVersion += 1; return }
        tracked.append(TrackedRun(id: id, label: label))
        Task {
            await refreshStatus()
            let run = try? await api.waitFor(run: id, every: 2.5)
            tracked.removeAll { $0.id == id }
            dataVersion += 1
            await refreshStatus()
            switch run?.status {
            case "ok": say("\(label): \(run?.summary ?? "done")")
            case "failed": say("\(label) failed: \(run?.summary ?? "")")
            case "cancelled": say("\(label) was stopped")
            default: break
            }
        }
    }

    // MARK: - song actions (shared by rows, Now Playing and the lock screen)

    func setStar(_ songId: String?, _ starred: Bool) {
        guard let songId else { return }
        player.update(songId: songId) { $0.starred = starred }
        Task {
            guard let r = await attempt("Couldn't change the like", { try await $0.like(songId, starred: starred) }) else {
                player.update(songId: songId) { $0.starred = !starred }
                return
            }
            if r.runId != nil {
                player.update(songId: songId) { $0.isInbox = false }
                track(r, "Keeping it")
            } else {
                dataVersion += 1
            }
        }
    }

    func setRating(_ songId: String?, _ rating: Int) {
        guard let songId else { return }
        player.update(songId: songId) { $0.rating = rating }
        Task {
            guard let r = await attempt("Couldn't rate it", { try await $0.like(songId, rating: rating) }) else { return }
            if r.runId != nil {
                player.update(songId: songId) { $0.isInbox = false }
                track(r, rating >= 4 ? "Keeping it" : "Removing it")
            } else {
                dataVersion += 1
            }
        }
    }

    func keep(_ songId: String) {
        player.update(songId: songId) { $0.isInbox = false; $0.starred = true }
        Task { track(await attempt("Couldn't keep it") { try await $0.keep(songId) }, "Keep") }
    }

    /// Delete an inbox track and block it from coming back. `onFailure` lets a list that hid the
    /// row straight away put it back.
    func remove(_ songId: String, title: String? = nil, onFailure: (@MainActor () -> Void)? = nil) {
        Task {
            guard let r = await attempt("Couldn't remove it", { try await $0.remove(songId) }) else {
                onFailure?()
                return
            }
            player.removeSong(songId)
            track(r, title.map { "Removed \($0)" } ?? "Remove")
        }
    }

    func runNow(_ job: String, label: String) {
        Task { track(await attempt("Couldn't start \(label)") { try await $0.runNow(job) }, label) }
    }

    func stopAll() {
        Task {
            guard let r = await attempt("Couldn't stop tasks", { try await $0.stopAll() }) else { return }
            say(r.cancelled + r.stopping == 0 ? "Nothing was running" : "Stopping \(r.cancelled + r.stopping) task(s)")
            await refreshStatus()
        }
    }

    func jobLabel(_ kind: String) -> String {
        let prefix = kind.split(separator: ":").first.map(String.init) ?? kind
        if let label = info?.jobs[kind] ?? status?.jobs[kind]?.label { return label }
        return ["prompt": "Prompt playlist", "keep": "Keep", "remove": "Remove", "tidy": "Tidy inbox",
                "tidy_playlists": "Remove duplicate playlists", "get": "Add to library",
                "reset": "Clear discovery history", "like": "Keep or remove"][prefix] ?? kind
    }
}
