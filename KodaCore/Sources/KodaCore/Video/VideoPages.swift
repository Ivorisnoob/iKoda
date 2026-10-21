import Foundation

// Whole www.youtube.com (WEB client) responses read into video pages.

enum VideoPages {
    // MARK: - Browse Feed (Home / what_to_watch)

    static func feed(_ root: JSON) -> VideoFeed {
        var shelves: [VideoShelf] = []
        var topLevelItems: [VideoItem] = []
        var continuation: String? = nil

        let gridContents = root["contents"]["twoColumnBrowseResultsRenderer"]["tabs"].array.first?["tabRenderer"]["content"]["richGridRenderer"]["contents"].array
            ?? root["contents"]["singleColumnBrowseResultsRenderer"]["tabs"].array.first?["tabRenderer"]["content"]["richGridRenderer"]["contents"].array
            ?? root.first("richGridRenderer")["contents"].array

        for entry in gridContents {
            if entry["richItemRenderer"].exists {
                if let item = VideoRows.video(from: entry["richItemRenderer"]) {
                    topLevelItems.append(item)
                }
            } else if entry["richSectionRenderer"].exists {
                let sectionContent = entry["richSectionRenderer"]["content"]
                if sectionContent["richShelfRenderer"].exists {
                    let shelf = sectionContent["richShelfRenderer"]
                    let title = shelf["title"].text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let items = shelf["contents"].array.compactMap { VideoRows.video(from: $0) }
                    if !items.isEmpty {
                        let id = shelf["shelfId"].string ?? UUID().uuidString
                        shelves.append(VideoShelf(id: id, title: title.isEmpty ? "Shelf" : title, items: items))
                    }
                } else if sectionContent["shelfRenderer"].exists {
                    let shelf = sectionContent["shelfRenderer"]
                    let title = shelf["title"].text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let items = shelf["contents"].array.compactMap { VideoRows.video(from: $0) }
                    if !items.isEmpty {
                        let id = shelf["shelfId"].string ?? UUID().uuidString
                        shelves.append(VideoShelf(id: id, title: title.isEmpty ? "Shelf" : title, items: items))
                    }
                }
            } else if entry["continuationItemRenderer"].exists {
                continuation = continuationToken(entry["continuationItemRenderer"])
            }
        }

        if !topLevelItems.isEmpty {
            shelves.insert(VideoShelf(id: "feed-recommended", title: "Recommended", items: topLevelItems), at: 0)
        }

        if continuation == nil {
            continuation = continuationToken(root)
        }

        return VideoFeed(shelves: shelves, continuation: continuation)
    }

    static func feedContinuation(_ root: JSON) -> (shelves: [VideoShelf], continuation: String?) {
        var shelves: [VideoShelf] = []
        var items: [VideoItem] = []
        var continuation: String? = nil

        let continuationItems = root["onResponseReceivedActions"].array.first?["appendContinuationItemsAction"]["continuationItems"].array
            ?? root["onResponseReceivedEndpoints"].array.first?["appendContinuationItemsAction"]["continuationItems"].array
            ?? root.first("appendContinuationItemsAction")["continuationItems"].array

        for entry in continuationItems {
            if entry["richItemRenderer"].exists {
                if let item = VideoRows.video(from: entry["richItemRenderer"]) {
                    items.append(item)
                }
            } else if entry["richSectionRenderer"].exists {
                let sectionContent = entry["richSectionRenderer"]["content"]
                if sectionContent["richShelfRenderer"].exists {
                    let shelf = sectionContent["richShelfRenderer"]
                    let title = shelf["title"].text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let shelfItems = shelf["contents"].array.compactMap { VideoRows.video(from: $0) }
                    if !shelfItems.isEmpty {
                        shelves.append(VideoShelf(id: UUID().uuidString, title: title.isEmpty ? "Shelf" : title, items: shelfItems))
                    }
                }
            } else if entry["continuationItemRenderer"].exists {
                continuation = continuationToken(entry["continuationItemRenderer"])
            }
        }

        if !items.isEmpty {
            shelves.insert(VideoShelf(id: UUID().uuidString, title: "", items: items), at: 0)
        }

        if continuation == nil {
            continuation = continuationToken(root)
        }

        return (shelves, continuation)
    }

    // MARK: - Search

    static func search(_ root: JSON) -> VideoSearchResults {
        var videos: [VideoItem] = []
        var channels: [VideoChannel] = []
        var playlists: [VideoPlaylistSummary] = []
        var continuation: String? = nil

        let sections = root["contents"]["twoColumnSearchResultsRenderer"]["primaryContents"]["sectionListRenderer"]["contents"].array

        for section in sections {
            if section["itemSectionRenderer"].exists {
                for item in section["itemSectionRenderer"]["contents"].array {
                    if let v = VideoRows.video(from: item) {
                        videos.append(v)
                    } else if let c = VideoRows.channel(from: item) {
                        channels.append(c)
                    } else if let p = VideoRows.playlist(from: item) {
                        playlists.append(p)
                    }
                }
            } else if section["continuationItemRenderer"].exists {
                continuation = continuationToken(section["continuationItemRenderer"])
            }
        }

        if continuation == nil {
            continuation = continuationToken(root)
        }

        return VideoSearchResults(videos: videos, channels: channels, playlists: playlists, continuation: continuation)
    }

    static func searchContinuation(_ root: JSON) -> (videos: [VideoItem], channels: [VideoChannel], playlists: [VideoPlaylistSummary], continuation: String?) {
        var videos: [VideoItem] = []
        var channels: [VideoChannel] = []
        var playlists: [VideoPlaylistSummary] = []
        var continuation: String? = nil

        let continuationItems = root["onResponseReceivedCommands"].array.first?["appendContinuationItemsAction"]["continuationItems"].array
            ?? root["onResponseReceivedActions"].array.first?["appendContinuationItemsAction"]["continuationItems"].array
            ?? root.first("appendContinuationItemsAction")["continuationItems"].array

        for item in continuationItems {
            if let v = VideoRows.video(from: item) {
                videos.append(v)
            } else if let c = VideoRows.channel(from: item) {
                channels.append(c)
            } else if let p = VideoRows.playlist(from: item) {
                playlists.append(p)
            } else if item["continuationItemRenderer"].exists {
                continuation = continuationToken(item["continuationItemRenderer"])
            }
        }

        if continuation == nil {
            continuation = continuationToken(root)
        }

        return (videos, channels, playlists, continuation)
    }

    // MARK: - Watch Page (/next)

    static func watch(_ root: JSON, videoId: String) -> VideoWatchPage? {
        let watchResults = root["contents"]["twoColumnWatchNextResults"]
        guard watchResults.exists else { return nil }

        let primary = watchResults.first("videoPrimaryInfoRenderer")
        let secondary = watchResults.first("videoSecondaryInfoRenderer")
        guard primary.exists || secondary.exists else { return nil }

        let title = primary["title"].text.trimmingCharacters(in: .whitespacesAndNewlines)
        let viewCount = primary["viewCount"]["videoViewCountRenderer"]["viewCount"]["simpleText"].nonEmpty
            ?? primary["viewCount"]["videoViewCountRenderer"]["shortViewCount"]["simpleText"].nonEmpty
            ?? primary["viewCount"].text.nonEmpty
        let published = primary["dateText"]["simpleText"].nonEmpty
            ?? primary["relativeDateText"]["simpleText"].nonEmpty
            ?? primary["dateText"].text.nonEmpty

        let owner = secondary["owner"]["videoOwnerRenderer"]
        let channelName = owner["title"].text.trimmingCharacters(in: .whitespacesAndNewlines)
        let channelId = owner["navigationEndpoint"]["browseEndpoint"]["browseId"].nonEmpty
        let channelAvatar = owner["thumbnail"].bestThumbnail
        let subText = owner["subscriberCountText"]["simpleText"].nonEmpty
            ?? owner["subscriberCountText"].text.nonEmpty

        let description = secondary["attributedDescription"]["content"].nonEmpty
            ?? secondary["description"].text.nonEmpty

        // Up next videos from secondaryResults
        var upNext: [VideoItem] = []
        var continuation: String? = nil

        let secondaryList = watchResults["secondaryResults"]["secondaryResults"]["results"].array
            + watchResults.first("secondaryResults")["results"].array

        for entry in secondaryList {
            if let v = VideoRows.video(from: entry) {
                upNext.append(v)
            } else if entry["continuationItemRenderer"].exists {
                continuation = continuationToken(entry["continuationItemRenderer"])
            }
        }

        let channel = VideoChannel(id: channelId ?? "", name: channelName, avatar: channelAvatar, subscriberText: subText)
        let video = VideoItem(
            id: videoId,
            title: title,
            channel: channelName,
            channelId: channelId,
            thumbnail: nil,
            duration: nil,
            viewCountText: viewCount,
            publishedText: published,
            isLive: false,
            isShort: false
        )

        return VideoWatchPage(
            video: video,
            channel: channel,
            description: description,
            viewCountText: viewCount,
            publishedText: published,
            upNext: upNext,
            continuation: continuation
        )
    }

    // MARK: - Playlist Page (browse with VL<playlistId>)

    static func playlist(_ root: JSON, id: String) -> VideoPlaylistPage? {
        var title = ""
        var channel: String? = nil
        var thumbnail: Artwork? = nil
        var itemCount: Int? = nil
        var description: String? = nil

        let pageHeader = root["header"]["pageHeaderRenderer"]["content"]["pageHeaderViewModel"]
        if pageHeader.exists {
            title = pageHeader["title"]["dynamicTextViewModel"]["text"]["content"].string ?? ""
            let rows = pageHeader["metadata"]["contentMetadataViewModel"]["metadataRows"].array
            for row in rows {
                for part in row["metadataParts"].array {
                    let text = part["text"]["content"].string ?? ""
                    if text.lowercased().contains("video") {
                        itemCount = VideoRows.parseItemCount(from: text)
                    } else if channel == nil, !text.isEmpty {
                        channel = text.hasPrefix("by ") ? String(text.dropFirst(3)) : text
                    }
                }
            }
            thumbnail = VideoRows.image(from: pageHeader)
        }

        let sidebar = root["sidebar"]["playlistSidebarRenderer"]["items"].array
        if let primarySidebar = sidebar.first?["playlistSidebarPrimaryInfoRenderer"] {
            if title.isEmpty {
                title = primarySidebar["title"].text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if thumbnail == nil {
                thumbnail = primarySidebar["thumbnailRenderer"]["playlistVideoThumbnailRenderer"]["thumbnail"].bestThumbnail
            }
            if itemCount == nil {
                for stat in primarySidebar["stats"].array {
                    if let count = VideoRows.parseItemCount(from: stat.text) {
                        itemCount = count
                        break
                    }
                }
            }
            if description == nil {
                description = primarySidebar["description"].text.nonEmpty
            }
        }

        if let secondarySidebar = sidebar.dropFirst().first?["playlistSidebarSecondaryInfoRenderer"] {
            if channel == nil {
                channel = secondarySidebar["videoOwnerRenderer"]["title"].text.nonEmpty
            }
        }

        let legacyHeader = root["header"]["playlistHeaderRenderer"]
        if legacyHeader.exists {
            if title.isEmpty { title = legacyHeader["title"].text }
            if channel == nil { channel = legacyHeader["ownerText"].text.nonEmpty }
            if thumbnail == nil { thumbnail = legacyHeader["playlistHeaderBanner"].bestThumbnail }
            if itemCount == nil { itemCount = VideoRows.parseItemCount(from: legacyHeader["numVideosText"].text) }
            if description == nil { description = legacyHeader["description"].text.nonEmpty }
        }

        let summary = VideoPlaylistSummary(
            id: id,
            title: title.isEmpty ? "Playlist" : title,
            channel: channel,
            thumbnail: thumbnail,
            itemCount: itemCount
        )

        // Parse video rows
        var items: [VideoItem] = []
        let sectionContents = root["contents"]["twoColumnBrowseResultsRenderer"]["tabs"].array.first?["tabRenderer"]["content"]["sectionListRenderer"]["contents"].array
            ?? root.first("sectionListRenderer")["contents"].array

        for section in sectionContents {
            if section["itemSectionRenderer"].exists {
                for entry in section["itemSectionRenderer"]["contents"].array {
                    if let v = VideoRows.video(from: entry) {
                        items.append(v)
                    }
                }
            } else if section["playlistVideoListRenderer"].exists {
                for entry in section["playlistVideoListRenderer"]["contents"].array {
                    if let v = VideoRows.video(from: entry) {
                        items.append(v)
                    }
                }
            }
        }

        if items.isEmpty {
            for listRenderer in root.objects("playlistVideoListRenderer") {
                for entry in listRenderer["contents"].array {
                    if let v = VideoRows.video(from: entry) {
                        items.append(v)
                    }
                }
            }
        }

        let continuation = continuationToken(root)

        return VideoPlaylistPage(
            playlist: summary,
            description: description,
            items: items,
            continuation: continuation
        )
    }

    static func playlistContinuation(_ root: JSON) -> (items: [VideoItem], continuation: String?) {
        var items: [VideoItem] = []
        var continuation: String? = nil

        let continuationItems = root["onResponseReceivedActions"].array.first?["appendContinuationItemsAction"]["continuationItems"].array
            ?? root["onResponseReceivedEndpoints"].array.first?["appendContinuationItemsAction"]["continuationItems"].array
            ?? root.first("appendContinuationItemsAction")["continuationItems"].array

        for entry in continuationItems {
            if let v = VideoRows.video(from: entry) {
                items.append(v)
            } else if entry["continuationItemRenderer"].exists || entry["continuationItemViewModel"].exists {
                continuation = continuationToken(entry)
            }
        }

        if continuation == nil {
            continuation = continuationToken(root)
        }

        return (items, continuation)
    }

    // MARK: - Continuation token extraction

    static func continuationToken(_ node: JSON) -> String? {
        node.first("continuationCommand")["token"].nonEmpty
            ?? node.first("continuationEndpoint")["continuationCommand"]["token"].nonEmpty
            ?? node.first("nextContinuationData")["continuation"].nonEmpty
    }
}
