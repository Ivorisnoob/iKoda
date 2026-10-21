# Video mode (iOS)

Koda for iOS is a YouTube Music client. This is the plan for the second half of YouTube: **watching videos**. It follows Koda for Android's video mode in spirit and skips its extras on purpose.

## Scope

**In**

- A Videos tab on the iPhone (a Videos section in the Mac sidebar, later).
- A feed of videos to browse, a search over videos, channels and playlists.
- A watch page: the video playing, its channel, its description, and the up-next list.
- Video playlists: open one, play it through.
- Quality choice: Auto, 360p, 480p, 720p, 1080p.
- Up-next queue, advancing on its own when a video ends.

**Out (deliberately)**

- Shaders, frame interpolation, picture sliders, a custom shader editor (Android only).
- Writing to YouTube in any form: no uploads, no likes, no subscriptions, no comments, no playlists created or edited.
- Casting, PiP-to-app, screen lock, vertical Shorts mode, live chat, channel pages, local video files, video downloads.
- A separate audio download path for videos: videos are streamed, not saved.

## How it works

**The API is the web one, not the music one.** YouTube Music (`music.youtube.com`, the `WEB_REMIX` client) answers in the shape of albums, songs and shelves. Ordinary YouTube (`www.youtube.com`, the `WEB` client) answers with `videoRenderer`, `lockupViewModel` and `richGridRenderer` rows. The two need separate clients, separate origins and separate parsers; a music client never returns a video feed.

**Streams come over HLS.** The `/player` answer for a video carries `streamingData.hlsManifestUrl`: an HLS variant playlist with an audio group, subtitle groups and a ladder of H.264 and VP9 renditions up to 2160p. AVPlayer plays that manifest directly, gets the audio with the video, and can be capped to a quality with `preferredMaximumResolution` — no muxing, no second player, no itag ladder to maintain. [verified October 2026, see `.scratchpad/probe_video2.py`]

The music app's own stream path is untouched: it resolves an audio-only AAC URL under the `VISIONOS` client and caches it as `.m4a`. Video playback runs beside it, not through it.

**The visitor token is shared.** The `VISIONOS` client with Koda's own `visitorData` is what `/player` wants, and the same token is what the web browse calls want. One identity, two origins.

## The API contract

Everything below lives in `KodaCore/Sources/KodaCore/Video/` and is public; the app target only uses it.

```swift
// VideoModels.swift
public struct VideoItem: Identifiable, Hashable, Codable, Sendable {
    public var id: String                 // the video id
    public var title: String
    public var channel: String
    public var channelId: String?
    public var thumbnail: Artwork?
    public var duration: TimeInterval?
    public var viewCountText: String?
    public var publishedText: String?
    public var isLive: Bool
    public var isShort: Bool
}

public struct VideoChannel: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var avatar: Artwork?
    public var subscriberText: String?
}

public struct VideoPlaylistSummary: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var title: String
    public var channel: String?
    public var thumbnail: Artwork?
    public var itemCount: Int?
}

public struct VideoShelf: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var items: [VideoItem]
}

public struct VideoFeed: Sendable {
    public var shelves: [VideoShelf]
    public var continuation: String?
}

public struct VideoSearchResults: Sendable {
    public var videos: [VideoItem]
    public var channels: [VideoChannel]
    public var playlists: [VideoPlaylistSummary]
    public var continuation: String?
}

public struct VideoPlaylistPage: Sendable {
    public var playlist: VideoPlaylistSummary
    public var description: String?
    public var items: [VideoItem]
    public var continuation: String?
}

public struct VideoWatchPage: Sendable {
    public var video: VideoItem
    public var channel: VideoChannel
    public var description: String?
    public var viewCountText: String?
    public var publishedText: String?
    public var upNext: [VideoItem]
    public var continuation: String?
}

/// The ladder the player offers. `automatic` lets AVPlayer decide.
public enum VideoQuality: String, CaseIterable, Sendable {
    case automatic, p360, p480, p720, p1080
    /// The peak bitrate AVPlayer is allowed, in bits per second.
    public var peakBitRate: Double
    /// The largest height AVPlayer may pick, in points.
    public var maxHeight: Int
}

/// Where a video's picture comes from.
public struct VideoStream: Sendable, Equatable {
    public var videoId: String
    public var url: URL
    public var isHLS: Bool
    public var userAgent: String
    public var duration: TimeInterval?
    public var expiresAt: Date?
}
```

```swift
// VideoTube.swift — the client. One instance for the whole app.
public final class YouTubeVideos: Sendable {
    public init(account: AccountStore? = nil, defaultsSuite: String? = nil)

    // Browse
    public func home() async throws -> VideoFeed
    public func feed(browseId: String) async throws -> VideoFeed
    public func feedMore(_ continuation: String) async throws -> (shelves: [VideoShelf], continuation: String?)

    // Search
    public func search(_ query: String, filter: VideoSearchFilter = .all) async throws -> VideoSearchResults
    public func searchMore(_ continuation: String) async throws -> (videos: [VideoItem], channels: [VideoChannel], playlists: [VideoPlaylistSummary], continuation: String?)

    // Pages
    public func playlist(_ id: String) async throws -> VideoPlaylistPage
    public func playlistMore(_ continuation: String) async throws -> (items: [VideoItem], continuation: String?)
    public func watch(_ videoId: String) async throws -> VideoWatchPage

    // Streams
    public func stream(for videoId: String) async throws -> VideoStream
    public func streamFailed(_ videoId: String) async
}

public enum VideoSearchFilter: String, CaseIterable, Sendable {
    case all, videos, channels, playlists, shorts
    /// The `params` the search chips send.
    var params: String?
}
```

Errors are the app's own `MusicError` (`network`, `badResponse`, `unplayable`, `botCheck`) — no second error type.

## The app side

- `Koda/Video/VideoModel.swift` — the pages' state: the feed, a search, a playlist, the watch page. `LoadState`, like the rest of the app.
- `Koda/Video/VideoPlayback.swift` — the picture and the sound: an `AVPlayer` on the main actor, the queue, the position, the quality. Separate from the music `Player`: the music player owns files, crossfades and downloads; this one owns a picture. It is called `VideoPlayback`, not `VideoPlayer`, so it never shadows `AVKit.VideoPlayer`.
- `Koda/Video/VideoHomeView.swift`, `VideoSearchView.swift`, `VideoWatchView.swift`, `VideoPlaylistView.swift` — the screens.
- `Koda/Video/VideoRow.swift` — the row and the card. A video's thumbnail is 16:9, so it is drawn cropped, never letterboxed.

## Verified answers (October 2026)

Probed from the Windows PC; the scripts and the raw answers are in `.scratchpad/`:

| Question | Answer |
| --- | --- |
| Which client answers the web pages? | `WEB`, `2.20260903.01.00`, on `https://www.youtube.com/youtubei/v1/…`, key `Clients.apiKey`. |
| Which client answers `/player` for a video? | `VISIONOS` (the one the music app already uses) or `ANDROID`; `WEB` is refused with "The page needs to be reloaded". |
| What does `/player` give? | `streamingData.hlsManifestUrl` (VISIONOS and IOS), adaptive MP4 and WebM renditions, and AAC audio (`itag` 139/140). `WEB` gives only progressive `itag` 18. |
| What is in the HLS manifest? | 17 variants: H.264 from 144p to 1080p, VP9 to 2160p, an audio group (`AUDIO="233"/"234"`), and subtitle groups (`SUBTITLES="vtt"`). |
| Where do the search rows live? | `contents.twoColumnSearchResultsRenderer.primaryContents.sectionListRenderer.contents[].itemSectionRenderer.contents[].videoRenderer`. |
| Where do the up-next rows live? | `contents.twoColumnWatchNextResults.secondaryResults.secondaryResults.results[].lockupViewModel` with `contentType = LOCKUP_CONTENT_TYPE_VIDEO`. |
| Where do the watch page's title and owner live? | `…results.results.contents[1].videoPrimaryInfoRenderer` and `…contents[2].videoSecondaryInfoRenderer`. |
| Which browse ids answer? | `FEwhat_to_watch` does, but only with an account: signed out it answers with a sign-in nudge and no rows. `FEtrending`, `FEexplore`, `FEpopular` and `FEtopics` are refused (HTTP 400). YouTube has no public trending feed any more, so the app falls back to a search when the feed is empty. |
| Does googlevideo check the User-Agent on the HLS path? | No. The manifest, its media playlists and its segments answer 200 with any User-Agent, including none at all. So the player needs no header trick. |
| What does a signed-out feed answer? | `browse` with `FEwhat_to_watch` answers `richGridRenderer` with one `richSectionRenderer` holding a `feedNudgeRenderer` and no rows. |
