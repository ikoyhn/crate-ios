import CrateKit
import SwiftUI

struct MiniPlayer: View {
    @Environment(AudioPlayer.self) private var player
    @Environment(AppModel.self) private var model
    /// Room scrolling content leaves for it.
    static let height: CGFloat = 76

    var body: some View {
        if let item = player.current {
            HStack(spacing: 12) {
                Artwork(url: item.artworkURL, size: 44, corner: 6)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if player.isPlaying { PlayingBars() }
                    }
                    Text(item.isPreview ? "Preview · \(item.artist)" : item.artist)
                        .font(.caption).foregroundStyle(Theme.textMedium).lineLimit(1)
                }
                Spacer(minLength: 0)
                if item.songId != nil {
                    HeartButton(starred: item.starred) { model.setStar(item.songId, !item.starred, addTo: item.likeAddsTo) }
                        .font(.title3)
                }
                Button { player.next() } label: {
                    Image(systemName: "forward.fill").font(.body).foregroundStyle(Theme.textMedium)
                }
                .buttonStyle(.plain)
                .disabled(!player.queue.hasNext)
                .accessibilityLabel("Next")
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.canvas)
                        .frame(width: 40, height: 40)
                        .background(Color.white, in: Circle())
                }
                .buttonStyle(PressScale())
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            }
            .padding(.leading, 8).padding(.trailing, 10).padding(.vertical, 8)
            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .bottom) {
                GeometryReader { g in
                    Capsule().fill(Theme.amber)
                        .frame(width: player.duration > 0 ? g.size.width * min(player.elapsed / player.duration, 1) : 0, height: 2)
                }
                .frame(height: 2)
                .padding(.horizontal, 12)
            }
            .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
            .padding(.horizontal, 8).padding(.bottom, 6)
            .contentShape(Rectangle())
            .onTapGesture { player.showNowPlaying = true }
        }
    }
}

struct NowPlayingView: View {
    @Environment(AudioPlayer.self) private var player
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showQueue = false
    @State private var addingToPlaylist = false

    var body: some View {
        NavigationStack {
            if let item = player.current {
                // Everything fits on one screen: the artwork takes whatever height is left over.
                VStack(spacing: 18) {
                    Artwork(url: item.artworkURL, size: nil, corner: 10)
                        .frame(maxWidth: .infinity, maxHeight: 360)
                        .shadow(color: Theme.amber.opacity(0.22), radius: 30, y: 14)
                        .padding(.top, 8)
                        .layoutPriority(-1)

                    HStack(alignment: .center, spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(Theme.headline(24)).tracking(-0.3).lineLimit(2)
                            Text(item.artist).font(.body).foregroundStyle(Theme.textMedium).lineLimit(1)
                            if item.isPreview { Badge(text: "30-second preview").padding(.top, 2) }
                            else if item.isInbox { Badge(text: "New · in your inbox").padding(.top, 2) }
                        }
                        Spacer(minLength: 0)
                        if item.songId != nil {
                            HeartButton(starred: item.starred) { model.setStar(item.songId, !item.starred, addTo: item.likeAddsTo) }
                                .font(.title2)
                            Button { addingToPlaylist = true } label: {
                                Image(systemName: "text.badge.plus").font(.title3).foregroundStyle(Theme.textMedium)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Add to playlist…")
                        }
                    }

                    Scrubber(elapsed: player.elapsed, duration: player.duration, buffering: player.isBuffering) {
                        player.seek(to: $0)
                    }
                    transport

                    if item.songId != nil {
                        curation(item)
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 12)
                .frame(maxHeight: .infinity, alignment: .top)
                .background {
                    LinearGradient(colors: [Theme.amber.opacity(0.16), Theme.canvas], startPoint: .top, endPoint: .center)
                        .ignoresSafeArea()
                }
                .background(Theme.canvas.ignoresSafeArea())
                .sheet(isPresented: $addingToPlaylist) {
                    if let id = item.songId { AddToPlaylistSheet(songId: id, title: item.title) }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: { Image(systemName: "chevron.down") }
                            .accessibilityLabel("Close")
                    }
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 1) {
                            Text("PLAYING FROM").font(Theme.caps).tracking(0.8).foregroundStyle(Theme.textMedium)
                            Text(playingFrom(item)).font(.footnote.weight(.semibold)).lineLimit(1)
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showQueue = true } label: { Image(systemName: "list.bullet") }
                            .accessibilityLabel("Queue")
                    }
                }
                .toolbarBackground(.hidden, for: .navigationBar)
                .sheet(isPresented: $showQueue) { QueueView() }
            } else {
                ContentUnavailableView("Nothing playing", systemImage: "music.note")
                    .crateScreen()
            }
        }
    }

    /// Where this song came from, for the header: the playlist family, else its album.
    private func playingFrom(_ item: PlayableItem) -> String {
        if item.isSuggestion { return "Suggestions" }
        guard let key = item.playlistKey else { return item.album.isEmpty ? "Your library" : item.album }
        switch PlaylistKind(key: key) {
        case .discover: return "Discover Weekly"
        case .releaseRadar: return "Release Radar"
        case .dailyMix: return "Daily Mix " + (key.split(separator: "_").last.map(String.init) ?? "")
        case .liked: return "Liked Songs"
        case .prompt, .own: return "Your playlist"
        case .other: return item.album.isEmpty ? "Crate" : item.album
        }
    }

    private var transport: some View {
        HStack {
            Button { player.setShuffle(!player.queue.shuffled) } label: {
                Image(systemName: "shuffle").font(.title3)
                    .foregroundStyle(player.queue.shuffled ? Theme.amber : Theme.textMedium)
            }
            .accessibilityLabel("Shuffle")
            Spacer()
            Button { player.previous() } label: { Image(systemName: "backward.fill").font(.title) }
                .accessibilityLabel("Previous")
            Spacer()
            PlayCircle(isPlaying: player.isPlaying, size: 70) { player.toggle() }
            Spacer()
            Button { player.next() } label: { Image(systemName: "forward.fill").font(.title) }
                .disabled(!player.queue.hasNext)
                .accessibilityLabel("Next")
            Spacer()
            Button { cycleRepeat() } label: {
                Image(systemName: player.queue.repeatMode == .one ? "repeat.1" : "repeat").font(.title3)
                    .foregroundStyle(player.queue.repeatMode == .off ? Theme.textMedium : Theme.amber)
            }
            .accessibilityLabel("Repeat")
        }
        .buttonStyle(.plain)
    }

    private func cycleRepeat() {
        switch player.queue.repeatMode {
        case .off: player.setRepeat(.all)
        case .all: player.setRepeat(.one)
        case .one: player.setRepeat(.off)
        }
    }

    /// Rate / keep / remove: everything that teaches Crate what you like.
    private func curation(_ item: PlayableItem) -> some View {
        VStack(spacing: 12) {
            StarRating(rating: item.rating) { model.setRating(item.songId, $0) }
            if item.isInbox, let id = item.songId {
                HStack(spacing: 10) {
                    PillButton(title: "Keep song", systemImage: "checkmark", prominent: true) { model.keep(id) }
                    PillButton(title: "Not for me", systemImage: "xmark", role: .destructive) { model.remove(id, title: item.title) }
                }
                Text("Not for me deletes it and it won't be suggested again.")
                    .font(.caption2).foregroundStyle(Theme.textLow).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// A thin progress bar you can drag, with elapsed and remaining time under it.
struct Scrubber: View {
    let elapsed: Double
    let duration: Double
    var buffering = false
    let onSeek: (Double) -> Void
    @State private var dragging: Double?

    var body: some View {
        let value = dragging ?? elapsed
        let fraction = duration > 0 ? min(max(value / duration, 0), 1) : 0
        VStack(spacing: 6) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.16)).frame(height: 4)
                    Capsule().fill(Theme.amber).frame(width: g.size.width * fraction, height: 4)
                    Circle().fill(Color.white)
                        .frame(width: dragging == nil ? 12 : 18, height: dragging == nil ? 12 : 18)
                        .offset(x: g.size.width * fraction - (dragging == nil ? 6 : 9))
                        .animation(.easeOut(duration: 0.12), value: dragging == nil)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        guard g.size.width > 0, duration > 0 else { return }
                        dragging = min(max(v.location.x / g.size.width, 0), 1) * duration
                    }
                    .onEnded { _ in
                        if let d = dragging { onSeek(d) }
                        dragging = nil
                    })
            }
            .frame(height: 22)
            HStack {
                Text(value.mmss)
                Spacer()
                if buffering { ProgressView().controlSize(.mini) }
                Spacer()
                Text("-" + max(duration - value, 0).mmss)
            }
            .font(.caption.monospacedDigit()).foregroundStyle(Theme.textMedium)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Position")
        .accessibilityValue("\(value.mmss) of \(duration.mmss)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSeek(min(elapsed + 15, duration))
            case .decrement: onSeek(max(elapsed - 15, 0))
            @unknown default: break
            }
        }
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
            .crateScreen()
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
