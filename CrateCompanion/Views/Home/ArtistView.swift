import CrateKit
import SwiftUI

/// An artist in your Navidrome library: their albums, and every song of theirs you have.
struct ArtistView: View {
    @Environment(AppModel.self) private var model
    @Environment(AudioPlayer.self) private var player
    let artist: NavidromeArtist
    @State private var albums: [NavidromeAlbum] = []
    @State private var songs: [Track] = []
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        List {
            VStack(spacing: 10) {
                Artwork(url: model.navidrome?.coverURL(id: artist.coverArt ?? artist.id, size: 600), size: 160, corner: 80)
                Text(artist.name).font(Theme.display(28)).tracking(-0.6).multilineTextAlignment(.center)
                if loaded {
                    Text("\(albums.count) album\(albums.count == 1 ? "" : "s") · \(songs.count) song\(songs.count == 1 ? "" : "s")")
                        .font(.subheadline).foregroundStyle(Theme.textMedium)
                }
                PlayShuffleRow(onPlay: { play(from: 0) }, onShuffle: { play(from: 0, shuffle: true) })
                    .disabled(songs.isEmpty)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            if !loaded { ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden) }
            if !albums.isEmpty {
                Section("Albums") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 14) {
                            ForEach(albums) { a in
                                NavigationLink(value: a) {
                                    Card(title: a.name, subtitle: a.year.map { String($0) } ?? "",
                                         art: model.navidrome?.coverURL(id: a.coverArt ?? a.id, size: 300))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .listRowBackground(Color.clear)
                }
            }
            if !songs.isEmpty {
                Section("Songs") {
                    // songs from different albums can share a position, so key them by song id
                    ForEach(Array(songs.enumerated()), id: \.element.songId) { i, t in
                        TrackRow(track: t, playlistKey: nil, isCurrent: player.current?.songId == t.songId,
                                 onPlay: { play(from: i) },
                                 onChange: { updated in
                                     if let j = songs.firstIndex(where: { $0.songId == t.songId }) { songs[j] = updated }
                                 })
                        .listRowBackground(Color.clear)
                    }
                }
            }
        }
        .listStyle(.plain)
        .crateScreen()
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.dataVersion) { await load() }
    }

    private func play(from index: Int, shuffle: Bool = false) {
        player.play(songs.compactMap { model.resolver?.item($0, playlistKey: nil) }, startAt: index, shuffle: shuffle)
    }

    /// Albums newest first, and their songs in album order.
    private func load() async {
        guard let nd = model.navidrome else { return }
        do {
            let list = try await nd.artistAlbums(artist.id)
            var all: [Track] = []
            for a in list {
                // their own albums in full; from compilations, just their songs
                let tracks = try await nd.albumSongs(a.id)
                all += a.artist == artist.name ? tracks : tracks.filter { $0.artist.localizedCaseInsensitiveContains(artist.name) }
            }
            albums = list
            songs = all
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }
}
