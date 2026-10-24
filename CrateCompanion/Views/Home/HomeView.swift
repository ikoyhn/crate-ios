import CrateKit
import SwiftUI

/// Home: what to play next, and shelves of your Navidrome library: recently played and added,
/// your most played, random albums, and what you've been listening to.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var upNext: [Track] = []
    @State private var upNextReason: String?
    @State private var stats: PlayStats?
    @State private var albums: [String: [NavidromeAlbum]] = [:]
    @State private var showAllHistory = false
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                if model.navidrome == nil {
                    ContentUnavailableView("Home needs Navidrome", systemImage: "music.note.house",
                                           description: Text("Add your Navidrome password under Activity > Change server… to see your library here."))
                } else {
                    LazyVStack(alignment: .leading, spacing: 28) {
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
            .navigationTitle("Home")
            .navigationDestination(for: NavidromeAlbum.self) { LibraryAlbumView(album: $0) }
            .refreshable { await load() }
            .task { if !loaded { await load() } }
            .overlay { if !loaded && model.navidrome != nil { ProgressView() } }
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
        async let played = try? nd.playStats(count: 30)
        async let recent = try? nd.albums("recent")
        async let newest = try? nd.albums("newest")
        async let frequent = try? nd.albums("frequent")
        async let random = try? nd.albums("random")
        albums = ["recent": await recent ?? [], "newest": await newest ?? [],
                  "frequent": await frequent ?? [], "random": await random ?? []]
        stats = await played
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
                Text(title).font(.title3.bold())
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if let action { Button(actionLabel, action: action).font(.subheadline) }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Artwork(url: art, size: 140, corner: 8)
                .overlay(alignment: .bottomTrailing) {
                    if playing {
                        Image(systemName: "speaker.wave.2.fill").font(.caption.bold()).foregroundStyle(.white)
                            .padding(6).background(.black.opacity(0.45), in: Circle()).padding(6)
                    }
                }
            Text(title).font(.caption.weight(.medium)).lineLimit(1)
                .foregroundStyle(playing ? Color.accentColor : Color.primary)
            Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 140)
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
                    Text(track.title).lineLimit(1)
                        .foregroundStyle(player.current?.songId == track.songId ? Color.accentColor : Color.primary)
                    Text("\(track.artist) · \(track.album)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text("\(track.plays) play\(track.plays == 1 ? "" : "s")").font(.caption2).foregroundStyle(.secondary)
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
    let track: Track

    var body: some View {
        if let item = model.resolver?.item(track, playlistKey: nil) {
            Button { player.playNext(item) } label: { Label("Play next", systemImage: "text.insert") }
            Button { player.addToQueue(item) } label: { Label("Add to queue", systemImage: "text.append") }
        }
        Button { model.setStar(track.songId, !track.starred) } label: {
            Label(track.starred ? "Unlove" : "Love", systemImage: track.starred ? "heart.slash" : "heart")
        }
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
                Text(album.name).font(.title3.bold()).multilineTextAlignment(.center)
                Text([album.artist, album.year.map { String($0) }].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button { play(from: 0) } label: { Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                    Button { play(from: 0, shuffle: true) } label: { Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                }
                .disabled(tracks.isEmpty)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            .frame(maxWidth: .infinity)
            .listRowSeparator(.hidden)

            if !loaded { ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden) }
            ForEach(Array(tracks.enumerated()), id: \.element.id) { i, t in
                TrackRow(track: t, playlistKey: nil, isCurrent: player.current?.songId == t.songId,
                         onPlay: { play(from: i) },
                         onChange: { updated in if let j = tracks.firstIndex(where: { $0.id == t.id }) { tracks[j] = updated } })
            }
        }
        .listStyle(.plain)
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
