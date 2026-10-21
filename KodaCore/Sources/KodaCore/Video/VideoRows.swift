import Foundation

// Reading www.youtube.com (WEB client) rows into video models.
//
// Modern YouTube web responses mix legacy renderers (videoRenderer,
// playlistVideoRenderer) with lockupViewModel components. Identity comes from
// navigation endpoints and content IDs; channel names and IDs are extracted
// only where YouTube provides them, never guessed.

enum VideoRows {
    // MARK: - Row parsing entry points

    /// Parses any video row wrapper or renderer into a VideoItem.
    static func video(from node: JSON) -> VideoItem? {
        if node["richItemRenderer"].exists {
            return video(richItem: node["richItemRenderer"])
        }
        if node["content"].exists {
            return video(from: node["content"])
        }
        if node["videoRenderer"].exists {
            return video(renderer: node["videoRenderer"])
        }
        if node["lockupViewModel"].exists {
            return video(lockup: node["lockupViewModel"])
        }
        if node["playlistVideoRenderer"].exists {
            return video(playlistVideo: node["playlistVideoRenderer"])
        }
        if node["playlistPanelVideoRenderer"].exists {
            return video(playlistPanelVideo: node["playlistPanelVideoRenderer"])
        }
        if node["compactVideoRenderer"].exists {
            return video(compactVideo: node["compactVideoRenderer"])
        }
        if node["videoId"].exists && (node["title"].exists || node["headline"].exists) {
            return video(renderer: node)
        }
        if node["contentType"].string == "LOCKUP_CONTENT_TYPE_VIDEO" {
            return video(lockup: node)
        }
        return nil
    }

    // MARK: - videoRenderer

    static func video(renderer: JSON) -> VideoItem? {
        guard let id = renderer["videoId"].nonEmpty ?? renderer["contentId"].nonEmpty else { return nil }
        let title = renderer["title"].text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        let channel = channelName(from: renderer)
        let channelId = channelBrowseId(from: renderer)
        let artwork = renderer["thumbnail"].bestThumbnail
        let durationSeconds = duration(renderer["lengthText"].text)
        let viewCount = renderer["viewCountText"]["simpleText"].nonEmpty
            ?? renderer["viewCountText"].text.nonEmpty
            ?? renderer["shortViewCountText"]["simpleText"].nonEmpty
        let published = renderer["publishedTimeText"]["simpleText"].nonEmpty
            ?? renderer["publishedTimeText"].text.nonEmpty

        let live = isLive(renderer: renderer, duration: durationSeconds, viewCount: viewCount)
        let short = isShort(renderer: renderer, duration: durationSeconds)

        return VideoItem(
            id: id,
            title: title,
            channel: channel,
            channelId: channelId,
            thumbnail: artwork,
            duration: durationSeconds,
            viewCountText: viewCount,
            publishedText: published,
            isLive: live,
            isShort: short
        )
    }

    // MARK: - lockupViewModel

    static func video(lockup: JSON) -> VideoItem? {
        guard let id = lockup["contentId"].nonEmpty else { return nil }
        if let type = lockup["contentType"].nonEmpty, type != "LOCKUP_CONTENT_TYPE_VIDEO" {
            return nil
        }
        let metadata = lockup["metadata"]["lockupMetadataViewModel"]
        let title = metadata["title"]["content"].nonEmpty
            ?? metadata["title"].text.nonEmpty
        guard let title, !title.isEmpty else { return nil }

        let (channel, channelId, viewCount, published) = lockupMetadata(metadata)
        let artwork = image(from: lockup["contentImage"])
        let (durationSeconds, live) = lockupOverlays(lockup["contentImage"])
        let short = (durationSeconds ?? 0) > 0 && (durationSeconds ?? 0) <= 60

        return VideoItem(
            id: id,
            title: title,
            channel: channel,
            channelId: channelId,
            thumbnail: artwork,
            duration: durationSeconds,
            viewCountText: viewCount,
            publishedText: published,
            isLive: live || (viewCount?.lowercased().contains("watching") == true),
            isShort: short
        )
    }

    // MARK: - richItemRenderer

    static func video(richItem: JSON) -> VideoItem? {
        video(from: richItem["content"])
    }

    // MARK: - playlistVideoRenderer

    static func video(playlistVideo: JSON) -> VideoItem? {
        guard let id = playlistVideo["videoId"].nonEmpty else { return nil }
        let title = playlistVideo["title"].text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        let channel = playlistVideo["shortBylineText"].text.trimmingCharacters(in: .whitespacesAndNewlines)
        let channelId = playlistVideo["shortBylineText"].runs.lazy.compactMap {
            $0["navigationEndpoint"]["browseEndpoint"]["browseId"].nonEmpty
        }.first
        let artwork = playlistVideo["thumbnail"].bestThumbnail
        let durationSeconds = duration(playlistVideo["lengthText"].text)

        return VideoItem(
            id: id,
            title: title,
            channel: channel,
            channelId: channelId,
            thumbnail: artwork,
            duration: durationSeconds,
            viewCountText: nil,
            publishedText: nil,
            isLive: false,
            isShort: (durationSeconds ?? 0) > 0 && (durationSeconds ?? 0) <= 60
        )
    }

    // MARK: - playlistPanelVideoRenderer

    static func video(playlistPanelVideo: JSON) -> VideoItem? {
        guard let id = playlistPanelVideo["videoId"].nonEmpty else { return nil }
        let title = playlistPanelVideo["title"].text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        var channel = playlistPanelVideo["longBylineText"].text.trimmingCharacters(in: .whitespacesAndNewlines)
        var channelId = playlistPanelVideo["longBylineText"].runs.lazy.compactMap {
            $0["navigationEndpoint"]["browseEndpoint"]["browseId"].nonEmpty
        }.first
        if channel.isEmpty {
            channel = playlistPanelVideo["shortBylineText"].text.trimmingCharacters(in: .whitespacesAndNewlines)
            channelId = playlistPanelVideo["shortBylineText"].runs.lazy.compactMap {
                $0["navigationEndpoint"]["browseEndpoint"]["browseId"].nonEmpty
            }.first
        }
        let artwork = playlistPanelVideo["thumbnail"].bestThumbnail
        let durationSeconds = duration(playlistPanelVideo["lengthText"].text)

        return VideoItem(
            id: id,
            title: title,
            channel: channel,
            channelId: channelId,
            thumbnail: artwork,
            duration: durationSeconds,
            viewCountText: nil,
            publishedText: nil,
            isLive: false,
            isShort: (durationSeconds ?? 0) > 0 && (durationSeconds ?? 0) <= 60
        )
    }

    // MARK: - compactVideoRenderer (watch up-next legacy)

    static func video(compactVideo: JSON) -> VideoItem? {
        guard let id = compactVideo["videoId"].nonEmpty else { return nil }
        let title = compactVideo["title"].text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        let channel = channelName(from: compactVideo)
        let channelId = channelBrowseId(from: compactVideo)
        let artwork = compactVideo["thumbnail"].bestThumbnail
        let durationSeconds = duration(compactVideo["lengthText"].text)
        let viewCount = compactVideo["viewCountText"]["simpleText"].nonEmpty
            ?? compactVideo["viewCountText"].text.nonEmpty
            ?? compactVideo["shortViewCountText"]["simpleText"].nonEmpty
        let published = compactVideo["publishedTimeText"]["simpleText"].nonEmpty
            ?? compactVideo["publishedTimeText"].text.nonEmpty

        return VideoItem(
            id: id,
            title: title,
            channel: channel,
            channelId: channelId,
            thumbnail: artwork,
            duration: durationSeconds,
            viewCountText: viewCount,
            publishedText: published,
            isLive: isLive(renderer: compactVideo, duration: durationSeconds, viewCount: viewCount),
            isShort: isShort(renderer: compactVideo, duration: durationSeconds)
        )
    }

    // MARK: - Channels & Playlists in search

    static func channel(from node: JSON) -> VideoChannel? {
        if node["channelRenderer"].exists {
            let cr = node["channelRenderer"]
            guard let id = cr["channelId"].nonEmpty
                ?? cr["navigationEndpoint"]["browseEndpoint"]["browseId"].nonEmpty else { return nil }
            let name = cr["title"].text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let avatar = cr["thumbnail"].bestThumbnail
            let subText = cr["videoCountText"]["simpleText"].nonEmpty
                ?? cr["videoCountText"].text.nonEmpty
                ?? cr["subscriberCountText"]["simpleText"].nonEmpty
            return VideoChannel(id: id, name: name, avatar: avatar, subscriberText: subText)
        }
        if node["lockupViewModel"].exists {
            let lockup = node["lockupViewModel"]
            let type = lockup["contentType"].string
            let id = lockup["contentId"].string ?? ""
            guard type == "LOCKUP_CONTENT_TYPE_CHANNEL" || id.hasPrefix("UC") else { return nil }
            let meta = lockup["metadata"]["lockupMetadataViewModel"]
            let name = meta["title"]["content"].nonEmpty ?? meta["title"].text.nonEmpty ?? ""
            guard !name.isEmpty else { return nil }
            let avatar = image(from: lockup["contentImage"])
            let rows = meta["metadata"]["contentMetadataViewModel"]["metadataRows"].array
            let subText = rows.first?["metadataParts"].array.first?["text"]["content"].nonEmpty
            return VideoChannel(id: id, name: name, avatar: avatar, subscriberText: subText)
        }
        return nil
    }

    static func playlist(from node: JSON) -> VideoPlaylistSummary? {
        if node["playlistRenderer"].exists {
            let pr = node["playlistRenderer"]
            guard let id = pr["playlistId"].nonEmpty else { return nil }
            let title = pr["title"].text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let channel = pr["shortBylineText"].text.nonEmpty ?? pr["longBylineText"].text.nonEmpty
            let thumbnail = pr["thumbnails"].bestThumbnail ?? pr["thumbnailRenderer"].bestThumbnail
            let countText = pr["videoCountText"].text
            let count = pr["videoCount"].int ?? parseItemCount(from: countText)
            return VideoPlaylistSummary(id: id, title: title, channel: channel, thumbnail: thumbnail, itemCount: count)
        }
        if node["lockupViewModel"].exists {
            let lockup = node["lockupViewModel"]
            let type = lockup["contentType"].string
            let id = lockup["contentId"].string ?? ""
            guard type == "LOCKUP_CONTENT_TYPE_PLAYLIST" || type == "LOCKUP_CONTENT_TYPE_COURSE" || id.hasPrefix("PL") else { return nil }
            let meta = lockup["metadata"]["lockupMetadataViewModel"]
            let title = meta["title"]["content"].nonEmpty ?? meta["title"].text.nonEmpty ?? ""
            guard !title.isEmpty else { return nil }
            let rows = meta["metadata"]["contentMetadataViewModel"]["metadataRows"].array
            let channel = rows.first?["metadataParts"].array.first?["text"]["content"].nonEmpty
            let thumbnail = image(from: lockup["contentImage"])
            let count = parseItemCount(from: lockup["contentImage"]) ?? parseItemCount(from: meta)
            return VideoPlaylistSummary(id: id, title: title, channel: channel, thumbnail: thumbnail, itemCount: count)
        }
        return nil
    }

    // MARK: - Helpers

    static func channelName(from renderer: JSON) -> String {
        let long = renderer["longBylineText"].text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !long.isEmpty { return long }
        let owner = renderer["ownerText"].text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !owner.isEmpty { return owner }
        let short = renderer["shortBylineText"].text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !short.isEmpty { return short }
        return ""
    }

    static func channelBrowseId(from renderer: JSON) -> String? {
        for key in ["longBylineText", "ownerText", "shortBylineText"] {
            for run in renderer[key].runs {
                if let browseId = run["navigationEndpoint"]["browseEndpoint"]["browseId"].nonEmpty {
                    return browseId
                }
            }
        }
        if let browseId = renderer["channelThumbnailSupportedRenderers"]["channelThumbnailWithLinkRenderer"]["navigationEndpoint"]["browseEndpoint"]["browseId"].nonEmpty {
            return browseId
        }
        if let navBrowseId = renderer["navigationEndpoint"]["browseEndpoint"]["browseId"].nonEmpty, navBrowseId.hasPrefix("UC") {
            return navBrowseId
        }
        return nil
    }

    static func duration(_ text: String) -> TimeInterval? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard (2...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        return parts.reduce(0) { $0 * 60 + (Double($1) ?? 0) }
    }

    static func isLive(renderer: JSON, duration: TimeInterval?, viewCount: String?) -> Bool {
        for badge in renderer["badges"].array {
            let label = badge["metadataBadgeRenderer"]["label"].string ?? ""
            let style = badge["metadataBadgeRenderer"]["style"].string ?? ""
            if label.uppercased().contains("LIVE") || style.uppercased().contains("LIVE") {
                return true
            }
        }
        for overlay in renderer["thumbnailOverlays"].array {
            let status = overlay["thumbnailOverlayTimeStatusRenderer"]["style"].string ?? ""
            let text = overlay["thumbnailOverlayTimeStatusRenderer"]["text"].text.uppercased()
            if status.contains("LIVE") || text.contains("LIVE") {
                return true
            }
        }
        if (duration == nil || duration == 0), let viewCount, viewCount.lowercased().contains("watching") {
            return true
        }
        return false
    }

    static func isShort(renderer: JSON, duration: TimeInterval?) -> Bool {
        if let dur = duration, dur > 0, dur <= 60 {
            return true
        }
        let url = renderer["navigationEndpoint"]["commandMetadata"]["webCommandMetadata"]["url"].string ?? ""
        if url.contains("/shorts/") {
            return true
        }
        if renderer["navigationEndpoint"]["reelWatchEndpoint"].exists {
            return true
        }
        return false
    }

    static func lockupMetadata(_ metadata: JSON) -> (channel: String, channelId: String?, viewCount: String?, published: String?) {
        var channel = ""
        var channelId: String? = nil
        var viewCount: String? = nil
        var published: String? = nil

        let rows = metadata["metadata"]["contentMetadataViewModel"]["metadataRows"].array
        if let firstRow = rows.first {
            let parts = firstRow["metadataParts"].array
            if let firstPart = parts.first {
                let text = firstPart["text"]["content"].string ?? ""
                if !text.lowercased().contains("view") && !text.lowercased().contains("ago") {
                    channel = text
                    for commandRun in firstPart["text"]["commandRuns"].array {
                        if let id = commandRun["onTap"]["innertubeCommand"]["browseEndpoint"]["browseId"].nonEmpty {
                            channelId = id
                            break
                        }
                    }
                }
            }
        }

        if channelId == nil {
            channelId = metadata["image"]["decoratedAvatarViewModel"]["rendererContext"]["commandContext"]["onTap"]["innertubeCommand"]["browseEndpoint"]["browseId"].nonEmpty
        }

        for row in rows {
            for part in row["metadataParts"].array {
                let text = part["text"]["content"].string ?? ""
                let lower = text.lowercased()
                if lower.contains("view") || lower.contains("watching") {
                    viewCount = text
                } else if lower.contains("ago") || lower.contains("streamed") || lower.contains("premiered") {
                    published = text
                }
            }
        }

        return (channel, channelId, viewCount, published)
    }

    static func lockupOverlays(_ contentImage: JSON) -> (duration: TimeInterval?, isLive: Bool) {
        var durationSeconds: TimeInterval? = nil
        var isLive = false

        for overlay in contentImage["thumbnailViewModel"]["overlays"].array {
            if overlay["thumbnailBottomOverlayViewModel"].exists {
                let bottom = overlay["thumbnailBottomOverlayViewModel"]
                for badge in bottom["badges"].array {
                    let bvm = badge["thumbnailBadgeViewModel"]
                    let text = bvm["text"].string ?? ""
                    let style = bvm["badgeStyle"].string ?? ""
                    if text.uppercased().contains("LIVE") || style.uppercased().contains("LIVE") {
                        isLive = true
                    } else if let dur = duration(text) {
                        durationSeconds = dur
                    }
                }
            }
            if overlay["thumbnailOverlayTimeStatusRenderer"].exists {
                let timeStatus = overlay["thumbnailOverlayTimeStatusRenderer"]
                let text = timeStatus["text"].text
                let style = timeStatus["style"].string ?? ""
                if text.uppercased().contains("LIVE") || style.uppercased().contains("LIVE") {
                    isLive = true
                } else if let dur = duration(text) {
                    durationSeconds = dur
                }
            }
        }

        return (durationSeconds, isLive)
    }

    static func image(from node: JSON) -> Artwork? {
        let sources = node["thumbnailViewModel"]["image"]["sources"].array
        if !sources.isEmpty {
            let best = sources.max { ($0["width"].int ?? 0) < ($1["width"].int ?? 0) }
            if let url = best?["url"].string.flatMap(URL.imageURL) {
                return Artwork(url: url, width: best?["width"].int ?? 0, height: best?["height"].int ?? 0)
            }
        }
        let directSources = node["sources"].array
        if !directSources.isEmpty {
            let best = directSources.max { ($0["width"].int ?? 0) < ($1["width"].int ?? 0) }
            if let url = best?["url"].string.flatMap(URL.imageURL) {
                return Artwork(url: url, width: best?["width"].int ?? 0, height: best?["height"].int ?? 0)
            }
        }
        return node.bestThumbnail
    }

    static func parseItemCount(from text: String) -> Int? {
        let digits = text.filter(\.isNumber)
        return digits.isEmpty ? nil : Int(digits)
    }

    static func parseItemCount(from node: JSON) -> Int? {
        for s in node.strings("content") + node.strings("text") + node.strings("simpleText") {
            if s.lowercased().contains("video") || s.lowercased().contains("track") {
                if let count = parseItemCount(from: s) { return count }
            }
        }
        return nil
    }
}
