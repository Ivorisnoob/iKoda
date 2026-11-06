import Foundation
import Testing
@testable import KodaCore

/// Library search, playlist photos and descriptions, the equalizer's curves and Data Saver.
@MainActor
@Suite struct LibrarySearchTests {
    private func song(_ id: String, _ title: String, _ artist: String, album: String? = nil) -> Song {
        Song(id: id, title: title, artistLine: artist, album: album.map { AlbumRef(id: "MPRE\(id)", title: $0) })
    }

    @Test func matchesEveryWordAcrossFieldsIgnoringCaseAndAccents() {
        let library = Library(directory: nil)
        library.toggleLike(song("a", "Blinding Lights", "The Weeknd", album: "After Hours"))
        library.toggleLike(song("b", "Pokémon Theme", "Jason Paige"))
        library.toggleLike(song("c", "Lights Up", "Harry Styles"))

        #expect(library.search("weeknd lights").songs.map(\.id) == ["a"])
        #expect(library.search("POKEMON").songs.map(\.id) == ["b"])
        #expect(library.search("after hours").songs.map(\.id) == ["a"])
        #expect(library.search("   ").isEmpty)
        #expect(library.search("nothing like this").isEmpty)
    }

    @Test func titlesStartingWithTheQueryComeFirst() {
        let library = Library(directory: nil)
        // Liked in this order, newest first: the artist match, a word match, then a title match.
        library.toggleLike(song("artist", "Something", "Lights Out"))
        library.toggleLike(song("word", "City Lights", "X"))
        library.toggleLike(song("title", "Lights Up", "Y"))
        library.toggleLike(song("other", "Bright Lights", "Z"))
        let found = library.search("lights").songs.map(\.id)
        #expect(found.first == "title")
        #expect(found.last == "artist")
    }

    @Test func eachSongOnceFromEveryPlace() {
        let library = Library(directory: nil)
        let liked = song("a", "Shared Song", "X")
        library.toggleLike(liked)
        let playlist = library.createPlaylist(named: "Road Trip", songs: [liked, song("b", "Shared Road", "Y")])
        library.recordPlay(song("c", "Shared Past", "Z"))

        let found = library.search("shared", extra: [song("d", "Shared Download", "W"), liked])
        #expect(found.songs.map(\.id).sorted() == ["a", "b", "c", "d"])
        #expect(library.search("road trip").userPlaylists.map(\.id) == [playlist.id])
    }

    @Test func filtersAListInPlace() {
        let songs = [song("a", "One", "Alpha"), song("b", "Two", "Beta"), song("c", "Three", "Alpha")]
        #expect(LibrarySearch.songs(songs, matching: "alpha").map(\.id) == ["a", "c"])
        #expect(LibrarySearch.songs(songs, matching: "").map(\.id) == ["a", "b", "c"])
    }
}

@MainActor
@Suite struct PlaylistDetailsTests {
    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "koda-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func photoAndDescriptionSurviveARelaunchAndGoWithThePlaylist() throws {
        let dir = try tempDirectory()
        let library = Library(directory: dir)
        let playlist = library.createPlaylist(named: "Mine")
        library.setPlaylistSummary(playlist.id, to: "  Songs for the drive  ")
        library.setPlaylistCover(Data([0xFF, 0xD8, 0xFF]), for: playlist.id)
        let file = try #require(library.playlistCoverFile(playlist.id))
        #expect(FileManager.default.fileExists(atPath: file.path))
        library.flush()

        let reopened = Library(directory: dir)
        let saved = try #require(reopened.userPlaylist(playlist.id))
        #expect(saved.summary == "Songs for the drive")
        #expect(saved.hasCover)
        #expect(saved.coverVersion == 1)

        reopened.setPlaylistCover(nil, for: playlist.id)
        #expect(reopened.userPlaylist(playlist.id)?.hasCover == false)
        // A new photo after removing one is still a new version.
        #expect(reopened.userPlaylist(playlist.id)?.coverVersion == 2)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        reopened.setPlaylistCover(Data([1]), for: playlist.id)
        reopened.setPlaylistSummary(playlist.id, to: " ")
        #expect(reopened.userPlaylist(playlist.id)?.summary == nil)
        reopened.deletePlaylist(playlist.id)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func playlistsFromBeforePhotosStillLoad() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Old","songs":[],"created":0,"modified":0}"#
        let playlist = try JSONDecoder().decode(UserPlaylist.self, from: Data(json.utf8))
        #expect(playlist.name == "Old")
        #expect(!playlist.hasCover)
        #expect(playlist.summary == nil)
    }
}

@Suite struct EqualizerTests {
    @Test func flatPassesUntouched() {
        #expect(Equalizer.design(EqualizerPreset.off.gains, sampleRate: 44_100) == nil)
        // Every preset has a curve for every band.
        #expect(EqualizerPreset.allCases.allSatisfy { $0.gains.count == Equalizer.frequencies.count })
    }

    @Test func bassBoosterLiftsTheLowsAndLeavesTheHighs() throws {
        let design = try #require(Equalizer.design(EqualizerPreset.bassBooster.gains, sampleRate: 48_000))
        let low = Equalizer.response(design.sections, at: 50, sampleRate: 48_000)
        let high = Equalizer.response(design.sections, at: 6_000, sampleRate: 48_000)
        #expect(low > 4)
        #expect(abs(high) < 0.5)
    }

    @Test func headroomKeepsTheCurveAtOrUnderFullScale() throws {
        for preset in EqualizerPreset.allCases where preset != .off {
            let design = try #require(Equalizer.design(preset.gains, sampleRate: 44_100))
            let peak = Equalizer.peakResponse(design.sections, sampleRate: 44_100) + 20 * log10(design.preamp)
            #expect(peak <= 0.01, "\(preset.title) peaks at \(peak) dB")
        }
        // A curve that only cuts needs no headroom.
        let reducer = try #require(Equalizer.design(EqualizerPreset.bassReducer.gains, sampleRate: 44_100))
        #expect(reducer.preamp > 0.99)
    }
}

@Suite struct DataSaverTests {
    @Test func picksTheLightestAACForDataSaver() throws {
        let root = try fixture("player")
        let light = try #require(StreamResolver.pickAudio(root, videoId: "4NRXx6U8ABQ", quality: .dataSaver))
        #expect(light.itag == 139, "48 kbps HE-AAC, never Opus")
        #expect(light.isDataSaver)
        let best = try #require(StreamResolver.pickAudio(root, videoId: "4NRXx6U8ABQ"))
        #expect(best.itag == 140)
        #expect(!best.isDataSaver)
    }
}

@MainActor
@Suite struct PlayRunTests {
    private func play(_ id: String, _ minute: Double) -> PlayEvent {
        PlayEvent(song: Song(id: id, title: id, artistLine: "X"), date: Date(timeIntervalSince1970: minute * 60))
    }

    @Test func backToBackPlaysOfOneSongAreOneRow() {
        // Newest first: a on repeat three times, then b, then a again with b between.
        let events = [play("a", 10), play("a", 7), play("a", 4), play("b", 2), play("a", 0)]
        let runs = PlayRun.runs(events)
        #expect(runs.map(\.song.id) == ["a", "b", "a"])
        #expect(runs.map(\.count) == [3, 1, 1])
        #expect(runs[0].date == events[0].date)
    }

    @Test func removingARunRemovesEveryPlayInIt() {
        let library = Library(directory: nil)
        let song = Song(id: "a", title: "A", artistLine: "X")
        for minute in 0..<3 { library.recordPlay(song, at: Date(timeIntervalSince1970: Double(minute) * 60)) }
        let run = PlayRun.runs(library.history)[0]
        #expect(run.count == 3)
        library.removeFromHistory(run)
        #expect(library.history.isEmpty)
        #expect(library.recent.isEmpty)
    }
}
