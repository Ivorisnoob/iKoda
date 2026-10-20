import Foundation

// Reading the signed-in parts of WEB_REMIX: the account's own Home, the songs
// it liked and the playlists in its library. [shapes as Koda for Android reads
// them, October 2026]

enum AccountPages {
    // MARK: Home

    /// One account's Home: its shelves and the recommendations in them.
    ///
    /// The recommendations are told by their rows and not by their title: they
    /// are the one shelf of songs on Home, whether YouTube draws that shelf
    /// as a list or as a carousel of rows. [verified on Koda for Android,
    /// October 2026]
    static func home(_ root: JSON) -> AccountHome {
        var shelves: [Shelf] = []
        var quickPicks: [Song] = []
        var quickPicksTitle = "Quick picks"

        for entry in sections(of: root) {
            let shelf = shelf(in: entry)
            guard let shelf else { continue }
            if quickPicks.isEmpty {
                let songs = shelf.items.compactMap { item -> Song? in
                    if case .song(let song) = item { return song }
                    return nil
                }
                if !songs.isEmpty {
                    // The recommendations are a shelf of their own, not a row
                    // of cards among the others.
                    quickPicks = songs
                    if !shelf.title.isEmpty { quickPicksTitle = shelf.title }
                    continue
                }
            }
            shelves.append(shelf)
        }

        return AccountHome(shelves: shelves, quickPicks: quickPicks, quickPicksTitle: quickPicksTitle)
    }

    /// The shelf one section of a page holds, whichever way it is drawn.
    private static func shelf(in entry: JSON) -> Shelf? {
        let carousel = entry["musicCarouselShelfRenderer"]
        if carousel.exists {
            let header = carousel["header"]["musicCarouselShelfBasicHeaderRenderer"]
            let items = carousel["contents"].array.compactMap(Rows.item(entry:))
            guard !items.isEmpty else { return nil }
            return Shelf(title: header["title"].text,
                         strapline: header["strapline"].text.nonEmptyString,
                         items: Pages.dedupe(items))
        }
        let shelf = entry["musicShelfRenderer"]
        if shelf.exists {
            let items = shelf["contents"].array.compactMap { Rows.item(listRow: $0["musicResponsiveListItemRenderer"]) }
            guard !items.isEmpty else { return nil }
            return Shelf(title: shelf["title"].text, items: Pages.dedupe(items))
        }
        return nil
    }

    /// The token for the next block of Home's shelves.
    ///
    /// Home's section list pages: the first answer carries it on
    /// `sectionListRenderer`, each continuation on `sectionListContinuation`.
    /// [verified October 2026 on Koda for Android: four pages signed in]
    static func sectionContinuation(_ root: JSON) -> String? {
        let first = root["contents"]["singleColumnBrowseResultsRenderer"]["tabs"].array.first?["tabRenderer"]["content"]["sectionListRenderer"] ?? .null
        let next = root["continuationContents"]["sectionListContinuation"]
        for renderer in [first, next] where renderer.exists {
            if let token = renderer["continuations"].array.first?["nextContinuationData"]["continuation"].nonEmpty { return token }
        }
        return nil
    }

    // MARK: Liked songs

    /// The songs the account liked, as one page of them.
    static func likedSongs(_ root: JSON) -> [Song] {
        var songs: [Song] = []
        for entry in sections(of: root) {
            for renderer in [entry["musicShelfRenderer"], entry["musicPlaylistShelfRenderer"]] where renderer.exists {
                songs += renderer["contents"].array.compactMap { Rows.song(listRow: $0["musicResponsiveListItemRenderer"]) }
            }
        }
        return songs
    }

    /// The token for the next page of liked songs.
    static func shelfContinuation(_ root: JSON) -> String? {
        for entry in sections(of: root) {
            for renderer in [entry["musicShelfRenderer"], entry["musicPlaylistShelfRenderer"]] where renderer.exists {
                if let token = renderer["continuations"].array.first?["nextContinuationData"]["continuation"].nonEmpty { return token }
                if let token = renderer["contents"].objects("continuationItemRenderer").first?["continuationEndpoint"]["continuationCommand"]["token"].nonEmpty { return token }
            }
        }
        return nil
    }

    // MARK: Playlists

    /// The playlists in the account's library, as one page of them.
    static func playlists(_ root: JSON) -> [PlaylistSummary] {
        var playlists: [PlaylistSummary] = []
        for entry in sections(of: root) {
            for renderer in [entry["gridRenderer"], entry["musicShelfRenderer"], entry["musicCarouselShelfRenderer"]] where renderer.exists {
                let items = renderer["items"].array + renderer["contents"].array
                for item in items {
                    if case .playlist(let playlist) = Rows.item(entry: item) {
                        playlists.append(playlist)
                    }
                }
            }
        }
        return Pages.dedupe(playlists)
    }

    /// The token for the next page of the account's playlists.
    static func gridContinuation(_ root: JSON) -> String? {
        for entry in sections(of: root) {
            for renderer in [entry["gridRenderer"], entry["musicShelfRenderer"], entry["musicCarouselShelfRenderer"]] where renderer.exists {
                if let token = renderer["continuations"].array.first?["nextContinuationData"]["continuation"].nonEmpty { return token }
                let items = renderer["items"].array + renderer["contents"].array
                for item in items {
                    if let token = item["continuationItemRenderer"]["continuationEndpoint"]["continuationCommand"]["token"].nonEmpty { return token }
                }
            }
        }
        return nil
    }

    // MARK: Shared

    /// The shelves of a browse page, whether it is the page itself or a
    /// continuation of it.
    static func sections(of root: JSON) -> [JSON] {
        let continuation = root["continuationContents"]["sectionListContinuation"]["contents"].array
        if !continuation.isEmpty { return continuation }
        let page = root["contents"]["singleColumnBrowseResultsRenderer"]["tabs"].array.first?["tabRenderer"]["content"]["sectionListRenderer"]["contents"].array
        return page ?? []
    }
}
