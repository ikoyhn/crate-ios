import CrateKit
import SwiftUI

/// What a playlist screen needs to open: Crate's playlists and your own Navidrome ones alike.
struct PlaylistRef: Hashable {
    let key: String
    let name: String
    var comment: String?
    var readonly = false
    var kind: PlaylistKind { PlaylistKind(key: key) }
}

struct PlaylistsView: View {
    @Environment(AppModel.self) private var model
    @State private var playlists: [Playlist] = []
    @State private var own: [OwnPlaylist] = []
    @State private var ownError: String?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            List {
                if !(model.status?.busy.isEmpty ?? true) {
                    BusyBanner().listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }
                if let inbox = model.status?.inbox, inbox.new > 0 {
                    Section {
                        Label("\(inbox.new) new track\(inbox.new == 1 ? "" : "s") waiting in your inbox. Love, rate 4–5 or Keep to keep them.",
                              systemImage: "tray.full")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Section("Made for you") {
                    if loaded && playlists.isEmpty {
                        Text("No playlists yet. Run Daily Mixes or Discover Weekly from the Create tab.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(sorted) { p in
                        NavigationLink(value: PlaylistRef(key: p.key, name: p.name, comment: p.comment)) {
                            PlaylistRow(name: p.name, subtitle: subtitle(p), kind: p.kind,
                                        cover: p.tracks.first.flatMap { model.resolver?.artwork(songId: $0.songId, size: 120) })
                        }
                    }
                }
                Section("Your playlists") {
                    if let ownError { Text(ownError).foregroundStyle(.secondary) }
                    ForEach(own) { p in
                        NavigationLink(value: PlaylistRef(key: p.key, name: p.name, comment: p.comment, readonly: p.readonly)) {
                            PlaylistRow(name: p.name, subtitle: "\(p.count) songs", kind: .own, cover: nil)
                        }
                    }
                }
            }
            .navigationTitle("Playlists")
            .navigationDestination(for: PlaylistRef.self) { PlaylistDetailView(ref: $0) }
            .refreshable { await load() }
            .task(id: model.dataVersion) { await load() }
            .overlay { if !loaded { ProgressView() } }
        }
    }

    /// Discover Weekly, Release Radar, then Daily Mixes in order, then prompt playlists.
    private var sorted: [Playlist] {
        func rank(_ p: Playlist) -> (Int, String) {
            switch p.kind {
            case .discover: (0, "")
            case .releaseRadar: (1, "")
            case .dailyMix: (2, String(format: "%04d", Int(p.key.split(separator: "_").last ?? "") ?? 0))
            default: (3, p.name.lowercased())
            }
        }
        return playlists.sorted { rank($0) < rank($1) }
    }

    private func subtitle(_ p: Playlist) -> String {
        var parts = ["\(p.tracks.count) songs"]
        if p.newCount > 0 { parts.append("\(p.newCount) new") }
        if let u = p.updatedAt { parts.append("updated \(Optional(u).ago)") }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        guard let api = model.crate else { return }
        async let pls = api.playlists()
        async let mine = api.ownPlaylists()
        if let p = try? await pls { playlists = p }
        do { own = try await mine; ownError = nil } catch { ownError = error.localizedDescription }
        loaded = true
    }
}

struct PlaylistRow: View {
    let name: String
    let subtitle: String
    let kind: PlaylistKind
    let cover: URL?

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Artwork(url: cover, size: 52)
                Image(systemName: kind.symbol)
                    .font(.caption2.bold()).foregroundStyle(.white)
                    .padding(4).background(kind.color, in: Circle())
                    .offset(x: 4, y: 4)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
