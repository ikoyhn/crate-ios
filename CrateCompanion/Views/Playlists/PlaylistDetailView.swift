import CrateKit
import SwiftUI

struct PlaylistDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(AudioPlayer.self) private var player
    let ref: PlaylistRef

    enum Tab: String, CaseIterable { case tracks = "Songs", suggested = "Suggested" }
    @State private var tab: Tab = .tracks
    @State private var tracks: [Track] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var showAll = false
    @State private var confirmRegenerate = false
    /// Held here rather than on the row: a sheet owned by a List row is dismissed again when the
    /// row's swipe actions close or the row is rebuilt, so it would sometimes flash shut.
    @State private var addingToPlaylist: Track?
    /// Songs you've removed: hidden straight away, even before Crate's job deletes them.
    @State private var removed: Set<String> = []

    private var regenerateJob: String? { ref.kind.job(key: ref.key) }
    private var promptId: Int? { PlaylistKind.promptId(key: ref.key) }
    private let pageSize = 50

    init(ref: PlaylistRef) {
        self.ref = ref
        _tab = State(initialValue: ref.kind == .own ? .suggested : .tracks)  // your own playlists open on suggestions
    }

    var body: some View {
        List {
            header
            Picker("Show", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)

            switch tab {
            case .tracks: trackList
            case .suggested: SuggestionsSection(ref: ref, onAdded: { Task { await load() } })
            }
        }
        .listStyle(.plain)
        .navigationTitle(ref.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .refreshable { await load() }
        .task(id: model.dataVersion) { await load() }
        .sheet(item: $addingToPlaylist) { t in AddToPlaylistSheet(songId: t.songId, title: t.title) }
        .confirmationDialog("Rebuild \(ref.name)?", isPresented: $confirmRegenerate, titleVisibility: .visible) {
            Button("Rebuild now") { regenerate() }
        } message: {
            Text(ref.kind == .dailyMix
                 ? "Rebuilds all Daily Mixes from your library. Songs you added stay."
                 : "Builds a fresh set. New tracks you haven't kept leave the inbox; songs you added stay.")
        }
    }

    // MARK: - header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let comment = ref.comment, !comment.isEmpty {
                Text(comment).font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button { playAll(shuffle: false) } label: { Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                Button { playAll(shuffle: true) } label: { Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
            }
            .disabled(tracks.isEmpty)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .listRowSeparator(.hidden)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if regenerateJob != nil || promptId != nil {
                    Button { confirmRegenerate = true } label: { Label("Rebuild now", systemImage: "arrow.triangle.2.circlepath") }
                }
                Button { tab = .suggested } label: { Label("Suggested songs", systemImage: "sparkles") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private func regenerate() {
        if let job = regenerateJob {
            model.runNow(job, label: ref.kind == .dailyMix ? "Daily Mixes" : ref.name)
        } else if let id = promptId {
            Task { model.track(await model.attempt("Couldn't rebuild it") { try await $0.rerunPrompt(id) }, ref.name) }
        }
    }

    // MARK: - tracks

    @ViewBuilder
    private var trackList: some View {
        if !loaded {
            ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden)
        } else if tracks.isEmpty {
            Text("No songs in this playlist yet.").foregroundStyle(.secondary)
        }
        let shown = showAll ? tracks : Array(tracks.prefix(pageSize))
        ForEach(Array(shown.enumerated()), id: \.element.id) { i, t in
            TrackRow(track: t, playlistKey: ref.key, isCurrent: player.current?.songId == t.songId,
                     onPlay: { play(from: i) },
                     onChange: { updated in if let j = tracks.firstIndex(where: { $0.id == t.id }) { tracks[j] = updated } },
                     onTakeOut: { takeOut(t) },
                     onRemove: { remove(t) },
                     onAddToPlaylist: { addToPlaylist(t) })
        }
        if !showAll && tracks.count > pageSize {
            Button("Show all \(tracks.count) songs") { showAll = true }
        }
    }

    private func items() -> [PlayableItem] {
        tracks.compactMap { model.resolver?.item($0, playlistKey: ref.key) }
    }

    private func play(from index: Int) {
        player.play(items(), startAt: index)
    }

    private func playAll(shuffle: Bool) {
        player.play(items(), startAt: shuffle ? Int.random(in: 0..<max(tracks.count, 1)) : 0, shuffle: shuffle)
    }

    private func takeOut(_ t: Track) {
        Task {
            guard await model.attempt("Couldn't take it out", { try await $0.takeOut(t.songId, from: ref.key) }) != nil else { return }
            tracks.removeAll { $0.id == t.id }
            model.say("Took \(t.title) out of \(ref.name)")
        }
    }

    /// Not for me: out of the list now, deleted and never suggested again by Crate.
    private func remove(_ t: Track) {
        removed.insert(t.songId)
        withAnimation { tracks.removeAll { $0.id == t.id } }
        model.remove(t.songId, title: t.title) {
            removed.remove(t.songId)
            Task { await load() }
        }
    }

    private func addToPlaylist(_ t: Track) {
        // let the swipe actions finish closing first, or the sheet can be dismissed with them
        Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            addingToPlaylist = t
        }
    }

    private func load() async {
        guard let api = model.crate else { return }
        do {
            tracks = try await api.tracks(forKey: ref.key).filter { !removed.contains($0.songId) }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }
}

/// A song in a playlist, with its inbox state, heart, and the keep / remove / rate actions.
struct TrackRow: View {
    @Environment(AppModel.self) private var model
    @Environment(AudioPlayer.self) private var player
    let track: Track
    let playlistKey: String?
    var isCurrent = false
    let onPlay: () -> Void
    let onChange: (Track) -> Void
    var onTakeOut: (() -> Void)?
    let onRemove: () -> Void
    let onAddToPlaylist: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPlay) {
                HStack(spacing: 12) {
                    Artwork(url: model.resolver?.artwork(songId: track.songId, size: 120), size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title).lineLimit(1)
                            .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                        HStack(spacing: 6) {
                            if track.state == .new { Badge(text: "New") }
                            if track.state == .kept { Badge(text: "Kept", color: .green) }
                            if track.addedByYou { Badge(text: "Added by you", color: .blue) }
                            Text(track.artist).lineLimit(1)
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if track.rating > 0 {
                Label("\(track.rating)", systemImage: "star.fill").labelStyle(.titleAndIcon)
                    .font(.caption2).foregroundStyle(.yellow)
            }
            if track.state == .new {
                Button(action: onRemove) {
                    Image(systemName: "hand.thumbsdown").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Not for me")
            }
            HeartButton(starred: track.starred) { toggleStar() }
        }
        .swipeActions(edge: .leading) {
            if track.state == .new {
                Button { keep() } label: { Label("Keep", systemImage: "checkmark") }.tint(.green)
            } else {
                Button { toggleStar() } label: { Label(track.starred ? "Unlove" : "Love", systemImage: "heart") }.tint(.pink)
            }
            Button(action: onAddToPlaylist) { Label("Add to playlist", systemImage: "text.badge.plus") }.tint(.blue)
        }
        .swipeActions(edge: .trailing) {
            if track.state == .new {
                Button(role: .destructive, action: onRemove) { Label("Not for me", systemImage: "hand.thumbsdown") }
            } else if track.addedByYou, let onTakeOut {
                Button(role: .destructive, action: onTakeOut) { Label("Take out", systemImage: "minus.circle") }
            }
        }
        .contextMenu { menu }
    }

    @ViewBuilder
    private var menu: some View {
        if let item = model.resolver?.item(track, playlistKey: playlistKey) {
            Button { player.playNext(item) } label: { Label("Play next", systemImage: "text.insert") }
            Button { player.addToQueue(item) } label: { Label("Add to queue", systemImage: "text.append") }
        }
        Button(action: onAddToPlaylist) { Label("Add to playlist…", systemImage: "text.badge.plus") }
        Divider()
        Button { toggleStar() } label: { Label(track.starred ? "Unlove" : "Love", systemImage: track.starred ? "heart.slash" : "heart") }
        Menu {
            ForEach((0...5).reversed(), id: \.self) { n in
                Button { rate(n) } label: {
                    Text(n == 0 ? "No rating" : String(repeating: "★", count: n)) + Text(n == track.rating ? "  ✓" : "")
                }
            }
        } label: { Label("Rate", systemImage: "star") }
        if track.state == .new {
            Divider()
            Button { keep() } label: { Label("Keep in my library", systemImage: "checkmark.circle") }
            Button(role: .destructive, action: onRemove) { Label("Not for me", systemImage: "hand.thumbsdown") }
        }
        if track.addedByYou, let onTakeOut {
            Button(role: .destructive, action: onTakeOut) { Label("Take out of playlist", systemImage: "minus.circle") }
        }
    }

    private func toggleStar() {
        var t = track
        t.starred.toggle()
        t.liked = t.starred || t.rating >= 4
        if t.starred && t.state == .new { t.state = .kept }  // starring an inbox track keeps it
        onChange(t)
        model.setStar(track.songId, t.starred)
    }

    private func rate(_ n: Int) {
        var t = track
        t.rating = n
        if t.state == .new && n >= 4 { t.state = .kept }
        onChange(t)
        model.setRating(track.songId, n)
    }

    private func keep() {
        var t = track
        t.state = .kept
        t.starred = true
        onChange(t)
        model.keep(track.songId)
    }
}
