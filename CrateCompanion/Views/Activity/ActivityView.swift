import CrateKit
import SwiftUI

struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var runs: [Run] = []
    @State private var decisions: [InboxDecision] = []
    @State private var summary: HistorySummary?
    @State private var health: [String: HealthCheck] = [:]
    @State private var showReset = false
    @State private var keepDislikes = true
    @State private var editServer = false

    var body: some View {
        NavigationStack {
            List {
                if !(model.status?.busy.isEmpty ?? true) {
                    BusyBanner().listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }
                overview
                if !health.isEmpty { connections }
                Section("Runs") {
                    ForEach(runs) { r in
                        NavigationLink(value: r) { RunRow(run: r) }
                    }
                }
                Section("Inbox decisions") {
                    if decisions.isEmpty { Text("Nothing kept or removed yet.").foregroundStyle(.secondary) }
                    ForEach(decisions, id: \.self) { d in DecisionRow(decision: d) }
                }
                discovery
                settings
            }
            .navigationTitle("Activity")
            .navigationDestination(for: Run.self) { RunDetailView(run: $0) }
            .task(id: model.dataVersion) { await load() }
            .refreshable { await load(); await model.refreshStatus() }
            .sheet(isPresented: $editServer) { ConnectView(editing: true) }
        }
    }

    private var overview: some View {
        Section {
            if let s = model.status {
                LabeledContent("Library", value: "\(s.library.songs) songs, \(s.library.embedded) analysed")
                LabeledContent("Waiting in the inbox", value: "\(s.inbox.new)")
                LabeledContent("Last 30 days", value: "\(s.inbox.kept30d) kept · \(s.inbox.removed30d) removed")
            } else {
                ProgressView()
            }
        }
    }

    private var connections: some View {
        Section("Connections") {
            ForEach(health.keys.sorted(), id: \.self) { name in
                let h = health[name]!
                HStack(alignment: .top) {
                    Circle().fill(h.ok ? Color.green : Color.red).frame(width: 8, height: 8).padding(.top, 6)
                    VStack(alignment: .leading) {
                        Text(name.capitalized)
                        Text(h.detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
            }
        }
    }

    private var discovery: some View {
        Section {
            if let h = summary {
                LabeledContent("Tracks Discover Weekly skips", value: "\(h.blockedTracks)")
                LabeledContent("Your dislikes", value: "\(h.dislikes)")
                LabeledContent("Artists ranked lower", value: "\(h.loweredArtists)")
                LabeledContent("Artists no longer suggested", value: "\(h.blockedArtists)")
            }
            Button("Clear discovery history…", role: .destructive) { showReset = true }
        } header: {
            Text("Discovery history")
        } footer: {
            Text("Lets songs and artists Crate already suggested come up again. Handy after testing.")
        }
        .sheet(isPresented: $showReset) {
            NavigationStack {
                Form {
                    Toggle("Keep blocking my dislikes", isOn: $keepDislikes)
                    Text(keepDislikes ? "Songs you removed, rated 1–2 or gave a 👎 stay blocked."
                                      : "Everything is forgotten, your dislikes too.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Clear history", role: .destructive) {
                        showReset = false
                        Task { model.track(await model.attempt { try await $0.clearHistory(keepDislikes: keepDislikes) }, "Clear history") }
                    }
                }
                .navigationTitle("Clear history")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showReset = false } } }
            }
            .presentationDetents([.medium])
        }
    }

    private var settings: some View {
        Section("Server") {
            if let c = model.connection {
                LabeledContent("Crate", value: c.crateURL)
                LabeledContent("Playback", value: c.useNavidrome ? "Navidrome · \(c.navidromeUser)" : "Through Crate")
            }
            Button("Change server…") { editServer = true }
            Button("Sign out", role: .destructive) { model.signOut() }
        }
    }

    private func load() async {
        guard let api = model.crate else { return }
        async let r = api.runs(limit: 40)
        async let d = api.inbox(limit: 40)
        async let s = api.historySummary()
        if let v = try? await r { runs = v }
        if let v = try? await d { decisions = v }
        summary = try? await s
        // health is slow (it pings everything), so it fills in last
        if let h = try? await api.health() { health = h }
    }
}

struct RunRow: View {
    @Environment(AppModel.self) private var model
    let run: Run

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon.frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.jobLabel(run.kind)).lineLimit(1)
                Text(run.summary ?? run.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Text(run.started.ago).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch run.status {
        case "ok": Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case "failed": Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case "cancelled", "interrupted": Image(systemName: "stop.circle").foregroundStyle(.secondary)
        default: ProgressView().controlSize(.small)
        }
    }
}

/// A run's log, live while it's going.
struct RunDetailView: View {
    @Environment(AppModel.self) private var model
    @State var run: Run

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    RunRow(run: run)
                    Text(run.log?.isEmpty == false ? run.log! : "No log yet.")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("end")
                }
                .padding()
            }
            .onChange(of: run.log) { if run.isActive { withAnimation { proxy.scrollTo("end") } } }
        }
        .navigationTitle(model.jobLabel(run.kind))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if run.isActive {
                ToolbarItem(placement: .topBarTrailing) { Button("Stop all", role: .destructive) { model.stopAll() } }
            }
        }
        .task {
            // the list leaves the log out; fetch it, and keep fetching while the run is going
            guard let api = model.crate else { return }
            repeat {
                if let r = try? await api.run(run.id) { run = r }
                if !run.isActive { break }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            } while !Task.isCancelled
        }
    }
}

struct DecisionRow: View {
    let decision: InboxDecision
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: decision.status == "kept" ? "checkmark.circle" : "trash")
                .foregroundStyle(decision.status == "kept" ? .green : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(decision.artist) – \(decision.title)").lineLimit(1)
                Text([decision.reason ?? decision.status, decision.decidedAt.ago].joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
