import Foundation

/// What a YouTube or YouTube Music link points at.
///
/// Accepts music.youtube.com, youtube.com (www and m), youtu.be, and Koda's own
/// `koda://` links, which carry the same path and query as a YouTube one
/// (`koda://watch?v=…`, `koda://playlist?list=…`, `koda://browse/MPREb_…`).
public enum YouTubeLink: Equatable, Sendable {
    case song(videoId: String)
    case video(videoId: String)
    case album(browseId: String)
    case playlist(id: String)
    case artist(channelId: String)

    public init?(_ url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let scheme = parts.scheme?.lowercased()
        let host = parts.host?.lowercased() ?? ""
        let query = Dictionary((parts.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } },
                               uniquingKeysWith: { first, _ in first })
        var path = parts.path.split(separator: "/").map(String.init)

        // koda://watch?v=… puts the first word in the host.
        let keepsSongSemantics: Bool
        switch scheme {
        case "koda":
            if !host.isEmpty { path.insert(host, at: 0) }
            keepsSongSemantics = true
        case "http", "https":
            if host == "youtu.be" {
                guard let id = path.first, Self.isVideoId(id) else { return nil }
                self = .video(videoId: id)
                return
            }
            let known = ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"]
            guard known.contains(host) else { return nil }
            // Only music.youtube.com (and koda://) keep the song meaning; a plain
            // youtube.com link is a video, even for watch/shorts/live.
            keepsSongSemantics = (host == "music.youtube.com")
        default:
            return nil
        }

        switch path.first {
        case "watch":
            if let v = query["v"], Self.isVideoId(v) {
                self = keepsSongSemantics ? .song(videoId: v) : .video(videoId: v)
            } else if let list = query["list"], let link = Self.playlistLink(list) {
                self = link
            } else {
                return nil
            }
        case "shorts", "live":
            guard path.count > 1, Self.isVideoId(path[1]) else { return nil }
            self = keepsSongSemantics ? .song(videoId: path[1]) : .video(videoId: path[1])
        case "playlist":
            guard let list = query["list"], let link = Self.playlistLink(list) else { return nil }
            self = link
        case "browse":
            guard path.count > 1 else { return nil }
            let id = path[1]
            if id.hasPrefix("MPREb_") {
                self = .album(browseId: id)
            } else if id.hasPrefix("UC") {
                self = .artist(channelId: id)
            } else if id.hasPrefix("VL") {
                self = .playlist(id: String(id.dropFirst(2)))
            } else {
                return nil
            }
        case "channel":
            guard path.count > 1, path[1].hasPrefix("UC") else { return nil }
            self = .artist(channelId: path[1])
        default:
            return nil
        }
    }

    /// A playlist id, or nil for a radio mix (`RD…`), which has no page of its own.
    private static func playlistLink(_ playlistId: String) -> YouTubeLink? {
        guard !playlistId.isEmpty, !playlistId.hasPrefix("RD") else { return nil }
        return .playlist(id: playlistId)
    }

    /// Finds the first link in free text, such as something pasted into search.
    public init?(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let link = YouTubeLink(url) {
            self = link
            return
        }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        for match in detector.matches(in: trimmed, range: range) {
            if let url = match.url, let link = YouTubeLink(url) {
                self = link
                return
            }
        }
        return nil
    }

    private static func isVideoId(_ id: String) -> Bool {
        id.count == 11 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}
