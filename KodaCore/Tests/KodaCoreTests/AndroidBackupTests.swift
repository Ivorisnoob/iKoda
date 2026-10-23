import Foundation
import Testing
@testable import KodaCore

@MainActor
struct AndroidBackupTests {
    func fixture() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "android-backup", withExtension: "zip", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    @Test func readsWhatKodaHasFromTheActiveProfile() throws {
        let backup = try AndroidBackup.read(fixture())
        #expect(backup.liked.map(\.id) == ["dQw4w9WgXcQ", "J7p4bzqLvCw"], "the phone's own file is left out")
        #expect(backup.liked[0].album == AlbumRef(id: "MPREb_abc", title: "Album"))
        #expect(backup.liked[0].duration == 200)
        #expect(backup.liked[0].year == 1987)
        #expect(backup.plays.count == 3, "a local play is left out")
        #expect(backup.plays.first?.song.id == "J7p4bzqLvCw", "oldest first")
        #expect(backup.searches == ["daft punk", "the weeknd"], "the active profile's, not another's")
        #expect(backup.playlists.map(\.name) == ["Gym"])
        #expect(backup.playlists.first?.songs.count == 1)
        #expect(backup.albums.map(\.id) == ["MPREb_album1"])
        #expect(backup.savedPlaylists.map(\.id) == ["PL1234"])
    }

    @Test func refusesOtherFiles() {
        #expect(throws: AndroidBackup.ReadError.notABackup) { try AndroidBackup.read(Data("{}".utf8)) }
    }

    @Test func importMergesAndNeverCountsAPlayTwice() throws {
        let backup = try AndroidBackup.read(fixture())
        let library = Library(directory: nil)
        let summary = library.importAndroid(backup)
        #expect(summary == AndroidImportSummary(likedSongs: 2, plays: 3, playlists: 1, saved: 2, searches: 2))
        #expect(library.plays(of: backup.liked[1]) == 2)
        #expect(library.recent.first?.id == "J7p4bzqLvCw", "the newest play leads")
        #expect(library.userPlaylists.first?.name == "Gym")

        let again = library.importAndroid(backup)
        #expect(again.isEmpty)
        #expect(library.plays(of: backup.liked[1]) == 2)
    }
}
