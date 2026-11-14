import Foundation

/// Text YouTube wrote links into: a video's description, a comment. The links are the ones
/// YouTube marked (`commandRuns`), never guessed from the prose: a time in a comment arrives as
/// a `watchEndpoint` with `startTimeSeconds` [verified November 2026, WEB `next`, signed out].
public struct RichText: Sendable, Hashable {
    public var text: String
    /// In order, never overlapping.
    public var links: [Link]

    public struct Link: Sendable, Hashable {
        /// Where it sits in `text`, in UTF-16 units, which is how YouTube counts (an emoji is two).
        public var range: Range<Int>
        public var target: Target

        public init(range: Range<Int>, target: Target) {
            self.range = range
            self.target = target
        }
    }

    public enum Target: Sendable, Hashable {
        /// An outside link, out of YouTube's redirect wrapper.
        case url(URL)
        /// A moment in a video: the one the text belongs to, as far as YouTube says.
        case timestamp(seconds: TimeInterval, videoId: String?)
        /// Another video.
        case video(id: String)
        case channel(id: String)
    }

    public init(text: String = "", links: [Link] = []) {
        self.text = text
        self.links = links
    }

    /// An attributed-text object: `{content, commandRuns}`.
    init(_ node: JSON) {
        let text = node["content"].string ?? ""
        let units = Array(text.utf16)
        var links: [Link] = []
        for run in node["commandRuns"].array {
            guard let start = run["startIndex"].int, let length = run["length"].int, start >= 0, length > 0, start < units.count,
                  let target = Self.target(run["onTap"]["innertubeCommand"]) else { continue }
            // A run often takes in the space or line break after it; the link is what's visible.
            var end = min(start + length, units.count)
            while end > start, let scalar = Unicode.Scalar(units[end - 1]), CharacterSet.whitespacesAndNewlines.contains(scalar) { end -= 1 }
            guard end > start else { continue }
            links.append(Link(range: start..<end, target: target))
        }
        links.sort { $0.range.lowerBound < $1.range.lowerBound }
        var disjoint: [Link] = []
        for link in links where disjoint.last.map({ link.range.lowerBound >= $0.range.upperBound }) ?? true {
            disjoint.append(link)
        }
        self.init(text: text, links: disjoint)
    }

    private static func target(_ command: JSON) -> Target? {
        let watch = command["watchEndpoint"]
        if let id = watch["videoId"].nonEmpty {
            if let seconds = watch["startTimeSeconds"].double { return .timestamp(seconds: seconds, videoId: id) }
            return .video(id: id)
        }
        if let url = VideoPages.unwrapRedirect(command["urlEndpoint"]["url"].string) { return .url(url) }
        // Hashtags and the rest browse to pages Koda doesn't have; they stay plain text.
        if let id = command["browseEndpoint"]["browseId"].nonEmpty, id.hasPrefix("UC") { return .channel(id: id) }
        return nil
    }
}
