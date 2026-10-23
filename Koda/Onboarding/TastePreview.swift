import AVFoundation
import KodaCore
import SwiftUI

/// A few seconds of the deck's top card, from a third of the way in where a song has usually
/// arrived, on a player of its own: a preview isn't a play, so it never reaches the queue,
/// history, stats, Last.fm or the account. The app's own player is paused while it runs.
@MainActor
@Observable
final class TastePreview {
    private(set) var playingID: String?
    private(set) var isLoading = false
    var isMuted = false { didSet { player.isMuted = isMuted } }

    private let music: YouTubeMusic
    private let player = AVPlayer()
    @ObservationIgnored private var loading: Task<Void, Never>?

    init(music: YouTubeMusic) {
        self.music = music
    }

    func play(_ song: Song?, pausing appPlayer: Player) {
        loading?.cancel()
        player.pause()
        guard let song else {
            playingID = nil
            return
        }
        if appPlayer.wantsToPlay { appPlayer.togglePlayPause() }
        playingID = song.id
        isLoading = true
        loading = Task {
            defer { if playingID == song.id { isLoading = false } }
            guard let stream = try? await music.stream(for: song.id), !Task.isCancelled, playingID == song.id else { return }
            let asset = AVURLAsset(url: stream.url, options: [AVURLAssetHTTPUserAgentKey: stream.userAgent])
            let item = AVPlayerItem(asset: asset)
            player.replaceCurrentItem(with: item)
            let length = stream.duration ?? song.duration ?? 0
            if length > 45 { await player.seek(to: CMTime(seconds: length / 3, preferredTimescale: 600)) }
            guard !Task.isCancelled, playingID == song.id else { return }
            player.isMuted = isMuted
            player.play()
        }
    }

    func stop() {
        loading?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        playingID = nil
        isLoading = false
    }
}
