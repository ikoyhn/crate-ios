import CrateKit
import SwiftUI

/// Everything saved on the phone: downloaded playlists and songs, playable without a connection.
struct DownloadsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AudioPlayer.self) private var player
    @Environment(DownloadStore.self) private var downloads
    @State private var confirmRemoveAll = false

    private var playlists: [DownloadedPlaylist] {
        downloads.playlists.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Every song on the phone, A–Z by artist, for Shuffle all.
    private var allSongs: [DownloadedSong] {
        downloads.songs.values.sorted { ($0.artist, $0.title) < ($1.artist, $1.title) }
    }

    var body: some View {
        List {
            if downloads.songs.isEmpty && downloads.progress.isEmpty {
                ContentUnavailableView("Nothing downloaded yet", systemImage: "arrow.down.circle",
                                       description: Text("Choose Download from a playlist's ⋯ menu, or long-press a song."))
            } else {
                Section {
                    HStack(spacing: 12) {
                        Button { play(allSongs, shuffle: false) } label: {
                            Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        Button { play(allSongs, shuffle: true) } label: {
                            Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .disabled(allSongs.isEmpty)
                    .listRowSeparator(.hidden)
                } footer: {
                    Text(summary)
                }
            }

            if !playlists.isEmpty {
                Section("Playlists") {
                    ForEach(playlists) { p in
                        NavigationLink(value: PlaylistRef(key: p.key, name: p.name, comment: p.comment,
                                                          readonly: p.key == PlaylistKind.likedKey)) {
                            PlaylistRow(name: p.name, subtitle: subtitle(p), kind: PlaylistKind(key: p.key),
                                        cover: p.songIds.lazy.compactMap { downloads.localCover($0) }.first)
                        }
                        .swipeActions {
                            Button(role: .destructive) { downloads.removePlaylist(p.key) } label: {
                                Label("Remove", systemImage: "xmark.circle")
                            }
                        }
                    }
                }
            }

            let songs = downloads.pinnedSongs
            if !songs.isEmpty {
                Section("Songs") {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { i, s in
                        Button { play(songs, startAt: i) } label: { DownloadedSongRow(song: s, isCurrent: player.current?.songId == s.songId) }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button(role: .destructive) { downloads.removeDownload(s.songId) } label: {
                                    Label("Remove", systemImage: "xmark.circle")
                                }
                            }
                    }
                }
            }

            if !downloads.songs.isEmpty {
                Section {
                    Button("Remove all downloads", role: .destructive) { confirmRemoveAll = true }
                }
            }
        }
        .crateScreen()
        .navigationTitle("Downloads")
        .confirmationDialog("Remove all downloads?", isPresented: $confirmRemoveAll, titleVisibility: .visible) {
            Button("Remove all", role: .destructive) { downloads.removeAll() }
        } message: {
            Text("Deletes every downloaded song from this phone. Nothing changes in your library.")
        }
    }

    private var summary: String {
        var parts = ["\(downloads.songs.count) songs", downloads.totalBytes.formatted(.byteCount(style: .file))]
        if !downloads.progress.isEmpty { parts.append("\(downloads.progress.count) downloading") }
        if !downloads.failed.isEmpty { parts.append("\(downloads.failed.count) failed; open the playlist online to retry") }
        return parts.joined(separator: " · ")
    }

    private func subtitle(_ p: DownloadedPlaylist) -> String {
        let (have, total) = downloads.counts(playlist: p.key)
        return have >= total ? "\(total) songs" : "\(have) of \(total) downloaded"
    }

    private func play(_ songs: [DownloadedSong], startAt: Int = 0, shuffle: Bool = false) {
        let items = songs.compactMap { model.resolver?.item($0.track, playlistKey: nil) }
        player.play(items, startAt: shuffle ? Int.random(in: 0..<max(items.count, 1)) : startAt, shuffle: shuffle)
    }
}

private struct DownloadedSongRow: View {
    @Environment(DownloadStore.self) private var downloads
    let song: DownloadedSong
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: downloads.localCover(song.songId), size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(song.title).lineLimit(1)
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                Text(song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(song.bytes.formatted(.byteCount(style: .file))).font(.caption2).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}
