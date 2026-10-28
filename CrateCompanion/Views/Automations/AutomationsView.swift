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
    private struct Entry { let job: String; let about: String; let symbol: String }
    private let order = [
        Entry(job: "discover", about: "New-to-you songs picked by sound, every Monday.", symbol: "sparkles"),
        Entry(job: "release_radar", about: "New releases from artists you play, every Friday.", symbol: "dot.radiowaves.left.and.right"),
        Entry(job: "daily_mix", about: "Your library grouped by sound, refreshed daily. Nothing downloaded.", symbol: "sun.max"),
        Entry(job: "library", about: "Read new songs from Navidrome and analyse their sound.", symbol: "waveform"),
        Entry(job: "likes", about: "Keep anything you've loved or rated 4–5, remove 1–2s.", symbol: "heart"),
        Entry(job: "radio_sync", about: "Copy your likes to the radio user.", symbol: "antenna.radiowaves.left.and.right"),
        Entry(job: "ytdlp_update", about: "Update the YouTube downloader.", symbol: "arrow.down.app"),
    ]

    private let quickPrompts = ["Energetic gym run", "Rainy day lo-fi", "Sunset on the beach",
                                "Late-night drive", "Ambient focus", "80s synth nostalgia"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    if !(model.status?.busy.isEmpty ?? true) { BusyBanner() }
                    composer
                    if !prompts.isEmpty { promptList }
                    jobs
                    VStack(alignment: .leading, spacing: 8) {
                        PillButton(title: "Remove duplicate playlists", systemImage: "square.stack.3d.up.slash") {
                            Task { model.track(await model.attempt { try await $0.removeDuplicatePlaylists() }, "Remove duplicates") }
                        }
                        Text("Deletes extra copies of Crate's playlists in Navidrome, and Daily Mixes that aren't made any more.")
                            .font(.caption).foregroundStyle(Theme.textLow)
                    }
                }
                .padding(.horizontal).padding(.vertical, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .crateScreen()
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

    private var canCreate: Bool { draft.prompt.trimmingCharacters(in: .whitespaces).count >= 3 && !creating }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label("AI CURATOR", systemImage: "sparkles")
                    .font(Theme.caps).tracking(0.8).foregroundStyle(Theme.amber)
                Text("What do you want to hear?").font(Theme.display(30)).tracking(-0.6)
                Text("Describe a mood, a place, an activity or a few artists. Crate matches it to the sound of your library.")
                    .font(.subheadline).foregroundStyle(Theme.textMedium)
            }

            VStack(alignment: .leading, spacing: 12) {
                TextField("Warm, slow songs for a rainy Sunday", text: $draft.prompt, axis: .vertical)
                    .font(.title3)
                    .lineLimit(3...6)
                    .focused($typingPrompt)
                    .submitLabel(.done)
                    .onChange(of: draft.prompt) { _, text in
                        // A multi-line field types a newline on Return: treat it as Done instead
                        guard text.contains("\n") else { return }
                        draft.prompt = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                        typingPrompt = false
                    }
                HStack {
                    Text(draft.newTracks == 0 ? "\(draft.size) SONGS · FROM YOUR LIBRARY" : "\(draft.size) SONGS · UP TO \(draft.newTracks) NEW")
                        .font(Theme.caps).tracking(0.6).foregroundStyle(Theme.textLow)
                    Spacer()
                    Button { create() } label: {
                        Group {
                            if creating { ProgressView().tint(Theme.canvas) }
                            else { Image(systemName: "arrow.up").font(.system(size: 17, weight: .bold)) }
                        }
                        .foregroundStyle(Theme.canvas)
                        .frame(width: 42, height: 42)
                        .background(canCreate || creating ? Theme.amber : Theme.surface3, in: Circle())
                    }
                    .buttonStyle(PressScale())
                    .disabled(!canCreate)
                    .accessibilityLabel("Make playlist")
                }
            }
            .padding(16)
            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.amber.opacity(typingPrompt ? 0.6 : 0), lineWidth: 1)
            }
            .animation(.easeOut(duration: 0.2), value: typingPrompt)

            VStack(alignment: .leading, spacing: 10) {
                Label("QUICK PROMPTS", systemImage: "bolt.fill")
                    .font(Theme.caps).tracking(0.8).foregroundStyle(Theme.textMedium)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(quickPrompts, id: \.self) { q in
                            Chip(title: q, selected: draft.prompt == q) { draft.prompt = q }
                        }
                    }
                }
                .scrollClipDisabled()
            }

            VStack(spacing: 0) {
                Stepper("\(draft.size) songs", value: $draft.size, in: 5...150, step: 5)
                    .padding(.vertical, 10)
                Divider().overlay(Theme.surface3)
                Stepper(draft.newTracks == 0 ? "Only songs I have" : "Up to \(draft.newTracks) new songs",
                        value: $draft.newTracks, in: 0...min(30, draft.size - 1))
                    .padding(.vertical, 10)
                Divider().overlay(Theme.surface3)
                Toggle("Refresh weekly", isOn: $draft.autoRefresh)
                    .tint(Theme.amber)
                    .padding(.vertical, 10)
            }
            .padding(.horizontal, 16)
            .background(Theme.surface1, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text("New songs also fill in whatever your library can't. Ones you don't keep leave again at the next rebuild.")
                .font(.caption).foregroundStyle(Theme.textLow)
        }
    }

    private var promptList: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Your prompt playlists")
            ForEach(prompts) { p in
                VStack(alignment: .leading, spacing: 12) {
                    NavigationLink(value: PlaylistRef(key: p.playlistKey, name: p.name ?? p.prompt, comment: p.prompt)) {
                        HStack(spacing: 12) {
                            Image(systemName: PlaylistKind.prompt.symbol)
                                .font(.headline).foregroundStyle(PlaylistKind.prompt.color)
                                .frame(width: 44, height: 44)
                                .background(Theme.surface3, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name ?? p.prompt).font(.body.weight(.semibold)).lineLimit(1)
                                Text("“\(p.prompt)” · \(p.size) songs" + (p.lastRun.map { " · made \(Optional($0).ago)" } ?? ""))
                                    .font(.caption).foregroundStyle(Theme.textMedium).lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(Theme.textLow)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    HStack(spacing: 10) {
                        Toggle("Weekly", isOn: Binding(get: { p.autoRefresh }, set: { on in setRefresh(p, on) }))
                            .font(.caption.weight(.semibold)).tint(Theme.amber).fixedSize()
                        Spacer()
                        PillButton(title: "Rebuild", systemImage: "arrow.triangle.2.circlepath", prominent: true) {
                            Task { model.track(await model.attempt { try await $0.rerunPrompt(p.id) }, p.name ?? "Prompt playlist") }
                        }
                        CircleIconButton(systemImage: "trash", tint: Color(hex: 0xFFB4AB), label: "Forget") { forgetting = p }
                    }
                }
                .padding(14)
                .background(Theme.surface1, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private var jobs: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Automated playlists", subtitle: "Crate runs these on a schedule. Run any of them now.")
            ForEach(order.filter { model.status?.jobs[$0.job] != nil }, id: \.job) { entry in
                JobRow(job: entry.job, about: entry.about, symbol: entry.symbol)
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
    var symbol = "gearshape"

    private var last: Run? { model.status?.jobs[job]?.last }
    private var running: Bool { model.status?.busy.contains { $0.kind == job } ?? false }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.headline).foregroundStyle(Theme.amber)
                .frame(width: 40, height: 40)
                .background(Theme.surface3, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(model.jobLabel(job)).font(.body.weight(.semibold))
                Text(about).font(.caption).foregroundStyle(Theme.textMedium)
                if let last {
                    Text("Last: \(last.summary ?? last.status) · \(last.finished.ago)")
                        .font(.caption2).foregroundStyle(last.status == "failed" ? Color(hex: 0xFFB4AB) : Theme.textLow)
                        .lineLimit(2)
                }
                if let next = model.status?.nextRun(job) {
                    Text("Next: \(next.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                        .font(.caption2).foregroundStyle(Theme.textLow)
                }
            }
            Spacer(minLength: 0)
            if running {
                ProgressView().tint(Theme.amber).padding(.top, 8)
            } else {
                PillButton(title: "Run", systemImage: "play.fill", prominent: true) {
                    model.runNow(job, label: model.jobLabel(job))
                }
            }
        }
        .padding(14)
        .background(Theme.surface1, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
