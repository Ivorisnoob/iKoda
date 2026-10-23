// The new Siri on iOS 27: Koda's songs, albums, artists and playlists as the audio schema's
// entities, and its actions as the schema's intents, so "play the new Daft Punk album in
// Koda" or "add this to my Gym playlist" work without any set phrase. Modeled on Apple's
// "Integrating your music app with Apple Intelligence" sample (WWDC26).
//
// Only built with the iOS 27 SDK (MediaIntents is new in it), and never for the Mac: the
// schemas aren't available to Mac Catalyst. Older systems use `KodaIntents.swift`.
#if canImport(MediaIntents) && !targetEnvironment(macCatalyst)
import AppIntents
import CoreSpotlight
import KodaCore
import MediaIntents

// MARK: - Entities

@available(iOS 27.0, *)
@AppEntity(schema: .audio.song)
struct SchemaSongEntity: IndexedEntity {
    static let defaultQuery = SchemaSongQuery()

    let id: String
    var title: String
    var artistName: String
    var albumTitle: String?
    var composerName: String?
    var internationalStandardRecordingCode: String?
    var album: SchemaAlbumEntity?
    var artists: [SchemaArtistEntity]
    var composers: [SchemaArtistEntity]
    var artworkURL: URL?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(artistName)", image: artworkURL.map { .init(url: $0) },
                              synonyms: ["\(title) by \(artistName)"])
    }

    // The schema's properties are wrapped by the macro: plain stored ones are set first.
    init(_ song: Song) {
        id = song.id
        artworkURL = song.artwork?.url(pixels: 300)
        title = song.title
        artistName = song.artistLine
        albumTitle = song.album?.title
        composerName = nil
        internationalStandardRecordingCode = nil
        album = song.album.map { SchemaAlbumEntity(id: $0.id, title: $0.title, artistName: song.artistLine) }
        artists = song.artists.map { SchemaArtistEntity(id: $0.id ?? $0.name, name: $0.name) }
        if artists.isEmpty, !song.artistLine.isEmpty { artists = [SchemaArtistEntity(id: song.artistLine, name: song.artistLine)] }
        composers = []
    }

    var song: Song {
        Song(id: id, title: title, artistLine: artistName, artwork: artworkURL.map { Artwork(url: $0) })
    }
}

@available(iOS 27.0, *)
extension SchemaSongEntity: Hashable {
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@available(iOS 27.0, *)
struct SchemaSongQuery: EntityStringQuery {
    @Dependency private var app: AppModel

    @MainActor
    func entities(for identifiers: [String]) async throws -> [SchemaSongEntity] {
        let known = IntentSongs.known(app)
        return identifiers.compactMap { known[$0].map(SchemaSongEntity.init) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [SchemaSongEntity] {
        let found = try await app.music.search(string, filter: .songs).songs
        IntentSongs.remember(found)
        return found.prefix(10).map(SchemaSongEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [SchemaSongEntity] {
        IntentSongs.library(app).prefix(50).map(SchemaSongEntity.init)
    }
}

@available(iOS 27.0, *)
@AppEntity(schema: .audio.album)
struct SchemaAlbumEntity: IndexedEntity {
    static let defaultQuery = SchemaAlbumQuery()

    let id: String
    var title: String
    var artistName: String
    var artists: [SchemaArtistEntity]
    var songs: [SchemaSongEntity]
    var universalProductCode: String?
    var artworkURL: URL?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(artistName)", image: artworkURL.map { .init(url: $0) },
                              synonyms: ["album \(title)", "\(artistName) album \(title)"])
    }

    init(id: String, title: String, artistName: String, artworkURL: URL? = nil) {
        self.id = id
        songs = []
        self.artworkURL = artworkURL
        self.title = title
        self.artistName = artistName
        artists = artistName.isEmpty ? [] : [SchemaArtistEntity(id: artistName, name: artistName)]
        universalProductCode = nil
    }

    init(_ album: AlbumSummary) {
        self.init(id: album.id, title: album.title, artistName: album.artistLine, artworkURL: album.artwork?.url(pixels: 300))
        artists = album.artists.map { SchemaArtistEntity(id: $0.id ?? $0.name, name: $0.name) }
    }
}

@available(iOS 27.0, *)
extension SchemaAlbumEntity: Hashable {
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@available(iOS 27.0, *)
struct SchemaAlbumQuery: EntityStringQuery {
    @Dependency private var app: AppModel

    @MainActor
    func entities(for identifiers: [String]) async throws -> [SchemaAlbumEntity] {
        let saved = Dictionary(app.library.albums.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return identifiers.map { id in saved[id].map(SchemaAlbumEntity.init) ?? SchemaAlbumEntity(id: id, title: "", artistName: "") }
    }

    @MainActor
    func entities(matching string: String) async throws -> [SchemaAlbumEntity] {
        try await app.music.search(string, filter: .albums).albums.prefix(10).map(SchemaAlbumEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [SchemaAlbumEntity] {
        app.library.albums.map(SchemaAlbumEntity.init)
    }
}

@available(iOS 27.0, *)
@AppEntity(schema: .audio.artist)
struct SchemaArtistEntity: IndexedEntity {
    static let defaultQuery = SchemaArtistQuery()

    /// The channel id when YouTube linked the artist, otherwise the name.
    let id: String
    var name: String
    var albums: [SchemaAlbumEntity]
    var songs: [SchemaSongEntity]

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: "music.microphone"))
    }

    init(id: String, name: String) {
        self.id = id
        albums = []
        songs = []
        self.name = name
    }
}

@available(iOS 27.0, *)
extension SchemaArtistEntity: Hashable {
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@available(iOS 27.0, *)
struct SchemaArtistQuery: EntityStringQuery {
    @Dependency private var app: AppModel

    @MainActor
    func entities(for identifiers: [String]) async throws -> [SchemaArtistEntity] {
        let saved = Dictionary(app.library.artists.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        return identifiers.map { SchemaArtistEntity(id: $0, name: saved[$0] ?? $0) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [SchemaArtistEntity] {
        try await app.music.search(string, filter: .artists).artists.prefix(10).map { SchemaArtistEntity(id: $0.id, name: $0.name) }
    }

    @MainActor
    func suggestedEntities() async throws -> [SchemaArtistEntity] {
        app.library.artists.map { SchemaArtistEntity(id: $0.id, name: $0.name) }
    }
}

@available(iOS 27.0, *)
@UnionValue
enum SchemaPlaylistOwner {
    case curator(String)
    case person(IntentPerson)
}

/// A playlist: one the listener made (its UUID) or one saved from YouTube Music (its id).
@available(iOS 27.0, *)
@AppEntity(schema: .audio.playlist)
struct SchemaPlaylistEntity: IndexedEntity {
    static let defaultQuery = SchemaPlaylistQuery()

    let id: String
    var title: String
    var owner: SchemaPlaylistOwner?
    var trackCount: Int
    var totalDuration: TimeInterval
    var createdByMe: Bool?
    var curatedForMe: Bool?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: createdByMe == true ? "^[\(trackCount) song](inflect: true)" : nil,
                              image: .init(systemName: "music.note.list"), synonyms: ["\(title) playlist"])
    }

    init(_ playlist: UserPlaylist) {
        id = playlist.id.uuidString
        trackCount = playlist.songs.count
        totalDuration = playlist.duration
        title = playlist.name
        owner = nil
        createdByMe = true
        curatedForMe = false
    }

    init(_ playlist: PlaylistSummary) {
        id = playlist.id
        trackCount = 0
        totalDuration = 0
        title = playlist.title
        owner = playlist.subtitle.map { .curator($0) }
        createdByMe = false
        curatedForMe = nil
    }
}

@available(iOS 27.0, *)
extension SchemaPlaylistEntity: Hashable {
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@available(iOS 27.0, *)
struct SchemaPlaylistQuery: EntityStringQuery {
    @Dependency private var app: AppModel

    @MainActor
    func entities(for identifiers: [String]) async throws -> [SchemaPlaylistEntity] {
        identifiers.compactMap { id in
            if let uuid = UUID(uuidString: id), let mine = app.library.userPlaylist(uuid) { return SchemaPlaylistEntity(mine) }
            return app.library.playlists.first { $0.id == id }.map(SchemaPlaylistEntity.init) ?? SchemaPlaylistEntity(PlaylistSummary(id: id, title: ""))
        }
    }

    @MainActor
    func entities(matching string: String) async throws -> [SchemaPlaylistEntity] {
        let mine = app.library.userPlaylists.filter { $0.name.localizedStandardContains(string) }.map(SchemaPlaylistEntity.init)
        let saved = app.library.playlists.filter { $0.title.localizedStandardContains(string) }.map(SchemaPlaylistEntity.init)
        guard mine.isEmpty, saved.isEmpty else { return mine + saved }
        return try await app.music.search(string, filter: .playlists).playlists.prefix(10).map(SchemaPlaylistEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [SchemaPlaylistEntity] {
        app.library.userPlaylists.map(SchemaPlaylistEntity.init) + app.library.playlists.map(SchemaPlaylistEntity.init)
    }
}

@available(iOS 27.0, *)
@AppEntity(schema: .audio.warmupAudioQueueResult)
struct SchemaWarmupResult: TransientAppEntity {
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "Queue Ready") }
    init() {}
}

@available(iOS 27.0, *)
@UnionValue
enum SchemaAudioItem {
    case song(SchemaSongEntity)
    case album(SchemaAlbumEntity)
    case artist(SchemaArtistEntity)
    case playlist(SchemaPlaylistEntity)
}

// MARK: - Enums

@available(iOS 27.0, *)
@AppEnum(schema: .audio.playbackAttributes)
enum SchemaPlaybackAttributes: String {
    case shuffle
    case `repeat`

    static let caseDisplayRepresentations: [SchemaPlaybackAttributes: DisplayRepresentation] = [
        .shuffle: "Shuffle",
        .repeat: "Repeat",
    ]
}

@available(iOS 27.0, *)
@AppEnum(schema: .audio.queueInsertionLocation)
enum SchemaQueueLocation: String {
    case next
    case tail

    static let caseDisplayRepresentations: [SchemaQueueLocation: DisplayRepresentation] = [
        .next: "Play Next",
        .tail: "Play Last",
    ]
}

@available(iOS 27.0, *)
@AppEnum(schema: .audio.affinityState)
enum SchemaAffinity: String {
    case like
    case dislike
    case unset

    static let caseDisplayRepresentations: [SchemaAffinity: DisplayRepresentation] = [
        .like: "Like",
        .dislike: "Dislike",
        .unset: "Clear",
    ]
}

// MARK: - Intents

enum SchemaIntentError: Error, CustomLocalizedStringResourceConvertible {
    case nothingFound
    case songsOnly

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .nothingFound: "Koda couldn't find that on YouTube Music."
        case .songsOnly: "That works with songs only."
        }
    }
}

@available(iOS 27.0, *)
@AppIntent(schema: .audio.playAudio)
struct SchemaPlayAudioIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play"
    static let description = IntentDescription("Plays a song, album, artist or playlist from YouTube Music.", categoryName: "Playback")

    var audioEntity: SchemaAudioItem
    @Parameter(default: [])
    var playbackAttributes: Set<SchemaPlaybackAttributes>
    var queueLocation: SchemaQueueLocation?
    var warmupAudioQueueResult: SchemaWarmupResult?

    @Dependency private var app: AppModel

    @MainActor
    func perform() async throws -> some IntentResult {
        let songs = try await Self.songs(for: audioEntity, app: app)
        guard !songs.isEmpty else { throw AppIntentError(wrapping: SchemaIntentError.nothingFound) }
        let player = app.player
        switch queueLocation {
        case .next: player.playNext(songs)
        case .tail: player.addToQueue(songs)
        case nil:
            let shuffled = playbackAttributes.contains(.shuffle)
            if case .song(let song) = audioEntity, !shuffled {
                player.startRadio(from: IntentSongs.known(app)[song.id] ?? song.song)
            } else {
                player.play(songs, startAt: shuffled ? Int.random(in: 0..<songs.count) : 0, shuffled: shuffled)
            }
            if playbackAttributes.contains(.repeat) { player.setRepeat(.all) }
        }
        return .result()
    }

    @MainActor
    static func songs(for item: SchemaAudioItem, app: AppModel) async throws -> [Song] {
        switch item {
        case .song(let song):
            return [IntentSongs.known(app)[song.id] ?? song.song]
        case .album(let album):
            return try await app.music.album(album.id).songs
        case .artist(let artist):
            return try await app.music.artist(artist.id).topSongs
        case .playlist(let playlist):
            if let uuid = UUID(uuidString: playlist.id), let mine = app.library.userPlaylist(uuid) { return mine.songs }
            return try await app.music.playlist(playlist.id).songs
        }
    }
}

/// What Siri heard, searched on YouTube Music: "play some Daft Punk", "play Discovery".
@available(iOS 27.0, *)
extension SchemaAudioItem {
    struct SearchQuery: IntentValueQuery {
        @Dependency private var app: AppModel

        @MainActor
        func values(for input: AudioSearch) async throws -> [SchemaAudioItem] {
            switch input.criteria {
            case .searchQuery(let text):
                let found = try await app.music.search(text)
                IntentSongs.remember(found.songs + found.topSongs)
                var items: [SchemaAudioItem] = []
                switch found.top {
                case .song(let song): items.append(.song(SchemaSongEntity(song)))
                case .album(let album): items.append(.album(SchemaAlbumEntity(album)))
                case .artist(let artist): items.append(.artist(SchemaArtistEntity(id: artist.id, name: artist.name)))
                case .playlist(let playlist): items.append(.playlist(SchemaPlaylistEntity(playlist)))
                case nil: break
                }
                items += found.songs.prefix(5).map { .song(SchemaSongEntity($0)) }
                items += found.albums.prefix(3).map { .album(SchemaAlbumEntity($0)) }
                items += found.artists.prefix(2).map { .artist(SchemaArtistEntity(id: $0.id, name: $0.name)) }
                items += found.playlists.prefix(2).map { .playlist(SchemaPlaylistEntity($0)) }
                return items
            case .unspecified:
                // "Play some music": the listener's own liked songs.
                return app.library.liked.prefix(50).map { .song(SchemaSongEntity($0)) }
            default:
                return []
            }
        }
    }
}

@available(iOS 27.0, *)
@AppIntent(schema: .audio.updateAudioAffinity)
struct SchemaUpdateAffinityIntent {
    var affinityState: SchemaAffinity
    var target: SchemaAudioItem

    @Dependency private var app: AppModel

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard case .song(let entity) = target else { throw AppIntentError(wrapping: SchemaIntentError.songsOnly) }
        let song = IntentSongs.known(app)[entity.id] ?? entity.song
        let liked = app.library.isLiked(song)
        switch affinityState {
        case .like:
            if !liked { app.library.toggleLike(song) }
            return .result(dialog: "Liked \(song.title).")
        case .dislike, .unset:
            // Koda has likes only; a dislike takes the like away.
            if liked { app.library.toggleLike(song) }
            return .result(dialog: "Removed \(song.title) from your liked songs.")
        }
    }
}

@available(iOS 27.0, *)
@AppIntent(schema: .audio.addToPlaylist)
struct SchemaAddToPlaylistIntent {
    static let title: LocalizedStringResource = "Add to Playlist"

    var audioEntity: SchemaAudioItem
    var playlist: SchemaPlaylistEntity

    @Dependency private var app: AppModel

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let uuid = UUID(uuidString: playlist.id), let target = app.library.userPlaylist(uuid) else {
            throw AppIntentError(wrapping: SchemaIntentError.nothingFound)
        }
        let songs = try await SchemaPlayAudioIntent.songs(for: audioEntity, app: app)
        let added = app.library.add(songs, toPlaylist: target.id)
        guard added > 0 else { return .result(dialog: "That's already in \(target.name).") }
        return .result(dialog: "Added to \(target.name).")
    }
}

// MARK: - Spotlight

@available(iOS 27.0, *)
@MainActor
enum SchemaIndex {
    /// The library in Spotlight's semantic index, where the new Siri looks for it.
    static func update(_ app: AppModel) {
        let songs = app.library.liked.prefix(500).map(SchemaSongEntity.init)
        let albums = app.library.albums.map(SchemaAlbumEntity.init)
        let playlists = app.library.userPlaylists.map(SchemaPlaylistEntity.init) + app.library.playlists.map(SchemaPlaylistEntity.init)
        Task.detached(priority: .utility) {
            let index = CSSearchableIndex.default()
            try? await index.indexAppEntities(Array(songs))
            try? await index.indexAppEntities(albums)
            try? await index.indexAppEntities(playlists)
        }
    }
}
#endif
