import CrateKit
import SwiftUI

/// Suggested songs for a playlist: new songs (30 s previews, downloaded when added) alternating
/// with songs from your library. 👎 teaches Crate; Refresh shows a different batch.
struct SuggestionsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(AudioPlayer.self) private var player
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
            }
        } header: {
            HStack {
                Text(updated.map { "Updated \(Optional($0).ago)" } ?? "Suggested songs")
                Spacer()
                if working && !items.isEmpty { ProgressView().controlSize(.small) }
                Button { Task { await refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .font(.caption.bold()).disabled(working)
            }
        } footer: {
            Text(ref.readonly
                 ? "Navidrome won't let Crate change this playlist, so you can listen to suggestions but not add them."
                 : "👎 on a new song: never suggested again, and similar songs rank lower. On a library song: just not for this playlist.")
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
                Text(s.title).lineLimit(1)
                Text(s.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 6) {
                    if s.kind == .new { Badge(text: "New") }
                    Text(s.reason).lineLimit(1)
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)

            Button { dislike(s) } label: {
                Image(systemName: "hand.thumbsdown").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Not for me")

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
            if !ref.readonly && adding[s.id] == nil {
                Button { add(s) } label: { Label("Add", systemImage: "plus") }.tint(.accentColor)
            }
        }
        .contextMenu {
            if let item {
                Button { player.playNext(item) } label: { Label("Play next", systemImage: "text.insert") }
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
            Button { add(s) } label: { Image(systemName: "plus.circle").font(.title3) }
                .buttonStyle(.borderless)
                .accessibilityLabel("Add to playlist")
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
