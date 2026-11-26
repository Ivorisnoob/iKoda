import AppIntents
#if !WIDGET_EXTENSION
import KodaCore
import os

/// Each widget or Control Center tap as it reaches the app (Console: subsystem Koda, category
/// Intents), to tell a tap that never arrives from one that arrives and finds nothing to do.
nonisolated enum IntentLog {
    static let logger = Logger(subsystem: "Koda", category: "Intents")
}
#endif

// Intents the widgets and Control Center use, compiled into the app and the widget extension
// alike. They're audio intents, so the system performs them in the app, starting it in the
// background if it isn't running: the extension's copies only name them and never run.

/// Liked songs, shuffled by default. From Siri, Shortcuts, widgets and Control Center.
struct PlayLikedSongsIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Liked Songs"
    static let description = IntentDescription("Plays the songs you liked in Koda.", categoryName: "Playback")

    @Parameter(title: "Shuffle", default: true)
    var shuffle: Bool

    init() {}

    init(shuffle: Bool) {
        self.shuffle = shuffle
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Play liked songs") { \.$shuffle }
    }

    #if WIDGET_EXTENSION
    func perform() async throws -> some IntentResult { .result() }
    #else
    @Dependency private var app: AppModel

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        IntentLog.logger.notice("PlayLikedSongsIntent: \(app.player.current == nil ? "nothing queued" : "playing", privacy: .public)")
        let songs = app.library.liked
        guard !songs.isEmpty else { return .result(dialog: "You haven't liked any songs in Koda yet.") }
        app.player.play(songs, startAt: shuffle ? Int.random(in: 0..<songs.count) : 0, shuffled: shuffle)
        return .result(dialog: "Playing your liked songs.")
    }
    #endif
}

/// Play or pause what Koda has queued; with nothing queued, liked songs shuffled.
struct TogglePlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play or Pause"
    static let description = IntentDescription("Plays or pauses Koda.", categoryName: "Playback")

    init() {}

    #if WIDGET_EXTENSION
    func perform() async throws -> some IntentResult { .result() }
    #else
    @Dependency private var app: AppModel

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentLog.logger.notice("TogglePlaybackIntent: \(app.player.current == nil ? "nothing queued" : "playing", privacy: .public)")
        let player = app.player
        if player.current != nil {
            player.togglePlayPause(from: "a shortcut or widget")
        } else if !app.library.liked.isEmpty {
            let songs = app.library.liked
            player.play(songs, startAt: Int.random(in: 0..<songs.count), shuffled: true)
        }
        return .result()
    }
    #endif
}

/// The next song in the queue, for the Now Playing widget.
struct NextSongIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Next Song"
    static let description = IntentDescription("Skips to the next song in Koda.", categoryName: "Playback")

    init() {}

    #if WIDGET_EXTENSION
    func perform() async throws -> some IntentResult { .result() }
    #else
    @Dependency private var app: AppModel

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentLog.logger.notice("NextSongIntent: \(app.player.current == nil ? "nothing queued" : "playing", privacy: .public)")
        app.player.next()
        return .result()
    }
    #endif
}

/// Back to the start of the song, or to the one before it, as the player's own button does.
struct PreviousSongIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Previous Song"
    static let description = IntentDescription("Goes back a song in Koda.", categoryName: "Playback")

    init() {}

    #if WIDGET_EXTENSION
    func perform() async throws -> some IntentResult { .result() }
    #else
    @Dependency private var app: AppModel

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentLog.logger.notice("PreviousSongIntent: \(app.player.current == nil ? "nothing queued" : "playing", privacy: .public)")
        app.player.previous()
        return .result()
    }
    #endif
}

/// One of the listener's recent songs, from the Recently Played widget; autoplay carries on after it.
struct PlayRecentSongIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Recent Song"
    static let description = IntentDescription("Plays a song you listened to lately in Koda.", categoryName: "Playback")
    /// Only the widget names a song by its id; Shortcuts has Koda's song entities for that.
    static let isDiscoverable = false

    @Parameter(title: "Song ID")
    var songId: String

    init() {}

    init(songId: String) {
        self.songId = songId
    }

    #if WIDGET_EXTENSION
    func perform() async throws -> some IntentResult { .result() }
    #else
    @Dependency private var app: AppModel

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentLog.logger.notice("PlayRecentSongIntent (song \(songId, privacy: .public)): \(app.player.current == nil ? "nothing queued" : "playing", privacy: .public)")
        let library = app.library
        if let song = library.recent.first(where: { $0.id == songId }) ?? library.history.first(where: { $0.song.id == songId })?.song {
            app.player.play([song], startAt: 0)
        } else {
            IntentLog.logger.error("PlayRecentSongIntent: \(songId, privacy: .public) isn't in this profile's recent songs")
        }
        return .result()
    }
    #endif
}
