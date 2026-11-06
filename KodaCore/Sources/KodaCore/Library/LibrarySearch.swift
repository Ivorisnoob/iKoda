import Foundation

/// What a search of the listener's own library found, best matches first in each kind.
public struct LibraryMatches: Sendable {
    public var songs: [Song] = []
    public var userPlaylists: [UserPlaylist] = []
    public var albums: [AlbumSummary] = []
    public var playlists: [PlaylistSummary] = []
    public var artists: [ArtistSummary] = []

    public var isEmpty: Bool {
        songs.isEmpty && userPlaylists.isEmpty && albums.isEmpty && playlists.isEmpty && artists.isEmpty
    }
}

/// Matching as Music's library search does: every word typed must appear somewhere in the
/// item (title, artist or album), ignoring case, accents and width; titles that start with
/// what was typed come first, then titles with a word starting with it, then the rest.
nonisolated public enum LibrarySearch {
    /// The query's words, folded. Empty when there is nothing to search for.
    static func words(_ text: String) -> [String] {
        fold(text).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Nil when `title` and `others` together don't hold every word; else a rank, lower first.
    static func rank(title: String, others: [String], words: [String]) -> Int? {
        let folded = fold(title)
        let haystack = ([folded] + others.map(fold)).joined(separator: "\n")
        guard words.allSatisfy(haystack.contains) else { return nil }
        let phrase = words.joined(separator: " ")
        if folded.hasPrefix(phrase) { return 0 }
        let titleWords = folded.split { !$0.isLetter && !$0.isNumber }
        if let first = words.first, titleWords.contains(where: { $0.hasPrefix(first) }) { return 1 }
        return 2
    }

    /// The matches among `items`, by rank, keeping their order within a rank.
    static func filter<Item>(_ items: [Item], words: [String], fields: (Item) -> (String, [String])) -> [Item] {
        items.enumerated()
            .compactMap { offset, item -> (Int, Int, Item)? in
                let (title, others) = fields(item)
                return rank(title: title, others: others, words: words).map { ($0, offset, item) }
            }
            .sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
            .map(\.2)
    }

    /// Songs in a list the listener is looking through (Liked Songs, a playlist) that match.
    public static func songs(_ songs: [Song], matching text: String) -> [Song] {
        let words = words(text)
        guard !words.isEmpty else { return songs }
        return filter(songs, words: words) { ($0.title, [$0.artistLine, $0.album?.title ?? ""]) }
    }
}

extension Library {
    /// Everything of the listener's that matches `text`. Songs come from Liked Songs, their
    /// playlists, `extra` (downloads, kept songs) and everything they have played, each once,
    /// in that order of preference within a rank.
    public func search(_ text: String, extra: [Song] = []) -> LibraryMatches {
        let words = LibrarySearch.words(text)
        guard !words.isEmpty else { return LibraryMatches() }
        var seen = Set<String>()
        var pool: [Song] = []
        let played = songStats.values.sorted { $0.lastPlayed > $1.lastPlayed }.map(\.song)
        for song in liked + userPlaylists.flatMap(\.songs) + extra + recent + played where seen.insert(song.id).inserted {
            pool.append(song)
        }
        var matches = LibraryMatches()
        matches.songs = LibrarySearch.filter(pool, words: words) { ($0.title, [$0.artistLine, $0.album?.title ?? ""]) }
        matches.userPlaylists = LibrarySearch.filter(userPlaylists, words: words) { ($0.name, []) }
        matches.albums = LibrarySearch.filter(albums, words: words) { ($0.title, [$0.artistLine]) }
        matches.playlists = LibrarySearch.filter(playlists, words: words) { ($0.title, [$0.subtitle ?? ""]) }
        matches.artists = LibrarySearch.filter(artists, words: words) { ($0.name, []) }
        return matches
    }
}
