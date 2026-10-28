import CrateKit
import SwiftUI

/// Search your library (songs play in full) and Deezer's catalogue, to add songs or albums to
/// your library (Crate downloads them).
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(AudioPlayer.self) private var player
    @State private var query = ""
    @State private var results: SearchResults?
    @State private var library: [Track] = []
    @State private var artists: [NavidromeArtist] = []
    @State private var searching = false
    @State private var wants: [Want] = []

    var body: some View {
        NavigationStack {
            List {
                if let results {
                    if results.tracks.isEmpty && results.albums.isEmpty && library.isEmpty && artists.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                    if !artists.isEmpty {
                        Section("Artists") {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(alignment: .top, spacing: 14) {
                                    ForEach(artists) { a in
                                        NavigationLink(value: a) { ArtistTile(artist: a) }.buttonStyle(.plain)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        }
                    }
                    if !library.isEmpty {
                        Section("In your library") {
                            ForEach(Array(library.prefix(8).enumerated()), id: \.element.id) { i, t in
                                TrackRow(track: t, playlistKey: nil, isCurrent: player.current?.songId == t.songId,
                                         onPlay: { playLibrary(from: i) },
                                         onChange: { updated in
                                             if let j = library.firstIndex(where: { $0.id == t.id }) { library[j] = updated }
                                         })
                            }
                        }
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
                        Section(library.isEmpty ? "Songs" : "More songs") {
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
            .crateScreen()
            .navigationTitle("Search")
            .navigationDestination(for: CatalogAlbum.self) { AlbumView(album: $0, wants: wants, onAdd: add) }
            .navigationDestination(for: NavidromeArtist.self) { ArtistView(artist: $0) }
            .navigationDestination(for: NavidromeAlbum.self) { LibraryAlbumView(album: $0) }
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
        let nd = model.navidrome
        async let mine = nd?.searchSongs(q)
        async let theirs = nd?.searchArtists(q)
        var r: SearchResults?
        var failure: Error?
        do { r = try await model.crate?.search(q) } catch { failure = error }
        let found = (try? await mine) ?? nil
        let foundArtists = (try? await theirs) ?? nil
        // typing again cancels this search, which ends in an error: only a real failure is worth saying
        guard !Task.isCancelled else { return }
        if let failure { model.say("Search failed: \(failure.localizedDescription)") }
        library = found ?? []
        artists = foundArtists ?? []
        if let r { results = r } else if found != nil { results = SearchResults(tracks: [], albums: []) }
    }

    private func playLibrary(from index: Int) {
        player.play(library.compactMap { model.resolver?.item($0, playlistKey: nil) }, startAt: index)
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
    @Environment(\.pickPlaylist) private var pickPlaylist

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
        // Tap anywhere on the row to play (or pause) it: in full if you have it, else its preview.
        // The + button keeps its own tap.
        .contentShape(Rectangle())
        .onTapGesture(perform: playOrPause)
        .accessibilityAction(named: isCurrent && player.isPlaying ? "Pause" : "Play", playOrPause)
        .swipeActions(edge: .leading) {
            Button { playNext() } label: { Label("Play next", systemImage: "text.insert") }
                .tint(Theme.amber)
            // a song you have is found in your library; a new one is downloaded first
            Button { addToPlaylist() } label: { Label("Playlist", systemImage: "text.badge.plus") }
                .tint(.blue)
        }
        .contextMenu {
            Button { playNext() } label: {
                Label(have ? "Play next" : "Download and play next", systemImage: "text.insert")
            }
            Button { model.queueCatalogSong(deezerId: track.deezerId, artist: track.artist, title: track.title, next: false) } label: {
                Label(have ? "Add to queue" : "Download and add to queue", systemImage: "text.append")
            }
            Button(action: addToPlaylist) { Label("Add to playlist…", systemImage: "text.badge.plus") }
            if !have && want?.isBusy != true {
                Button { onAdd(track) } label: { Label("Save to my library", systemImage: "plus.circle") }
            }
            if !track.preview.isEmpty, let item = model.resolver?.item(track) {
                Divider()
                Button { player.play(item) } label: { Label("Play preview", systemImage: "play.circle") }
            }
        }
    }

    /// Queued straight away if you have it; otherwise downloaded into your library, then queued.
    private func playNext() {
        model.queueCatalogSong(deezerId: track.deezerId, artist: track.artist, title: track.title)
    }

    private func addToPlaylist() {
        pickPlaylist(PlaylistPick(song: .new(deezerId: track.deezerId), title: track.title))
    }

    private var have: Bool { track.owned || want?.succeeded == true }

    private var isCurrent: Bool {
        guard let current = player.current else { return false }
        return current.id == "p:\(track.deezerId)"
            || (current.songId != nil && current.title == track.title && current.artist == track.artist)
    }

    private func playOrPause() {
        if isCurrent { player.toggle(); return }
        Task {
            if have, let item = await model.libraryItem(artist: track.artist, title: track.title) {
                player.play(item)
            } else if let item = model.resolver?.item(track) {
                player.play(item)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if want?.isBusy == true {
            ProgressView().controlSize(.small)
        } else if want?.status == "failed" && !track.owned {
            Button { onAdd(track) } label: { Image(systemName: "arrow.clockwise.circle").font(.title3) }
                .buttonStyle(.borderless)
                .accessibilityLabel("Try again")
        } else if have {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("In your library")
        } else {
            Button { onAdd(track) } label: { Image(systemName: "plus.circle").font(.title3) }
                .buttonStyle(.borderless)
                .accessibilityLabel("Save to my library")
        }
    }
}

/// An artist in your library, in the search results.
struct ArtistTile: View {
    @Environment(AppModel.self) private var model
    let artist: NavidromeArtist
    var body: some View {
        VStack(spacing: 4) {
            Artwork(url: model.navidrome?.coverURL(id: artist.coverArt ?? artist.id, size: 300), size: 96, corner: 48)
            Text(artist.name).font(.caption.weight(.medium)).lineLimit(1)
            if let n = artist.albumCount {
                Text("\(n) album\(n == 1 ? "" : "s")").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 100)
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
                Text(album.title).font(Theme.display(24)).tracking(-0.5).multilineTextAlignment(.center)
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
                    .buttonBorderShape(.capsule)
                    .disabled(missing == 0 || addingAll)
                }
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            if let d = detail {
                ForEach(d.tracks) { t in
                    CatalogTrackRow(track: t, want: wants.first { $0.deezerId == t.deezerId }, onAdd: onAdd)
                        .listRowBackground(Color.clear)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .listStyle(.plain)
        .crateScreen()
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

/// A song you added. Once it's downloaded, tap it to play it from your library.
struct WantRow: View {
    @Environment(AppModel.self) private var model
    @Environment(AudioPlayer.self) private var player
    let want: Want
    let retry: () -> Void

    private var isCurrent: Bool {
        player.current?.songId != nil && player.current?.title == want.title && player.current?.artist == want.artist
    }

    @Environment(\.pickPlaylist) private var pickPlaylist

    var body: some View {
        row
            .contentShape(Rectangle())
            .onTapGesture { play() }
            .contextMenu {
                if want.succeeded {
                    Button { queue(next: true) } label: { Label("Play next", systemImage: "text.insert") }
                    Button { queue(next: false) } label: { Label("Add to queue", systemImage: "text.append") }
                }
                if let id = want.deezerId {
                    Button { pickPlaylist(PlaylistPick(song: .new(deezerId: id), title: want.title)) } label: {
                        Label("Add to playlist…", systemImage: "text.badge.plus")
                    }
                }
            }
    }

    private func queue(next: Bool) {
        if let id = want.deezerId {
            model.queueCatalogSong(deezerId: id, artist: want.artist, title: want.title, next: next)
        }
    }

    private func play() {
        guard want.succeeded else { return }
        if isCurrent { player.toggle(); return }
        Task {
            if let item = await model.libraryItem(artist: want.artist, title: want.title) { player.play(item) }
            else { model.say("Couldn't find \(want.title) in your library yet") }
        }
    }

    private var row: some View {
        HStack(spacing: 12) {
            Artwork(url: want.cover.flatMap(URL.init(string:)), size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(want.title).lineLimit(1)
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
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
