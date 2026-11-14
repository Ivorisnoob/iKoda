import ImageIO
import KodaCore
import SwiftUI
import UniformTypeIdentifiers
import WidgetKit

/// Keeps the widgets in step with the app, on the iPhone and the Mac: what's playing
/// (`NowPlayingSnapshot`: the song, whether it plays, where it has got to, what's next, the
/// cover's colours) and the listener's recent songs and listening (`ListeningSnapshot`), written
/// to the shared folder whenever they change, each followed by a reload of its widgets. Covers
/// are written once per song, small, and dropped when no widget shows them any more. Made only
/// when the build has a shared folder (see `SharedContainer`).
@MainActor
final class WidgetBridge {
    private let player: Player
    private let library: Library
    private var nowWritten: NowPlayingSnapshot?
    private var listeningWritten: ListeningSnapshot?
    private var listeningWrittenAt: Date?
    private var nowWork: Task<Void, Never>?
    private var listeningWork: Task<Void, Never>?
    /// A listening write held back by the throttle, due when it runs out.
    private var listeningPending: Task<Void, Never>?
    /// Cover files on disk, by song id, and the colours found in each.
    private var covers: [String: String] = [:]
    private var palettes: [String: [WidgetColor]] = [:]
    private var fetching: [String: Task<String?, Never>] = [:]

    /// Listening time grows every second a song plays; the widgets show minutes, so they're told
    /// at most this often, and at once when a new song starts.
    private static let listeningInterval: TimeInterval = 300
    private static let coverPixels = 300

    init?(player: Player, library: Library) {
        guard let folder = SharedContainer.covers else { return nil }
        self.player = player
        self.library = library
        // Covers written on an earlier run are still good.
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".jpg") {
            covers[String(name.dropLast(4))] = name
        }
        observePlayer()
        observeRecent()
        observeListening()
    }

    // MARK: Observation

    private func observePlayer() {
        withObservationTracking({
            _ = player.current
            _ = player.wantsToPlay
            _ = player.upcoming
            _ = player.timeAnchor
            _ = player.duration
        }, onChange: Self.handler { $0.observePlayer() }(self))
        publishNowPlaying()
    }

    private func observeRecent() {
        withObservationTracking({
            _ = library.recent
            _ = library.history
        }, onChange: Self.handler { $0.observeRecent() }(self))
        publishListening(now: true)
    }

    private func observeListening() {
        withObservationTracking({
            _ = library.dailyListening
        }, onChange: Self.handler { $0.observeListening() }(self))
        publishListening(now: false)
    }

    /// Observation calls back on whichever thread made the change, so the handler is built
    /// outside the main actor and hops back to it.
    private nonisolated static func handler(_ action: @escaping @MainActor @Sendable (WidgetBridge) -> Void)
        -> (WidgetBridge) -> @Sendable () -> Void {
        { bridge in { Task { @MainActor in action(bridge) } } }
    }

    // MARK: Now Playing

    private func publishNowPlaying() {
        guard let song = player.current else {
            guard nowWritten != nil else { return }
            nowWritten = nil
            nowWork?.cancel()
            nowWork = Task {
                await Self.write(Self.nowKinds) { NowPlayingSnapshot.save(nil) }
                prune()
            }
            return
        }
        let now = Date()
        let upcoming = player.upcoming.prefix(4).map(\.song)
        let snapshot = NowPlayingSnapshot(
            song: widgetSong(song), isPlaying: player.wantsToPlay, position: player.position(at: now), date: now,
            duration: song.duration ?? player.duration, colors: palettes[song.id], upNext: upcoming.map(widgetSong))
        // The widget's bar runs by itself, so the clock ticking on is no news; a seek is.
        if let written = nowWritten {
            var same = snapshot
            same.position = written.position
            same.date = written.date
            if same == written, abs(written.position(at: now) - snapshot.position) < 2 { return }
        }
        nowWritten = snapshot
        nowWork?.cancel()
        nowWork = Task {
            var snapshot = snapshot
            let songs = [song] + upcoming
            if songs.contains(where: { covers[$0.id] == nil }) || palettes[song.id] == nil {
                // What's known goes out at once; the covers follow.
                await Self.write(Self.nowKinds) { [snapshot] in NowPlayingSnapshot.save(snapshot) }
                for each in songs { _ = await cover(for: each) }
                guard !Task.isCancelled else { return }
                snapshot.song.cover = covers[song.id]
                snapshot.upNext = upcoming.map(widgetSong)
                snapshot.colors = palette(for: song.id)
                nowWritten = snapshot
            }
            guard !Task.isCancelled else { return }
            await Self.write(Self.nowKinds) { [snapshot] in NowPlayingSnapshot.save(snapshot) }
            prune()
        }
    }

    // MARK: Recently Played and Listening

    private func publishListening(now: Bool) {
        let date = Date()
        if !now, let last = listeningWrittenAt, date.timeIntervalSince(last) < Self.listeningInterval {
            guard listeningPending == nil else { return }
            listeningPending = Task {
                try? await Task.sleep(for: .seconds(Self.listeningInterval - date.timeIntervalSince(last)))
                guard !Task.isCancelled else { return }
                listeningPending = nil
                publishListening(now: true)
            }
            return
        }
        listeningPending?.cancel()
        listeningPending = nil
        let snapshot = listeningSnapshot(at: date)
        guard snapshot != listeningWritten else { return }
        listeningWritten = snapshot
        listeningWrittenAt = date
        let recent = Array(library.recent.prefix(9))
        listeningWork?.cancel()
        listeningWork = Task {
            var snapshot = snapshot
            if recent.contains(where: { covers[$0.id] == nil }) || (recent.first.map { palettes[$0.id] == nil } ?? false) {
                await Self.write(Self.listeningKinds) { [snapshot] in ListeningSnapshot.save(snapshot) }
                for song in recent { _ = await cover(for: song) }
                guard !Task.isCancelled else { return }
                snapshot.recent = recent.map(widgetSong)
                snapshot.recentColors = recent.first.flatMap { palette(for: $0.id) }
                listeningWritten = snapshot
            }
            guard !Task.isCancelled else { return }
            await Self.write(Self.listeningKinds) { [snapshot] in ListeningSnapshot.save(snapshot) }
            prune()
        }
    }

    private func listeningSnapshot(at date: Date) -> ListeningSnapshot {
        let calendar = Calendar.current
        var days: [String: TimeInterval] = [:]
        for back in 0..<8 {
            guard let day = calendar.date(byAdding: .day, value: -back, to: date) else { continue }
            // Whole minutes: the widgets show no more, and a second more is no reason to redraw them.
            let seconds = (library.listening(on: day) / 60).rounded(.down) * 60
            if seconds > 0 { days[WidgetDay.key(day)] = seconds }
        }
        let streak = library.streak(asOf: date)
        let streakEnd = library.listening(on: date) > 0 ? date : calendar.date(byAdding: .day, value: -1, to: date)
        // The artist played most this week, by the artist YouTube credits first.
        let weekAgo = date.addingTimeInterval(-7 * 86_400)
        var plays: [String: Int] = [:]
        for event in library.history where event.date >= weekAgo {
            plays[event.song.artists.first?.name ?? event.song.artistLine, default: 0] += 1
        }
        let top = plays.max { $0.value < $1.value }
        let recent = library.recent.prefix(9)
        return ListeningSnapshot(
            recent: recent.map(widgetSong), recentColors: recent.first.flatMap { palettes[$0.id] }, days: days,
            streak: streak, streakEnds: streak > 0 ? streakEnd.map { WidgetDay.key($0) } : nil,
            topArtist: top?.key, topArtistPlays: top?.value ?? 0)
    }

    // MARK: Covers

    private func widgetSong(_ song: Song) -> WidgetSong {
        WidgetSong(id: song.id, title: song.title, artist: song.artistLine, cover: covers[song.id])
    }

    /// The song's cover as a small square JPEG in the shared folder, fetched once.
    private func cover(for song: Song) async -> String? {
        if let file = covers[song.id] { return file }
        if let pending = fetching[song.id] { return await pending.value }
        let task = Task { await writeCover(of: song) }
        fetching[song.id] = task
        let file = await task.value
        fetching[song.id] = nil
        if let file { covers[song.id] = file }
        return file
    }

    private func writeCover(of song: Song) async -> String? {
        guard let folder = SharedContainer.covers, let artwork = song.artwork,
              let image = await ImagePipeline.shared.image(artwork.url(pixels: Self.coverPixels), pixels: Self.coverPixels),
              let cgImage = image.cgImage else { return nil }
        // YouTube's video thumbnails are 4:3 with the 16:9 picture letterboxed inside, as ArtworkView knows.
        let letterboxed = artwork.url.host()?.contains("ytimg.com") == true
            && abs(Double(cgImage.width) / Double(max(1, cgImage.height)) - 4.0 / 3.0) < 0.02
        guard let jpeg = Self.squareJPEG(cgImage, letterboxed: letterboxed) else { return nil }
        let name = "\(song.id).jpg"
        let written = await Task.detached(priority: .utility) { () -> Bool in
            (try? jpeg.write(to: folder.appending(path: name), options: .atomic)) != nil
        }.value
        guard written else { return nil }
        palettes[song.id] = Self.colors(of: image)
        return name
    }

    /// The cover's colours; for a cover written on an earlier run, read back from its file.
    private func palette(for songId: String) -> [WidgetColor]? {
        if let known = palettes[songId] { return known }
        guard let url = SharedContainer.cover(covers[songId]),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let colors = Self.colors(of: PlatformImage(cgImage: cgImage))
        palettes[songId] = colors
        return colors
    }

    private static func colors(of image: PlatformImage) -> [WidgetColor] {
        let environment = EnvironmentValues()
        return PaletteExtractor.palette(for: image).mesh.map { WidgetColor($0.resolve(in: environment)) }
    }

    /// The middle square of the cover (of the picture, for a letterboxed thumbnail), as JPEG.
    private static func squareJPEG(_ image: CGImage, letterboxed: Bool) -> Data? {
        let height = letterboxed ? Int(Double(image.height) * 0.75) : image.height
        let side = min(image.width, height)
        let rect = CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)
        guard let square = image.cropping(to: rect) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, square, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Covers no widget shows any more are removed, from the disk and from what's known.
    private func prune() {
        var kept = Set<String>()
        if let now = nowWritten { kept.insert(now.song.id); kept.formUnion(now.upNext.map(\.id)) }
        if let listening = listeningWritten { kept.formUnion(listening.recent.map(\.id)) }
        let dropped = covers.filter { !kept.contains($0.key) && fetching[$0.key] == nil }
        guard !dropped.isEmpty, let folder = SharedContainer.covers else { return }
        for id in dropped.keys {
            covers[id] = nil
            palettes[id] = nil
        }
        let files = Array(dropped.values)
        Task.detached(priority: .utility) {
            for file in files { try? FileManager.default.removeItem(at: folder.appending(path: file)) }
        }
    }

    // MARK: Writing

    private static let nowKinds = [NowPlayingSnapshot.widgetKind]
    private static let listeningKinds = [ListeningSnapshot.recentKind, ListeningSnapshot.listeningKind]

    /// Writes off the main thread, then asks the widgets that read it to read again.
    private static func write(_ kinds: [String], _ save: @escaping @Sendable () -> Void) async {
        await Task.detached(priority: .utility) {
            save()
            for kind in kinds { WidgetCenter.shared.reloadTimelines(ofKind: kind) }
        }.value
    }
}
