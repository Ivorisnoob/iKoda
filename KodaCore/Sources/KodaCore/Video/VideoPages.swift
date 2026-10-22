import Foundation

/// WEB (www.youtube.com) responses → video models. [verified October 2026, signed out]
///
/// Two shapes of video row are current: search still sends `videoRenderer`; the watch page's Up
/// Next, channels and the signed-in Home send `lockupViewModel`. Each page's rows and its
/// continuation are read from that page's own list, never the whole response: a response also
/// holds end screens, menus and other panels' tokens (the channel page's last token is its About
/// panel's, search's is a filter's).
enum VideoPages {
    // MARK: Pages

    /// Home or the subscriptions feed: a rich grid.
    static func feed(_ root: JSON) -> VideoPage {
        page(root.first("richGridRenderer")["contents"])
    }

    static func search(_ root: JSON) -> VideoSearchResults {
        let list = root.first("twoColumnSearchResultsRenderer")["primaryContents"]["sectionListRenderer"]["contents"]
        return VideoSearchResults(channels: channels(list), videos: page(list))
    }

    /// The next page of any list: Home, search, a channel's videos or Up Next.
    static func continuation(_ root: JSON) -> VideoPage {
        for key in ["onResponseReceivedActions", "onResponseReceivedEndpoints", "onResponseReceivedCommands"] {
            for action in root[key].array where action["appendContinuationItemsAction"].exists {
                return page(action["appendContinuationItemsAction"]["continuationItems"])
            }
        }
        return VideoPage()
    }

    static func watch(_ root: JSON, id: String) -> WatchPage? {
        let primary = root.first("videoPrimaryInfoRenderer")
        let secondary = root.first("videoSecondaryInfoRenderer")
        let title = primary["title"].text
        guard !title.isEmpty else { return nil }
        let owner = secondary["owner"]["videoOwnerRenderer"]
        let channel = owner.exists
            ? ChannelRef(id: owner["navigationEndpoint"]["browseEndpoint"]["browseId"].nonEmpty, name: owner["title"].text,
                         avatar: owner["thumbnail"].bestThumbnail)
            : nil
        let counts = primary["viewCount"]["videoViewCountRenderer"]
        let isLive = counts["isLive"].bool == true
        let video = Video(id: id, title: title, channel: channel, views: counts["shortViewCount"].text.nonEmptyString,
                          published: primary["relativeDateText"].text.nonEmptyString, isLive: isLive)
        let related = root.first("twoColumnWatchNextResults")["secondaryResults"]["secondaryResults"]["results"]
        return WatchPage(
            video: video,
            viewCount: counts["viewCount"].text.nonEmptyString,
            date: primary["dateText"].text.nonEmptyString,
            description: secondary["attributedDescription"]["content"].string ?? "",
            subscribers: owner["subscriberCountText"].text.nonEmptyString,
            isSubscribed: root.first("subscribeButtonRenderer")["subscribed"].bool ?? false,
            related: page(related)
        )
    }

    static func channel(_ root: JSON, id: String) -> ChannelPage? {
        let header = root.first("pageHeaderViewModel")
        let name = header["title"].strings("content").first ?? root.first("channelMetadataRenderer")["title"].string ?? ""
        guard !name.isEmpty else { return nil }
        let parts = header.first("contentMetadataViewModel")["metadataRows"].array
            .flatMap { $0["metadataParts"].array }
            .compactMap { $0["text"]["content"].nonEmpty }
        let handle = parts.first { $0.hasPrefix("@") }
        let subscribers = parts.first { $0.localizedCaseInsensitiveContains("subscriber") }
        let videoCount = parts.first { $0.localizedCaseInsensitiveContains("video") }
        let summary = ChannelSummary(id: id, name: name, handle: handle, subscribers: subscribers,
                                     avatar: bestSource(header.first("decoratedAvatarViewModel")))
        // The tab that is open is the one asked for (Videos); its grid is the page's videos.
        let tab = root.objects("tabRenderer").first { $0["selected"].bool == true } ?? root
        return ChannelPage(
            channel: summary,
            banner: bestSource(header.first("imageBannerViewModel")),
            description: header.first("descriptionPreviewViewModel")["description"]["content"].nonEmpty,
            videoCount: videoCount,
            isSubscribed: root.first("subscribeButtonRenderer")["subscribed"].bool ?? false,
            videos: withChannel(feed(tab), summary.ref)
        )
    }

    /// A channel's own rows leave the channel out; it's the page's.
    static func withChannel(_ page: VideoPage, _ channel: ChannelRef) -> VideoPage {
        var page = page
        page.videos = page.videos.map { video in
            var video = video
            if video.channel == nil { video.channel = channel }
            return video
        }
        return page
    }

    // MARK: Lists

    /// The videos in a list, in order, and the list's own continuation.
    static func page(_ list: JSON) -> VideoPage {
        var videos: [Video] = []
        collectVideos(list.raw, into: &videos)
        var seen = Set<String>()
        return VideoPage(videos: videos.filter { seen.insert($0.id).inserted }, continuation: token(list))
    }

    /// The continuation at the end of a list (wrapped lists keep it at their own end).
    static func token(_ list: JSON) -> String? {
        for item in list.array.reversed() {
            if let token = item["continuationItemRenderer"]["continuationEndpoint"].first("continuationCommand")["token"].nonEmpty {
                return token
            }
        }
        return nil
    }

    private static func channels(_ list: JSON) -> [ChannelSummary] {
        var seen = Set<String>()
        return list.objects("channelRenderer").compactMap(channel(renderer:)).filter { seen.insert($0.id).inserted }
    }

    /// Video rows in document order. Shorts (`shortsLockupViewModel`, reel shelves) are left out:
    /// they're a format of their own, not something to watch here.
    private static func collectVideos(_ node: Any?, into out: inout [Video]) {
        if let dict = node as? [String: Any] {
            // An object holds one renderer in practice; sorted keys keep the walk deterministic.
            for key in dict.keys.sorted() {
                switch key {
                case "videoRenderer":
                    if let video = video(renderer: JSON(dict[key])) { out.append(video) }
                case "lockupViewModel":
                    if let video = video(lockup: JSON(dict[key])) { out.append(video) }
                case "reelShelfRenderer", "shortsLockupViewModel", "continuationItemRenderer":
                    continue
                default:
                    collectVideos(dict[key], into: &out)
                }
            }
        } else if let array = node as? [Any] {
            for element in array { collectVideos(element, into: &out) }
        }
    }

    // MARK: Rows

    /// Search's row: `videoRenderer`.
    static func video(renderer row: JSON) -> Video? {
        guard let id = row["videoId"].nonEmpty else { return nil }
        let owner = row["ownerText"].runs.first ?? row["longBylineText"].runs.first ?? .null
        let channel = owner.exists
            ? ChannelRef(id: owner["navigationEndpoint"]["browseEndpoint"]["browseId"].nonEmpty, name: owner["text"].string ?? "",
                         avatar: row["channelThumbnailSupportedRenderers"].bestThumbnail)
            : nil
        let isLive = row["badges"].array.contains { $0["metadataBadgeRenderer"]["style"].string == "BADGE_STYLE_TYPE_LIVE_NOW" }
        return Video(id: id, title: row["title"].text, channel: channel, thumbnail: row["thumbnail"].bestThumbnail,
                     duration: Rows.duration(row["lengthText"].text),
                     views: (row["shortViewCountText"].text.nonEmptyString ?? row["viewCountText"].text.nonEmptyString),
                     published: row["publishedTimeText"].text.nonEmptyString, isLive: isLive)
    }

    /// The watch page's, channels' and Home's row: `lockupViewModel` of content type video.
    static func video(lockup: JSON) -> Video? {
        guard lockup["contentType"].string == "LOCKUP_CONTENT_TYPE_VIDEO", let id = lockup["contentId"].nonEmpty,
              lockup["rendererContext"].first("watchEndpoint").exists else { return nil }
        let meta = lockup["metadata"]["lockupMetadataViewModel"]
        let rows = meta["metadata"]["contentMetadataViewModel"]["metadataRows"].array
        // Two lines: the channel, then views and age. On a channel's own tabs there is one line,
        // views and age, and the channel is the page's.
        let firstParts = rows.count > 1 ? rows[0]["metadataParts"].array : []
        let channelName = firstParts.first?["text"]["content"].nonEmpty
        let channelId = firstParts.first?["text"].first("browseEndpoint")["browseId"].nonEmpty ?? meta["image"].first("browseEndpoint")["browseId"].nonEmpty
        let channel = channelName.map { ChannelRef(id: channelId, name: $0, avatar: bestSource(meta["image"].first("avatarViewModel"))) }
        let second = rows.last?["metadataParts"].array.compactMap { $0["text"]["content"].nonEmpty } ?? []
        let badges = lockup["contentImage"].objects("thumbnailBadgeViewModel").compactMap { $0["text"].nonEmpty }
        let duration = badges.lazy.compactMap(Rows.duration).first
        let watching = second.first { $0.localizedCaseInsensitiveContains("watching") }
        let isLive = watching != nil || badges.contains { $0.uppercased() == "LIVE" }
        var views = second.first
        // Lockups give the bare count ("87K"); say what it counts, as the other rows do.
        if let count = views, watching == nil, count.first?.isNumber == true, !count.localizedCaseInsensitiveContains("view") {
            views = count == "1" ? "1 view" : "\(count) views"
        }
        return Video(id: id, title: meta["title"]["content"].string ?? "", channel: channel,
                     thumbnail: bestSource(lockup["contentImage"]), duration: duration, views: views,
                     published: isLive ? nil : second.dropFirst().first, isLive: isLive)
    }

    static func channel(renderer row: JSON) -> ChannelSummary? {
        guard let id = row["channelId"].nonEmpty else { return nil }
        // Search swaps them: the handle sits in subscriberCountText, the count in videoCountText.
        let texts = [row["subscriberCountText"].text, row["videoCountText"].text].filter { !$0.isEmpty }
        return ChannelSummary(id: id, name: row["title"].text, handle: texts.first { $0.hasPrefix("@") },
                              subscribers: texts.first { $0.localizedCaseInsensitiveContains("subscriber") },
                              avatar: row["thumbnail"].bestThumbnail)
    }

    /// The widest image of the first `sources` list below a view model.
    static func bestSource(_ node: JSON) -> Artwork? {
        guard let list = firstSources(node.raw) else { return nil }
        let best = list.map(JSON.init).max { ($0["width"].int ?? 0) < ($1["width"].int ?? 0) }
        guard let url = best?["url"].string.flatMap(URL.imageURL) else { return nil }
        return Artwork(url: url, width: best?["width"].int ?? 0, height: best?["height"].int ?? 0)
    }

    private static func firstSources(_ node: Any?) -> [Any]? {
        if let dict = node as? [String: Any] {
            if let list = dict["sources"] as? [Any], !list.isEmpty { return list }
            for key in dict.keys.sorted() {
                if let found = firstSources(dict[key]) { return found }
            }
        } else if let array = node as? [Any] {
            for element in array {
                if let found = firstSources(element) { return found }
            }
        }
        return nil
    }
}
