import AVFoundation
import CrateKit
import Foundation
import Observation
import UIKit

/// A song saved on the phone, playable without a connection.
struct DownloadedSong: Codable, Hashable, Identifiable {
    let songId: String
    var title: String
    var artist: String
    var album: String
    var duration: Int
    var file: String
    var cover: String?
    var bytes: Int64
    /// Downloaded on its own (not only as part of a playlist), so it stays when its playlists go.
    var pinned: Bool
    var addedAt: Date
    var id: String { songId }

    var track: Track { Track(pos: 0, songId: songId, artist: artist, title: title, album: album, duration: duration) }
}

/// A playlist saved on the phone. Its songs follow the playlist whenever it's loaded online.
struct DownloadedPlaylist: Codable, Hashable, Identifiable {
    let key: String
    var name: String
    var comment: String?
    var songIds: [String]
    var id: String { key }
}

/// Songs and playlists downloaded for offline listening. Files live in Application Support (not
/// backed up to iCloud), with a small JSON index beside them. Downloads use the same quality as
/// streaming; a format AVPlayer can't open from a file is fetched again as MP3.
@MainActor
@Observable
final class DownloadStore {
    private(set) var songs: [String: DownloadedSong] = [:]
    private(set) var playlists: [String: DownloadedPlaylist] = [:]
    /// Song id -> progress (0...1) while it's queued or downloading.
    private(set) var progress: [String: Double] = [:]
    private(set) var failed: Set<String> = []

    @ObservationIgnored var resolver: (() -> MediaResolver?)?
    @ObservationIgnored var onError: ((String) -> Void)?

    @ObservationIgnored private var pending: [Track] = []
    @ObservationIgnored private var active = 0
    @ObservationIgnored private let concurrent = 3
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 30 * 60
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    private let folder: URL
    private var indexURL: URL { folder.appendingPathComponent("index.json") }

    private struct Index: Codable {
        var songs: [String: DownloadedSong]
        var playlists: [String: DownloadedPlaylist]
    }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = base.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        if let data = try? Data(contentsOf: indexURL), let index = try? JSONDecoder().decode(Index.self, from: data) {
            // drop anything whose file has gone missing
            songs = index.songs.filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.value.file).path) }
            playlists = index.playlists
        }
    }

    // MARK: - lookups

    func localFile(_ songId: String) -> URL? {
        songs[songId].map { folder.appendingPathComponent($0.file) }
    }

    func localCover(_ songId: String) -> URL? {
        songs[songId]?.cover.map { folder.appendingPathComponent($0) }
    }

    func isDownloaded(_ songId: String) -> Bool { songs[songId] != nil }
    func isDownloading(_ songId: String) -> Bool { progress[songId] != nil }
    func isSaved(playlist key: String) -> Bool { playlists[key] != nil }

    /// How much of a saved playlist is on the phone: (downloaded, total).
    func counts(playlist key: String) -> (Int, Int) {
        guard let p = playlists[key] else { return (0, 0) }
        return (p.songIds.filter { songs[$0] != nil }.count, p.songIds.count)
    }

    var totalBytes: Int64 { songs.values.reduce(0) { $0 + $1.bytes } }

    /// Songs downloaded on their own, newest first.
    var pinnedSongs: [DownloadedSong] {
        songs.values.filter(\.pinned).sorted { $0.addedAt > $1.addedAt }
    }

    func tracks(playlist key: String) -> [Track] {
        guard let p = playlists[key] else { return [] }
        return p.songIds.enumerated().compactMap { i, id in
            songs[id].map { s in Track(pos: i, songId: id, artist: s.artist, title: s.title, album: s.album, duration: s.duration) }
        }
    }

    // MARK: - songs

    func download(_ tracks: [Track]) {
        for t in tracks {
            if songs[t.songId] != nil { songs[t.songId]?.pinned = true } else { enqueue(t, pinned: true) }
        }
        save()
        pump()
    }

    func removeDownload(_ songId: String) {
        songs[songId]?.pinned = false
        pinnedWhenDone.remove(songId)
        for key in playlists.keys { playlists[key]?.songIds.removeAll { $0 == songId } }
        dropUnwanted()
        collect()
    }

    // MARK: - playlists

    /// Save a playlist and download its songs. Called again whenever it's loaded online, so the
    /// copy on the phone follows the playlist (a rebuilt Discover Weekly, a new Liked song...).
    func save(playlist key: String, name: String, comment: String?, tracks: [Track]) {
        playlists[key] = DownloadedPlaylist(key: key, name: name, comment: comment, songIds: tracks.map(\.songId))
        for t in tracks where songs[t.songId] == nil && progress[t.songId] == nil {
            if adoptMovedFile(for: t) { continue }
            enqueue(t, pinned: false)
        }
        collect()
        pump()
    }

    /// Keep a saved playlist in step with what the server says is in it now (and retry any
    /// song that didn't download last time).
    func sync(playlist key: String, name: String, comment: String?, tracks: [Track]) {
        guard let old = playlists[key] else { return }
        let missing = tracks.contains { songs[$0.songId] == nil && progress[$0.songId] == nil }
        guard missing || old.songIds != tracks.map(\.songId) || old.name != name else { return }
        save(playlist: key, name: name, comment: comment, tracks: tracks)
    }

    func removePlaylist(_ key: String) {
        playlists[key] = nil
        dropUnwanted()
        collect()
    }

    func removeAll() {
        playlists = [:]
        pinnedWhenDone = []
        for s in songs.values { songs[s.songId]?.pinned = false }
        dropUnwanted()
        collect()
    }

    /// Take queued songs nothing wants any more off the queue. One already downloading is
    /// thrown away when it finishes.
    private func dropUnwanted() {
        for t in pending where !wanted(t.songId) { progress[t.songId] = nil }
        pending.removeAll { !wanted($0.songId) }
    }

    // MARK: - queue

    private func enqueue(_ t: Track, pinned: Bool) {
        if pinned { pinnedWhenDone.insert(t.songId) }
        guard progress[t.songId] == nil else { return }
        failed.remove(t.songId)
        progress[t.songId] = 0
        pending.append(t)
    }

    @ObservationIgnored private var pinnedWhenDone: Set<String> = []

    private func pump() {
        while active < concurrent, !pending.isEmpty {
            let t = pending.removeFirst()
            active += 1
            beginBackgroundTime()
            Task {
                await fetch(t)
                active -= 1
                pump()
                if active == 0 && pending.isEmpty { endBackgroundTime() }
            }
        }
    }

    private func fetch(_ t: Track) async {
        defer { progress[t.songId] = nil }
        guard let resolver = resolver?(), let url = resolver.stream(songId: t.songId) else {
            failed.insert(t.songId)
            return
        }
        do {
            var (file, bytes) = try await fetchAudio(url, songId: t.songId)
            // Some formats stream fine but AVPlayer won't open them from a file: get an MP3 instead
            if !(try await AVURLAsset(url: file).load(.isPlayable)), let nd = resolver.navidrome {
                try? FileManager.default.removeItem(at: file)
                (file, bytes) = try await fetchAudio(nd.streamURL(songId: t.songId, maxBitRate: 320), songId: t.songId)
            }
            guard wanted(t.songId) else {  // removed while it downloaded
                try? FileManager.default.removeItem(at: file)
                return
            }
            let cover = await fetchCover(resolver.artwork(songId: t.songId, size: 600), songId: t.songId)
            songs[t.songId] = DownloadedSong(songId: t.songId, title: t.title, artist: t.artist, album: t.album,
                                             duration: t.duration, file: file.lastPathComponent, cover: cover,
                                             bytes: bytes, pinned: pinnedWhenDone.remove(t.songId) != nil, addedAt: Date())
            save()
        } catch {
            failed.insert(t.songId)
            if (error as? URLError)?.code != .cancelled { onError?("Couldn't download \(t.title): \(error.localizedDescription)") }
        }
    }

    private func wanted(_ songId: String) -> Bool {
        pinnedWhenDone.contains(songId) || playlists.values.contains { $0.songIds.contains(songId) }
    }

    private func fetchAudio(_ url: URL, songId: String) async throws -> (URL, Int64) {
        let (temp, response) = try await session.download(from: url, delegate: ProgressDelegate { [weak self] p in
            Task { @MainActor in if self?.progress[songId] != nil { self?.progress[songId] = p } }
        })
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let dest = folder.appendingPathComponent("\(Self.safe(songId)).\(Self.fileExtension(response))")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: temp, to: dest)
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path))?[.size] as? NSNumber
        return (dest, size?.int64Value ?? 0)
    }

    private func fetchCover(_ url: URL?, songId: String) async -> String? {
        guard let url, let result = try? await session.data(from: url) else { return nil }
        let (data, response) = result
        guard ((response as? HTTPURLResponse)?.statusCode ?? 200) < 300, UIImage(data: data) != nil else { return nil }
        let name = "\(Self.safe(songId)).cover"
        return (try? data.write(to: folder.appendingPathComponent(name))) != nil ? name : nil
    }

    /// AVPlayer picks a decoder by file extension, so it has to be right.
    static func fileExtension(_ response: URLResponse) -> String {
        let known = ["mp3", "m4a", "mp4", "aac", "flac", "wav", "aif", "aiff", "caf", "alac", "opus", "ogg", "oga"]
        if let ext = response.suggestedFilename.map({ ($0 as NSString).pathExtension.lowercased() }), known.contains(ext) {
            return ext == "alac" ? "m4a" : ext
        }
        switch response.mimeType?.lowercased() {
        case "audio/flac", "audio/x-flac": return "flac"
        case "audio/mp4", "audio/x-m4a", "audio/aac", "audio/m4a": return "m4a"
        case "audio/wav", "audio/x-wav", "audio/wave": return "wav"
        case "audio/ogg", "audio/opus": return "ogg"
        case "audio/aiff", "audio/x-aiff": return "aiff"
        default: return "mp3"
        }
    }

    private static func safe(_ id: String) -> String {
        id.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }.reduce(into: "") { $0.append($1) }
    }

    // MARK: - bookkeeping

    /// A kept inbox track gets a new song id when its file moves into your library. Reuse the
    /// file already on the phone instead of downloading the same song again.
    private func adoptMovedFile(for t: Track) -> Bool {
        func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let inPlaylists = Set(playlists.values.flatMap(\.songIds))
        guard let old = songs.values.first(where: { norm($0.artist) == norm(t.artist) && norm($0.title) == norm(t.title)
                                                    && !inPlaylists.contains($0.songId) && !$0.pinned }) else { return false }
        songs[old.songId] = nil
        songs[t.songId] = DownloadedSong(songId: t.songId, title: t.title, artist: t.artist, album: t.album,
                                         duration: t.duration, file: old.file, cover: old.cover, bytes: old.bytes,
                                         pinned: false, addedAt: old.addedAt)
        return true
    }

    /// Delete files nothing wants any more: not downloaded on their own, and in no saved playlist.
    private func collect() {
        let inPlaylists = Set(playlists.values.flatMap(\.songIds))
        for s in songs.values where !s.pinned && !inPlaylists.contains(s.songId) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(s.file))
            if let cover = s.cover { try? FileManager.default.removeItem(at: folder.appendingPathComponent(cover)) }
            songs[s.songId] = nil
        }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Index(songs: songs, playlists: playlists)) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// A few minutes to finish when you leave the app mid-download.
    private func beginBackgroundTime() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Downloads") { [weak self] in
            Task { @MainActor in self?.endBackgroundTime() }
        }
    }

    private func endBackgroundTime() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

/// Reports a download's progress (0...1) as bytes arrive.
private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let report: (Double) -> Void
    init(_ report: @escaping (Double) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        report(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    // The async download(from:delegate:) call hands back the file itself
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
