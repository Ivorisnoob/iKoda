import Foundation

// Whole WEB_REMIX responses read into pages. [verified October 2026, signed out]

enum Pages {
    // MARK: Shelves (Home, Explore, charts, a mood)

    static func shelves(_ root: JSON) -> ShelfPage {
        var shelves: [Shelf] = []
        var quickPicks: [Song] = []
        for carousel in root.objects("musicCarouselShelfRenderer") {
            let header = carousel["header"]["musicCarouselShelfBasicHeaderRenderer"]
            let entries = carousel["contents"].array
            let items = entries.compactMap(Rows.item(entry:))
            guard !items.isEmpty else { continue }
            let shelf = Shelf(title: header["title"].text, strapline: header["strapline"].text.nonEmptyString, items: dedupe(items))
            shelves.append(shelf)
            // Quick picks is the one Home shelf drawn as rows of songs; the shelves around it
            // ("Listen again", mixes, albums) are cards, and their songs are ones already heard.
            // Told apart by layout, not title, which is in the listener's language.
            if quickPicks.isEmpty, entries.first?["musicResponsiveListItemRenderer"].exists == true {
                quickPicks = shelf.items.compactMap { item in
                    guard case .song(let song) = item, !song.title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                    return song
                }
            }
        }
        var moods: [Mood] = []
        for chip in root.objects("chipCloudChipRenderer") {
            guard let target = chip["navigationEndpoint"].browseTarget else { continue }
            moods.append(Mood(title: chip["text"].text, browseId: target.id, params: target.params))
        }
        for button in root.objects("musicNavigationButtonRenderer") {
            guard let target = button["clickCommand"].browseTarget else { continue }
            moods.append(Mood(title: button["buttonText"].text, browseId: target.id, params: target.params))
        }
        return ShelfPage(shelves: shelves, moods: moods, quickPicks: quickPicks)
    }

    static func dedupe<T: Identifiable>(_ items: [T]) -> [T] {
        var seen = Set<T.ID>()
        return items.filter { seen.insert($0.id).inserted }
    }

    // MARK: Search

    static func search(_ root: JSON) -> SearchResults {
        var results = SearchResults.empty

        if let card = root.objects("musicCardShelfRenderer").first {
            let title = card["title"]
            let titleRuns = title.runs
            let artwork = card["thumbnail"].bestThumbnail
            let subtitleRuns = card["subtitle"].runs
            if let target = titleRuns.first?.link ?? card["onTap"].browseTarget {
                let name = title.text
                if target.isArtist {
                    results.top = .artist(ArtistSummary(id: target.id, name: name, subtitle: segmentAfterLabel(subtitleRuns), artwork: artwork))
                    let fallback = (line: name, artists: [ArtistRef(id: target.id, name: name)])
                    results.topSongs = card["contents"].array.compactMap { Rows.song(listRow: $0["musicResponsiveListItemRenderer"], fallbackArtist: fallback) }
                } else if target.isAlbum {
                    let by = Rows.byline(subtitleRuns)
                    results.top = .album(AlbumSummary(id: target.id, title: name, artistLine: by.line, artists: by.artists,
                                                      year: Rows.year(subtitleRuns), kind: Rows.kind(subtitleRuns), artwork: artwork))
                } else if target.isPlaylist {
                    results.top = .playlist(PlaylistSummary(id: String(target.id.trimmingPrefix("VL")), title: name, subtitle: segmentAfterLabel(subtitleRuns), artwork: artwork))
                }
            } else if let videoId = titleRuns.first?["navigationEndpoint"]["watchEndpoint"]["videoId"].nonEmpty {
                let by = Rows.byline(subtitleRuns)
                results.top = .song(Song(id: videoId, title: title.text, artistLine: by.line, artists: by.artists,
                                         album: Rows.album(subtitleRuns), artwork: artwork, isVideo: Rows.isVideo(card)))
            }
        }

        // Rows outside the top card. The all-results page lists them one per
        // item section, a filtered page in one shelf; reading rows either way
        // and sorting by kind covers both.
        let shelves = root.objects("musicShelfRenderer")
        for shelf in shelves {
            for entry in shelf["contents"].array {
                let row = entry["musicResponsiveListItemRenderer"]
                guard row.exists, let item = Rows.item(listRow: row) else { continue }
                add(item, row: row, to: &results)
            }
        }
        for section in root.objects("itemSectionRenderer") {
            for entry in section["contents"].array {
                let row = entry["musicResponsiveListItemRenderer"]
                guard row.exists, let item = Rows.item(listRow: row) else { continue }
                add(item, row: row, to: &results)
            }
        }
        results.songs = dedupe(results.songs)
        results.videos = dedupe(results.videos)
        results.albums = dedupe(results.albums)
        results.artists = dedupe(results.artists)
        results.playlists = dedupe(results.playlists)
        return results
    }

    private static func add(_ item: MusicItem, row: JSON, to results: inout SearchResults) {
        switch item {
        case .song(let song):
            // Podcast episodes link a non-music page from their title.
            if Rows.columns(row).first?.runs.contains(where: { $0.link != nil }) == true { return }
            if song.isVideo { results.videos.append(song) } else { results.songs.append(song) }
        case .album(let album): results.albums.append(album)
        case .artist(let artist):
            // Profiles are user channels, not artists.
            let label = Rows.columns(row).dropFirst().first.map { Rows.plainText($0.runs) } ?? ""
            if !label.hasPrefix("Profile") { results.artists.append(artist) }
        case .playlist(let playlist): results.playlists.append(playlist)
        }
    }

    private static func segmentAfterLabel(_ runs: [JSON]) -> String? {
        let segs = Rows.segments(runs).map(Rows.plainText).filter { !Rows.typeLabels.contains($0) && !$0.isEmpty }
        return segs.last
    }

    static func searchContinuation(_ root: JSON) -> String? {
        root.objects("nextContinuationData").first?["continuation"].nonEmpty
            ?? root.objects("continuationItemRenderer").lazy.compactMap { $0["continuationEndpoint"]["continuationCommand"]["token"].nonEmpty }.first
    }

    // MARK: Album

    static func album(_ root: JSON, id: String) -> AlbumPage? {
        let header = root.first("musicResponsiveHeaderRenderer").exists ? root.first("musicResponsiveHeaderRenderer") : root.first("musicDetailHeaderRenderer")
        let title = header["title"].text
        guard !title.isEmpty else { return nil }
        let strapline = header["straplineTextOne"].runs
        var by = Rows.byline(strapline)
        if by.line.isEmpty { by = (Rows.plainText(strapline), []) }
        let subtitle = header["subtitle"].runs
        let artwork = header["thumbnail"].bestThumbnail
        let summary = AlbumSummary(id: id, title: title, artistLine: by.line, artists: by.artists,
                                   year: Rows.year(subtitle), kind: Rows.kind(subtitle), artwork: artwork)
        let albumRef = AlbumRef(id: id, title: title)

        // Only the track shelf: "Other versions" and "Releases for you" must never become tracks.
        var songs: [Song] = []
        for shelf in root.objects("musicShelfRenderer") {
            for entry in shelf["contents"].array {
                let row = entry["musicResponsiveListItemRenderer"]
                guard var song = Rows.song(listRow: row, fallbackArtist: by) else { continue }
                song.album = albumRef
                song.year = summary.year
                if song.artwork == nil { song.artwork = artwork }
                songs.append(song)
            }
        }
        let other = root.objects("musicCarouselShelfRenderer").first { $0["header"]["musicCarouselShelfBasicHeaderRenderer"]["title"].text == "Other versions" }
        let otherVersions = other?["contents"].array.compactMap { entry -> AlbumSummary? in
            if case .album(let a) = Rows.item(entry: entry) { return a }
            return nil
        } ?? []
        let description = header.first("musicDescriptionShelfRenderer")["description"].text
        return AlbumPage(album: summary, description: description.nonEmptyString,
                         detailLine: Rows.plainText(header["secondSubtitle"].runs).nonEmptyString,
                         songs: songs, otherVersions: otherVersions,
                         audioPlaylistId: header.strings("playlistId").first { $0.hasPrefix("OLAK5uy_") })
    }

    /// Signed out, an album lists a track's music video in place of the song
    /// where it has one: same title and length, but the video's audio with its
    /// own intro and ending. The album's audio playlist has the songs.
    static func withSongVersions(_ album: [Song], audio: [Song]) -> [Song] {
        func key(_ s: Song) -> String { s.title.trimmingCharacters(in: .whitespaces).lowercased() }
        var unused = audio
        return album.enumerated().map { index, track in
            guard track.isVideo else { return track }
            let match: Song?
            if index < audio.count, key(audio[index]) == key(track), unused.contains(audio[index]) {
                match = audio[index]
            } else {
                match = unused.first { key($0) == key(track) }
            }
            guard let match, let i = unused.firstIndex(of: match) else { return track }
            unused.remove(at: i)
            var song = track
            song.id = match.id
            song.isVideo = false
            song.duration = match.duration ?? track.duration
            return song
        }
    }

    // MARK: Artist

    static func artist(_ root: JSON, id: String) -> ArtistPage? {
        let header = root.first("musicImmersiveHeaderRenderer").exists ? root.first("musicImmersiveHeaderRenderer") : root.first("musicVisualHeaderRenderer")
        let name = header["title"].text
        guard !name.isEmpty else { return nil }
        let banner = header["thumbnail"].bestThumbnail
        let summary = ArtistSummary(id: id, name: name, subtitle: header["monthlyListenerCount"].text.nonEmptyString, artwork: banner)
        let fallback = (line: name, artists: [ArtistRef(id: id, name: name)])

        let songShelf = root.objects("musicShelfRenderer").first
        let topSongs = songShelf?["contents"].array.compactMap { Rows.song(listRow: $0["musicResponsiveListItemRenderer"], fallbackArtist: fallback) } ?? []
        let allSongs = songShelf?["bottomEndpoint"].browseTarget.map { String($0.id.trimmingPrefix("VL")) }

        var albums: [AlbumSummary] = [], singles: [AlbumSummary] = [], featured: [PlaylistSummary] = [], similar: [ArtistSummary] = []
        for carousel in root.objects("musicCarouselShelfRenderer") {
            let title = carousel["header"]["musicCarouselShelfBasicHeaderRenderer"]["title"].text
            let items = carousel["contents"].array.compactMap(Rows.item(entry:))
            switch title {
            case "Albums":
                albums = items.compactMap { if case .album(var a) = $0 { a.kind = a.kind ?? .album; if a.artistLine.isEmpty { a.artistLine = name }; return a }; return nil }
            case "Singles & EPs", "Singles", "EPs":
                singles = items.compactMap { if case .album(var a) = $0 { if a.artistLine.isEmpty { a.artistLine = name }; return a }; return nil }
            case "Featured on":
                featured = items.compactMap { if case .playlist(let p) = $0 { return p }; return nil }
            case "Fans might also like":
                similar = items.compactMap { if case .artist(let a) = $0 { return a }; return nil }
            default: break
            }
        }
        return ArtistPage(artist: summary, description: header["description"].text.nonEmptyString, banner: banner,
                          topSongs: topSongs, allSongsPlaylistId: allSongs, albums: albums, singles: singles,
                          featuredOn: featured, similar: similar)
    }

    // MARK: Playlist

    static func playlist(_ root: JSON, id: String) -> PlaylistPage? {
        let header = root.first("musicResponsiveHeaderRenderer").exists ? root.first("musicResponsiveHeaderRenderer") : root.first("musicDetailHeaderRenderer")
        let title = header["title"].text
        guard !title.isEmpty else { return nil }
        let strapline = Rows.plainText(header["straplineTextOne"].runs)
        let songs = playlistSongs(root)
        return PlaylistPage(
            playlist: PlaylistSummary(id: id, title: title, subtitle: strapline.nonEmptyString, artwork: header["thumbnail"].bestThumbnail),
            author: strapline.nonEmptyString,
            detailLine: Rows.plainText(header["secondSubtitle"].runs).nonEmptyString,
            description: header.first("musicDescriptionShelfRenderer")["description"].text.nonEmptyString,
            songs: songs,
            continuation: playlistContinuation(root))
    }

    static func playlistSongs(_ root: JSON) -> [Song] {
        let containers = root.objects("musicPlaylistShelfRenderer") + root.objects("appendContinuationItemsAction")
        return containers.flatMap { container in
            (container["contents"].array + container["continuationItems"].array).compactMap { Rows.song(listRow: $0["musicResponsiveListItemRenderer"]) }
        }
    }

    /// Only the track shelf's token: a playlist page also carries a section
    /// continuation that leads to a shelf of related playlists, not more tracks.
    static func playlistContinuation(_ root: JSON) -> String? {
        let scopes = root.objects("musicPlaylistShelfRenderer") + root.objects("appendContinuationItemsAction")
        for scope in scopes {
            if let token = scope.objects("continuationCommand").first?["token"].nonEmpty { return token }
            if let token = scope.objects("nextContinuationData").first?["continuation"].nonEmpty { return token }
        }
        return nil
    }

    // MARK: Radio (/next)

    static func queue(_ root: JSON) -> (songs: [Song], continuation: String?) {
        let panel = root.first("playlistPanelRenderer")
        var songs: [Song] = []
        for entry in panel["contents"].array {
            if entry["playlistPanelVideoWrapperRenderer"].exists {
                // Signed in, an entry with both a video and a song carries the two; take the song.
                let versions = entry.objects("playlistPanelVideoRenderer").compactMap(Rows.song(panel:))
                if let pick = versions.first(where: { !$0.isVideo }) ?? versions.first { songs.append(pick) }
            } else if let song = Rows.song(panel: entry["playlistPanelVideoRenderer"]) {
                songs.append(song)
            }
        }
        let token = panel.objects("nextRadioContinuationData").first?["continuation"].nonEmpty
            ?? panel.objects("nextContinuationData").first?["continuation"].nonEmpty
        return (songs, token)
    }
}

extension String {
    var nonEmptyString: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
