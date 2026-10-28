import CrateKit
import SwiftUI

/// Home: what to play next, Crate's playlists made for you, and shelves of your Navidrome library:
/// recently played and added, your most played, random albums, and what you've been listening to.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var upNext: [Track] = []
    @State private var upNextReason: String?
    @State private var stats: PlayStats?
    @State private var albums: [String: [NavidromeAlbum]] = [:]
    @State private var madeForYou: [Playlist] = []
    @State private var showAllHistory = false
    @State private var loaded = false
    /// New songs you've kept or passed on from Home: gone from the queue straight away.
    @State private var decided: Set<String> = []

    var body: some View {
        NavigationStack {
            ScrollView {
                if model.navidrome == nil {
                    ContentUnavailableView("Home needs Navidrome", systemImage: "music.note.house",
                                           description: Text("Add your Navidrome password under Activity > Change server… to see your library here."))
                } else {
                    LazyVStack(alignment: .leading, spacing: 36) {
                        QuickGrid(playlists: Array(madeForYou.prefix(6)))
                        curationQueue
                        MadeForYouShelf(playlists: madeForYou)
                        SongShelf(title: "Up Next", subtitle: upNextReason, songs: upNext)
                        AlbumShelf(title: "Recently played", albums: albums["recent"])
                        AlbumShelf(title: "Recently added", albums: albums["newest"])
                        AlbumShelf(title: "Frequently played", albums: albums["frequent"])
                        AlbumShelf(title: "Random albums", albums: albums["random"]) {
                            Task { await loadAlbums("random") }
                        }
                        SongShelf(title: "Top played", subtitle: nil, songs: stats?.top ?? [])
                        history
                    }
                    .padding(.vertical)
                }
            }
            .crateScreen()
            .navigationTitle(greeting)
            .navigationDestination(for: NavidromeAlbum.self) { LibraryAlbumView(album: $0) }
            .navigationDestination(for: PlaylistRef.self) { PlaylistDetailView(ref: $0) }
            .refreshable { await load() }
            .task { if !loaded { await load() } }
            .overlay { if !loaded && model.navidrome != nil { ProgressView() } }
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        default: "Good evening"
        }
    }

    /// New songs waiting in your inbox across Crate's playlists: keep them or pass, right here.
    private struct Waiting: Identifiable {
        let track: Track
        let key: String
        var id: String { track.songId }
    }

    private var waiting: [Waiting] {
        var seen = Set<String>()
        var out: [Waiting] = []
        for p in madeForYou {
            for t in p.tracks where t.state == .new && !decided.contains(t.songId) && seen.insert(t.songId).inserted {
                out.append(Waiting(track: t, key: p.key))
            }
        }
        return out
    }

    @ViewBuilder
    private var curationQueue: some View {
        let queue = waiting
        if !queue.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Waiting for you",
                             subtitle: "\(queue.count) new song\(queue.count == 1 ? "" : "s") · ✓ keeps it, ✕ passes")
                ForEach(queue.prefix(3)) { entry in
                    CurationRow(track: entry.track, playlistKey: entry.key,
                                onKeep: {
                                    withAnimation { _ = decided.insert(entry.track.songId) }
                                    model.keep(entry.track.songId)
                                },
                                onPass: {
                                    withAnimation { _ = decided.insert(entry.track.songId) }
                                    model.remove(entry.track.songId, title: entry.track.title) {
                                        decided.remove(entry.track.songId)
                                    }
                                })
                }
            }
            .padding(.horizontal)
        }
    }

    @ViewBuilder
    private var history: some View {
        let songs = stats?.recent ?? []
        if !songs.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ShelfHeader(title: "Song history")
                let shown = showAllHistory ? songs : Array(songs.prefix(8))
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, t in
                    SongListRow(track: t, songs: songs, index: i)
                }
                if !showAllHistory && songs.count > 8 {
                    Button("Show more") { showAllHistory = true }.padding(.horizontal).padding(.top, 4)
                }
            }
        }
    }

    // MARK: - loading

    private func load() async {
        guard let nd = model.navidrome else { loaded = true; return }
        let crate = model.crate
        async let playlists = try? crate?.playlists()
        async let played = try? nd.playStats(count: 30)
        async let recent = try? nd.albums("recent")
        async let newest = try? nd.albums("newest")
        async let frequent = try? nd.albums("frequent")
        async let random = try? nd.albums("random")
        albums = ["recent": await recent ?? [], "newest": await newest ?? [],
                  "frequent": await frequent ?? [], "random": await random ?? []]
        stats = await played
        madeForYou = ((await playlists) ?? nil)?.madeForYouOrder() ?? []
        await loadUpNext(nd)
        loaded = true
    }

    private func loadAlbums(_ type: String) async {
        guard let nd = model.navidrome, let list = try? await nd.albums(type) else { return }
        albums[type] = list
    }

    /// Songs like the one playing (or the last one you played), else a random handful.
    private func loadUpNext(_ nd: Subsonic) async {
        let seed = model.player.current.flatMap { $0.songId == nil ? nil : $0 }
        let seedId = seed?.songId ?? stats?.recent.first?.songId
        let seedTitle = seed?.title ?? stats?.recent.first?.title
        if let seedId, let similar = try? await nd.similarSongs(seedId, count: 20), !similar.isEmpty {
            upNext = similar
            upNextReason = seedTitle.map { "Because you played \($0)" }
        } else if let random = try? await nd.randomSongs(count: 20) {
            upNext = random
            upNextReason = "A mix from your library"
        }
    }
}

// MARK: - shelves

struct ShelfHeader: View {
    let title: String
    var subtitle: String?
    var actionLabel = ""
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.headline()).tracking(-0.3)
                if let subtitle { Text(subtitle).font(.footnote).foregroundStyle(Theme.textMedium) }
            }
            Spacer()
            if let action {
                Button(actionLabel, action: action).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.amber)
            }
        }
        .padding(.horizontal)
    }
}

/// A row of songs to swipe through; tapping one plays the row from there.
struct SongShelf: View {
    @Environment(AppModel.self) private var model
    @Environment(AudioPlayer.self) private var player
    let title: String
    let subtitle: String?
    let songs: [Track]

    var body: some View {
        if !songs.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ShelfHeader(title: title, subtitle: subtitle, actionLabel: "Play all") { play(from: 0) }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(Array(songs.enumerated()), id: \.element.id) { i, t in
                            Button { play(from: i) } label: {
                                Card(title: t.title, subtitle: t.artist,
                                     art: model.resolver?.artwork(songId: t.songId, size: 300),
                                     playing: player.current?.songId == t.songId)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { SongMenu(track: t) }
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    private func play(from index: Int) {
        player.play(songs.compactMap { model.resolver?.item($0, playlistKey: nil) }, startAt: index)
    }
}

/// Crate's playlists: Discover Weekly, Release Radar, Daily Mixes and your prompt playlists.
struct MadeForYouShelf: View {
    @Environment(AppModel.self) private var model
    let playlists: [Playlist]

    var body: some View {
        if !playlists.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ShelfHeader(title: "Made for you", subtitle: "Curated by Crate from your listening")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(playlists, id: \.key) { p in
                            NavigationLink(value: PlaylistRef(key: p.key, name: p.name, comment: p.comment)) {
                                Card(title: p.name, subtitle: subtitle(p),
                                     art: p.tracks.first.flatMap { model.resolver?.artwork(songId: $0.songId, size: 300) },
                                     size: 160)
                                    .overlay(alignment: .topLeading) {
                                        if p.newCount > 0 {
                                            Text("\(p.newCount) NEW")
                                                .font(Theme.caps).tracking(0.6).foregroundStyle(Theme.canvas)
                                                .padding(.horizontal, 8).padding(.vertical, 4)
                                                .background(Theme.amber, in: Capsule())
                                                .padding(8)
                                        } else {
                                            Image(systemName: p.kind.symbol)
                                                .font(.caption.bold()).foregroundStyle(.white)
                                                .padding(6).background(p.kind.color, in: Circle()).padding(8)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    private func subtitle(_ p: Playlist) -> String {
        p.newCount > 0 ? "\(p.tracks.count) songs · \(p.newCount) new" : "\(p.tracks.count) songs"
    }
}

/// A row of albums; tapping one opens it.
struct AlbumShelf: View {
    @Environment(AppModel.self) private var model
    let title: String
    let albums: [NavidromeAlbum]?
    var reshuffle: (() -> Void)?

    var body: some View {
        if let albums, !albums.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ShelfHeader(title: title, actionLabel: "Shuffle", action: reshuffle)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(albums) { a in
                            NavigationLink(value: a) {
                                Card(title: a.name, subtitle: a.artist ?? "",
                                     art: model.navidrome?.coverURL(id: a.coverArt ?? a.id, size: 300))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }
}

struct Card: View {
    let title: String
    let subtitle: String
    let art: URL?
    var playing = false
    var size: CGFloat = 140

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Artwork(url: art, size: size, corner: 8)
                .overlay(alignment: .bottomTrailing) {
                    if playing {
                        Image(systemName: "speaker.wave.2.fill").font(.caption.bold()).foregroundStyle(.white)
                            .padding(6).background(.black.opacity(0.45), in: Circle()).padding(6)
                    }
                }
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                .foregroundStyle(playing ? Theme.amber : Color.white)
                .padding(.top, 4)
            Text(subtitle).font(.caption).foregroundStyle(Theme.textMedium).lineLimit(2)
        }
        .frame(width: size, alignment: .leading)
    }
}

/// A song in a plain list outside a List (Song history): tap to play the list from it.
struct SongListRow: View {
    @Environment(AppModel.self) private var model
    @Environment(AudioPlayer.self) private var player
    let track: Track
    let songs: [Track]
    let index: Int

    var body: some View {
        Button {
            player.play(songs.compactMap { model.resolver?.item($0, playlistKey: nil) }, startAt: index)
        } label: {
            HStack(spacing: 12) {
                Artwork(url: model.resolver?.artwork(songId: track.songId, size: 120), size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(.body.weight(.medium)).lineLimit(1)
                        .foregroundStyle(player.current?.songId == track.songId ? Theme.amber : Color.white)
                    Text("\(track.artist) · \(track.album)").font(.caption).foregroundStyle(Theme.textMedium).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text("\(track.plays) play\(track.plays == 1 ? "" : "s")").font(.caption2).foregroundStyle(Theme.textLow)
            }
            .padding(.horizontal).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { SongMenu(track: track) }
    }
}

/// Long-press actions for a song outside a playlist.
struct SongMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(AudioPlayer.self) private var player
    @Environment(DownloadStore.self) private var downloads
    @Environment(\.pickPlaylist) private var pickPlaylist
    let track: Track

    var body: some View {
        if let item = model.resolver?.item(track, playlistKey: nil) {
            Button { player.playNext(item) } label: { Label("Play next", systemImage: "text.insert") }
            Button { player.addToQueue(item) } label: { Label("Add to queue", systemImage: "text.append") }
        }
        Button { pickPlaylist(PlaylistPick(song: .library(track.songId), title: track.title)) } label: {
            Label("Add to playlist…", systemImage: "text.badge.plus")
        }
        if !downloads.isDownloaded(track.songId) && !downloads.isDownloading(track.songId) {
            Button { downloads.download([track]) } label: { Label("Download", systemImage: "arrow.down.circle") }
        }
        Button { model.setStar(track.songId, !track.starred) } label: {
            Label(track.starred ? "Unlove" : "Love", systemImage: track.starred ? "heart.slash" : "heart")
        }
    }
}

/// Crate's playlists as compact tiles, two to a row, at the top of Home.
struct QuickGrid: View {
    @Environment(AppModel.self) private var model
    let playlists: [Playlist]

    var body: some View {
        if !playlists.isEmpty {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(playlists, id: \.key) { p in
                    NavigationLink(value: PlaylistRef(key: p.key, name: p.name, comment: p.comment)) {
                        HStack(spacing: 10) {
                            Artwork(url: p.tracks.first.flatMap { model.resolver?.artwork(songId: $0.songId, size: 160) },
                                    size: 56, corner: 0)
                            Text(p.name).font(.footnote.weight(.bold)).lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                            if p.newCount > 0 { Circle().fill(Theme.amber).frame(width: 7, height: 7).padding(.trailing, 8) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surface2)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(PressScale())
                }
            }
            .padding(.horizontal)
        }
    }
}

/// A new inbox song with ✕ (pass) and ✓ (keep). Tap the song to hear it.
struct CurationRow: View {
    @Environment(AppModel.self) private var model
    @Environment(AudioPlayer.self) private var player
    let track: Track
    let playlistKey: String
    let onKeep: () -> Void
    let onPass: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button {
                if let item = model.resolver?.item(track, playlistKey: playlistKey) { player.play(item) }
            } label: {
                HStack(spacing: 12) {
                    Artwork(url: model.resolver?.artwork(songId: track.songId, size: 120), size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title).font(.body.weight(.semibold)).lineLimit(1)
                            .foregroundStyle(player.current?.songId == track.songId ? Theme.amber : Color.white)
                        Text(track.artist).font(.caption).foregroundStyle(Theme.textMedium).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            CircleIconButton(systemImage: "xmark", size: 38, label: "Not for me", action: onPass)
            CircleIconButton(systemImage: "checkmark", tint: Theme.amber, filled: true, size: 38, label: "Keep", action: onKeep)
        }
        .padding(10)
        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - album

/// An album from your Navidrome library.
struct LibraryAlbumView: View {
    @Environment(AppModel.self) private var model
    @Environment(AudioPlayer.self) private var player
    let album: NavidromeAlbum
    @State private var tracks: [Track] = []
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        List {
            VStack(spacing: 10) {
                Artwork(url: model.navidrome?.coverURL(id: album.coverArt ?? album.id, size: 600), size: 220, corner: 10)
                Text(album.name).font(Theme.display(24)).tracking(-0.5).multilineTextAlignment(.center)
                Text([album.artist, album.year.map { String($0) }].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(Theme.textMedium)
                PlayShuffleRow(onPlay: { play(from: 0) }, onShuffle: { play(from: 0, shuffle: true) })
                    .disabled(tracks.isEmpty)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            if !loaded { ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden) }
            ForEach(Array(tracks.enumerated()), id: \.element.id) { i, t in
                TrackRow(track: t, playlistKey: nil, isCurrent: player.current?.songId == t.songId,
                         onPlay: { play(from: i) },
                         onChange: { updated in if let j = tracks.firstIndex(where: { $0.id == t.id }) { tracks[j] = updated } })
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .crateScreen()
        .navigationTitle(album.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func play(from index: Int, shuffle: Bool = false) {
        player.play(tracks.compactMap { model.resolver?.item($0, playlistKey: nil) }, startAt: index, shuffle: shuffle)
    }

    private func load() async {
        guard let nd = model.navidrome else { return }
        do {
            tracks = try await nd.albumSongs(album.id)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }
}
