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

        var artistScores: [String: Double] = [:]
        for entry in scored {
            artistScores[Self.leadArtist(entry.stats.song), default: 0] += entry.score
        }
        let ranked = artistScores.sorted { a, b in a.value != b.value ? a.value > b.value : a.key < b.key }
        let artists = ranked.map(\.key).filter { !$0.isEmpty }

        var seeds: [Song] = []
        for artist in artists where seeds.count < maxSeeds {
            if let best = scored.first(where: { Self.leadArtist($0.stats.song) == artist }) { seeds.append(best.stats.song) }
        }
        self.artists = artists
        self.seeds = seeds
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
