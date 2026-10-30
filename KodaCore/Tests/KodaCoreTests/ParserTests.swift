import Foundation
import Testing
@testable import KodaCore

/// Reduced live responses, captured signed out in October 2026 (see `.probe/`).
func fixture(_ name: String) throws -> JSON {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try JSON(data: Data(contentsOf: url))
}

@Suite struct ParserTests {
    @Test func homeShelvesAndMoodChips() throws {
        let page = Pages.shelves(try fixture("home"))
        #expect(page.shelves.count == 2)
        #expect(page.shelves[1].title == "Trending community playlists")
        #expect(page.shelves.allSatisfy { !$0.items.isEmpty })
        guard case .playlist(let p) = page.shelves[0].items[0] else { Issue.record("expected a playlist"); return }
        #expect(!p.id.hasPrefix("VL"))
        #expect(page.moods.contains { $0.title == "Feel good" && $0.params != nil })
    }

    @Test func homeQuickPicksAreSongs() throws {
        let page = Pages.shelves(try fixture("home-quick-picks"))
        #expect(page.shelves.first?.title == "Quick picks")
        let songs = page.songs
        #expect(songs.count == 20)
        #expect(songs.allSatisfy { !$0.id.isEmpty && !$0.title.isEmpty && !$0.artistLine.isEmpty })
        #expect(Set(songs.map(\.id)).count == songs.count)
        #expect(page.quickPicks.map(\.id) == songs.map(\.id))
    }

    @Test func homeQuickPicksLeaveOutListenAgain() throws {
        // Signed in, Home can lead with "Listen again", cards of songs already heard.
        let heard = ["musicTwoRowItemRenderer": [
            "title": ["runs": [["text": "Heard Before"]]],
            "subtitle": ["runs": [["text": "Some Artist"]]],
            "navigationEndpoint": ["watchEndpoint": ["videoId": "heardBefore"]],
        ]]
        let listenAgain = ["musicCarouselShelfRenderer": [
            "header": ["musicCarouselShelfBasicHeaderRenderer": ["title": ["runs": [["text": "Listen again"]]]]],
            "contents": [heard],
        ]]
        let quick = try fixture("home-quick-picks").objects("musicCarouselShelfRenderer")[0].raw!
        let page = Pages.shelves(JSON(["contents": [listenAgain, ["musicCarouselShelfRenderer": quick]]]))
        #expect(page.songs.first?.id == "heardBefore")
        #expect(page.quickPicks.count == 20)
        #expect(!page.quickPicks.contains { $0.id == "heardBefore" })
    }

    @Test func signedInHomeFindsQuickPicksOnALaterPage() throws {
        // Signed in, Home's first page (October 2026) is Listen again and two card shelves with a
        // continuation; Quick picks comes on the next page, in a sectionListContinuation.
        let heard = ["musicTwoRowItemRenderer": [
            "title": ["runs": [["text": "Heard Before"]]],
            "subtitle": ["runs": [["text": "Some Artist"]]],
            "navigationEndpoint": ["watchEndpoint": ["videoId": "heardBefore"]],
        ]]
        let listenAgain = ["musicCarouselShelfRenderer": [
            "header": ["musicCarouselShelfBasicHeaderRenderer": ["title": ["runs": [["text": "Listen again"]]]]],
            "contents": [heard],
        ]]
        let first = JSON(["contents": ["singleColumnBrowseResultsRenderer": ["tabs": [["tabRenderer": ["content": ["sectionListRenderer": [
            "contents": [listenAgain],
            "continuations": [["nextContinuationData": ["continuation": "page2"]]],
        ]]]]]]]])
        var page = Pages.shelves(first)
        #expect(page.quickPicks.isEmpty)
        #expect(Pages.searchContinuation(first) == "page2")

        let quick = try fixture("home-quick-picks").objects("musicCarouselShelfRenderer")[0].raw!
        let second = JSON(["continuationContents": ["sectionListContinuation": [
            "contents": [["musicCarouselShelfRenderer": quick]],
        ]]])
        page.append(Pages.shelves(second))
        #expect(page.shelves.map(\.title) == ["Listen again", "Quick picks"])
        #expect(page.quickPicks.count == 20)
        #expect(!page.quickPicks.contains { $0.id == "heardBefore" })
    }

    @Test func chartTopArtistsAreArtists() throws {
        let page = Pages.shelves(try fixture("charts-top-artists"))
        let artists = page.artists
        #expect(artists.count == 40)
        #expect(artists.allSatisfy { $0.id.hasPrefix("UC") && !$0.name.isEmpty && $0.artwork != nil })
    }

    @Test func exploreHasNewReleasesAsAlbums() throws {
        let page = Pages.shelves(try fixture("explore"))
        let releases = try #require(page.shelves.first { $0.title == "New albums & singles" })
        guard case .album(let album) = releases.items[0] else { Issue.record("expected an album"); return }
        #expect(album.id.hasPrefix("MPRE"))
        #expect(album.kind != nil)
        #expect(!album.artistLine.isEmpty)
        #expect(page.moods.count > 20, "moods & genres buttons")
    }

    @Test func songSearchReadsLinksNotPositions() throws {
        let results = Pages.search(try fixture("search-songs"))
        let first = try #require(results.songs.first)
        #expect(first.id == "J7p4bzqLvCw")
        #expect(first.title == "Blinding Lights")
        #expect(first.artistLine == "The Weeknd")
        #expect(first.album?.id.hasPrefix("MPRE") == true)
        #expect(first.duration == 202)
        #expect(!first.isVideo)
        // A collaborator row keeps the artist YouTube did not link.
        let collab = try #require(results.songs.first { $0.id == "oud4MUJ45UQ" })
        #expect(collab.artistLine == "Marcus D, Funky DL, Substantial & Cise Star")
        #expect(collab.artists.count == 3)
        #expect(collab.album?.title == "Blinding Light")
    }

    @Test func allResultsSortByKind() throws {
        let results = Pages.search(try fixture("search-all"))
        guard case .artist(let top) = results.top else { Issue.record("top result should be the artist"); return }
        #expect(top.name == "The Weeknd")
        #expect(results.topSongs.count == 3)
        #expect(results.topSongs.allSatisfy { $0.artistLine == "The Weeknd" }, "the card's songs name no artist; the card does")
        #expect(results.albums.contains { $0.title == "Pray For Me" && $0.year == 2018 && $0.kind == .single })
        #expect(results.artists.contains { $0.name == "Travis Scott" })
        #expect(!results.artists.contains { $0.name == "thevieira" }, "profiles are not artists")
        #expect(results.playlists.contains { $0.title == "Presenting The Weeknd" })
        #expect(results.videos.contains { $0.id == "Mt-xG6GO848" })
        #expect(!results.songs.contains { $0.title.contains("BELLA HADID") }, "podcast episodes are dropped")
    }

    @Test func albumTakesSongVersionsFromItsAudioPlaylist() throws {
        let root = try fixture("album")
        var page = try #require(Pages.album(root, id: "MPREb_TH6Wut5eTMQ"))
        #expect(page.album.title == "After Hours")
        #expect(page.album.artistLine == "The Weeknd")
        #expect(page.album.year == 2020)
        #expect(page.album.kind == .album)
        #expect(page.songs.count == 14)
        #expect(page.songs.allSatisfy { $0.album?.id == "MPREb_TH6Wut5eTMQ" && $0.artistLine == "The Weeknd" })
        #expect(page.audioPlaylistId == "OLAK5uy_l4UqNJCpAF3kNaV37LHdRc_A07MmVdiSU")
        #expect(page.otherVersions.count == 5)
        #expect(page.songs[0].isVideo, "signed out, the album row is the music video")

        let audio = Pages.playlistSongs(try fixture("album-audio"))
        page.songs = Pages.withSongVersions(page.songs, audio: audio)
        #expect(page.songs[0].id == "i8r4zJC1i70")
        #expect(page.songs[0].title == "Alone Again")
        #expect(page.songs.allSatisfy { !$0.isVideo })
    }

    @Test func artistPage() throws {
        let page = try #require(Pages.artist(try fixture("artist"), id: "UClYV6hHlupm_S_ObS1W-DYw"))
        #expect(page.artist.name == "The Weeknd")
        #expect(page.artist.subtitle == "238M monthly audience")
        #expect(page.topSongs.count == 5)
        // Artist, plays and album sit in separate columns with no dot between them.
        #expect(page.topSongs[0].artistLine == "The Weeknd, JENNIE & Lily Rose Depp")
        #expect(page.topSongs[1].artistLine == "The Weeknd")
        #expect(page.topSongs[1].album?.title == "After Hours")
        #expect(page.allSongsPlaylistId?.hasPrefix("OLAK5uy_") == true)
        #expect(page.albums.first?.title == "Hurry Up Tomorrow")
        #expect(page.albums.allSatisfy { $0.kind == .album && $0.artistLine == "The Weeknd" })
        #expect(page.singles.first?.kind == .single)
        #expect(page.similar.first?.name == "Labrinth")
        #expect(page.featuredOn.first?.title == "Presenting The Weeknd")
        #expect(page.banner != nil)
    }

    @Test func playlistAndItsContinuation() throws {
        let root = try fixture("playlist")
        let page = try #require(Pages.playlist(root, id: "RDCLAK5uy_lmztFiBPwa16-qz6nwMaNrtVFPzCYNOkA"))
        #expect(page.songs.count == 100)
        let token = try #require(page.continuation)
        #expect(!token.isEmpty)
        let more = try fixture("playlist-continuation")
        #expect(Pages.playlistSongs(more).count > 0)
    }

    @Test func radioQueueIsSongsFromASongSeed() throws {
        let (songs, continuation) = Pages.queue(try fixture("next-song"))
        #expect(songs.count == 50)
        #expect(songs[0].id == "J7p4bzqLvCw")
        #expect(songs.allSatisfy { !$0.isVideo })
        #expect(songs[1].artistLine == "The Weeknd & Anitta")
        #expect(songs[1].album?.title == "São Paulo")
        #expect(songs[1].year == 2024)
        #expect(continuation != nil)
    }

    @Test func pickAudioChoosesBestAAC() throws {
        let stream = try #require(StreamResolver.pickAudio(try fixture("player"), videoId: "4NRXx6U8ABQ"))
        #expect(stream.itag == 140, "Opus is unplayable on AVPlayer, so the best AAC wins over itag 251")
        #expect(stream.contentLength == 4_250_167)
        #expect(abs((stream.duration ?? 0) - 262.571) < 0.01)
        #expect(stream.expiresAt != nil)
        #expect(stream.loudnessDb != nil)
    }

    @Test func artworkResizesOnlyGoogleImageDirectives() {
        let art = Artwork(url: URL(string: "https://lh3.googleusercontent.com/abcs120xyz=w120-h120-l90-rj")!, width: 120, height: 120)
        #expect(art.url(pixels: 600).absoluteString == "https://lh3.googleusercontent.com/abcs120xyz=w600-h600-l90-rj")
        let s = Artwork(url: URL(string: "https://yt3.ggpht.com/tok=s88-c-k")!)
        #expect(s.url(pixels: 300).absoluteString == "https://yt3.ggpht.com/tok=s300-c-k")
        let video = Artwork(url: URL(string: "https://i.ytimg.com/vi/x/hqdefault.jpg")!, width: 400, height: 225)
        #expect(video.url(pixels: 600) == video.url)
        #expect(video.isLandscape)
    }
}
