import AVFoundation
import MediaPlayer
import UIKit

/// Playback time lives apart from `Player` so the twice-a-second tick only redraws the views
/// that show progress, not every list observing the player.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var time: Double = 0
    @Published var duration: Double = 0
}

@MainActor
final class Player: ObservableObject {
    static let shared = Player()

    enum RepeatMode { case off, all, one }

    @Published private(set) var queue: [SCTrack] = []
    @Published private(set) var index = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var shuffle = false
    @Published var repeatMode: RepeatMode = .off
    @Published var error: String?
    @Published private(set) var sleepAt: Date?
    @Published var showFullPlayer = false

    let clock = PlaybackClock()

    var current: SCTrack? { queue.indices.contains(index) ? queue[index] : nil }
    var upNext: [SCTrack] { index + 1 < queue.count ? Array(queue[(index + 1)...]) : [] }

    /// When the queue runs out, keep going with related tracks, like the website's autoplay.
    var autoplay: Bool {
        get { UserDefaults.standard.object(forKey: "player.autoplay") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "player.autoplay"); objectWillChange.send() }
    }

    private let player = AVPlayer()
    private var originalQueue: [SCTrack] = []
    private var loadTask: Task<Void, Never>?
    private var statusObservation: NSKeyValueObservation?
    private var controlObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var artwork: MPMediaItemArtwork?
    private var artworkFor: Int?
    private var sleepTimer: Timer?
    private var failures = 0
    private var seeking = false

    private init() {
        player.automaticallyWaitsToMinimizeStalling = true
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, !self.seeking else { return }
                let t = time.seconds
                if t.isFinite { self.clock.time = t }
                if let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0, abs(d - self.clock.duration) > 0.5 {
                    self.clock.duration = d
                    self.updateNowPlaying()
                }
            }
        }

        controlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let status = p.timeControlStatus
            Task { @MainActor in
                guard let self else { return }
                self.isPlaying = status != .paused
                self.isBuffering = status == .waitingToPlayAtSpecifiedRate
                self.updateNowPlaying()
            }
        }

        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] n in
            let item = n.object as? AVPlayerItem
            Task { @MainActor in
                guard let self, item === self.player.currentItem else { return }
                self.trackEnded()
            }
        }

        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let info = n.userInfo
            Task { @MainActor in
                guard let self,
                      let raw = info?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                if type == .ended,
                   let o = info?[AVAudioSessionInterruptionOptionKey] as? UInt,
                   AVAudioSession.InterruptionOptions(rawValue: o).contains(.shouldResume) {
                    self.resume()
                }
            }
        }

        setupRemoteCommands()
    }

    // MARK: queue

    func play(_ tracks: [SCTrack], at i: Int = 0) {
        let list = tracks.filter { !$0.isStub }
        guard !list.isEmpty else { return }
        let start = tracks.indices.contains(i) ? (list.firstIndex(where: { $0.id == tracks[i].id }) ?? 0) : 0
        originalQueue = list
        if shuffle {
            var rest = list
            let first = rest.remove(at: start)
            rest.shuffle()
            queue = [first] + rest
            index = 0
        } else {
            queue = list
            index = start
        }
        failures = 0
        load()
        showFullPlayerIfFirst()
    }

    func shufflePlay(_ tracks: [SCTrack]) {
        let list = tracks.filter { !$0.isStub }
        guard !list.isEmpty else { return }
        shuffle = true
        play(list, at: Int.random(in: 0..<list.count))
    }

    /// Plays one track, then its related tracks (a "station").
    func startStation(_ t: SCTrack) {
        play([t])
        Task {
            if let rel = try? await SCClient.shared.related(t.id) {
                let ids = Set(queue.map { $0.id })
                queue += rel.filter { !ids.contains($0.id) }
            }
        }
    }

    func playNext(_ t: SCTrack) {
        if queue.isEmpty { play([t]); return }
        queue.insert(t, at: index + 1)
        originalQueue.append(t)
    }

    func enqueue(_ tracks: [SCTrack]) {
        let list = tracks.filter { !$0.isStub }
        if queue.isEmpty { play(list); return }
        queue += list
        originalQueue += list
    }

    func jump(to i: Int) {
        guard queue.indices.contains(i) else { return }
        index = i
        load()
    }

    func removeUpNext(at offsets: IndexSet) {
        let absolute = IndexSet(offsets.map { $0 + index + 1 })
        for i in absolute.sorted(by: >) where queue.indices.contains(i) {
            queue.remove(at: i)
        }
    }

    func moveUpNext(from source: IndexSet, to destination: Int) {
        var up = upNext
        up.move(fromOffsets: source, toOffset: destination)
        queue = Array(queue[...index]) + up
    }

    func toggleShuffle() {
        shuffle.toggle()
        guard let cur = current else { return }
        if shuffle {
            let rest = upNext.shuffled()
            queue = Array(queue[...index]) + rest
        } else {
            // Back to the original order, keeping tracks added since.
            let known = Set(originalQueue.map { $0.id })
            let extra = queue.filter { !known.contains($0.id) }
            queue = originalQueue + extra
            index = queue.firstIndex(where: { $0.id == cur.id }) ?? 0
        }
    }

    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    // MARK: transport

    func togglePlay() {
        if isPlaying { pause() } else { resume() }
    }

    func resume() {
        if player.currentItem == nil {
            load()
            return
        }
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
    }

    func pause() {
        player.pause()
    }

    func next() {
        if index + 1 < queue.count {
            index += 1
            load()
        } else if repeatMode == .all, !queue.isEmpty {
            index = 0
            load()
        } else if autoplay, let t = current {
            continueWithRelated(t)
        }
    }

    func previous() {
        if clock.time > 3 || index == 0 {
            seek(to: 0)
        } else {
            index -= 1
            load()
        }
    }

    func seek(to seconds: Double) {
        seeking = true
        clock.time = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.seeking = false
                self?.updateNowPlaying()
            }
        }
    }

    func skip(_ delta: Double) {
        seek(to: max(0, min(clock.duration, clock.time + delta)))
    }

    // MARK: sleep timer

    func setSleep(minutes: Int?) {
        sleepTimer?.invalidate()
        sleepTimer = nil
        guard let minutes else {
            sleepAt = nil
            return
        }
        let at = Date().addingTimeInterval(Double(minutes) * 60)
        sleepAt = at
        sleepTimer = Timer.scheduledTimer(withTimeInterval: Double(minutes) * 60, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.pause()
                self?.sleepAt = nil
            }
        }
    }

    // MARK: loading

    private func showFullPlayerIfFirst() {
        if !UserDefaults.standard.bool(forKey: "player.shownOnce") {
            UserDefaults.standard.set(true, forKey: "player.shownOnce")
            showFullPlayer = true
        }
    }

    private func load() {
        guard let t = current else { return }
        loadTask?.cancel()
        error = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        clock.time = 0
        clock.duration = t.seconds
        isBuffering = true
        updateNowPlaying()
        loadArtwork(t)

        loadTask = Task {
            do {
                let url: URL
                if let local = Downloads.shared.localURL(for: t.id) {
                    url = local
                } else {
                    url = try await SCClient.shared.streamURL(for: t)
                }
                guard !Task.isCancelled, current?.id == t.id else { return }
                let item = AVPlayerItem(url: url)
                observe(item, track: t)
                try? AVAudioSession.sharedInstance().setActive(true)
                player.replaceCurrentItem(with: item)
                player.play()
                failures = 0
                History.shared.add(t)
            } catch {
                guard !Task.isCancelled, current?.id == t.id else { return }
                failed(error.localizedDescription)
            }
        }
    }

    private func observe(_ item: AVPlayerItem, track: SCTrack) {
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let message = item.error?.localizedDescription
            Task { @MainActor in
                guard let self, self.current?.id == track.id else { return }
                if status == .failed {
                    self.failed(message ?? "Не удалось воспроизвести трек")
                }
            }
        }
    }

    /// A track that cannot play (DRM, region, removed) is skipped, up to a few in a row.
    private func failed(_ message: String) {
        error = message
        isBuffering = false
        failures += 1
        guard failures < 5, index + 1 < queue.count else { return }
        let failedId = current?.id
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if current?.id == failedId { next() }
        }
    }

    private func trackEnded() {
        if repeatMode == .one {
            seek(to: 0)
            player.play()
            return
        }
        if index + 1 < queue.count || repeatMode == .all || autoplay {
            next()
        } else {
            seek(to: 0)
            pause()
        }
    }

    private func continueWithRelated(_ t: SCTrack) {
        Task {
            guard let rel = try? await SCClient.shared.related(t.id) else { return }
            let ids = Set(queue.map { $0.id })
            let fresh = rel.filter { !ids.contains($0.id) }
            guard !fresh.isEmpty else { return }
            queue += fresh
            index += 1
            load()
        }
    }

    // MARK: lock screen

    private func setupRemoteCommands() {
        let rc = MPRemoteCommandCenter.shared()
        rc.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        rc.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        rc.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlay() }
            return .success
        }
        rc.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        rc.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        rc.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let pos = e.positionTime
            Task { @MainActor in self?.seek(to: pos) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let t = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title ?? "",
            MPMediaItemPropertyArtist: t.user?.name ?? "",
            MPMediaItemPropertyPlaybackDuration: clock.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: clock.time,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying && !isBuffering ? 1.0 : 0.0,
        ]
        if artworkFor == t.id, let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork(_ t: SCTrack) {
        guard artworkFor != t.id, let url = t.artwork() else { return }
        Task {
            guard let res = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: res.0),
                  current?.id == t.id else { return }
            artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            artworkFor = t.id
            updateNowPlaying()
        }
    }
}
