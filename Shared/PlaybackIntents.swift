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
// background if it isn't running. The extension's copies were meant never to run; since iOS
// 27.2.1 left most widget buttons doing nothing (issue #10), they note the tap and hand it to
// the app (`WidgetTaps`), which runs it once whichever copy the system picked.

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
    func perform() async throws -> some IntentResult {
        WidgetTaps.extensionReceived(.playLiked, shuffle: shuffle)
        return .result()
    }
    #else
    @Dependency private var app: AppModel

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        IntentLog.logger.notice("PlayLikedSongsIntent: \(app.player.current == nil ? "nothing queued" : "playing", privacy: .public)")
        guard !app.library.liked.isEmpty else { return .result(dialog: "You haven't liked any songs in Koda yet.") }
        if WidgetTapRelay.shared.ranInApp(.playLiked) {
            WidgetTaps.Action.playLiked.run(on: app, shuffle: shuffle)
        }
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
    func perform() async throws -> some IntentResult {
        WidgetTaps.extensionReceived(.toggle)
        return .result()
    }
    #else
    @Dependency private var app: AppModel

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentLog.logger.notice("TogglePlaybackIntent: \(app.player.current == nil ? "nothing queued" : "playing", privacy: .public)")
        if WidgetTapRelay.shared.ranInApp(.toggle) { WidgetTaps.Action.toggle.run(on: app) }
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
    func perform() async throws -> some IntentResult {
        WidgetTaps.extensionReceived(.next)
        return .result()
    }
    #else
    @Dependency private var app: AppModel

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentLog.logger.notice("NextSongIntent: \(app.player.current == nil ? "nothing queued" : "playing", privacy: .public)")
        if WidgetTapRelay.shared.ranInApp(.next) { WidgetTaps.Action.next.run(on: app) }
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
    func perform() async throws -> some IntentResult {
        WidgetTaps.extensionReceived(.previous)
        return .result()
    }
    #else
    @Dependency private var app: AppModel

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentLog.logger.notice("PreviousSongIntent: \(app.player.current == nil ? "nothing queued" : "playing", privacy: .public)")
        if WidgetTapRelay.shared.ranInApp(.previous) { WidgetTaps.Action.previous.run(on: app) }
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
    func perform() async throws -> some IntentResult {
        WidgetTaps.extensionReceived(.playRecent, songId: songId)
        return .result()
    }
    #else
    @Dependency private var app: AppModel

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentLog.logger.notice("PlayRecentSongIntent (song \(songId, privacy: .public)): \(app.player.current == nil ? "nothing queued" : "playing", privacy: .public)")
        if WidgetTapRelay.shared.ranInApp(.playRecent) { WidgetTaps.Action.playRecent.run(on: app, songId: songId) }
        return .result()
    }
    #endif
}

#if !WIDGET_EXTENSION
extension WidgetTaps.Action {
    /// What each intent does in the app: from the app's own copy of the intent, and for a tap
    /// the widget extension handed over (`WidgetTapRelay`).
    @MainActor
    func run(on app: AppModel, shuffle: Bool = true, songId: String? = nil) {
        let player = app.player
        let liked = app.library.liked
        switch self {
        case .playLiked:
            guard !liked.isEmpty else { return }
            player.play(liked, startAt: shuffle ? Int.random(in: 0..<liked.count) : 0, shuffled: shuffle)
        case .toggle:
            if player.current != nil {
                player.togglePlayPause(from: "a shortcut or widget")
            } else if !liked.isEmpty {
                player.play(liked, startAt: Int.random(in: 0..<liked.count), shuffled: true)
            }
        case .next:
            player.next()
        case .previous:
            player.previous()
        case .playRecent:
            let library = app.library
            if let songId, let song = library.recent.first(where: { $0.id == songId }) ?? library.history.first(where: { $0.song.id == songId })?.song {
                player.play([song], startAt: 0)
            } else {
                IntentLog.logger.error("PlayRecentSongIntent: \(songId ?? "no id", privacy: .public) isn't in this profile's recent songs")
            }
        }
    }
}
#endif
