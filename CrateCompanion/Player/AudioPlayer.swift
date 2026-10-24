import AVFoundation
import CrateKit
import MediaPlayer
import Observation
import UIKit

/// Plays a PlayQueue with AVPlayer, keeps the lock screen / Control Centre in step, and scrobbles
/// full songs to Navidrome. Lock-screen handling follows the approach of Vibrdrome's
/// NowPlayingManager / RemoteCommandManager (MIT, github.com/ddmoney420/vibrdrome).
@MainActor
@Observable
final class AudioPlayer {
    private(set) var queue = PlayQueue()
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var elapsed: Double = 0
    private(set) var duration: Double = 0
    var showNowPlaying = false

    var current: PlayableItem? { queue.current }

    @ObservationIgnored var navidrome: Subsonic?
    /// Lock-screen heart: (item, starred).
    @ObservationIgnored var onLike: ((PlayableItem, Bool) -> Void)?

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var scrobbled = false
    @ObservationIgnored private var artwork: (URL, MPMediaItemArtwork)?
    @ObservationIgnored private var sessionActive = false

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
        player.automaticallyWaitsToMinimizeStalling = true
        observePlayer()
        setupRemoteCommands()
    }

    // MARK: - transport

    func play(_ items: [PlayableItem], startAt: Int = 0, shuffle: Bool = false) {
        guard !items.isEmpty else { return }
        queue.replace(with: items, startAt: startAt, shuffle: shuffle)
        load(queue.current, autoplay: true)
    }

    func play(_ item: PlayableItem) { play([item]) }

    func playNext(_ item: PlayableItem) {
        if queue.current == nil { play(item) } else { queue.playNext(item) }
    }

    func addToQueue(_ item: PlayableItem) {
        if queue.current == nil { play(item) } else { queue.append(item) }
    }

    func toggle() { isPlaying ? pause() : resume() }

    func resume() {
        guard queue.current != nil else { return }
        activateSession()
        player.play()
    }

    func pause() { player.pause() }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        queue = PlayQueue()
        elapsed = 0; duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func next() {
        if let item = queue.advance(userInitiated: true) { load(item, autoplay: true) } else { pause() }
    }

    func previous() {
        if elapsed > 3 { seek(to: 0); return }
        load(queue.back(), autoplay: true)
    }

    func jump(to id: PlayableItem.ID) {
        queue.jump(to: id)
        load(queue.current, autoplay: true)
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        elapsed = seconds
        updateNowPlaying()
    }

    func setShuffle(_ on: Bool) { queue.setShuffle(on) }
    func setRepeat(_ mode: PlayQueue.Repeat) { queue.repeatMode = mode }
    func removeFromQueue(_ id: PlayableItem.ID) { queue.remove(id: id) }

    /// Reflect a like / keep on the queue (and the lock screen's heart).
    func update(songId: String, _ change: (inout PlayableItem) -> Void) {
        queue.update(songId: songId, change)
        MPRemoteCommandCenter.shared().likeCommand.isActive = current?.starred ?? false
    }

    /// A removed inbox track is deleted from the server: skip it if it's playing, drop it otherwise.
    func removeSong(_ songId: String) {
        let ids = queue.items.filter { $0.songId == songId }.map(\.id)
        if current?.songId == songId { next() }
        ids.forEach { queue.remove(id: $0) }
    }

    // MARK: - loading

    private func load(_ item: PlayableItem?, autoplay: Bool) {
        guard let item else { return }
        scrobbled = false
        elapsed = 0
        duration = Double(item.duration)
        let playerItem = AVPlayerItem(url: item.streamURL)
        playerItem.preferredForwardBufferDuration = 10
        player.replaceCurrentItem(with: playerItem)
        if autoplay { activateSession(); player.play() }
        updateNowPlaying()
        loadArtwork(for: item)
        if let id = item.songId, let nd = navidrome {
            Task.detached { try? await nd.scrobble(songId: id, submission: false) }  // "now playing"
        }
    }

    private func activateSession() {
        guard !sessionActive else { return }
        // Activated on first play rather than at launch, so opening the app doesn't stop other audio
        sessionActive = (try? AVAudioSession.sharedInstance().setActive(true)) != nil
    }

    private func trackEnded() {
        maybeScrobble(force: true)
        if let item = queue.advance(userInitiated: false) {
            if item.id == current?.id && queue.repeatMode == .one { seek(to: 0); player.play() }
            else { load(item, autoplay: true) }
        } else {
            isPlaying = false
            updateNowPlaying()
        }
    }

    /// Navidrome counts a listen at half the song or 4 minutes, like Last.fm. Previews never count.
    private func maybeScrobble(force: Bool = false) {
        guard !scrobbled, let item = current, let id = item.songId, let nd = navidrome else { return }
        let needed = min(max(duration, 30) / 2, 240)
        guard force || elapsed >= needed else { return }
        scrobbled = true
        Task.detached { try? await nd.scrobble(songId: id, submission: true) }
    }

    // MARK: - observing AVPlayer

    private func observePlayer() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                                                      queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.elapsed = time.seconds.isFinite ? time.seconds : 0
                if let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 { self.duration = d }
                self.maybeScrobble()
            }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let status = p.timeControlStatus
            Task { @MainActor in
                guard let self else { return }
                self.isPlaying = status == .playing || status == .waitingToPlayAtSpecifiedRate
                self.isBuffering = status == .waitingToPlayAtSpecifiedRate
                self.updateNowPlaying()
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.trackEnded()
            }
        }
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                                                      object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let opts = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            MainActor.assumeIsolated {
                guard let self, let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                if type == .began { self.sessionActive = false }
                if type == .ended, AVAudioSession.InterruptionOptions(rawValue: opts).contains(.shouldResume) {
                    self.resume()
                }
            }
        }
    }

    // MARK: - lock screen

    private func setupRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()
        // Remote commands arrive on the main thread
        func on(_ command: MPRemoteCommand, _ action: @escaping @MainActor (AudioPlayer, MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
            command.addTarget { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self else { return .commandFailed }
                    return action(self, event)
                }
            }
        }
        on(cc.playCommand) { p, _ in p.resume(); return .success }
        on(cc.pauseCommand) { p, _ in p.pause(); return .success }
        on(cc.togglePlayPauseCommand) { p, _ in p.toggle(); return .success }
        on(cc.nextTrackCommand) { p, _ in p.next(); return .success }
        on(cc.previousTrackCommand) { p, _ in p.previous(); return .success }
        on(cc.changePlaybackPositionCommand) { p, event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            p.seek(to: e.positionTime)
            return .success
        }
        cc.likeCommand.localizedTitle = "Love"
        cc.likeCommand.localizedShortTitle = "Love"
        on(cc.likeCommand) { p, _ in
            guard let item = p.current, item.songId != nil else { return .noActionableNowPlayingItem }
            p.onLike?(item, !item.starred)
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let item = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: item.artist,
            MPMediaItemPropertyAlbumTitle: item.isPreview ? "Preview · \(item.album)" : item.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let art = artwork, art.0 == item.artworkURL { info[MPMediaItemPropertyArtwork] = art.1 }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        let cc = MPRemoteCommandCenter.shared()
        cc.likeCommand.isEnabled = item.songId != nil
        cc.likeCommand.isActive = item.starred
    }

    private func loadArtwork(for item: PlayableItem) {
        guard let url = item.artworkURL, artwork?.0 != url else { return }
        Task {
            guard let data = try? await URLSession.shared.data(from: url).0, let image = UIImage(data: data) else { return }
            let art = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.artwork = (url, art)
            if self.current?.artworkURL == url { self.updateNowPlaying() }
        }
    }
}
