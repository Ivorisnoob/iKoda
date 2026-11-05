import Foundation
import Testing
@testable import KodaCore

@Suite struct HomePicksTests {
    private let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 6))!

    private func release(_ id: String, _ year: Int?) -> AlbumSummary {
        AlbumSummary(id: id, title: id, artistLine: "A", year: year)
    }

    private func page(_ name: String, singles: [AlbumSummary] = [], albums: [AlbumSummary] = [], similar: [ArtistSummary] = []) -> ArtistPage {
        ArtistPage(artist: ArtistSummary(id: "UC\(name)", name: name), description: nil, banner: nil, topSongs: [],
                   allSongsPlaylistId: nil, albums: albums, singles: singles, featuredOn: [], similar: similar)
    }

    @Test func latestReleasesTakeTurnsAndLeadWithThisYear() {
        let top = page("Top", singles: [release("t1", 2026), release("t2", 2026), release("t3", 2025), release("old", 2019)],
                       albums: [release("tAlbum", 2025)])
        let second = page("Second", singles: [release("s1", 2025)], albums: [release("s2", nil)])
        let releases = HomePicks.latestReleases([top, second], now: now)
        // Older than last year, or with no year, are left out; turns are taken, then this year leads.
        #expect(releases.map(\.id) == ["t1", "t2", "s1", "t3", "tAlbum"])
    }

    @Test func latestReleasesStopAtTheLimitAndNeverRepeat() {
        let one = page("One", singles: (0..<10).map { release("x\($0)", 2026) })
        let two = page("Two", singles: [release("x0", 2026)] + (0..<10).map { release("y\($0)", 2026) })
        let releases = HomePicks.latestReleases([one, two], now: now, limit: 6)
        #expect(releases.count == 6)
        #expect(Set(releases.map(\.id)).count == 6)
    }

    private func stats(_ id: String, plays: Int, daysAgo: Double) -> SongStats {
        var stats = SongStats(song: Song(id: id, title: id, artistLine: "A"), firstPlayed: now - 400 * 86400)
        stats.plays = plays
        stats.lastPlayed = now - daysAgo * 86400
        return stats
    }

    @Test func forgottenFavouritesArePlayedOftenButNotLately() {
        var hidden = NotInterested()
        hidden.songs = [Song(id: "hidden", title: "h", artistLine: "A")]
        let all = [
            stats("often", plays: 20, daysAgo: 90),
            stats("recent", plays: 50, daysAgo: 2),
            stats("rare", plays: 1, daysAgo: 200),
            stats("some", plays: 5, daysAgo: 45),
            stats("hidden", plays: 30, daysAgo: 60),
        ]
        #expect(HomePicks.forgottenFavourites(all, hidden: hidden, now: now).map(\.id) == ["often", "some"])
    }

    @Test func similarArtistsLeaveOutTheOnesAlreadyPlayed() {
        let similar = [ArtistSummary(id: "UC1", name: "Known"), ArtistSummary(id: "UC2", name: "New"), ArtistSummary(id: "UC3", name: "Hidden")]
        var hidden = NotInterested()
        hidden.artists = [ArtistRef(id: "UC3", name: "Hidden")]
        let found = HomePicks.similar(to: page("Top", similar: similar), excluding: ["UC1"], hidden: hidden)
        #expect(found.map(\.name) == ["New"])
    }
}
