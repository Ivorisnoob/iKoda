import Foundation

/// What a YouTube or YouTube Music link points at.
///
/// Accepts music.youtube.com, youtube.com (www and m), youtu.be, and Koda's own
/// `koda://` links, which carry the same path and query as a YouTube one
/// (`koda://watch?v=…`, `koda://playlist?list=…`, `koda://browse/MPREb_…`).
public enum YouTubeLink: Equatable, Sendable {
    case song(videoId: String)
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

        switch scheme {
        case "koda":
            // koda://watch?v=… puts the first word in the host.
            if !host.isEmpty { path.insert(host, at: 0) }
        case "http", "https":
            if host == "youtu.be" {
                guard let id = path.first, Self.isVideoId(id) else { return nil }
                self = .song(videoId: id)
                return
            }
            let known = ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"]
            guard known.contains(host) else { return nil }
        default:
            return nil
        }

        switch path.first {
        case "watch":
            if let v = query["v"], Self.isVideoId(v) {
                self = .song(videoId: v)
            } else if let list = query["list"], let link = Self.playlistLink(list) {
                self = link
            } else {
                return nil
            }
        case "shorts", "live":
            guard path.count > 1, Self.isVideoId(path[1]) else { return nil }
            self = .song(videoId: path[1])
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

    /// The link inside one Koda's share extension handed over (`koda://open?url=<the link>`),
    /// or `url` itself.
    public static func unwrapped(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "koda", url.host()?.lowercased() == "open",
              let inner = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value,
              let link = URL(string: inner) else { return url }
        return link
    }

    /// Whether a link is to YouTube itself rather than YouTube Music: with Video Mode on, its
    /// video is one to watch and its channel a channel, not a song and an artist.
    public static func isVideoSite(_ url: URL) -> Bool {
        ["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be"].contains(url.host()?.lowercased() ?? "")
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
