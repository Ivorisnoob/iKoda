import AVFoundation
import KodaCore
import SwiftUI

/// The picture and the sound for Video mode: a player on the main actor, the
/// current video, the up-next queue, the position and the chosen quality.
/// Separate from the music `Player`, which owns files, crossfades and downloads.
@MainActor
@Observable
final class VideoPlayback {
    let videos: YouTubeVideos

    @ObservationIgnored let player = AVPlayer()

    var current: VideoItem?
    var upNext: [VideoItem] = []
    var position: TimeInterval = 0
    var duration: TimeInterval = 0
    var isPlaying: Bool = false
    var quality: VideoQuality = .automatic
    /// Called when a video starts, so the music player can step aside: two
    /// sounds at once is not a mode anybody asked for.
    var onStart: (() -> Void)?

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var retriedCurrent = false

    init(videos: YouTubeVideos) {
        self.videos = videos
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                if time.isValid { self.position = time.seconds }
                if let item = self.player.currentItem {
                    let d = item.duration.seconds
                    if d.isFinite, !d.isNaN { self.duration = d }
                }
                self.isPlaying = self.player.rate > 0
            }
        }
    }

    // MARK: - Transport

    func play(_ item: VideoItem, queue: [VideoItem] = []) {
        upNext = queue
        current = item
        Task { await loadAndPlay(item) }
    }

    func playQueue(_ items: [VideoItem], startAt: Int = 0) {
        guard !items.isEmpty else { return }
        let start = min(max(0, startAt), items.count - 1)
        upNext = Array(items[(start + 1)...])
        current = items[start]
        Task { await loadAndPlay(items[start]) }
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func resume() {
        player.play()
        isPlaying = true
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { resume() }
    }

    func seek(to seconds: TimeInterval) {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time) { [weak self] _ in
            Task { @MainActor in self?.position = seconds }
        }
    }

    func skipToNext() {
        advance()
    }

    func setQuality(_ q: VideoQuality) {
        quality = q
        if let item = player.currentItem { applyQuality(to: item) }
    }

    // MARK: - Loading

    private func loadAndPlay(_ item: VideoItem) async {
        do {
            let stream = try await videos.stream(for: item.id)
            apply(stream, item: item)
        } catch {
            await videos.streamFailed(item.id)
            do {
                let stream = try await videos.stream(for: item.id)
                apply(stream, item: item)
            } catch {
                advance()
            }
        }
    }

    private func apply(_ stream: VideoStream, item: VideoItem) {
        retriedCurrent = false
        let asset = AVURLAsset(url: stream.url)
        let avItem = AVPlayerItem(asset: asset)
        if let d = stream.duration, d > 0 { duration = d }

        applyQuality(to: avItem)

        statusObservation?.invalidate()
        statusObservation = avItem.observe(\.status, options: [.new]) { [weak self] observed, _ in
            Task { @MainActor in
                guard let self else { return }
                if observed.status == .failed, !self.retriedCurrent {
                    self.retriedCurrent = true
                    await self.videos.streamFailed(item.id)
                    await self.loadAndPlay(item)
                }
            }
        }

        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: avItem,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }

        player.replaceCurrentItem(with: avItem)
        onStart?()
        player.play()
        isPlaying = true
        current = item
        position = 0
    }

    private func applyQuality(to item: AVPlayerItem) {
        switch quality {
        case .automatic:
            item.preferredPeakBitRate = 0
            item.preferredMaximumResolution = .zero
        case .p360:
            item.preferredPeakBitRate = quality.peakBitRate
            item.preferredMaximumResolution = CGSize(width: 640, height: 360)
        case .p480:
            item.preferredPeakBitRate = quality.peakBitRate
            item.preferredMaximumResolution = CGSize(width: 854, height: 480)
        case .p720:
            item.preferredPeakBitRate = quality.peakBitRate
            item.preferredMaximumResolution = CGSize(width: 1280, height: 720)
        case .p1080:
            item.preferredPeakBitRate = quality.peakBitRate
            item.preferredMaximumResolution = CGSize(width: 1920, height: 1080)
        }
    }

    private func advance() {
        guard !upNext.isEmpty else {
            player.pause()
            isPlaying = false
            return
        }
        let next = upNext.removeFirst()
        current = next
        Task { await loadAndPlay(next) }
    }
}
