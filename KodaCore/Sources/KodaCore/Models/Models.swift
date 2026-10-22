import Foundation

/// An image as InnerTube serves it, with the size it was served at.
public struct Artwork: Hashable, Codable, Sendable {
    public var url: URL
    public var width: Int
    public var height: Int

    public init(url: URL, width: Int = 0, height: Int = 0) {
        self.url = url
        self.width = width
        self.height = height
    }

    /// A video frame (16:9) rather than square cover art; drawn cropped to a square.
    public var isLandscape: Bool { width > 0 && height > 0 && Double(width) / Double(height) > 1.2 }

    /// The same image asked for at `pixels` on its longest side.
    ///
    /// Only Google's image hosts take a size, and the size directive lives
    /// after the last `=`: the opaque token before it can itself contain
    /// `s<digits>`, so rewriting the whole URL corrupts it into a 404.
    public func url(pixels: Int) -> URL {
        let string = url.absoluteString
        guard string.contains("googleusercontent.com") || string.contains("ggpht.com"),
              let separator = string.lastIndex(of: "=") else { return url }
        let head = string[..<separator]
        var directives = String(string[separator...])
        directives = directives.replacingOccurrences(of: #"w\d+-h\d+"#, with: "w\(pixels)-h\(pixels)", options: .regularExpression)
        directives = directives.replacingOccurrences(of: #"(?<![a-z])s\d+"#, with: "s\(pixels)", options: .regularExpression)
        return URL(string: head + directives) ?? url
    }
}

public struct ArtistRef: Hashable, Codable, Sendable {
    /// A `UC…` channel id; nil when the response named the artist without a link.
    public var id: String?
    public var name: String

    public init(id: String?, name: String) {
        self.id = id
        self.name = name
    }
}

public struct AlbumRef: Hashable, Codable, Sendable {
    /// An `MPRE…` browse id.
    public var id: String
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public struct Song: Identifiable, Hashable, Codable, Sendable {
    /// The YouTube video id.
    public var id: String
    public var title: String
    /// The byline as YouTube wrote it ("A, B & C"), including artists it did not link.
    public var artistLine: String
    /// The artists YouTube linked, for navigation.
    public var artists: [ArtistRef]
    public var album: AlbumRef?
    public var duration: TimeInterval?
    public var artwork: Artwork?
    /// A music video or upload rather than the audio track itself.
    public var isVideo: Bool
    public var year: Int?

    public init(
        id: String, title: String, artistLine: String, artists: [ArtistRef] = [], album: AlbumRef? = nil,
        duration: TimeInterval? = nil, artwork: Artwork? = nil, isVideo: Bool = false, year: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.artistLine = artistLine
        self.artists = artists
        self.album = album
        self.duration = duration
        self.artwork = artwork
        self.isVideo = isVideo
        self.year = year
    }
}

public enum ReleaseKind: String, Codable, Sendable, CaseIterable {
    case album = "Album", ep = "EP", single = "Single"
}

public struct AlbumSummary: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var title: String
    public var artistLine: String
    public var artists: [ArtistRef]
    public var year: Int?
    public var kind: ReleaseKind?
    public var artwork: Artwork?

    public init(id: String, title: String, artistLine: String, artists: [ArtistRef] = [], year: Int? = nil, kind: ReleaseKind? = nil, artwork: Artwork? = nil) {
        self.id = id
        self.title = title
        self.artistLine = artistLine
        self.artists = artists
        self.year = year
        self.kind = kind
        self.artwork = artwork
    }
}

public struct ArtistSummary: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    /// "238M monthly audience", "2.29M subscribers".
    public var subtitle: String?
    public var artwork: Artwork?

    public init(id: String, name: String, subtitle: String? = nil, artwork: Artwork? = nil) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.artwork = artwork
    }
}

public struct PlaylistSummary: Identifiable, Hashable, Codable, Sendable {
    /// The playlist id without the `VL` browse prefix.
    public var id: String
    public var title: String
    public var subtitle: String?
    public var artwork: Artwork?

    public init(id: String, title: String, subtitle: String? = nil, artwork: Artwork? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.artwork = artwork
    }
}

public enum MusicItem: Identifiable, Hashable, Codable, Sendable {
    case song(Song)
    case album(AlbumSummary)
    case artist(ArtistSummary)
    case playlist(PlaylistSummary)

    public var id: String {
        switch self {
        case .song(let s): "s:" + s.id
        case .album(let a): "a:" + a.id
        case .artist(let a): "r:" + a.id
        case .playlist(let p): "p:" + p.id
        }
    }

    public var title: String {
        switch self {
        case .song(let s): s.title
        case .album(let a): a.title
        case .artist(let a): a.name
        case .playlist(let p): p.title
        }
    }

    public var artwork: Artwork? {
        switch self {
        case .song(let s): s.artwork
        case .album(let a): a.artwork
        case .artist(let a): a.artwork
        case .playlist(let p): p.artwork
        }
    }
}

public struct Shelf: Identifiable, Hashable, Codable, Sendable {
    public var id: String { title + ":" + (items.first?.id ?? "") }
    public var title: String
    /// The small line YouTube puts above some titles ("FOR FEELING GOOD").
    public var strapline: String?
    public var items: [MusicItem]

    public init(title: String, strapline: String? = nil, items: [MusicItem]) {
        self.title = title
        self.strapline = strapline
        self.items = items
    }
}

/// A mood or genre chip; browsing it opens a page of shelves.
public struct Mood: Identifiable, Hashable, Codable, Sendable {
    public var id: String { browseId + (params ?? "") }
    public var title: String
    public var browseId: String
    public var params: String?

    public init(title: String, browseId: String, params: String?) {
        self.title = title
        self.browseId = browseId
        self.params = params
    }
}

public struct ShelfPage: Sendable {
    public var shelves: [Shelf]
    public var moods: [Mood]

    public init(shelves: [Shelf], moods: [Mood]) {
        self.shelves = shelves
        self.moods = moods
    }

    /// Every artist on the page, in shelf order, each once: a chart's "Top artists".
    public var artists: [ArtistSummary] {
        var seen = Set<String>()
        return shelves.flatMap(\.items).compactMap { item in
            guard case .artist(let artist) = item, seen.insert(artist.id).inserted else { return nil }
            return artist
        }
    }

    /// Every song on the page, in shelf order, each once: signed in, YouTube Music's Home leads
    /// with the account's Quick picks, which is what Koda for Android takes for its own.
    public var songs: [Song] {
        var seen = Set<String>()
        return shelves.flatMap(\.items).compactMap { item in
            guard case .song(let song) = item, !song.title.trimmingCharacters(in: .whitespaces).isEmpty,
                  seen.insert(song.id).inserted else { return nil }
            return song
        }
    }
}

public struct AlbumPage: Sendable {
    public var album: AlbumSummary
    public var description: String?
    /// "14 songs • 56 minutes".
    public var detailLine: String?
    public var songs: [Song]
    public var otherVersions: [AlbumSummary]
    /// The album's `OLAK5uy_…` audio playlist.
    public var audioPlaylistId: String?
}

public struct ArtistPage: Sendable {
    public var artist: ArtistSummary
    public var description: String?
    public var banner: Artwork?
    public var topSongs: [Song]
    /// The playlist behind the Top songs shelf's "See all".
    public var allSongsPlaylistId: String?
    public var albums: [AlbumSummary]
    public var singles: [AlbumSummary]
    public var featuredOn: [PlaylistSummary]
    public var similar: [ArtistSummary]
}

public struct PlaylistPage: Sendable {
    public var playlist: PlaylistSummary
    public var author: String?
    public var detailLine: String?
    public var description: String?
    public var songs: [Song]
    public var continuation: String?
}

public struct SearchResults: Sendable {
    /// The card YouTube puts first, usually an artist or album.
    public var top: MusicItem?
    /// Songs the top card offers alongside it.
    public var topSongs: [Song]
    public var songs: [Song]
    public var albums: [AlbumSummary]
    public var artists: [ArtistSummary]
    public var playlists: [PlaylistSummary]
    public var videos: [Song]

    public var isEmpty: Bool {
        top == nil && songs.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty && videos.isEmpty
    }

    public static let empty = SearchResults(top: nil, topSongs: [], songs: [], albums: [], artists: [], playlists: [], videos: [])
}

public enum SearchFilter: String, CaseIterable, Sendable, Identifiable {
    case all, songs, albums, artists, playlists

    public var id: String { rawValue }

    /// The `params` the YouTube Music search chips send. [verified October 2026]
    var params: String? {
        switch self {
        case .all: nil
        case .songs: "EgWKAQIIAWoSEAUQCRADEAoQBBAQEBUQDhAR"
        case .albums: "EgWKAQIYAWoSEAUQCRADEAoQBBAQEBUQDhAR"
        case .artists: "EgWKAQIgAWoSEAUQCRADEAoQBBAQEBUQDhAR"
        case .playlists: "EgeKAQQoADgBahIQBRAJEAMQChAEEBAQFRAOEBE%3D"
        }
    }
}
