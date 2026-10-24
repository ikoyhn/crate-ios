import CrateKit
import SwiftUI

/// "Add to playlist…": put a song you're hearing into one of your own playlists, or a new one,
/// without searching for it again. Inbox tracks are kept first, so they aren't deleted later.
struct AddToPlaylistSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let songId: String
    let title: String

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
            guard let r = await model.attempt("Couldn't add it", { try await $0.addLibrarySong(songId, to: key) }) else { return }
            finish(keeping: r.keeping == true, runId: r.runId, name: name)
        }
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        busy = true
        Task {
            defer { busy = false }
            guard let r = await model.attempt("Couldn't make the playlist", { try await $0.createPlaylist(named: name, with: songId) })
            else { return }
            finish(keeping: r.keeping == true, runId: r.runId, name: name)
        }
    }

    private func finish(keeping: Bool, runId: Int?, name: String) {
        if keeping {
            model.player.update(songId: songId) { $0.isInbox = false }
            model.track(Started(runId: runId), "Keeping and adding to \(name)")
        } else {
            model.say("Added to \(name)")
            model.dataVersion += 1
        }
        dismiss()
    }
}
