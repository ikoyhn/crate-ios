import CrateKit
import SwiftUI

struct PlaylistDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(AudioPlayer.self) private var player
    @Environment(DownloadStore.self) private var downloads
    let ref: PlaylistRef

    enum Tab: String, CaseIterable { case tracks = "Songs", suggested = "Suggested" }
    @State private var tab: Tab = .tracks
    /// Which songs the list shows: all, or just the new / kept / added-by-you ones.
    enum Filter { case all, new, kept, added }
    @State private var filter: Filter = .all
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
    /// Couldn't reach the server: showing the copy saved on the phone.
    @State private var offline = false

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
            } else {
                chips
                switch tab {
                case .tracks: trackList
                case .suggested: SuggestionsSection(ref: ref, onAdded: { Task { await load() } })
                }
            }
        }
        .listStyle(.plain)
        .crateScreen()
        .navigationTitle(selecting ? "\(selected.count) selected" : "")
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
        VStack(spacing: 14) {
            cover
                .shadow(color: Theme.amber.opacity(0.2), radius: 26, y: 12)
                .padding(.top, 4)
            VStack(spacing: 6) {
                Text(ref.name).font(Theme.display(28)).tracking(-0.6)
                    .multilineTextAlignment(.center).lineLimit(2)
                if let comment = ref.comment, !comment.isEmpty {
                    Text(comment).font(.subheadline).foregroundStyle(Theme.textMedium)
                        .multilineTextAlignment(.center).lineLimit(3)
                }
            }
            stats
            if downloads.isSaved(playlist: ref.key) { downloadStatus }
            if offline {
                Label("Offline: showing the songs downloaded to this phone", systemImage: "wifi.slash")
                    .font(.caption).foregroundStyle(Theme.textMedium)
            } else if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            actions
        }
        .frame(maxWidth: .infinity)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private var cover: some View {
        if ref.kind == .own, ref.key.hasPrefix("nd:") {
            PlaylistCover(playlistId: String(ref.key.dropFirst(3)), size: 210)
        } else {
            Artwork(url: tracks.first.flatMap { downloads.localCover($0.songId) ?? model.resolver?.artwork(songId: $0.songId, size: 600) },
                    size: 210, corner: 8)
        }
    }

    /// "30 songs, 1 hr 54 min" and how many are new or kept.
    private var stats: some View {
        let seconds = tracks.reduce(0) { $0 + $1.duration }
        let length = Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        let new = tracks.filter { $0.state == .new }.count
        let kept = tracks.filter { $0.state == .kept }.count
        return HStack(spacing: 8) {
            Text("\(tracks.count) songs" + (seconds > 0 ? ", \(length)" : ""))
                .font(.footnote.weight(.semibold))
            if new + kept > 0 {
                HStack(spacing: 6) {
                    if kept > 0 { Text("\(kept) KEPT") }
                    if kept > 0 && new > 0 { Text("·") }
                    if new > 0 { Text("\(new) NEW") }
                }
                .font(Theme.caps).tracking(0.6).foregroundStyle(Theme.amber)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Theme.amber.opacity(0.14), in: Capsule())
            }
        }
    }

    /// Download, the ⋯ menu, shuffle, and the big play button.
    private var actions: some View {
        HStack(spacing: 22) {
            Button {
                if downloads.isSaved(playlist: ref.key) { downloads.removePlaylist(ref.key) } else { downloadPlaylist() }
            } label: {
                Image(systemName: downloads.isSaved(playlist: ref.key) ? "arrow.down.circle.fill" : "arrow.down.circle")
                    .font(.title2)
                    .foregroundStyle(downloads.isSaved(playlist: ref.key) ? Theme.amber : Theme.textMedium)
            }
            .accessibilityLabel(downloads.isSaved(playlist: ref.key) ? "Remove download" : "Download")
            .disabled(tracks.isEmpty)
            Menu { menuItems } label: {
                Image(systemName: "ellipsis").font(.title2).foregroundStyle(Theme.textMedium)
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("More")
            Spacer()
            Button { playAll(shuffle: true) } label: {
                Image(systemName: "shuffle").font(.title2).foregroundStyle(Theme.amber)
            }
            .accessibilityLabel("Shuffle")
            .disabled(tracks.isEmpty)
            PlayCircle(isPlaying: isPlayingHere && player.isPlaying, size: 58) {
                if isPlayingHere { player.toggle() } else { playAll(shuffle: false) }
            }
            .disabled(tracks.isEmpty)
        }
        .buttonStyle(.borderless)
        .padding(.top, 2)
    }

    /// Something from this playlist is what's playing.
    private var isPlayingHere: Bool {
        guard let cur = player.current, cur.playlistKey == ref.key, !cur.isSuggestion else { return false }
        return true
    }

    /// All · New · Kept · Added by you · Suggested
    private var chips: some View {
        let new = tracks.filter { $0.state == .new }.count
        let kept = tracks.filter { $0.state == .kept }.count
        let added = tracks.filter(\.addedByYou).count
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Chip(title: "All (\(tracks.count))", selected: tab == .tracks && filter == .all) { show(.tracks, .all) }
                if new > 0 {
                    Chip(title: "New (\(new))", selected: tab == .tracks && filter == .new, dot: Theme.amber) { show(.tracks, .new) }
                }
                if kept > 0 {
                    Chip(title: "Kept (\(kept))", systemImage: "checkmark", selected: tab == .tracks && filter == .kept) { show(.tracks, .kept) }
                }
                if added > 0 {
                    Chip(title: "Added by you", selected: tab == .tracks && filter == .added) { show(.tracks, .added) }
                }
                if ref.kind != .liked {  // Crate has no suggestions for Liked Songs
                    Chip(title: "Suggested", systemImage: "sparkles", selected: tab == .suggested) { show(.suggested, .all) }
                }
            }
            .padding(.horizontal, 16)
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func show(_ t: Tab, _ f: Filter) {
        withAnimation(.easeOut(duration: 0.2)) { tab = t; filter = f }
    }

    private var filtered: [Track] {
        switch filter {
        case .all: tracks
        case .new: tracks.filter { $0.state == .new }
        case .kept: tracks.filter { $0.state == .kept }
        case .added: tracks.filter(\.addedByYou)
        }
    }

    private var downloadStatus: some View {
        let (have, total) = downloads.counts(playlist: ref.key)
        return Label(have >= total ? "Downloaded" : "Downloading \(have) of \(total)",
                     systemImage: have >= total ? "arrow.down.circle.fill" : "arrow.down.circle")
            .font(.caption).foregroundStyle(have >= total ? Color.accentColor : .secondary)
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
                    Button { downloadSelected() } label: { Label("Download", systemImage: "arrow.down.circle") }
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
                Button("Select") { show(.tracks, .all); selecting = true }
                    .disabled(tracks.isEmpty)
            }
        }
    }

    /// The ⋯ menu in the header.
    @ViewBuilder
    private var menuItems: some View {
        if downloads.isSaved(playlist: ref.key) {
            Button(role: .destructive) { downloads.removePlaylist(ref.key) } label: {
                Label("Remove download", systemImage: "xmark.circle")
            }
        } else {
            Button { downloadPlaylist() } label: { Label("Download", systemImage: "arrow.down.circle") }
                .disabled(tracks.isEmpty)
        }
        Button { show(.tracks, .all); selecting = true } label: { Label("Select songs", systemImage: "checkmark.circle") }
            .disabled(tracks.isEmpty)
        if ref.kind != .liked {  // nothing to rebuild or suggest for Liked Songs
            if regenerateJob != nil || promptId != nil {
                Button { confirmRegenerate = true } label: { Label("Rebuild now", systemImage: "arrow.triangle.2.circlepath") }
            }
            Button { show(.suggested, .all) } label: { Label("Suggested songs", systemImage: "sparkles") }
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
            Text(ref.kind == .liked ? "Songs you ♥ show up here." : "No songs in this playlist yet.")
                .foregroundStyle(Theme.textMedium)
                .listRowBackground(Color.clear)
        }
        let list = selecting ? tracks : filtered
        let shown = showAll || selecting ? list : Array(list.prefix(pageSize))
        ForEach(Array(shown.enumerated()), id: \.element.id) { i, t in
            Group {
                if selecting {
                    SelectableTrackRow(track: t, isSelected: selected.contains(t.songId)) { toggle(t.songId) }
                } else {
                    TrackRow(track: t, playlistKey: ref.key, isCurrent: player.current?.songId == t.songId,
                             onPlay: { play(list, from: i) },
                             onChange: { updated in if let j = tracks.firstIndex(where: { $0.id == t.id }) { tracks[j] = updated } },
                             onTakeOut: { takeOut(t) },
                             onRemove: { remove(t) },
                             onKeep: { keep(t) })
                }
            }
            .listRowInsets(EdgeInsets(top: 9, leading: 22, bottom: 9, trailing: 22))
            .listRowBackground(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface1)
                .padding(.horizontal, 12).padding(.vertical, 3))
            .listRowSeparator(.hidden)
        }
        if !showAll && !selecting && list.count > pageSize {
            Button("Show all \(list.count) songs") { showAll = true }
                .foregroundStyle(Theme.amber)
                .listRowBackground(Color.clear)
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

    private func downloadSelected() {
        downloads.download(selected.compactMap { id in tracks.first { $0.songId == id } })
        model.say("Downloading \(selected.count) songs")
        endSelecting()
    }

    /// Saved on the phone, and kept in step with the playlist whenever it's opened online.
    private func downloadPlaylist() {
        downloads.save(playlist: ref.key, name: ref.name, comment: ref.comment, tracks: tracks)
        model.say("Downloading \(ref.name)")
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

    private func play(_ list: [Track], from index: Int) {
        player.play(list.compactMap { model.resolver?.item($0, playlistKey: ref.key) }, startAt: index)
    }

    private func keep(_ t: Track) {
        if let j = tracks.firstIndex(where: { $0.id == t.id }) { tracks[j].state = .kept; tracks[j].starred = true }
        model.keep(t.songId)
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
            offline = false
            downloads.sync(playlist: ref.key, name: ref.name, comment: ref.comment, tracks: tracks)
        } catch {
            if downloads.isSaved(playlist: ref.key) {
                tracks = downloads.tracks(playlist: ref.key)
                offline = true
            }
            self.error = error.localizedDescription
        }
        loaded = true
    }
}

/// A song in a playlist, with its inbox state, heart, and the keep / remove / rate actions.
struct TrackRow: View {
    @Environment(AppModel.self) private var model
    @Environment(AudioPlayer.self) private var player
    @Environment(DownloadStore.self) private var downloads
    @Environment(\.pickPlaylist) private var pickPlaylist
    let track: Track
    let playlistKey: String?
    var isCurrent = false
    let onPlay: () -> Void
    let onChange: (Track) -> Void
    var onTakeOut: (() -> Void)?
    /// Not for me on a new song. A list can pass its own to hide the row straight away.
    var onRemove: (() -> Void)?
    /// Keep on a new song. A list can pass its own to update the row straight away.
    var onKeep: (() -> Void)?
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPlay) {
                HStack(spacing: 12) {
                    Artwork(url: downloads.localCover(track.songId) ?? model.resolver?.artwork(songId: track.songId, size: 120), size: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(track.title).font(.body.weight(.semibold)).lineLimit(1)
                                .foregroundStyle(isCurrent ? Theme.amber : Color.white)
                            if isCurrent { PlayingBars(animating: player.isPlaying) }
                        }
                        HStack(spacing: 6) {
                            DownloadMark(songId: track.songId)
                            if track.state == .new { Badge(text: "New") }
                            if track.state == .kept { Badge(text: "Kept", color: Theme.honey) }
                            if track.addedByYou { Badge(text: "Added by you", color: Color(hex: 0x93CCFF)) }
                            Text(track.artist).lineLimit(1)
                        }
                        .font(.caption).foregroundStyle(Theme.textMedium)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if track.rating > 0 {
                Label("\(track.rating)", systemImage: "star.fill").labelStyle(.titleAndIcon)
                    .font(.caption2).foregroundStyle(Theme.honey)
            }
            if track.state == .new {
                CircleIconButton(systemImage: "checkmark", size: 32, label: "Keep") { keep() }
                CircleIconButton(systemImage: "xmark", size: 32, label: "Not for me", action: remove)
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
        if downloads.isDownloaded(track.songId) {
            Button { downloads.removeDownload(track.songId) } label: { Label("Remove download", systemImage: "xmark.circle") }
        } else if !downloads.isDownloading(track.songId) {
            Button { downloads.download([track]) } label: { Label("Download", systemImage: "arrow.down.circle") }
        }
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
        if let onKeep { onKeep(); return }
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
    @Environment(DownloadStore.self) private var downloads
    let track: Track
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            Artwork(url: downloads.localCover(track.songId) ?? model.resolver?.artwork(songId: track.songId, size: 120), size: 44)
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

/// A small arrow by a song that's on the phone, or a spinner while it downloads.
struct DownloadMark: View {
    @Environment(DownloadStore.self) private var downloads
    let songId: String

    var body: some View {
        if downloads.isDownloaded(songId) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
                .accessibilityLabel("Downloaded")
        } else if let p = downloads.progress[songId] {
            ProgressView(value: max(p, 0.02)).progressViewStyle(.circular).controlSize(.mini)
                .accessibilityLabel("Downloading")
        }
    }
}
