import AppIntents
#if !WIDGET_EXTENSION
import KodaCore
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
        let player = app.player
        if player.current != nil {
            player.togglePlayPause()
        } else if !app.library.liked.isEmpty {
            let songs = app.library.liked
            player.play(songs, startAt: Int.random(in: 0..<songs.count), shuffled: true)
        }
        return .result()
    }
    #endif
}
