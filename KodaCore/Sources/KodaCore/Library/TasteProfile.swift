import Foundation

/// What the listener has *said* they like, beside what their plays show: the artists, genres and
/// songs picked in taste setup. It is what a new profile's Home is built from before there is any
/// history, and stays as the explicit signal afterwards. Kept per profile in the library, so it
/// moves with backups. Koda for Android's TasteProfileStore, without following artists (saving
/// an artist to the library is that here, and it reaches a signed-in account; a taste pick doesn't).
public struct TasteProfile: Codable, Hashable, Sendable {
    public var artists: [ArtistSummary] = []
    /// Genre names from `TasteProfile.genres`.
    public var genres: [String] = []
    /// Songs kept from the taste deck, newest first: seeds, not library entries.
    public var songs: [Song] = []

    public init() {}

    public var isEmpty: Bool { artists.isEmpty && genres.isEmpty && songs.isEmpty }

    static let maxArtists = 50
    static let maxSongs = 60

    /// Genres, and only genres: no languages, countries, moods or decades. YouTube Music's own
    /// grid is built per country and is mostly languages and regions, which isn't what the word
    /// means to the person asked [Android, October 2026]. The names are also what a genre's songs
    /// are searched for by, so they stay in English.
    public static let genres = [
        "Pop", "Hip-hop", "Rock", "R&B", "Electronic", "Indie", "Alternative", "Metal",
        "Jazz", "Classical", "Country", "Folk", "Soul", "Funk", "Blues", "Punk",
        "House", "Techno", "Drum and bass", "Lo-fi", "Ambient", "Reggae", "K-Pop",
        "Afrobeats", "Reggaeton", "Soundtracks",
    ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        artists = try c.decodeIfPresent([ArtistSummary].self, forKey: .artists) ?? []
        genres = try c.decodeIfPresent([String].self, forKey: .genres) ?? []
        songs = try c.decodeIfPresent([Song].self, forKey: .songs) ?? []
    }
}
