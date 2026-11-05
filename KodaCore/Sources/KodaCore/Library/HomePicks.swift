import Foundation

/// Home's rows that are made from the listener's own artists and plays, worked out from
/// pages Home already has (the top artists' pages, the play counts), with no requests of
/// their own.
public enum HomePicks {
    /// Albums, EPs and singles from this year and last by the listener's artists, the top
    /// artist's newest first, then taking turns so one prolific artist doesn't fill the row;
    /// this year's ahead of last year's. Release years are all YouTube Music gives.
    public static func latestReleases(_ pages: [ArtistPage], now: Date = .now, limit: Int = 16) -> [AlbumSummary] {
        let year = Calendar.current.component(.year, from: now)
        var seen = Set<String>()
        let perArtist = pages.map { page in
            newestFirst((page.singles + page.albums).filter { ($0.year ?? 0) >= year - 1 })
        }
        var taken: [AlbumSummary] = []
        var round = 0
        while taken.count < limit, perArtist.contains(where: { round < $0.count }) {
            for releases in perArtist where round < releases.count && taken.count < limit {
                if seen.insert(releases[round].id).inserted { taken.append(releases[round]) }
            }
            round += 1
        }
        return newestFirst(taken)
    }

    /// By year, newest first; within a year, the order given (a page's own is newest first).
    private static func newestFirst(_ releases: [AlbumSummary]) -> [AlbumSummary] {
        let indexed = Array(releases.enumerated())
        let sorted = indexed.sorted { a, b in
            let ya = a.element.year ?? 0, yb = b.element.year ?? 0
            return ya != yb ? ya > yb : a.offset < b.offset
        }
        return sorted.map(\.element)
    }

    /// Songs played often that haven't been played for a while, most played first, as Music's
    /// "Forgotten favourites".
    public static func forgottenFavourites(_ stats: some Collection<SongStats>, hidden: NotInterested, now: Date = .now,
                                           minimumPlays: Int = 3, idle: TimeInterval = 30 * 86400, limit: Int = 20) -> [Song] {
        let cutoff = now - idle
        let candidates = stats.filter { $0.plays >= minimumPlays && $0.lastPlayed < cutoff && !hidden.hides($0.song) }
        let ranked = candidates.sorted { a, b in a.plays != b.plays ? a.plays > b.plays : a.lastPlayed > b.lastPlayed }
        return ranked.prefix(limit).map(\.song)
    }

    /// Artists fans of `page`'s artist also like, leaving out those the listener already plays
    /// or asked not to be offered.
    public static func similar(to page: ArtistPage, excluding known: Set<String>, hidden: NotInterested) -> [ArtistSummary] {
        page.similar.filter { !known.contains($0.id) && !hidden.hides(ArtistRef(id: $0.id, name: $0.name)) }
    }
}
