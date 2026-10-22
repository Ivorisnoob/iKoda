import Foundation
import Testing
@testable import KodaCore

@MainActor
@Suite struct TasteProfileTests {
    private func song(_ id: String, _ artist: String) -> Song {
        Song(id: id, title: id, artistLine: artist, artists: [ArtistRef(id: "UC\(artist)", name: artist)])
    }

    @Test func survivesARelaunchAndKeepsOnlyRealGenres() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "koda-taste-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let library = Library(directory: dir)
        library.setTasteArtists([ArtistSummary(id: "UC1", name: "One"), ArtistSummary(id: "UC1", name: "One"), ArtistSummary(id: "UC2", name: "Two")])
        library.setTasteGenres(["Jazz", "Bhojpuri", "Rock"])
        library.keepTasteSong(song("a", "A"))
        library.keepTasteSong(song("b", "B"))
        library.keepTasteSong(song("a", "A"))
        library.flush()
        let reopened = Library(directory: dir)
        #expect(reopened.taste.artists.map(\.id) == ["UC1", "UC2"])
        #expect(reopened.taste.genres == ["Jazz", "Rock"])
        #expect(reopened.taste.songs.map(\.id) == ["a", "b"])
    }

    @Test func keptSongsSeedTheMixBeforeAnythingIsPlayed() {
        let library = Library(directory: nil)
        library.keepTasteSong(song("k1", "Kept"))
        #expect(Taste(library: library).seeds.map(\.id) == ["k1"])
        library.recordPlay(song("p1", "Played"))
        #expect(Taste(library: library).artists == ["Played"])
    }

    @Test func aBackupCarriesTheTaste() throws {
        let library = Library(directory: nil)
        library.setTasteGenres(["Soul"])
        let data = try #require(library.backupData())
        let other = Library(directory: nil)
        try other.restore(from: data)
        #expect(other.taste.genres == ["Soul"])
    }
}
