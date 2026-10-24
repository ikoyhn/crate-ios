import CrateKit
import SwiftUI

/// "Add to playlist…": put a song into one of your own playlists, or a new one, without searching
/// for it again. Inbox tracks are kept first, so they aren't deleted later; new songs (a suggestion
/// or a search result) are downloaded into your library first.
struct AddToPlaylistSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    enum Song { case library(String), new(deezerId: Int) }
    let song: Song
    let title: String
    /// Called once it's on its way into a playlist.
    var onSent: (() -> Void)?

    init(songId: String, title: String, onSent: (() -> Void)? = nil) {
        song = .library(songId); self.title = title; self.onSent = onSent
    }

    init(deezerId: Int, title: String, onSent: (() -> Void)? = nil) {
        song = .new(deezerId: deezerId); self.title = title; self.onSent = onSent
    }

    @State private var playlists: [OwnPlaylist] = []
    @State private var loading = true
    @State private var newName = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            List {
                Section("New playlist") {
                    HStack {
                        TextField("Name", text: $newName).submitLabel(.done).onSubmit(create)
                        Button("Create", action: create)
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                    }
                }
                Section("Your playlists") {
                    if loading { ProgressView() }
                    ForEach(playlists.filter { !$0.readonly }) { p in
                        Button { add(to: p.key, name: p.name) } label: {
                            PlaylistRow(name: p.name, subtitle: "\(p.count) songs", kind: .own, cover: nil)
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)
                    }
                }
            }
            .navigationTitle("Add “\(title)”")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task {
                playlists = await model.attempt("Couldn't load your playlists") { try await $0.ownPlaylists() } ?? []
                loading = false
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func add(to key: String, name: String) {
        busy = true
        Task {
            defer { busy = false }
            guard let r = await model.attempt("Couldn't add it", { api -> Started in
                switch song {
                case .library(let id): return try await api.addLibrarySong(id, to: key)
                case .new(let deezerId): return try await api.addNewSong(deezerId: deezerId, to: key)
                }
            }) else { return }
            finish(keeping: r.keeping == true, runId: r.runId, name: name)
        }
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        busy = true
        Task {
            defer { busy = false }
            guard let r = await model.attempt("Couldn't make the playlist", { api -> CreatedPlaylist in
                switch song {
                case .library(let id): return try await api.createPlaylist(named: name, with: id)
                case .new(let deezerId): return try await api.createPlaylist(named: name, deezerId: deezerId)
                }
            }) else { return }
            finish(keeping: r.keeping == true, runId: r.runId, name: name)
        }
    }

    private func finish(keeping: Bool, runId: Int?, name: String) {
        onSent?()
        if case .new = song {
            model.dataVersion += 1  // shows it downloading
            model.track(Started(runId: runId), "Downloading \(title) into \(name)")
        } else if keeping, case .library(let songId) = song {
            model.player.update(songId: songId) { $0.isInbox = false }
            model.track(Started(runId: runId), "Keeping and adding to \(name)")
        } else {
            model.say("Added to \(name)")
            model.dataVersion += 1
        }
        dismiss()
    }
}
