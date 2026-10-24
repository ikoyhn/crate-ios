import CrateKit
import SwiftUI

struct MiniPlayer: View {
    @Environment(AudioPlayer.self) private var player
    @Environment(AppModel.self) private var model
    /// Room scrolling content leaves for it.
    static let height: CGFloat = 64

    var body: some View {
        if let item = player.current {
            HStack(spacing: 12) {
                Artwork(url: item.artworkURL, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(item.isPreview ? "Preview · \(item.artist)" : item.artist)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if item.songId != nil {
                    HeartButton(starred: item.starred) { model.setStar(item.songId, !item.starred) }
                        .font(.title3)
                }
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                        .frame(width: 32)
                }
                .buttonStyle(.plain)
                Button { player.next() } label: { Image(systemName: "forward.fill").font(.title3) }
                    .buttonStyle(.plain)
                    .disabled(!player.queue.hasNext)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .bottom) {
                GeometryReader { g in
                    Rectangle().fill(Color.accentColor)
                        .frame(width: player.duration > 0 ? g.size.width * min(player.elapsed / player.duration, 1) : 0, height: 2)
                }
                .frame(height: 2)
            }
            .contentShape(Rectangle())
            .onTapGesture { player.showNowPlaying = true }
        }
    }
}

struct NowPlayingView: View {
    @Environment(AudioPlayer.self) private var player
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var scrubbing: Double?
    @State private var showQueue = false
    @State private var addingToPlaylist = false

    var body: some View {
        NavigationStack {
            if let item = player.current {
                ScrollView {
                    VStack(spacing: 22) {
                        Artwork(url: item.artworkURL, size: 300, corner: 14)
                            .shadow(radius: 16, y: 6)
                            .padding(.top, 8)

                        VStack(spacing: 4) {
                            Text(item.title).font(.title2.bold()).multilineTextAlignment(.center)
                            Text(item.artist).font(.title3).foregroundStyle(.secondary)
                            if !item.album.isEmpty { Text(item.album).font(.subheadline).foregroundStyle(.tertiary) }
                            if item.isPreview { Badge(text: "30-second preview").padding(.top, 4) }
                            if item.isInbox { Badge(text: "New · waiting in your inbox").padding(.top, 4) }
                        }

                        scrubber
                        transport

                        if item.songId != nil {
                            curation(item)
                        }
                    }
                    .padding(.horizontal, 24).padding(.bottom, 24)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: { Image(systemName: "chevron.down") }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showQueue = true } label: { Image(systemName: "list.bullet") }
                    }
                }
                .sheet(isPresented: $showQueue) { QueueView() }
            } else {
                ContentUnavailableView("Nothing playing", systemImage: "music.note")
            }
        }
    }

    private var scrubber: some View {
        VStack(spacing: 4) {
            Slider(value: Binding(get: { scrubbing ?? player.elapsed }, set: { scrubbing = $0 }),
                   in: 0...max(player.duration, 1)) { editing in
                if !editing, let s = scrubbing { player.seek(to: s); scrubbing = nil }
            }
            HStack {
                Text((scrubbing ?? player.elapsed).mmss)
                Spacer()
                if player.isBuffering { ProgressView().controlSize(.mini) }
                Spacer()
                Text("-" + max(player.duration - (scrubbing ?? player.elapsed), 0).mmss)
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private var transport: some View {
        HStack(spacing: 36) {
            Button { player.setShuffle(!player.queue.shuffled) } label: {
                Image(systemName: "shuffle").foregroundStyle(player.queue.shuffled ? Color.accentColor : .secondary)
            }
            Button { player.previous() } label: { Image(systemName: "backward.fill").font(.title) }
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 64))
            }
            Button { player.next() } label: { Image(systemName: "forward.fill").font(.title) }
                .disabled(!player.queue.hasNext)
            Button { cycleRepeat() } label: {
                Image(systemName: player.queue.repeatMode == .one ? "repeat.1" : "repeat")
                    .foregroundStyle(player.queue.repeatMode == .off ? .secondary : Color.accentColor)
            }
        }
        .buttonStyle(.plain)
        .font(.title3)
    }

    private func cycleRepeat() {
        switch player.queue.repeatMode {
        case .off: player.setRepeat(.all)
        case .all: player.setRepeat(.one)
        case .one: player.setRepeat(.off)
        }
    }

    /// Love / rate / keep / remove: everything that teaches Crate what you like.
    private func curation(_ item: PlayableItem) -> some View {
        VStack(spacing: 16) {
            HStack(spacing: 28) {
                HeartButton(starred: item.starred) { model.setStar(item.songId, !item.starred) }
                    .font(.title)
                StarRating(rating: item.rating) { model.setRating(item.songId, $0) }
            }
            Button { addingToPlaylist = true } label: {
                Label("Add to playlist…", systemImage: "text.badge.plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .sheet(isPresented: $addingToPlaylist) {
                if let id = item.songId { AddToPlaylistSheet(songId: id, title: item.title) }
            }
            if item.isInbox, let id = item.songId {
                HStack(spacing: 12) {
                    Button { model.keep(id) } label: {
                        Label("Keep", systemImage: "checkmark.circle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.green)
                    Button(role: .destructive) { model.remove(id) } label: {
                        Label("Remove", systemImage: "trash").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                Text("Love it or rate it 4–5 to keep it; 1–2 removes it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct QueueView: View {
    @Environment(AudioPlayer.self) private var player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let cur = player.current {
                    Section("Now playing") { row(cur) }
                }
                Section("Up next") {
                    ForEach(Array(player.queue.upNext)) { item in
                        Button { player.jump(to: item.id) } label: { row(item) }
                            .buttonStyle(.plain)
                            .swipeActions { Button(role: .destructive) { player.removeFromQueue(item.id) } label: { Label("Remove", systemImage: "minus.circle") } }
                    }
                }
            }
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func row(_ item: PlayableItem) -> some View {
        HStack(spacing: 12) {
            Artwork(url: item.artworkURL, size: 40)
            VStack(alignment: .leading) {
                Text(item.title).lineLimit(1)
                Text(item.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if item.isPreview { Badge(text: "Preview") }
        }
    }
}
