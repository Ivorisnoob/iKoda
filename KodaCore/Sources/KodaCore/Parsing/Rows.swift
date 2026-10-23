import Foundation

// Reading WEB_REMIX rows into models. [verified October 2026 against live
// search, browse, explore, charts and next responses, signed out]
//
// Identity comes from links and page types, never from a run's position:
// collaborators sit where single-artist rows put the album, and a row's
// second column can lead with a type label ("Song", "Single") or not at all.

enum PageType: String {
    case artist = "MUSIC_PAGE_TYPE_ARTIST"
    case userChannel = "MUSIC_PAGE_TYPE_USER_CHANNEL"
    case album = "MUSIC_PAGE_TYPE_ALBUM"
    case playlist = "MUSIC_PAGE_TYPE_PLAYLIST"
}

struct BrowseTarget {
    var id: String
    var params: String?
    var pageType: PageType?

    var isArtist: Bool { pageType == .artist || pageType == .userChannel || (pageType == nil && id.hasPrefix("UC")) }
    var isAlbum: Bool { pageType == .album || (pageType == nil && id.hasPrefix("MPRE")) }
    var isPlaylist: Bool { pageType == .playlist || (pageType == nil && id.hasPrefix("VL")) }
}

extension JSON {
    var browseTarget: BrowseTarget? {
        let endpoint = self["browseEndpoint"]
        guard let id = endpoint["browseId"].nonEmpty else { return nil }
        let type = endpoint["browseEndpointContextSupportedConfigs"]["browseEndpointContextMusicConfig"]["pageType"].string
        return BrowseTarget(id: id, params: endpoint["params"].nonEmpty, pageType: type.flatMap(PageType.init))
    }

    /// A run's or renderer's browse link.
    var link: BrowseTarget? { self["navigationEndpoint"].browseTarget }
}

enum Rows {
    static let typeLabels: Set<String> = ["Song", "Video", "Album", "Single", "EP", "Playlist", "Artist", "Episode", "Podcast", "Profile"]

    // MARK: Text helpers

    /// Runs split into " • " separated segments.
    static func segments(_ runs: [JSON]) -> [[JSON]] {
        var result: [[JSON]] = [[]]
        for run in runs {
            if run["text"].string?.trimmingCharacters(in: .whitespaces) == "•" {
                result.append([])
            } else {
                result[result.count - 1].append(run)
            }
        }
        return result.filter { !$0.isEmpty }
    }

    /// A row's columns after the title as one run list, with a "•" between columns. A column
    /// boundary separates fields as the dot does: an artist page's songs read "The Weeknd" |
    /// "3.3B plays" | "After Hours" with no dot, which flattened as is ran into one byline.
    static func metaRuns(_ columns: [JSON]) -> [JSON] {
        let separator = JSON(["text": " • "] as [String: Any])
        return Array(columns.dropFirst().map(\.runs).filter { !$0.isEmpty }.joined(separator: [separator]))
    }

    static func plainText(_ runs: [JSON]) -> String {
        runs.compactMap { $0["text"].string }.joined().trimmingCharacters(in: .whitespaces)
    }

    static func duration(_ text: String) -> TimeInterval? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard (2...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        return parts.reduce(0) { $0 * 60 + (Double($1) ?? 0) }
    }

    static func year(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.count == 4, let y = Int(t), (1900...2100).contains(y) else { return nil }
        return y
    }

    /// The byline: the segment that links an artist, else the first segment that reads as a name.
    static func byline(_ runs: [JSON]) -> (line: String, artists: [ArtistRef]) {
        let segs = segments(runs)
        if let linked = segs.first(where: { $0.contains { $0.link?.isArtist == true } }) {
            let refs = linked.compactMap { run -> ArtistRef? in
                guard let target = run.link, target.isArtist, let name = run["text"].nonEmpty else { return nil }
                return ArtistRef(id: target.id, name: name)
            }
            return (plainText(linked), refs)
        }
        for seg in segs where seg.allSatisfy({ $0.link == nil }) {
            let text = plainText(seg)
            if text.isEmpty || typeLabels.contains(text) || duration(text) != nil || year(text) != nil { continue }
            if text.first?.isNumber == true { continue } // "4M views", "50 songs"
            return (text, [ArtistRef(id: nil, name: text)])
        }
        return ("", [])
    }

    static func album(_ runs: [JSON]) -> AlbumRef? {
        for run in runs {
            if let target = run.link, target.isAlbum, let title = run["text"].nonEmpty {
                return AlbumRef(id: target.id, title: title)
            }
        }
        return nil
    }

    static func kind(_ runs: [JSON]) -> ReleaseKind? {
        for run in runs where run.link == nil {
            if let k = ReleaseKind(rawValue: run["text"].string?.trimmingCharacters(in: .whitespaces) ?? "") { return k }
        }
        return nil
    }

    static func year(_ runs: [JSON]) -> Int? {
        runs.lazy.filter { $0.link == nil }.compactMap { year($0["text"].string ?? "") }.first
    }

    static func isVideo(_ node: JSON) -> Bool {
        let types = node.strings("musicVideoType")
        guard let type = types.first else { return false }
        return type != "MUSIC_VIDEO_TYPE_ATV"
    }

    // MARK: musicResponsiveListItemRenderer

    static func columns(_ row: JSON) -> [JSON] {
        row["flexColumns"].array.map { $0["musicResponsiveListItemFlexColumnRenderer"]["text"] }
    }

    static func videoId(_ row: JSON) -> String? {
        row["playlistItemData"]["videoId"].nonEmpty
            ?? row["videoId"].nonEmpty
            ?? row["navigationEndpoint"]["watchEndpoint"]["videoId"].nonEmpty
            ?? row["overlay"].first("watchEndpoint")["videoId"].nonEmpty
            ?? columns(row).first?.runs.lazy.compactMap { $0["navigationEndpoint"]["watchEndpoint"]["videoId"].nonEmpty }.first
    }

    /// Any list row: a song or video, or an album, artist or playlist link.
    static func item(listRow row: JSON, fallbackArtist: (line: String, artists: [ArtistRef])? = nil) -> MusicItem? {
        let cols = columns(row)
        guard let title = cols.first.map({ $0.text.trimmingCharacters(in: .whitespaces) }), !title.isEmpty else { return nil }
        let meta = metaRuns(cols)
        let artwork = row["thumbnail"].bestThumbnail

        if let target = row.link {
            let subtitle = cols.count > 1 ? plainText(cols[1].runs) : ""
            if target.isAlbum {
                let by = byline(meta)
                return .album(AlbumSummary(id: target.id, title: title, artistLine: by.line, artists: by.artists,
                                           year: year(meta), kind: kind(meta), artwork: artwork))
            }
            if target.isArtist {
                let audience = segments(meta).last.map(plainText)
                return .artist(ArtistSummary(id: target.id, name: title, subtitle: audience.flatMap { $0 == "Artist" ? nil : $0 }, artwork: artwork))
            }
            if target.isPlaylist {
                let sub = subtitle.hasPrefix("Playlist • ") ? String(subtitle.dropFirst("Playlist • ".count)) : subtitle
                return .playlist(PlaylistSummary(id: String(target.id.trimmingPrefix("VL")), title: title, subtitle: sub.isEmpty ? nil : sub, artwork: artwork))
            }
            return nil
        }

        guard let id = videoId(row) else { return nil }
        var by = byline(meta)
        if by.line.isEmpty, let fallbackArtist { by = fallbackArtist }
        let fixed = row["fixedColumns"].array.map { $0["musicResponsiveListItemFixedColumnRenderer"]["text"].text }
        let length = (fixed + meta.compactMap { $0["text"].string }).lazy.compactMap(duration).first
        return .song(Song(id: id, title: title, artistLine: by.line, artists: by.artists, album: album(meta),
                          duration: length, artwork: artwork, isVideo: isVideo(row), year: year(meta)))
    }

    static func song(listRow row: JSON, fallbackArtist: (line: String, artists: [ArtistRef])? = nil) -> Song? {
        if case .song(let s) = item(listRow: row, fallbackArtist: fallbackArtist) { return s }
        return nil
    }

    // MARK: musicTwoRowItemRenderer

    static func item(twoRow row: JSON) -> MusicItem? {
        let title = row["title"].text.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        let subtitleRuns = row["subtitle"].runs
        let subtitle = plainText(subtitleRuns)
        let artwork = row["thumbnailRenderer"].bestThumbnail
        let nav = row["navigationEndpoint"]

        if let videoId = nav["watchEndpoint"]["videoId"].nonEmpty {
            let by = byline(subtitleRuns)
            return .song(Song(id: videoId, title: title, artistLine: by.line, artists: by.artists, album: album(subtitleRuns),
                              artwork: artwork, isVideo: isVideo(row)))
        }
        guard let target = nav.browseTarget else { return nil }
        if target.isAlbum {
            let by = byline(subtitleRuns)
            return .album(AlbumSummary(id: target.id, title: title, artistLine: by.line, artists: by.artists,
                                       year: year(subtitleRuns), kind: kind(subtitleRuns), artwork: artwork))
        }
        if target.isArtist {
            return .artist(ArtistSummary(id: target.id, name: title, subtitle: subtitle.isEmpty ? nil : subtitle, artwork: artwork))
        }
        if target.isPlaylist {
            return .playlist(PlaylistSummary(id: String(target.id.trimmingPrefix("VL")), title: title, subtitle: subtitle.isEmpty ? nil : subtitle, artwork: artwork))
        }
        return nil
    }

    // MARK: playlistPanelVideoRenderer (the /next queue)

    static func song(panel: JSON) -> Song? {
        guard let id = panel["videoId"].nonEmpty else { return nil }
        let title = panel["title"].text.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        let runs = panel["longBylineText"].runs
        var by = byline(runs)
        if by.line.isEmpty { by = byline(panel["shortBylineText"].runs) }
        return Song(id: id, title: title, artistLine: by.line, artists: by.artists, album: album(runs),
                    duration: duration(panel["lengthText"].text), artwork: panel["thumbnail"].bestThumbnail,
                    isVideo: isVideo(panel), year: year(runs))
    }

    /// Any renderer wrapper found in a shelf's `contents`.
    static func item(entry: JSON) -> MusicItem? {
        if entry["musicTwoRowItemRenderer"].exists { return item(twoRow: entry["musicTwoRowItemRenderer"]) }
        if entry["musicResponsiveListItemRenderer"].exists { return item(listRow: entry["musicResponsiveListItemRenderer"]) }
        return nil
    }
}
