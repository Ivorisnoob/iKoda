import Foundation
import Testing
@testable import KodaCore

@MainActor
@Suite struct LibraryTests {
    func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "koda-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func survivesARelaunch() throws {
        let dir = try tempDirectory()
        let library = Library(directory: dir)
        let song = Song(id: "a", title: "A", artistLine: "X")
        library.toggleLike(song)
        library.recordPlay(song)
        library.toggleSave(AlbumSummary(id: "MPRE1", title: "Album", artistLine: "X"))
        library.recordSearch("weeknd")
        // Writes happen in the background; the app flushes as it leaves the screen.
        library.flush()

        let reopened = Library(directory: dir)
        #expect(reopened.isLiked(song))
        #expect(reopened.recent.first?.id == "a")
        #expect(reopened.history.map(\.song.id) == ["a"])
        #expect(reopened.isSaved(album: "MPRE1"))
        #expect(reopened.searches == ["weeknd"])
    }

    @Test func backgroundSavesReachTheDisk() async throws {
        let dir = try tempDirectory()
        let library = Library(directory: dir)
        library.toggleLike(Song(id: "a", title: "A", artistLine: "X"))
        try await Task.sleep(for: .seconds(1.5))
        #expect(Library(directory: dir).liked.map(\.id) == ["a"])
    }

    @Test func eachProfileFolderKeepsItsOwnLibrary() throws {
        let first = try tempDirectory(), second = try tempDirectory()
        let library = Library(directory: first)
        let song = Song(id: "a", title: "A", artistLine: "X")
        library.toggleLike(song)
        library.recordPlay(song)
        library.open(directory: second)
        #expect(library.liked.isEmpty)
        #expect(library.history.isEmpty)
        library.recordSearch("other")
        library.open(directory: first)
        #expect(library.isLiked(song))
        #expect(library.history.count == 1)
        #expect(library.searches.isEmpty)
    }

    @Test func historyKeepsEveryPlayAndForgetsOne() {
        let library = Library(directory: nil)
        let a = Song(id: "a", title: "A", artistLine: ""), b = Song(id: "b", title: "B", artistLine: "")
        library.recordPlay(a)
        library.recordPlay(b)
        library.recordPlay(a)
        #expect(library.history.map(\.song.id) == ["a", "b", "a"])
        library.removeFromHistory(library.history[1].id)
        #expect(library.history.map(\.song.id) == ["a", "a"])
        // No play of b is left, so it leaves Recently Played too; a still has plays.
        #expect(library.recent.map(\.id) == ["a"])
        library.clearHistory()
        #expect(library.history.isEmpty && library.recent.isEmpty)
    }

    @Test func notInterestedHidesSongsAndArtistsFromWhatIsOffered() {
        let library = Library(directory: nil)
        let artist = ArtistRef(id: "UC1", name: "Band")
        let byBand = Song(id: "a", title: "A", artistLine: "Band & Friend", artists: [artist, ArtistRef(id: "UC2", name: "Friend")])
        let unlinked = Song(id: "b", title: "B", artistLine: "Band")
        let other = Song(id: "c", title: "C", artistLine: "Someone", artists: [ArtistRef(id: "UC3", name: "Someone")])
        library.hide(other)
        #expect(library.offerable([byBand, unlinked, other]).map(\.id) == ["a", "b"])
        library.hide(artist: artist)
        #expect(library.offerable([byBand, unlinked, other]).isEmpty)
        library.unhide(artist: ArtistRef(id: "UC1", name: "Renamed"))
        library.unhide(other)
        #expect(library.offerable([byBand, unlinked, other]).count == 3)
    }

    @Test func accountMergeAddsWithoutTellingAndDropsWhenMirrored() {
        let library = Library(directory: nil)
        var told: [String] = []
        library.onChange = { change in
            if case .liked(let song, _) = change { told.append(song.id) }
        }
        let mine = Song(id: "mine", title: "M", artistLine: ""), theirs = Song(id: "theirs", title: "T", artistLine: "")
        library.toggleLike(mine)
        library.mergeAccount(liked: [theirs], albums: [], playlists: [], artists: [])
        #expect(library.liked.map(\.id) == ["theirs", "mine"])
        #expect(told == ["mine"])
        library.dropMissing(liked: ["theirs"], albums: nil, playlists: nil, artists: nil)
        #expect(library.liked.map(\.id) == ["theirs"])
    }

    @Test func recentKeepsOneEntryPerSongNewestFirst() {
        let library = Library(directory: nil)
        let a = Song(id: "a", title: "A", artistLine: ""), b = Song(id: "b", title: "B", artistLine: "")
        library.recordPlay(a)
        library.recordPlay(b)
        library.recordPlay(a)
        #expect(library.recent.map(\.id) == ["a", "b"])
    }

    @Test func searchHistoryIgnoresCaseDuplicatesAndBlanks() {
        let library = Library(directory: nil)
        library.recordSearch("Weeknd")
        library.recordSearch("  ")
        library.recordSearch("weeknd")
        #expect(library.searches == ["weeknd"])
    }

    @Test func toggleSaveTwiceRemoves() {
        let library = Library(directory: nil)
        let p = PlaylistSummary(id: "PL1", title: "P")
        library.toggleSave(p)
        library.toggleSave(p)
        #expect(!library.isSaved(playlist: "PL1"))
    }
}

@MainActor
@Suite struct LibraryPlaylistAndStatsTests {
    @Test func playlistsKeepOneOfEachSongAndReorder() {
        let library = Library(directory: nil)
        let a = Song(id: "a", title: "A", artistLine: ""), b = Song(id: "b", title: "B", artistLine: ""), c = Song(id: "c", title: "C", artistLine: "")
        let playlist = library.createPlaylist(named: "  Road trip ", songs: [a, a])
        #expect(library.userPlaylist(playlist.id)?.name == "Road trip")
        #expect(library.add([a, b, c], toPlaylist: playlist.id) == 2)
        library.moveSongs(fromOffsets: [2], toOffset: 0, inPlaylist: playlist.id)
        #expect(library.userPlaylist(playlist.id)?.songs.map(\.id) == ["c", "a", "b"])
        library.removeSongs(atOffsets: [1], fromPlaylist: playlist.id)
        #expect(library.userPlaylist(playlist.id)?.songs.map(\.id) == ["c", "b"])
        library.renamePlaylist(playlist.id, to: "   ")
        #expect(library.userPlaylist(playlist.id)?.name == "Road trip")
        library.deletePlaylist(playlist.id)
        #expect(library.userPlaylists.isEmpty)
    }

    @Test func countsPlaysAndListeningAndStreaks() {
        let library = Library(directory: nil)
        // Listening is filed under the phone's own days, so the test reads them the same way.
        let calendar = Calendar.current
        let song = Song(id: "a", title: "A", artistLine: "")
        let today = Date(timeIntervalSince1970: 1_760_000_000)
        library.recordPlay(song, at: today)
        library.recordPlay(song, at: today)
        library.addListening(30, to: song, at: today)
        library.addListening(30, to: song, at: today.addingTimeInterval(-86_400))
        library.addListening(30, to: song, at: today.addingTimeInterval(-3 * 86_400))
        #expect(library.plays(of: song) == 2)
        #expect(library.songStats["a"]?.seconds == 90)
        #expect(library.streak(asOf: today, calendar: calendar) == 2)
        // Nothing yet today still counts the run up to yesterday.
        #expect(library.streak(asOf: today.addingTimeInterval(86_400), calendar: calendar) == 2)
    }

    @Test func readsALibraryFileFromBeforePlaylists() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "koda-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = #"{"liked":[{"id":"a","title":"A","artistLine":"X","artists":[],"isVideo":false}],"albums":[],"playlists":[],"artists":[],"recent":[],"searches":["q"]}"#
        try Data(old.utf8).write(to: dir.appending(path: "library.json"))
        let library = Library(directory: dir)
        #expect(library.liked.map(\.id) == ["a"])
        #expect(library.searches == ["q"])
        #expect(library.userPlaylists.isEmpty)
    }

    @Test func lyricsOffsetsRoundAndClear() {
        let library = Library(directory: nil)
        library.setLyricsOffset(0.54, for: "a")
        #expect(library.lyricsOffset(for: "a") == 0.5)
        library.setLyricsOffset(0.01, for: "a")
        #expect(library.lyricsOffsets["a"] == nil)
    }
}

@MainActor
@Suite struct LibraryBackupTests {
    @Test func backupRestoresEverythingElsewhere() throws {
        let source = Library(directory: nil)
        let song = Song(id: "a", title: "A", artistLine: "X", duration: 200)
        source.toggleLike(song)
        source.recordPlay(song)
        source.addListening(42, to: song)
        let playlist = source.createPlaylist(named: "Mine", songs: [song])
        source.setLyricsOffset(0.4, for: "a")
        let data = try #require(source.backupData())

        let target = Library(directory: nil)
        target.toggleLike(Song(id: "z", title: "Z", artistLine: ""))
        try target.restore(from: data)
        #expect(target.liked.map(\.id) == ["a"])
        #expect(target.userPlaylist(playlist.id)?.songs.map(\.id) == ["a"])
        #expect(target.songStats["a"]?.seconds == 42)
        #expect(target.lyricsOffset(for: "a") == 0.4)
        #expect(target.history.map(\.song.id) == ["a"])
    }

    @Test func refusesFilesThatAreNotBackups() {
        let library = Library(directory: nil)
        library.toggleLike(Song(id: "a", title: "A", artistLine: ""))
        #expect(throws: Library.BackupError.self) { try library.restore(from: Data(#"{"liked":[]}"#.utf8)) }
        #expect(throws: Library.BackupError.self) { try library.restore(from: Data("not json".utf8)) }
        #expect(library.liked.map(\.id) == ["a"])
    }
}

@MainActor
@Suite struct TasteTests {
    private func song(_ id: String, _ artist: String) -> Song {
        Song(id: id, title: id, artistLine: artist, artists: [ArtistRef(id: "UC\(artist)", name: artist)])
    }

    @Test func favoursWhatIsPlayedLately() {
        let library = Library(directory: nil)
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let old = song("old", "Old Band"), new = song("new", "New Band"), newer = song("newer", "New Band")
        // Played often two months ago; that fades below a few plays this week.
        for _ in 0..<10 { library.recordPlay(old, at: now.addingTimeInterval(-60 * 86_400)) }
        for _ in 0..<3 { library.recordPlay(new, at: now.addingTimeInterval(-86_400)) }
        library.recordPlay(newer, at: now)
        let taste = Taste(library: library, now: now)
        #expect(taste.artists == ["New Band", "Old Band"])
        // One seed per artist, that artist's strongest song.
        #expect(taste.seeds.map(\.id) == ["new", "old"])
    }

    @Test func leavesOutArtistsTheListenerHid() {
        let library = Library(directory: nil)
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        library.recordPlay(song("a", "Kept"), at: now)
        library.recordPlay(song("b", "Hidden"), at: now)
        library.hide(artist: ArtistRef(id: "UCHidden", name: "Hidden"))
        #expect(Taste(library: library, now: now).artists == ["Kept"])
    }

    @Test func emptyWithoutListening() {
        #expect(Taste(library: Library(directory: nil)).isEmpty)
    }

    @Test func weavesRadiosWithoutRepeats() {
        let a = [song("a1", "A"), song("shared", "S"), song("a2", "A")]
        let b = [song("b1", "B"), song("shared", "S")]
        let woven = Taste.weave([a, b], excluding: ["a2"])
        #expect(woven.map(\.id) == ["a1", "b1", "shared"])
        #expect(Taste.weave([a, b], limit: 2).count == 2)
    }
}
