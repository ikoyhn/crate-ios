import Foundation

/// Something the player can play: a song in Navidrome, or a 30 s preview of a suggested new song.
public struct PlayableItem: Sendable, Identifiable, Hashable {
    public enum Source: Sendable, Hashable {
        case library(songId: String)   // full song, from Navidrome (or Crate's preview stream)
        case preview(deezerId: Int)    // 30 s Deezer preview of a song you don't have yet
    }
    public let id: String
    public let source: Source
    public let title: String
    public let artist: String
    public let album: String
    public let duration: Int
    public let streamURL: URL
    public let artworkURL: URL?
    /// Which Crate playlist it was started from, so its suggestions and actions are at hand.
    public let playlistKey: String?
    /// Waiting in the inbox: Keep / Remove apply.
    public var isInbox: Bool
    public var starred: Bool
    public var rating: Int

    public var songId: String? {
        if case .library(let id) = source { return id }
        return nil
    }
    public var isPreview: Bool { songId == nil }
}

/// Turns Crate's tracks and suggestions into playable items. With Navidrome credentials, songs
/// stream from Navidrome at full quality and scrobble; without, they stream through Crate's
/// 128 kbps preview endpoint (which doesn't count as a play).
public struct MediaResolver: Sendable {
    public let crate: CrateAPI
    public let navidrome: Subsonic?
    public let maxBitRate: Int

    public init(crate: CrateAPI, navidrome: Subsonic?, maxBitRate: Int = 0) {
        self.crate = crate
        self.navidrome = navidrome
        self.maxBitRate = maxBitRate
    }

    public func stream(songId: String) -> URL? {
        navidrome?.streamURL(songId: songId, maxBitRate: maxBitRate) ?? crate.previewURL(songId: songId)
    }

    public func artwork(songId: String, size: Int = 600) -> URL? {
        navidrome?.coverURL(id: songId, size: size) ?? crate.coverURL(songId: songId, size: size)
    }

    public func item(_ t: Track, playlistKey: String?) -> PlayableItem? {
        guard let url = stream(songId: t.songId) else { return nil }
        return PlayableItem(id: "t:\(t.songId)", source: .library(songId: t.songId), title: t.title, artist: t.artist,
                            album: t.album, duration: t.duration, streamURL: url, artworkURL: artwork(songId: t.songId),
                            playlistKey: playlistKey, isInbox: t.state == .new, starred: t.starred, rating: t.rating)
    }

    public func item(_ s: Suggestion, playlistKey: String?) -> PlayableItem? {
        switch s.kind {
        case .library:
            guard let id = s.songId, let url = stream(songId: id) else { return nil }
            return PlayableItem(id: "t:\(id)", source: .library(songId: id), title: s.title, artist: s.artist,
                                album: s.album, duration: s.duration, streamURL: url, artworkURL: artwork(songId: id),
                                playlistKey: playlistKey, isInbox: false, starred: false, rating: 0)
        case .new:
            guard let did = s.deezerId, let url = crate.mediaURL(s.preview) else { return nil }
            return PlayableItem(id: "p:\(did)", source: .preview(deezerId: did), title: s.title, artist: s.artist,
                                album: s.album, duration: 30, streamURL: url, artworkURL: crate.mediaURL(s.cover),
                                playlistKey: playlistKey, isInbox: false, starred: false, rating: 0)
        }
    }

    public func item(_ t: CatalogTrack) -> PlayableItem? {
        guard let url = URL(string: t.preview), !t.preview.isEmpty else { return nil }
        return PlayableItem(id: "p:\(t.deezerId)", source: .preview(deezerId: t.deezerId), title: t.title,
                            artist: t.artist, album: t.album, duration: 30, streamURL: url,
                            artworkURL: URL(string: t.cover), playlistKey: nil, isInbox: false, starred: false, rating: 0)
    }
}

/// The play queue, without any audio: what's current, what's next, shuffle and repeat.
public struct PlayQueue: Sendable {
    public enum Repeat: Sendable { case off, all, one }

    public private(set) var items: [PlayableItem] = []
    public private(set) var index: Int = 0
    public var repeatMode: Repeat = .off
    public private(set) var shuffled = false
    private var original: [PlayableItem] = []

    public init() {}

    public var current: PlayableItem? { items.indices.contains(index) ? items[index] : nil }
    public var upNext: ArraySlice<PlayableItem> { items.indices.contains(index + 1) ? items[(index + 1)...] : [] }
    public var hasNext: Bool { repeatMode != .off || index + 1 < items.count }

    public mutating func replace(with new: [PlayableItem], startAt: Int = 0, shuffle: Bool = false) {
        original = new
        items = new
        index = new.indices.contains(startAt) ? startAt : 0
        shuffled = false
        if shuffle { setShuffle(true) }
    }

    /// Advance after a track ends (respects repeat-one) or when Next is pressed (doesn't).
    @discardableResult
    public mutating func advance(userInitiated: Bool) -> PlayableItem? {
        guard !items.isEmpty else { return nil }
        if repeatMode == .one && !userInitiated { return current }
        if index + 1 < items.count { index += 1; return current }
        if repeatMode != .off { index = 0; return current }
        return nil
    }

    @discardableResult
    public mutating func back() -> PlayableItem? {
        guard !items.isEmpty else { return nil }
        index = index > 0 ? index - 1 : (repeatMode == .all ? items.count - 1 : 0)
        return current
    }

    public mutating func jump(to id: PlayableItem.ID) {
        if let i = items.firstIndex(where: { $0.id == id }) { index = i }
    }

    public mutating func playNext(_ item: PlayableItem) {
        items.insert(item, at: items.isEmpty ? 0 : index + 1)
        original.append(item)
    }

    public mutating func append(_ item: PlayableItem) {
        items.append(item)
        original.append(item)
    }

    public mutating func remove(id: PlayableItem.ID) {
        guard let i = items.firstIndex(where: { $0.id == id }), i != index else { return }
        items.remove(at: i)
        original.removeAll { $0.id == id }
        if i < index { index -= 1 }
    }

    /// Keeps the current track playing and shuffles the rest around it (or restores the order).
    public mutating func setShuffle(_ on: Bool) {
        guard on != shuffled else { return }
        let cur = current
        if on {
            var rest = items
            if let cur { rest.removeAll { $0.id == cur.id } }
            rest.shuffle()
            items = (cur.map { [$0] } ?? []) + rest
            index = 0
        } else {
            items = original
            index = cur.flatMap { c in items.firstIndex { $0.id == c.id } } ?? 0
        }
        shuffled = on
    }

    /// Reflect a heart / rating / keep on every copy of a song in the queue.
    public mutating func update(songId: String, _ change: (inout PlayableItem) -> Void) {
        for i in items.indices where items[i].songId == songId { change(&items[i]) }
        for i in original.indices where original[i].songId == songId { change(&original[i]) }
    }
}
