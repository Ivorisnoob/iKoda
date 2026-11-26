import Foundation
import Testing
@testable import KodaCore

/// Against real Apple Music answers (November 2026): a catalogue search for "BTS", which
/// finds two artists of that name, and both read with their songs, albums and newest release.
@Suite struct AppleArtistTests {
    private let youTubeBTS = ["Dynamite", "Butter", "Spring Day", "BE", "MAP OF THE SOUL : 7"]

    @Test func findsTheCandidatesNamedLikeTheArtist() throws {
        let ids = MotionArtworkCatalog.artistCandidates(in: try fixture("apple-artist-search-bts"), name: "BTS")
        #expect(ids.prefix(2) == ["883131348", "1109312329"])
        #expect(MotionArtworkCatalog.artistCandidates(in: try fixture("apple-artist-search-bts"), name: "").isEmpty)
    }

    @Test func picksTheArtistWhoseSongsAreTheYouTubeArtists() throws {
        let json = try fixture("apple-artists-bts")
        let artist = try #require(MotionArtworkCatalog.artist(in: json, candidates: ["1109312329", "883131348"], titles: youTubeBTS))
        #expect(artist.id == "883131348")
        #expect(artist.isGroup)
        #expect(artist.origin == "Seoul, South Korea")
        #expect(artist.bornOrFormed == "June 13, 2013")
        #expect(artist.genre == "K-Pop")
        #expect(artist.background == "2b2b2b")
        #expect(artist.textColors.first == "f5f5f5")
        #expect(artist.latest?.title == "NORMAL")
        #expect(artist.latest?.isSingle == false)
        let motion = try #require(artist.motion)
        #expect(motion.albumID == "artist883131348")
        #expect(motion.masters[.square] != nil)
        #expect(motion.masters[.wide] != nil)
        let preview = try #require(motion.preview(.wide, pixels: 1280))
        #expect(preview.lastPathComponent == "1280x720bb.jpg")
    }

    @Test func aNameAloneIsNeverEnough() throws {
        let json = try fixture("apple-artists-bts")
        // The other BTS's songs, and titles nobody has.
        #expect(MotionArtworkCatalog.artist(in: json, candidates: ["883131348", "1109312329"], titles: ["Iron", "Low Run"])?.id == "1109312329")
        #expect(MotionArtworkCatalog.artist(in: json, candidates: ["883131348", "1109312329"], titles: ["Nothing Like It", "Elsewhere"]) == nil)
        #expect(MotionArtworkCatalog.artist(in: json, candidates: ["883131348"], titles: ["Dynamite"])?.id == "883131348")
        #expect(MotionArtworkCatalog.artist(in: json, candidates: ["883131348"], titles: []) == nil)
    }

    @Test func turnsTheBiographyIntoMarkdown() throws {
        let bio = try #require(MotionArtworkCatalog.markdown(fromHTML: "You cannot <i>tell</i> anyone<br />Next &amp; <b>last</b> <a href=\"x\">line</a>"))
        #expect(bio == "You cannot *tell* anyone\nNext & **last** line")
        let artist = try #require(MotionArtworkCatalog.artist(in: try fixture("apple-artists-bts"), candidates: ["883131348"], titles: youTubeBTS))
        let text = try #require(artist.bio)
        #expect(!text.contains("<"))
        #expect(text.count > 500)
    }

    @Test func releaseDatesAreCalendarDays() throws {
        let date = try #require(MotionArtworkCatalog.releaseDate("2026-07-17"))
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        #expect(parts.year == 2026 && parts.month == 7 && parts.day == 17)
        #expect(MotionArtworkCatalog.releaseDate("July 2026") == nil)
    }

    @Test func survivesARoundTripAndOlderFiles() throws {
        let artist = try #require(MotionArtworkCatalog.artist(in: try fixture("apple-artists-bts"), candidates: ["883131348"], titles: youTubeBTS))
        let data = try JSONEncoder().encode(artist)
        #expect(try JSONDecoder().decode(AppleArtist.self, from: data) == artist)
        let older = try JSONDecoder().decode(AppleArtist.self, from: Data(#"{"id":"1","name":"A"}"#.utf8))
        #expect(older.textColors.isEmpty && older.motion == nil && !older.isGroup)
    }
}
