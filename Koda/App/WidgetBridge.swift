#if os(iOS) && !targetEnvironment(macCatalyst)
import KodaCore
import SwiftUI
import UIKit
import WidgetKit

/// Keeps the Now Playing widget in step with the player: the song, whether it plays, where it
/// has got to, its cover and what's next, written to the app group's folder (`NowPlayingSnapshot`)
/// whenever one of them changes, followed by a reload of the widget. Made only when the build
/// has an app group (see `SharedContainer`).
@MainActor
final class WidgetBridge {
    private let player: Player
    private var written: NowPlayingSnapshot?
    /// The song the cover on disk belongs to, and its file.
    private var cover: (songId: String, file: String)?
    private var work: Task<Void, Never>?

    init?(player: Player) {
        guard SharedContainer.directory != nil else { return nil }
        self.player = player
        observe()
    }

    private func observe() {
        withObservationTracking({
            _ = player.current
            _ = player.wantsToPlay
            _ = player.upcoming
            _ = player.timeAnchor
            _ = player.duration
        }, onChange: Self.changeHandler(self))
        publish()
    }

    /// Observation calls back on whichever thread made the change, so the handler is built
    /// outside the main actor and hops back to it.
    private nonisolated static func changeHandler(_ bridge: WidgetBridge) -> @Sendable () -> Void {
        { Task { @MainActor in bridge.observe() } }
    }

    private func publish() {
        guard let song = player.current else {
            guard written != nil else { return }
            written = nil
            work?.cancel()
            work = Task.detached(priority: .utility) {
                NowPlayingSnapshot.save(nil)
                WidgetCenter.shared.reloadTimelines(ofKind: NowPlayingSnapshot.widgetKind)
            }
            return
        }
        let now = Date()
        var snapshot = NowPlayingSnapshot(
            songId: song.id, title: song.title, artist: song.artistLine, isPlaying: player.wantsToPlay,
            position: player.position(at: now), date: now, duration: song.duration ?? player.duration,
            cover: cover?.songId == song.id ? cover?.file : nil,
            upNext: player.upcoming.prefix(4).map { .init(title: $0.song.title, artist: $0.song.artistLine) })
        // The widget's bar runs by itself, so the clock ticking on is no news; a seek is.
        if let written, written.songId == snapshot.songId, written.isPlaying == snapshot.isPlaying, written.upNext == snapshot.upNext,
           written.title == snapshot.title, written.cover == snapshot.cover, abs(written.duration - snapshot.duration) < 1,
           abs(written.position(at: now) - snapshot.position) < 2 {
            return
        }
        written = snapshot
        work?.cancel()
        work = Task {
            if snapshot.cover == nil, let file = await fetchCover(of: song) {
                guard !Task.isCancelled else { return }
                snapshot.cover = file
                written = snapshot
            }
            guard !Task.isCancelled else { return }
            let saved = snapshot
            await Task.detached(priority: .utility) {
                NowPlayingSnapshot.save(saved)
                WidgetCenter.shared.reloadTimelines(ofKind: NowPlayingSnapshot.widgetKind)
            }.value
        }
    }

    /// The song's cover as a small JPEG in the shared folder, named for the song so the widget
    /// never draws one song's cover under another's title. The last song's is removed.
    private func fetchCover(of song: Song) async -> String? {
        guard let folder = SharedContainer.directory, let artwork = song.artwork,
              let image = await ImagePipeline.shared.image(artwork.url(pixels: 400), pixels: 400) else { return nil }
        let name = "cover-\(song.id).jpg"
        let previous = cover?.file
        let written = await Task.detached(priority: .utility) { () -> Bool in
            guard let data = image.jpegData(compressionQuality: 0.8) else { return false }
            do {
                try data.write(to: folder.appending(path: name), options: .atomic)
            } catch {
                return false
            }
            if let previous, previous != name { try? FileManager.default.removeItem(at: folder.appending(path: previous)) }
            return true
        }.value
        guard written else { return nil }
        cover = (song.id, name)
        return name
    }
}
#endif
