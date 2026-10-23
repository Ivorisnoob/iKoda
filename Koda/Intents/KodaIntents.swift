import AppIntents
import CoreSpotlight
import KodaCore

// Siri, Shortcuts, Spotlight and the Action button, on the iPhone and the Mac.
//
// These are the App Intents every Siri understands, through the App Shortcuts at the
// bottom ("Play Starboy in Koda"). On iOS 27, `SiriSchemas.swift` adds the audio schemas
// the new Siri matches without set phrases. Both run inside the app; an audio intent
// starts it in the background when it isn't running.

// MARK: - Entities

/// A song the listener has: liked, played, in a playlist of theirs, or just found by a search.
struct SongEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Song", numericFormat: "\(placeholder: .int) songs")
    static let defaultQuery = SongEntityQuery()

    let id: String
    var title: String
    var artist: String
    var artworkURL: URL?

    init(_ song: Song) {
        id = song.id
        title = song.title
        artist = song.artistLine
        artworkURL = song.artwork?.url(pixels: 300)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(artist)", image: artworkURL.map { .init(url: $0) },
                              synonyms: ["\(title) by \(artist)"])
    }

    var song: Song {
        Song(id: id, title: title, artistLine: artist, artwork: artworkURL.map { Artwork(url: $0) })
    }
}

struct SongEntityQuery: EntityStringQuery {
    @Dependency private var app: AppModel

    @MainActor
    func entities(for identifiers: [String]) async throws -> [SongEntity] {
        let known = IntentSongs.known(app)
        return identifiers.compactMap { id in known[id].map(SongEntity.init) }
    }

    /// The library first; anything else from YouTube Music, remembered so Siri can come back for it.
    @MainActor
    func entities(matching string: String) async throws -> [SongEntity] {
        let mine = IntentSongs.library(app).filter { $0.matches(string) }
        if !mine.isEmpty { return mine.prefix(10).map(SongEntity.init) }
        let found = try await app.music.search(string, filter: .songs).songs
        IntentSongs.remember(found)
        return found.prefix(10).map(SongEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [SongEntity] {
        IntentSongs.library(app).prefix(50).map(SongEntity.init)
    }
}

/// A playlist the listener made in Koda.
struct PlaylistEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Playlist", numericFormat: "\(placeholder: .int) playlists")
    static let defaultQuery = PlaylistEntityQuery()

    let id: UUID
    var name: String
    var count: Int

    init(_ playlist: UserPlaylist) {
        id = playlist.id
        name = playlist.name
        count = playlist.songs.count
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(count) songs", image: .init(systemName: "music.note.list"),
                              synonyms: ["\(name) playlist"])
    }
}

struct PlaylistEntityQuery: EntityStringQuery {
    @Dependency private var app: AppModel

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [PlaylistEntity] {
        identifiers.compactMap { app.library.userPlaylist($0) }.map(PlaylistEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [PlaylistEntity] {
        app.library.userPlaylists.filter { $0.name.localizedStandardContains(string) }.map(PlaylistEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [PlaylistEntity] {
        app.library.userPlaylists.map(PlaylistEntity.init)
    }
}

/// Where intents look songs up: the library, and songs a recent search turned up.
@MainActor
enum IntentSongs {
    private static var found: [String: Song] = [:]

    /// Liked, then recently played, then the listener's playlists; each song once.
    static func library(_ app: AppModel) -> [Song] {
        var seen = Set<String>()
        let all = app.library.liked + app.library.recent + app.library.userPlaylists.flatMap(\.songs)
        return all.filter { seen.insert($0.id).inserted }
    }

    static func known(_ app: AppModel) -> [String: Song] {
        var songs = found
        for song in library(app) { songs[song.id] = song }
        return songs
    }

    static func remember(_ songs: [Song]) {
        for song in songs.prefix(20) { found[song.id] = song }
    }
}

private extension Song {
    func matches(_ text: String) -> Bool {
        title.localizedStandardContains(text) || artistLine.localizedStandardContains(text)
            || "\(title) \(artistLine)".localizedStandardContains(text)
    }
}

// MARK: - Playing

struct PlaySongIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Song"
    static let description = IntentDescription("Plays a song, followed by songs like it.", categoryName: "Playback")

    @Parameter(title: "Song", requestValueDialog: "Which song?")
    var song: SongEntity

    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$song)") }

    @Dependency private var app: AppModel

    @MainActor
    func perform() async throws -> some IntentResult {
        let chosen = IntentSongs.known(app)[song.id] ?? song.song
        app.player.startRadio(from: chosen)
        return .result()
    }
}

struct PlayPlaylistIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Playlist"
    static let description = IntentDescription("Plays one of the playlists you made in Koda.", categoryName: "Playback")

    @Parameter(title: "Playlist", requestValueDialog: "Which playlist?")
    var playlist: PlaylistEntity

    @Parameter(title: "Shuffle", default: false)
    var shuffle: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$playlist)") { \.$shuffle }
    }

    @Dependency private var app: AppModel

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let saved = app.library.userPlaylist(playlist.id), !saved.songs.isEmpty else {
            return .result(dialog: "That playlist is empty.")
        }
        app.player.play(saved.songs, startAt: shuffle ? Int.random(in: 0..<saved.songs.count) : 0, shuffled: shuffle)
        return .result(dialog: "Playing \(saved.name).")
    }
}

/// "Play something" for any words: the best match on YouTube Music, as Search would show it.
struct SearchAndPlayIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Search and Play"
    static let description = IntentDescription("Finds a song, album, artist or playlist on YouTube Music and plays it.",
                                               categoryName: "Playback", searchKeywords: ["play", "music", "search", "listen"])

    @Parameter(title: "What to Play", requestValueDialog: "What would you like to hear?")
    var query: String

    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$query)") }

    @Dependency private var app: AppModel

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let results = try await app.music.search(query)
        switch results.top {
        case .song(let song):
            app.player.startRadio(from: song)
            return .result(dialog: "Playing \(song.title) by \(song.artistLine).")
        case .album(let album):
            let songs = try await app.music.album(album.id).songs
            guard !songs.isEmpty else { break }
            app.player.play(songs)
            return .result(dialog: "Playing \(album.title).")
        case .playlist(let playlist):
            let songs = try await app.music.playlist(playlist.id).songs
            guard !songs.isEmpty else { break }
            app.player.play(songs)
            return .result(dialog: "Playing \(playlist.title).")
        case .artist(let artist):
            let page = try await app.music.artist(artist.id)
            guard let first = page.topSongs.first else { break }
            app.player.play(page.topSongs)
            return .result(dialog: "Playing \(page.artist.name.isEmpty ? first.artistLine : page.artist.name).")
        case nil:
            break
        }
        guard let song = results.songs.first ?? results.topSongs.first else {
            return .result(dialog: "Koda couldn't find \(query).")
        }
        app.player.startRadio(from: song)
        return .result(dialog: "Playing \(song.title) by \(song.artistLine).")
    }
}

struct StartRadioIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Start Radio"
    static let description = IntentDescription("Plays songs like the one playing now.", categoryName: "Playback")

    @Dependency private var app: AppModel

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let song = app.player.current else { return .result(dialog: "Nothing is playing in Koda.") }
        app.player.startRadio(from: song)
        return .result(dialog: "Playing songs like \(song.title).")
    }
}

// MARK: - Library

struct LikeCurrentSongIntent: AppIntent {
    static let title: LocalizedStringResource = "Like Current Song"
    static let description = IntentDescription("Adds the song playing now to your liked songs.", categoryName: "Library")

    @Dependency private var app: AppModel

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let song = app.player.current else { return .result(dialog: "Nothing is playing in Koda.") }
        if app.library.isLiked(song) { return .result(dialog: "\(song.title) is already in your liked songs.") }
        app.library.toggleLike(song)
        return .result(dialog: "Liked \(song.title).")
    }
}

// MARK: - App Shortcuts

/// Phrases Siri knows without setup, and the actions Shortcuts and Spotlight show first.
struct KodaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlaySongIntent(), phrases: [
            "Play \(\.$song) in \(.applicationName)",
            "Play \(\.$song) on \(.applicationName)",
        ], shortTitle: "Play Song", systemImageName: "music.note")
        AppShortcut(intent: PlayPlaylistIntent(), phrases: [
            "Play \(\.$playlist) in \(.applicationName)",
            "Play my \(\.$playlist) playlist in \(.applicationName)",
        ], shortTitle: "Play Playlist", systemImageName: "music.note.list")
        AppShortcut(intent: PlayLikedSongsIntent(), phrases: [
            "Play my liked songs in \(.applicationName)",
            "Shuffle my liked songs in \(.applicationName)",
            "Play my favorites in \(.applicationName)",
        ], shortTitle: "Liked Songs", systemImageName: "heart.fill")
        AppShortcut(intent: SearchAndPlayIntent(), phrases: [
            "Play music in \(.applicationName)",
            "Play something in \(.applicationName)",
            "Search \(.applicationName)",
        ], shortTitle: "Search and Play", systemImageName: "magnifyingglass")
        AppShortcut(intent: StartRadioIntent(), phrases: [
            "Start a radio in \(.applicationName)",
            "Play more like this in \(.applicationName)",
        ], shortTitle: "Start Radio", systemImageName: "dot.radiowaves.left.and.right")
        AppShortcut(intent: LikeCurrentSongIntent(), phrases: [
            "Like this song in \(.applicationName)",
            "Love this song in \(.applicationName)",
        ], shortTitle: "Like Song", systemImageName: "heart")
    }
}

// MARK: - Spotlight

/// Puts liked songs and the listener's playlists in Spotlight, and tells Siri which song and
/// playlist names it can expect, whenever they change.
@MainActor
enum IntentsIndex {
    static func update(_ app: AppModel) {
        let songs = app.library.liked.prefix(500).map(SongEntity.init)
        let playlists = app.library.userPlaylists.map(PlaylistEntity.init)
        KodaShortcuts.updateAppShortcutParameters()
        Task.detached(priority: .utility) {
            let index = CSSearchableIndex.default()
            try? await index.deleteAppEntities(ofType: SongEntity.self)
            try? await index.indexAppEntities(Array(songs))
            try? await index.indexAppEntities(playlists)
        }
        #if canImport(MediaIntents) && !targetEnvironment(macCatalyst)
        if #available(iOS 27, *) { SchemaIndex.update(app) }
        #endif
    }
}
