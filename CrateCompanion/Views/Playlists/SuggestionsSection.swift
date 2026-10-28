import CrateKit
import SwiftUI

/// Suggested songs for a playlist: new songs (30 s previews, downloaded when added), alternating
/// with songs from your library on your own playlists. 👎 teaches Crate; Refresh shows a different batch.
struct SuggestionsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(AudioPlayer.self) private var player
    @Environment(\.pickPlaylist) private var pickPlaylist
    let ref: PlaylistRef
    let onAdded: () -> Void

    @State private var items: [Suggestion] = []
    @State private var working = false
    @State private var error: String?
    @State private var updated: Double?
    /// Suggestion id -> what's happening to it.
    @State private var adding: [String: AddState] = [:]

    enum AddState { case adding, downloading, added }

    var body: some View {
        Section {
            if working && items.isEmpty {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Listening for songs that fit… this takes a minute the first time.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } else if let error {
                Text(error).foregroundStyle(.secondary)
            } else if items.isEmpty {
                Text("No suggestions right now. Try Refresh.").foregroundStyle(.secondary)
            }
            ForEach(items) { s in
                row(s)
                    .listRowInsets(EdgeInsets(top: 9, leading: 22, bottom: 9, trailing: 22))
                    .listRowBackground(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface1)
                        .padding(.horizontal, 12).padding(.vertical, 3))
                    .listRowSeparator(.hidden)
            }
        } header: {
            HStack {
                Text(updated.map { "Updated \(Optional($0).ago)" } ?? "Suggested songs")
                Spacer()
                if working && !items.isEmpty { ProgressView().controlSize(.small) }
                Button { Task { await refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .font(.caption.bold()).foregroundStyle(Theme.amber).disabled(working)
            }
        } footer: {
            Text((ref.readonly
                 ? "Navidrome won't let Crate change this playlist, but you can add suggestions to your other playlists. "
                 : ref.kind == .own
                 ? "👎 on a new song: never suggested again, and similar songs rank lower. On a library song: just not for this playlist. "
                 : "New songs only: songs you already have are suggested for your own playlists. + saves a song to your library. "
                   + "👎: never suggested again, and similar songs rank lower. ")
                 + "Add to playlist puts a song into any of your playlists; a new song is downloaded into your library first.")
        }
        .task(id: ref.key) { await poll() }
    }

    @ViewBuilder
    private func row(_ s: Suggestion) -> some View {
        let item = model.resolver?.item(s, playlistKey: ref.key)
        let isCurrent = item != nil && player.current?.id == item?.id
        HStack(spacing: 12) {
            ZStack {
                Artwork(url: cover(s), size: 48)
                Image(systemName: isCurrent && player.isPlaying ? "speaker.wave.2.fill" : "play.fill")
                    .font(.caption.bold()).foregroundStyle(.white)
                    .padding(6).background(.black.opacity(0.45), in: Circle())
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(s.title).font(.body.weight(.semibold)).lineLimit(1)
                    .foregroundStyle(isCurrent ? Theme.amber : Color.white)
                Text(s.artist).font(.caption).foregroundStyle(Theme.textMedium).lineLimit(1)
                HStack(spacing: 6) {
                    if s.kind == .new { Badge(text: "New") }
                    Text(s.reason).lineLimit(1)
                }
                .font(.caption2).foregroundStyle(Theme.textLow)
            }
            Spacer(minLength: 0)

            CircleIconButton(systemImage: "hand.thumbsdown", tint: Theme.textMedium, size: 32, label: "Not for me") { dislike(s) }

            if adding[s.id] == nil {
                // Into any of your playlists; a new song is downloaded into your library first
                CircleIconButton(systemImage: "text.badge.plus", tint: Theme.textMedium, size: 32,
                                 label: "Add to playlist…") { send(s) }
            }
            if !ref.readonly { addButton(s) }
        }
        // Tap anywhere on the row to play (or pause) it; the 👎 and + buttons keep their own taps
        .contentShape(Rectangle())
        .onTapGesture { playOrPause(item, isCurrent: isCurrent) }
        .accessibilityAction(named: isCurrent && player.isPlaying ? "Pause" : "Play") { playOrPause(item, isCurrent: isCurrent) }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { dislike(s) } label: { Label("Not for me", systemImage: "hand.thumbsdown") }
        }
        .swipeActions(edge: .leading) {
            if adding[s.id] == nil {
                Button { send(s) } label: { Label("Playlist", systemImage: "text.badge.plus") }.tint(.blue)
                if !ref.readonly {
                    // your own playlist: straight in; one of Crate's: pinned so it stays across rebuilds
                    Button { add(s) } label: { Label(ref.kind == .own ? "Add" : "Add here", systemImage: ref.kind == .own ? "plus" : "pin") }
                        .tint(.accentColor)
                }
            }
        }
        .contextMenu {
            Button { queue(s, item, next: true) } label: {
                Label(s.kind == .new ? "Download and play next" : "Play next", systemImage: "text.insert")
            }
            Button { queue(s, item, next: false) } label: {
                Label(s.kind == .new ? "Download and add to queue" : "Add to queue", systemImage: "text.append")
            }
            if adding[s.id] == nil {
                Button { send(s) } label: { Label("Add to playlist…", systemImage: "text.badge.plus") }
                if !ref.readonly {
                    Button { add(s) } label: { Label(ref.kind == .own ? "Add to this playlist" : "Keep in this playlist",
                                                     systemImage: ref.kind == .own ? "plus" : "pin") }
                }
            }
        }
    }

    @ViewBuilder
    private func addButton(_ s: Suggestion) -> some View {
        switch adding[s.id] {
        case .adding:
            ProgressView().controlSize(.small)
        case .downloading:
            Label("Getting…", systemImage: "arrow.down.circle").labelStyle(.iconOnly).foregroundStyle(.secondary)
        case .added:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case nil:
            if ref.kind == .own {
                // your own playlist: adding saves it and puts it here
                Button { add(s) } label: { Image(systemName: "plus.circle").font(.title3) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Add to playlist")
            } else {
                // Crate rebuilds its playlists, so + just saves it (swipe right for a playlist)
                Button { save(s) } label: { Image(systemName: "plus.circle").font(.title3) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(s.kind == .library ? "Like it" : "Save to my library")
            }
        }
    }

    private func cover(_ s: Suggestion) -> URL? {
        if s.kind == .library, let id = s.songId { return model.resolver?.artwork(songId: id, size: 120) }
        return model.crate?.mediaURL(s.cover)
    }

    // MARK: - actions

    private func playOrPause(_ item: PlayableItem?, isCurrent: Bool) {
        guard let item else { return }
        if isCurrent { player.toggle() } else { player.play(item) }
    }

    private func add(_ s: Suggestion) {
        adding[s.id] = .adding
        Task {
            guard let started = await model.attempt("Couldn't add it", { try await $0.add(s, to: ref.key) }) else {
                adding[s.id] = nil
                return
            }
            if s.kind == .library {
                adding[s.id] = .added
                model.say("Added \(s.title) to \(ref.name)")
                onAdded()
            } else {
                // a new song: Crate downloads it into your library, then adds it
                adding[s.id] = .downloading
                model.track(started, "Adding \(s.title)")
            }
        }
    }

    /// A library song is queued now; a new one is downloaded into your library, then queued
    /// (rather than queueing its 30-second preview).
    private func queue(_ s: Suggestion, _ item: PlayableItem?, next: Bool) {
        if s.kind == .new, let deezerId = s.deezerId {
            adding[s.id] = .downloading
            model.queueCatalogSong(deezerId: deezerId, artist: s.artist, title: s.title, next: next)
        } else if let item {
            if next { player.playNext(item) } else { player.addToQueue(item) }
        }
    }

    /// Into one of your playlists, via "Add to playlist…".
    private func send(_ s: Suggestion) {
        let sent = { adding[s.id] = s.kind == .library ? .added : .downloading }
        if s.kind == .library, let id = s.songId {
            pickPlaylist(PlaylistPick(song: .library(id), title: s.title, onSent: sent))
        } else if let deezerId = s.deezerId {
            pickPlaylist(PlaylistPick(song: .new(deezerId: deezerId), title: s.title, onSent: sent))
        }
    }

    /// Into your library without a playlist: a library song is liked, a new song downloaded.
    private func save(_ s: Suggestion) {
        if s.kind == .library {
            adding[s.id] = .added
            model.setStar(s.songId, true)
            return
        }
        guard let deezerId = s.deezerId else { return }
        adding[s.id] = .adding
        Task {
            guard let started = await model.attempt("Couldn't save it", { try await $0.want(track: deezerId) }) else {
                adding[s.id] = nil
                return
            }
            adding[s.id] = .downloading
            model.track(started, "Saving \(s.title)")
        }
    }

    private func dislike(_ s: Suggestion) {
        guard let i = items.firstIndex(of: s) else { return }
        withAnimation { _ = items.remove(at: i) }
        Task {
            guard await model.attempt("Couldn't save that", { try await $0.dislike(s, in: ref.key) }) != nil else {
                items.insert(s, at: min(i, items.count))
                return
            }
            model.say(s.kind == .new ? "Got it: less like \(s.artist)" : "Hidden from this playlist") {
                Task {
                    await model.attempt { try await $0.undoDislike(s, in: ref.key) }
                    withAnimation { items.insert(s, at: min(i, items.count)) }
                }
            }
        }
    }

    // MARK: - loading

    private func refresh() async {
        guard let api = model.crate else { return }
        working = true
        do {
            try await api.refreshSuggestions(ref.key, excluding: items)
            adding = [:]
            await poll()
        } catch {
            working = false
            model.say(error.localizedDescription)
        }
    }

    /// Suggestions are worked out in the background on the server; check back until they're ready.
    private func poll() async {
        guard let api = model.crate else { return }
        while !Task.isCancelled {
            do {
                let res = try await api.suggestions(ref.key)
                working = res.isWorking
                if !res.isWorking || !res.items.isEmpty { items = res.items }
                updated = res.at
                error = res.status == "failed" ? "Couldn't work out suggestions: \(res.error ?? "unknown error")" : nil
                if !res.isWorking { return }
            } catch {
                self.error = error.localizedDescription
                working = false
                return
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }
}
