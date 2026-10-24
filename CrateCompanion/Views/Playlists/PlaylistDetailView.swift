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
    /// Select mode: tick songs, then act on them all at once.
    @State private var selecting = false
    @State private var selected: [String] = []  // song ids, in the order you ticked them
    @State private var addingSelected = false
    @State private var confirmDeleteSelected = false
    /// Songs you've removed: hidden straight away, even before Crate's job deletes them.
    @State private var removed: Set<String> = []

    private var regenerateJob: String? { ref.kind.job(key: ref.key) }
    private var promptId: Int? { PlaylistKind.promptId(key: ref.key) }
    private let pageSize = 50

    // Explicit, as the private properties would make the memberwise init private
    init(ref: PlaylistRef) { self.ref = ref }

    var body: some View {
        List {
            header
            if selecting {
                trackList
            } else if ref.kind == .liked {
                trackList  // Crate has no suggestions for Liked Songs
            } else {
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
        }
        .listStyle(.plain)
        .navigationTitle(selecting ? "\(selected.count) selected" : ref.name)
        .navigationBarBackButtonHidden(selecting)
        .sheet(isPresented: $addingSelected) {
            AddToPlaylistSheet(songIds: selected) { endSelecting() }
        }
        .confirmationDialog("Delete \(selected.count) songs from your library?", isPresented: $confirmDeleteSelected,
                            titleVisibility: .visible) {
            Button("Delete \(selected.count) songs", role: .destructive) {
                model.deleteFromLibrary(selected, label: "Deleting \(selected.count) songs")
                tracks.removeAll { selected.contains($0.songId) }
                endSelecting()
            }
        } message: {
            Text("Their files are deleted for good, they leave your playlists, and Crate won't suggest them again. New songs still in the inbox are just removed.")
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .refreshable { await load() }
        .task(id: model.dataVersion) { await load() }
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
        if selecting {
            ToolbarItem(placement: .topBarLeading) {
                Button(selected.count == tracks.count ? "Deselect all" : "Select all") {
                    selected = selected.count == tracks.count ? [] : tracks.map(\.songId)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { addingSelected = true } label: { Label("Add to playlist…", systemImage: "text.badge.plus") }
                    Button { loveSelected() } label: { Label("Love", systemImage: "heart") }
                    Divider()
                    Button { playSelected(next: false) } label: { Label("Play", systemImage: "play") }
                    Button { playSelected(next: true) } label: { Label("Add to queue", systemImage: "text.append") }
                    Divider()
                    Button(role: .destructive) { confirmDeleteSelected = true } label: {
                        Label("Delete from library…", systemImage: "trash")
                    }
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
                .disabled(selected.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { endSelecting() }.bold()
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Select") { tab = .tracks; selecting = true }
                    .disabled(tracks.isEmpty)
            }
            toolbarMenu
        }
    }

    @ToolbarContentBuilder
    private var toolbarMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if regenerateJob != nil || promptId != nil {
                    Button { confirmRegenerate = true } label: { Label("Rebuild now", systemImage: "arrow.triangle.2.circlepath") }
                }
                Button { tab = .suggested } label: { Label("Suggested songs", systemImage: "sparkles") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .opacity(ref.kind == .liked ? 0 : 1)  // nothing to rebuild or suggest for Liked Songs
            .disabled(ref.kind == .liked)
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
            Text(ref.kind == .liked ? "Songs you ♥ show up here." : "No songs in this playlist yet.").foregroundStyle(.secondary)
        }
        let shown = showAll || selecting ? tracks : Array(tracks.prefix(pageSize))
        ForEach(Array(shown.enumerated()), id: \.element.id) { i, t in
            if selecting {
                SelectableTrackRow(track: t, isSelected: selected.contains(t.songId)) { toggle(t.songId) }
            } else {
                TrackRow(track: t, playlistKey: ref.key, isCurrent: player.current?.songId == t.songId,
                         onPlay: { play(from: i) },
                         onChange: { updated in if let j = tracks.firstIndex(where: { $0.id == t.id }) { tracks[j] = updated } },
                         onTakeOut: { takeOut(t) },
                         onRemove: { remove(t) })
            }
        }
        if !showAll && !selecting && tracks.count > pageSize {
            Button("Show all \(tracks.count) songs") { showAll = true }
        }
    }

    // MARK: - selection

    private func toggle(_ songId: String) {
        if let i = selected.firstIndex(of: songId) { selected.remove(at: i) } else { selected.append(songId) }
    }

    private func endSelecting() {
        selecting = false
        selected = []
    }

    private func loveSelected() {
        for id in selected { model.setStar(id, true) }
        for i in tracks.indices where selected.contains(tracks[i].songId) { tracks[i].starred = true }
        model.say("Loved \(selected.count) songs")
        endSelecting()
    }

    /// Play the selection now, or add it to the end of the queue.
    private func playSelected(next: Bool) {
        let chosen = selected.compactMap { id in tracks.first { $0.songId == id } }
            .compactMap { model.resolver?.item($0, playlistKey: ref.key) }
        if next { for item in chosen { player.addToQueue(item) } } else { player.play(chosen) }
        endSelecting()
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

    private func load() async {
        guard let api = model.crate else { return }
        do {
            if ref.kind == .liked {
                guard let nd = model.navidrome else { return }
                tracks = try await nd.starredSongs()
            } else {
                tracks = try await api.tracks(forKey: ref.key).filter { !removed.contains($0.songId) }
            }
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
    @Environment(\.pickPlaylist) private var pickPlaylist
    let track: Track
    let playlistKey: String?
    var isCurrent = false
    let onPlay: () -> Void
    let onChange: (Track) -> Void
    var onTakeOut: (() -> Void)?
    /// Not for me on a new song. A list can pass its own to hide the row straight away.
    var onRemove: (() -> Void)?
    @State private var confirmDelete = false

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
                Button(action: remove) {
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
            Button(action: addToPlaylist) { Label("Add to playlist", systemImage: "text.badge.plus") }.tint(.blue)
        }
        .swipeActions(edge: .trailing) {
            if track.state == .new {
                Button(role: .destructive, action: remove) { Label("Not for me", systemImage: "hand.thumbsdown") }
            } else if track.addedByYou, let onTakeOut {
                Button(role: .destructive, action: onTakeOut) { Label("Take out", systemImage: "minus.circle") }
            }
        }
        .contextMenu { menu }
        .confirmationDialog("Delete \(track.title) from your library?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { model.deleteFromLibrary([track.songId], label: "Deleting \(track.title)") }
        } message: {
            Text("The file is deleted for good, the song leaves your playlists, and Crate won't suggest it again.")
        }
    }

    @ViewBuilder
    private var menu: some View {
        if let item = model.resolver?.item(track, playlistKey: playlistKey) {
            Button { player.playNext(item) } label: { Label("Play next", systemImage: "text.insert") }
            Button { player.addToQueue(item) } label: { Label("Add to queue", systemImage: "text.append") }
        }
        Button(action: addToPlaylist) { Label("Add to playlist…", systemImage: "text.badge.plus") }
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
            Button(role: .destructive, action: remove) { Label("Not for me", systemImage: "hand.thumbsdown") }
        }
        if track.addedByYou, let onTakeOut {
            Button(role: .destructive, action: onTakeOut) { Label("Take out of playlist", systemImage: "minus.circle") }
        }
        if track.state != .new {
            Divider()
            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete from library…", systemImage: "trash") }
        }
    }

    private func addToPlaylist() {
        pickPlaylist(PlaylistPick(song: .library(track.songId), title: track.title))
    }

    private func remove() {
        if let onRemove { onRemove() } else { model.remove(track.songId, title: track.title) }
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

/// A song in select mode: tap anywhere on the row to tick it.
struct SelectableTrackRow: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            Artwork(url: model.resolver?.artwork(songId: track.songId, size: 120), size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title).lineLimit(1)
                Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
