import CrateKit
import SwiftUI

/// Regenerate playlists on demand, and make new ones from a prompt.
struct AutomationsView: View {
    @Environment(AppModel.self) private var model
    @State private var prompts: [PromptPlaylist] = []
    @State private var draft = NewPrompt(prompt: "")
    @State private var creating = false
    @State private var forgetting: PromptPlaylist?
    @FocusState private var typingPrompt: Bool

    /// The playlist jobs first, then housekeeping.
    private struct Entry { let job: String; let about: String }
    private let order = [
        Entry(job: "discover", about: "New-to-you songs picked by sound, every Monday."),
        Entry(job: "release_radar", about: "New releases from artists you play, every Friday."),
        Entry(job: "daily_mix", about: "Your library grouped by sound, refreshed daily. Nothing downloaded."),
        Entry(job: "library", about: "Read new songs from Navidrome and analyse their sound."),
        Entry(job: "likes", about: "Keep anything you've loved or rated 4–5, remove 1–2s."),
        Entry(job: "radio_sync", about: "Copy your likes to the radio user."),
        Entry(job: "ytdlp_update", about: "Update the YouTube downloader."),
    ]

    var body: some View {
        NavigationStack {
            Form {
                if !(model.status?.busy.isEmpty ?? true) {
                    Section { BusyBanner().listRowInsets(EdgeInsets()) }
                }
                composer
                if !prompts.isEmpty { promptList }
                Section("Playlists and jobs") {
                    ForEach(order.filter { model.status?.jobs[$0.job] != nil }, id: \.job) { entry in
                        JobRow(job: entry.job, about: entry.about)
                    }
                }
                Section {
                    Button("Remove duplicate playlists") {
                        Task { model.track(await model.attempt { try await $0.removeDuplicatePlaylists() }, "Remove duplicates") }
                    }
                } footer: {
                    Text("Deletes extra copies of Crate's playlists in Navidrome, and Daily Mixes that aren't made any more.")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { typingPrompt = false }.bold()
                }
            }
            .navigationTitle("Create")
            .navigationDestination(for: PlaylistRef.self) { PlaylistDetailView(ref: $0) }
            .task(id: model.dataVersion) { await load() }
            .refreshable { await load(); await model.refreshStatus() }
            .confirmationDialog("Forget this prompt playlist?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
                                titleVisibility: .visible, presenting: forgetting) { p in
                Button("Forget", role: .destructive) { forget(p) }
            } message: { _ in
                Text("Crate stops managing it. The playlist stays in Navidrome; new tracks it downloaded that you haven't kept are deleted.")
            }
        }
    }

    // MARK: - prompt playlists

    private var composer: some View {
        Section {
            TextField("Warm, slow songs for a rainy Sunday", text: $draft.prompt, axis: .vertical)
                .lineLimit(2...5)
                .focused($typingPrompt)
                .submitLabel(.done)
                .onChange(of: draft.prompt) { _, text in
                    // A multi-line field types a newline on Return: treat it as Done instead
                    guard text.contains("\n") else { return }
                    draft.prompt = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                    typingPrompt = false
                }
            Stepper("\(draft.size) songs", value: $draft.size, in: 5...150, step: 5)
            Stepper(draft.newTracks == 0 ? "Only songs I have" : "Up to \(draft.newTracks) new songs",
                    value: $draft.newTracks, in: 0...min(30, draft.size - 1))
            Toggle("Refresh weekly", isOn: $draft.autoRefresh)
            Button {
                create()
            } label: {
                HStack { Text("Make playlist").bold(); if creating { Spacer(); ProgressView() } }
            }
            .disabled(draft.prompt.trimmingCharacters(in: .whitespaces).count < 3 || creating)
        } header: {
            Text("New prompt playlist")
        } footer: {
            Text("Crate matches the sound of your library to your words, and can fetch a few new songs too.")
        }
    }

    private var promptList: some View {
        Section("Prompt playlists") {
            ForEach(prompts) { p in
                VStack(alignment: .leading, spacing: 6) {
                    NavigationLink(value: PlaylistRef(key: p.playlistKey, name: p.name ?? p.prompt, comment: p.prompt)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name ?? p.prompt).lineLimit(1)
                            Text("“\(p.prompt)” · \(p.size) songs" + (p.lastRun.map { " · made \(Optional($0).ago)" } ?? ""))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    HStack {
                        Toggle("Weekly", isOn: Binding(get: { p.autoRefresh }, set: { on in setRefresh(p, on) }))
                            .font(.caption).fixedSize()
                        Spacer()
                        Button("Rebuild") {
                            Task { model.track(await model.attempt { try await $0.rerunPrompt(p.id) }, p.name ?? "Prompt playlist") }
                        }
                        .buttonStyle(.bordered).font(.caption)
                        Button(role: .destructive) { forgetting = p } label: { Image(systemName: "trash") }
                            .buttonStyle(.bordered).font(.caption)
                    }
                }
            }
        }
    }

    private func create() {
        typingPrompt = false
        creating = true
        let p = draft
        Task {
            defer { creating = false }
            guard let started = await model.attempt("Couldn't make it", { try await $0.createPrompt(p) }) else { return }
            draft = NewPrompt(prompt: "")
            model.track(started, "“\(p.prompt)”")
            await load()
        }
    }

    private func setRefresh(_ p: PromptPlaylist, _ on: Bool) {
        Task {
            await model.attempt { try await $0.setAutoRefresh(p.id, on) }
            await load()
        }
    }

    private func forget(_ p: PromptPlaylist) {
        Task {
            await model.attempt { try await $0.forgetPrompt(p.id) }
            await load()
        }
    }

    private func load() async {
        if let p = try? await model.crate?.prompts() { prompts = p }
    }
}

struct JobRow: View {
    @Environment(AppModel.self) private var model
    let job: String
    let about: String

    private var last: Run? { model.status?.jobs[job]?.last }
    private var running: Bool { model.status?.busy.contains { $0.kind == job } ?? false }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.jobLabel(job)).font(.body.weight(.medium))
                Text(about).font(.caption).foregroundStyle(.secondary)
                if let last {
                    Text("Last: \(last.summary ?? last.status) · \(last.finished.ago)")
                        .font(.caption2).foregroundStyle(last.status == "failed" ? .red : .secondary)
                        .lineLimit(2)
                }
                if let next = model.status?.nextRun(job) {
                    Text("Next: \(next.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if running {
                ProgressView()
            } else {
                Button("Run now") { model.runNow(job, label: model.jobLabel(job)) }
                    .buttonStyle(.bordered).font(.caption)
            }
        }
        .padding(.vertical, 2)
    }
}
