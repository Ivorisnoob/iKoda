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
        let channelId = owner["navigationEndpoint"]["browseEndpoint"]["browseId"].nonEmpty
        let channel = owner.exists
            ? ChannelRef(id: channelId, name: owner["title"].text, avatar: owner["thumbnail"].bestThumbnail)
            : nil
        let counts = primary["viewCount"]["videoViewCountRenderer"]
        let isLive = counts["isLive"].bool == true
        let video = Video(id: id, title: title, channel: channel, views: counts["shortViewCount"].text.nonEmptyString,
                          published: primary["relativeDateText"].text.nonEmptyString, isLive: isLive)
        let related = root.first("twoColumnWatchNextResults")["secondaryResults"]["secondaryResults"]["results"]
        let comments = root.objects("engagementPanelSectionListRenderer")
            .first { $0["panelIdentifier"].string == "engagement-panel-comments-section" } ?? .null
        return WatchPage(
            video: video,
            viewCount: counts["viewCount"].text.nonEmptyString,
            date: primary["dateText"].text.nonEmptyString,
            description: secondary["attributedDescription"]["content"].string ?? "",
            subscribers: owner["subscriberCountText"].text.nonEmptyString,
            isSubscribed: isSubscribed(root, to: channelId),
            likeCounts: likeCounts(primary),
            likeStatus: likeStatus(root, videoId: id),
            commentCount: comments.first("engagementPanelTitleHeaderRenderer")["contextualInfo"].text.nonEmptyString,
            commentsToken: commentsToken(root),
            autoplayId: root.first("autoplayVideo")["watchEndpoint"]["videoId"].nonEmpty,
            related: page(related)
        )
    }

    /// The count on the video's own like button for each rating. A creator hiding it leaves the
    /// button saying "Like", which isn't a count.
    static func likeCounts(_ primary: JSON) -> [LikeStatus: String] {
        let entity = primary.first("likeCountEntity")
        var counts: [LikeStatus: String] = [:]
        for (status, key) in [(LikeStatus.indifferent, "likeCountIfIndifferent"), (.like, "likeCountIfLiked"), (.dislike, "likeCountIfDisliked")] {
            if let count = entity[key]["content"].nonEmpty, count.contains(where: \.isNumber) { counts[status] = count }
        }
        return counts
    }

    /// The response draws a like button in several places (under the video, in full screen),
    /// each with its own status entity: the one keyed to this video is the video's.
    static func likeStatus(_ root: JSON, videoId: String) -> LikeStatus {
        let entities = root.objects("likeStatusEntity")
        let own = entities.first { entityKey($0["key"].string, names: videoId) } ?? entities.first
        return switch own?["likeStatus"].string {
        case "LIKE": .like
        case "DISLIKE": .dislike
        default: .indifferent
        }
    }

    /// Whether the account follows `channelId`. The current Subscribe button keeps its state in
    /// a `subscriptionStateEntity` (frameworkUpdates), the older one in `subscribeButtonRenderer`;
    /// both are live. A page draws buttons for other channels too (featured ones, collaborators),
    /// so only a state naming this channel counts, and none is nil rather than false.
    static func isSubscribed(_ root: JSON, to channelId: String?) -> Bool? {
        guard let channelId else { return nil }
        if let entity = root.objects("subscriptionStateEntity").first(where: { entityKey($0["key"].string, names: channelId) }),
           let subscribed = entity["subscribed"].bool {
            return subscribed
        }
        if let button = root.objects("subscribeButtonRenderer").first(where: { $0["channelId"].string == channelId }),
           let subscribed = button["subscribed"].bool {
            return subscribed
        }
        return nil
    }

    /// A framework entity's key is URL-encoded base64 with the id of what it describes inside
    /// it in plain ASCII (a channel's for a subscription, a video's for a like) [verified
    /// October 2026, Koda for Android].
    static func entityKey(_ key: String?, names id: String) -> Bool {
        guard let key = key?.removingPercentEncoding, !id.isEmpty else { return false }
        var base64 = key.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64), let text = String(data: data, encoding: .isoLatin1) else { return false }
        return text.contains(id)
    }

    /// The comments section's token. It holds two; the longer opens the full list.
    static func commentsToken(_ root: JSON) -> String? {
        root.objects("itemSectionRenderer")
            .filter { $0["sectionIdentifier"].string == "comment-item-section" }
            .flatMap { $0.objects("continuationCommand").compactMap { $0["token"].nonEmpty } }
            .max { $0.count < $1.count }
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
        // The tab that is open is the one asked for; its grid is the page's videos.
        let tabRenderers = root.objects("tabRenderer")
        let open = tabRenderers.first { $0["selected"].bool == true } ?? root
        let tabs = tabRenderers.compactMap(tab)
        let preview = header.first("descriptionPreviewViewModel")
        return ChannelPage(
            channel: summary,
            banner: bestSource(header.first("imageBannerViewModel")),
            description: preview["description"]["content"].nonEmpty,
            videoCount: videoCount,
            isSubscribed: isSubscribed(root, to: id),
            // The tick is an image run on the title, named by a client resource, not a label.
            isVerified: header["title"].strings("imageName").contains { $0.hasPrefix("CHECK_CIRCLE") },
            tabs: tabs,
            tab: tab(open)?.kind ?? .videos,
            sorts: sorts(open),
            aboutToken: preview.first("continuationCommand")["token"].nonEmpty,
            videos: withChannel(feed(open), summary.ref)
        )
    }

    /// A tab Koda shows; Home, Shorts, Playlists, Posts and the rest aren't.
    static func tab(_ renderer: JSON) -> ChannelTab? {
        guard let params = renderer["endpoint"]["browseEndpoint"]["params"].nonEmpty?.removingPercentEncoding else { return nil }
        let kind: ChannelTabKind? = switch renderer["title"].string {
        case "Videos": .videos
        case "Live": .live
        default: nil
        }
        return kind.map { ChannelTab(kind: $0, params: params) }
    }

    /// Latest, Popular and Oldest: chips over the tab's grid, each a continuation that reloads it.
    static func sorts(_ tab: JSON) -> [ChannelSort] {
        tab.first("chipBarViewModel")["chips"].array.compactMap { chip in
            let chip = chip["chipViewModel"]
            guard let title = chip["text"].nonEmpty, let token = chip["tapCommand"].first("continuationCommand")["token"].nonEmpty else { return nil }
            return ChannelSort(title: title, token: token, isSelected: chip["selected"].bool == true)
        }
    }

    /// A sort chip's answer: the grid's header (the chips, now with this one selected) and its
    /// body, each in a `reloadContinuationItemsCommand`.
    static func reloaded(_ root: JSON) -> (videos: VideoPage, sorts: [ChannelSort]) {
        var videos = VideoPage()
        var sorts: [ChannelSort] = []
        for action in root["onResponseReceivedActions"].array {
            let command = action["reloadContinuationItemsCommand"]
            switch command["slot"].string {
            case "RELOAD_CONTINUATION_SLOT_BODY": videos = page(command["continuationItems"])
            case "RELOAD_CONTINUATION_SLOT_HEADER": sorts = self.sorts(command)
            default: continue
            }
        }
        return (videos, sorts)
    }

    /// The About panel, reached by the header description's continuation.
    static func about(_ root: JSON) -> ChannelAbout? {
        let about = root.first("aboutChannelViewModel")
        guard about.exists else { return nil }
        let links = about["links"].array.compactMap { item -> ChannelLink? in
            let link = item["channelExternalLinkViewModel"]
            guard let label = link["link"]["content"].nonEmpty,
                  let url = unwrapRedirect(link["link"].first("urlEndpoint")["url"].string) ?? URL(string: "https://\(label)") else { return nil }
            return ChannelLink(title: link["title"]["content"].nonEmpty ?? label, label: label, url: url)
        }
        return ChannelAbout(description: about["description"].nonEmpty, country: about["country"].nonEmpty,
                            subscribers: about["subscriberCountText"].nonEmpty, views: about["viewCountText"].nonEmpty,
                            joined: about["joinedDateText"]["content"].nonEmpty, videoCount: about["videoCountText"].nonEmpty,
                            links: links)
    }

    /// YouTube sends outside links through `youtube.com/redirect?q=<the link>`.
    static func unwrapRedirect(_ string: String?) -> URL? {
        guard let string, let components = URLComponents(string: string) else { return nil }
        if components.path == "/redirect", let target = components.queryItems?.first(where: { $0.name == "q" })?.value {
            return URL(string: target)
        }
        return components.scheme?.hasPrefix("http") == true ? components.url : nil
    }

    /// A page of comments: `commentEntityPayload`s in the framework updates, in order (replies
    /// left out), and the token at the end of the list for the next page.
    static func comments(_ root: JSON) -> CommentsPage {
        let comments = root.objects("commentEntityPayload").compactMap { payload -> VideoComment? in
            let properties = payload["properties"]
            guard let id = properties["commentId"].nonEmpty, (properties["replyLevel"].int ?? 0) == 0 else { return nil }
            let author = payload["author"]
            let toolbar = payload["toolbar"]
            return VideoComment(id: id, author: author["displayName"].string ?? "", authorChannelId: author["channelId"].nonEmpty,
                                avatar: author["avatarThumbnailUrl"].string.flatMap(URL.imageURL),
                                text: properties["content"]["content"].string ?? "", published: properties["publishedTime"].string ?? "",
                                likes: toolbar["likeCountNotliked"].string ?? "", replies: toolbar["replyCount"].string ?? "",
                                isCreator: author["isCreator"].bool == true, isVerified: author["isVerified"].bool == true)
        }
        var token: String?
        for key in ["onResponseReceivedEndpoints", "onResponseReceivedActions"] {
            for action in root[key].array {
                let items = action["reloadContinuationItemsCommand"]["continuationItems"].exists
                    ? action["reloadContinuationItemsCommand"]["continuationItems"]
                    : action["appendContinuationItemsAction"]["continuationItems"]
                if let found = Self.token(items) { token = found }
            }
        }
        var seen = Set<String>()
        return CommentsPage(comments: comments.filter { seen.insert($0.id).inserted }, continuation: token)
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

    /// The continuation at the end of a list (wrapped lists keep it at their own end). Older
    /// lists end with a `continuationItemRenderer`, playlists now with a `continuationItemViewModel`
    /// whose token sits in a command nested in a command [verified October 2026].
    static func token(_ list: JSON) -> String? {
        for item in list.array.reversed() {
            if let token = item["continuationItemRenderer"]["continuationEndpoint"].first("continuationCommand")["token"].nonEmpty {
                return token
            }
            if let token = item["continuationItemViewModel"]["continuationCommand"]["innertubeCommand"]
                .first("continuationCommand")["token"].nonEmpty {
                return token
            }
        }
        return nil
    }

    /// A topic page (Music, News, Live…): its shelves of videos, each with its title, in order.
    /// Shelves with no videos (news posts, Shorts) are left out.
    static func shelves(_ root: JSON) -> [VideoShelf] {
        (root.objects("richShelfRenderer") + root.objects("shelfRenderer")).compactMap { shelf in
            let title = shelf["title"].text
            let videos = page(shelf["contents"].exists ? shelf["contents"] : shelf["content"]).videos
            guard !title.isEmpty, !videos.isEmpty else { return nil }
            return VideoShelf(title: title, videos: videos)
        }
    }

    /// A playlist's page (Watch Later, Liked videos, any other): its title and videos, in the
    /// first section's list. Most are lockups like Up Next's; Watch Later still comes as
    /// `playlistVideoRenderer` rows wrapped in a `playlistVideoListRenderer` [verified October 2026].
    static func playlist(_ root: JSON) -> VideoPlaylistPage? {
        let header = root.first("pageHeaderViewModel")
        let title = header["title"].strings("content").first ?? root.first("playlistMetadataRenderer")["title"].string ?? ""
        let sections = root.first("sectionListRenderer")["contents"]
        var list = sections[0]["itemSectionRenderer"]["contents"]
        // Unwrapped, so its continuation is found at the list's own end.
        if list[0]["playlistVideoListRenderer"].exists { list = list[0]["playlistVideoListRenderer"]["contents"] }
        guard !title.isEmpty || list.exists else { return nil }
        var videos = page(list)
        // The first page's continuation sits beside the list, not at its end.
        videos.continuation = videos.continuation ?? token(sections)
        return VideoPlaylistPage(title: title, videos: videos)
    }

    /// The channels the account subscribes to, as YouTube's own sidebar lists them (most
    /// recently active first), from the guide. Signed out there are none.
    static func subscriptions(_ root: JSON) -> [ChannelRef] {
        root.objects("guideSubscriptionsSectionRenderer").flatMap { $0.objects("guideEntryRenderer") }.compactMap { entry in
            guard let id = entry["navigationEndpoint"]["browseEndpoint"]["browseId"].nonEmpty, id.hasPrefix("UC"),
                  let name = entry["formattedTitle"]["simpleText"].nonEmpty ?? entry["title"].nonEmpty else { return nil }
            return ChannelRef(id: id, name: name, avatar: entry["thumbnail"].bestThumbnail)
        }
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
                case "playlistVideoRenderer":
                    if let video = video(playlistRow: JSON(dict[key])) { out.append(video) }
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

    /// Watch Later's row: `playlistVideoRenderer`. Views and age share one line ("150K views",
    /// " • ", "1 day ago"). Deleted and private videos stay in the list but can't be played.
    static func video(playlistRow row: JSON) -> Video? {
        guard let id = row["videoId"].nonEmpty, row["isPlayable"].bool != false else { return nil }
        let owner = row["shortBylineText"].runs.first ?? .null
        let channel = owner.exists
            ? ChannelRef(id: owner["navigationEndpoint"]["browseEndpoint"]["browseId"].nonEmpty, name: owner["text"].string ?? "", avatar: nil)
            : nil
        let info = row["videoInfo"].runs.compactMap { $0["text"].string?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0 != "•" }
        let isLive = row["thumbnailOverlays"].array.contains { $0["thumbnailOverlayTimeStatusRenderer"]["style"].string == "LIVE" }
        return Video(id: id, title: row["title"].text, channel: channel, thumbnail: row["thumbnail"].bestThumbnail,
                     duration: Rows.duration(row["lengthText"].text), views: info.first,
                     published: isLive ? nil : info.dropFirst().first, isLive: isLive)
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
