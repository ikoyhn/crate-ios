import CrateKit
import SwiftUI

/// Search Deezer's catalogue and add songs or albums to your library (Crate downloads them).
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(AudioPlayer.self) private var player
    @State private var query = ""
    @State private var results: SearchResults?
    @State private var searching = false
    @State private var wants: [Want] = []

    var body: some View {
        NavigationStack {
            List {
                if let results {
                    if results.tracks.isEmpty && results.albums.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                    if !results.albums.isEmpty {
                        Section("Albums") {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(alignment: .top, spacing: 14) {
                                    ForEach(results.albums) { a in
                                        NavigationLink(value: a) { AlbumTile(album: a) }.buttonStyle(.plain)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        }
                    }
                    if !results.tracks.isEmpty {
                        Section("Songs") {
                            ForEach(results.tracks) { CatalogTrackRow(track: $0, want: want(for: $0), onAdd: add) }
                        }
                    }
                } else if !wants.isEmpty {
                    Section("Recently added") {
                        ForEach(wants.prefix(40)) { w in WantRow(want: w, retry: { retry(w) }) }
                    }
                } else {
                    ContentUnavailableView("Find any song", systemImage: "magnifyingglass",
                                           description: Text("Songs you add are downloaded straight into your library."))
                }
            }
            .navigationTitle("Search")
            .navigationDestination(for: CatalogAlbum.self) { AlbumView(album: $0, wants: wants, onAdd: add) }
            .searchable(text: $query, prompt: "Songs, albums, artists")
            .overlay { if searching { ProgressView() } }
            .task(id: query) { await search() }
            .task(id: model.dataVersion) { await loadWants() }
            .refreshable { await loadWants() }
        }
    }

    private func want(for t: CatalogTrack) -> Want? { wants.first { $0.deezerId == t.deezerId } }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { results = nil; return }
        try? await Task.sleep(nanoseconds: 350_000_000)  // wait for typing to pause
        guard !Task.isCancelled else { return }
        searching = true
        defer { searching = false }
        if let r = await model.attempt("Search failed", { try await $0.search(q) }), !Task.isCancelled { results = r }
    }

    private func loadWants() async {
        if let w = try? await model.crate?.wants(limit: 200) { wants = w }
    }

    private func add(_ track: CatalogTrack) {
        Task {
            let started = await model.attempt("Couldn't add it") { try await $0.want(track: track.deezerId) }
            await loadWants()  // shows it as downloading; reloaded again when the run finishes
            model.track(started, "Adding \(track.title)")
        }
    }

    private func retry(_ w: Want) {
        guard let id = w.deezerId else { return }
        Task {
            let started = await model.attempt("Couldn't retry") { try await $0.want(track: id) }
            await loadWants()
            model.track(started, "Adding \(w.title)")
        }
    }
}

struct CatalogTrackRow: View {
    @Environment(AppModel.self) private var model
    @Environment(AudioPlayer.self) private var player
    let track: CatalogTrack
    let want: Want?
    let onAdd: (CatalogTrack) -> Void
    @State private var sendingToPlaylist = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Artwork(url: URL(string: track.cover), size: 44)
                if !track.preview.isEmpty {
                    Image(systemName: isCurrent && player.isPlaying ? "speaker.wave.2.fill" : "play.fill")
                        .font(.caption2).foregroundStyle(.white)
                        .padding(5).background(.black.opacity(0.45), in: Circle())
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).lineLimit(1)
                Text("\(track.artist) · \(track.album)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(track.duration.mmss).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            status
        }
        // Tap anywhere on the row to play (or pause) its preview; the add button keeps its own tap
        .contentShape(Rectangle())
        .onTapGesture(perform: playOrPause)
        .accessibilityAction(named: isCurrent && player.isPlaying ? "Pause" : "Play preview", playOrPause)
        .sheet(isPresented: $sendingToPlaylist) { AddToPlaylistSheet(deezerId: track.deezerId, title: track.title) }
    }

    private var isCurrent: Bool { player.current?.id == "p:\(track.deezerId)" }

    private func playOrPause() {
        if isCurrent { player.toggle() } else if let item = model.resolver?.item(track) { player.play(item) }
    }

    @ViewBuilder
    private var status: some View {
        if want?.isBusy == true {
            ProgressView().controlSize(.small)
        } else if want?.status == "failed" && !track.owned {
            Button { onAdd(track) } label: { Image(systemName: "arrow.clockwise.circle").font(.title3) }
                .buttonStyle(.borderless)
                .accessibilityLabel("Try again")
        } else {
            let have = track.owned || want?.succeeded == true
            Menu {
                if !have {
                    Button { onAdd(track) } label: { Label("Save to my library", systemImage: "arrow.down.circle") }
                }
                // a song you have is found in your library; a new one is downloaded first
                Button { sendingToPlaylist = true } label: { Label("Save to a playlist…", systemImage: "text.badge.plus") }
            } label: {
                Image(systemName: have ? "checkmark.circle.fill" : "plus.circle").font(.title3)
                    .foregroundStyle(have ? Color.green : Color.accentColor)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(have ? "In your library" : "Save")
        }
    }
}

struct AlbumTile: View {
    let album: CatalogAlbum
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Artwork(url: URL(string: album.cover), size: 130, corner: 8)
            Text(album.title).font(.caption.weight(.medium)).lineLimit(1)
            Text(album.artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 130)
    }
}

struct AlbumView: View {
    @Environment(AppModel.self) private var model
    let album: CatalogAlbum
    let wants: [Want]
    let onAdd: (CatalogTrack) -> Void
    @State private var detail: AlbumDetail?
    @State private var addingAll = false

    var body: some View {
        List {
            VStack(spacing: 8) {
                Artwork(url: URL(string: album.cover), size: 200, corner: 10)
                Text(album.title).font(.title3.bold()).multilineTextAlignment(.center)
                Text([album.artist, detail?.year ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
                if let d = detail {
                    let missing = d.tracks.filter { !$0.owned }.count
                    Button {
                        addAll()
                    } label: {
                        Label(missing == 0 ? "You have every song" : "Add \(missing) song\(missing == 1 ? "" : "s")",
                              systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(missing == 0 || addingAll)
                }
            }
            .frame(maxWidth: .infinity)
            .listRowSeparator(.hidden)

            if let d = detail {
                ForEach(d.tracks) { t in
                    CatalogTrackRow(track: t, want: wants.first { $0.deezerId == t.deezerId }, onAdd: onAdd)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .listStyle(.plain)
        .navigationBarTitleDisplayMode(.inline)
        .task { detail = await model.attempt("Couldn't load the album") { try await $0.album(album.deezerId) } }
    }

    private func addAll() {
        addingAll = true
        Task {
            let started = await model.attempt("Couldn't add the album") { try await $0.want(album: album.deezerId) }
            model.track(started, "Adding \(album.title)")
        }
    }
}

struct WantRow: View {
    let want: Want
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: want.cover.flatMap(URL.init(string:)), size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(want.title).lineLimit(1)
                Text(want.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if want.status == "failed", let d = want.detail, !d.isEmpty {
                    Text(d).font(.caption2).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer()
            switch want.status {
            case "ok", "exists": Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case "failed": Button("Try again", action: retry).font(.caption).buttonStyle(.bordered)
            default: ProgressView().controlSize(.small)
            }
        }
    }
}
