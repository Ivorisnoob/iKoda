import Foundation

/// What the listener plays most lately, from the library's counts: the seeds for Your Mix.
///
/// Each song scores its plays and listening time, weighed by how recently it was
/// last played: a song last played two weeks ago counts half as much as one from
/// today. Liked songs get a bonus. Artists score the sum of their songs.
public struct Taste: Sendable, Equatable {
    /// Lead artists, strongest first.
    public var artists: [String]
    /// One favourite song per top artist, strongest first, to start radios from.
    public var seeds: [Song]

    public var isEmpty: Bool { seeds.isEmpty }

    static let halfLife: TimeInterval = 14 * 86_400

    public init(artists: [String], seeds: [Song]) {
        self.artists = artists
        self.seeds = seeds
    }

    @MainActor
    public init(library: Library, now: Date = Date(), maxSeeds: Int = 4) {
        let liked = Set(library.liked.map(\.id))
        var scored: [(stats: SongStats, score: Double)] = []
        // What the listener asked not to be offered doesn't seed their mix either.
        for stats in library.songStats.values where !library.isHidden(stats.song) {
            let age = max(0, now.timeIntervalSince(stats.lastPlayed))
            let decay: Double = pow(0.5, age / Self.halfLife)
            let bonus: Double = liked.contains(stats.song.id) ? 2 : 0
            let listening = Double(stats.plays) + stats.seconds / 180 + bonus
            let score = listening * decay
            if score > 0 { scored.append((stats, score)) }
        }
        scored.sort { a, b in a.score != b.score ? a.score > b.score : a.stats.song.id < b.stats.song.id }
        guard !scored.isEmpty else {
            // Nothing played yet: what the listener liked, then what they kept in taste setup.
            var seen = Set<String>()
            let said = (library.liked + library.taste.songs).filter { !library.isHidden($0) && seen.insert($0.id).inserted }
            (artists, seeds) = Self.fromLiked(said, maxSeeds: maxSeeds)
            return
        }

        var artistScores: [String: Double] = [:]
        for entry in scored {
            artistScores[Self.leadArtist(entry.stats.song), default: 0] += entry.score
        }
        let ranked = artistScores.sorted { a, b in a.value != b.value ? a.value > b.value : a.key < b.key }

        var artists = ranked.map(\.key).filter { !$0.isEmpty }
        var seeds: [Song] = []
        for artist in artists where seeds.count < maxSeeds {
            if let best = scored.first(where: { Self.leadArtist($0.stats.song) == artist }) { seeds.append(best.stats.song) }
        }
        if seeds.count < maxSeeds {
            // Only a few artists played here yet, as just after signing in: the account's liked
            // songs fill the rest, so the mix isn't one or two artists' radios alone.
            let played = Set(artists)
            let said = library.liked.filter { !library.isHidden($0) && !played.contains(Self.leadArtist($0)) }
            let more = Self.fromLiked(said, maxSeeds: maxSeeds - seeds.count)
            artists += more.artists.prefix(more.seeds.count)
            seeds += more.seeds
        }
        self.artists = artists
        self.seeds = seeds
    }

    /// Taste from liked songs alone, for a profile with nothing played on this device yet, such
    /// as one just signed in to an account: artists rank by how many of their songs are liked,
    /// and each seeds from its most recently liked. `liked` is newest first, as the library keeps it.
    static func fromLiked(_ liked: [Song], maxSeeds: Int) -> (artists: [String], seeds: [Song]) {
        var counts: [String: Int] = [:]
        var order: [String] = []
        var newest: [String: Song] = [:]
        for song in liked {
            let artist = Self.leadArtist(song)
            guard !artist.isEmpty else { continue }
            if counts[artist] == nil {
                order.append(artist)
                newest[artist] = song
            }
            counts[artist, default: 0] += 1
        }
        // Stable for ties: the artist liked more recently comes first.
        let artists = order.enumerated().sorted { a, b in
            let ca = counts[a.element]!, cb = counts[b.element]!
            return ca != cb ? ca > cb : a.offset < b.offset
        }.map(\.element)
        return (artists, artists.prefix(maxSeeds).compactMap { newest[$0] })
    }

    public static func leadArtist(_ song: Song) -> String {
        song.artists.first?.name ?? song.artistLine
    }

    /// Radios woven together a song at a time, so no one artist's radio takes over;
    /// songs heard in more than one radio, and the seeds themselves, appear once.
    public static func weave(_ radios: [[Song]], excluding: Set<String> = [], limit: Int = 50) -> [Song] {
        var seen = excluding
        var out: [Song] = []
        let longest = radios.map(\.count).max() ?? 0
        for index in 0..<longest {
            for radio in radios where index < radio.count {
                let song = radio[index]
                if seen.insert(song.id).inserted { out.append(song) }
                if out.count == limit { return out }
            }
        }
        return out
    }
}
