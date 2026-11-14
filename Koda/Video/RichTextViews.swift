import KodaCore
import SwiftUI

extension RichText {
    /// The text with YouTube's links laid over it. Times, videos and channels become links of
    /// Koda's own (`koda-link:`), which `richLinks` opens inside the app.
    var attributed: AttributedString {
        var result = AttributedString(text)
        let units = text.utf16
        for link in links {
            // YouTube counts in UTF-16; a range that splits a character is left as plain text.
            guard let lower = units.index(units.startIndex, offsetBy: link.range.lowerBound, limitedBy: units.endIndex),
                  let upper = units.index(units.startIndex, offsetBy: link.range.upperBound, limitedBy: units.endIndex),
                  let from = AttributedString.Index(lower, within: result),
                  let to = AttributedString.Index(upper, within: result), from < to else { continue }
            result[from..<to].link = link.target.url
        }
        return result
    }
}

extension RichText.Target {
    static let scheme = "koda-link"

    var url: URL {
        switch self {
        case .url(let url): url
        // Ids are letters, digits, - and _, so they need no escaping.
        case .timestamp(let seconds, let videoId): URL(string: "\(Self.scheme)://time?t=\(Int(seconds))&v=\(videoId ?? "")")!
        case .video(let id): URL(string: "\(Self.scheme)://video?v=\(id)")!
        case .channel(let id): URL(string: "\(Self.scheme)://channel?id=\(id)")!
        }
    }
}

extension View {
    /// Opens the links of `RichText.attributed` drawn inside: a time seeks the video it belongs
    /// to (`videoId`, the one the text is under), a video or channel opens its page in Koda, and
    /// anything else goes to the system. `leaving` runs before a page opens, for a sheet to close.
    func richLinks(videoId: String?, leaving: @escaping () -> Void = {}) -> some View {
        modifier(RichLinks(videoId: videoId, leaving: leaving))
    }
}

private struct RichLinks: ViewModifier {
    let videoId: String?
    let leaving: () -> Void
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        content.environment(\.openURL, OpenURLAction { url in
            open(url) ? .handled : .systemAction
        })
    }

    private func open(_ url: URL) -> Bool {
        guard url.scheme == RichText.Target.scheme else {
            // A link to YouTube or YouTube Music is Koda's to open.
            guard YouTubeLink(url) != nil else { return false }
            leaving()
            return app.open(url)
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 } }
        switch url.host() {
        case "time":
            guard let seconds = value("t").flatMap(TimeInterval.init) else { return true }
            let playback = app.videos
            let target = value("v") ?? videoId
            if target == nil || target == playback.current?.id {
                playback.seek(to: seconds)
                playback.resume()
            } else if let target {
                // Another video's moment: start it there, on its own page.
                let video = Video(id: target, title: "")
                playback.play(video, startingAt: seconds)
                leaving()
                app.open(.video(video))
            }
        case "video":
            guard let id = value("v") else { return true }
            leaving()
            app.open(.video(Video(id: id, title: "")))
        case "channel":
            guard let id = value("id") else { return true }
            leaving()
            app.open(.channel(id: id, name: ""))
        default:
            break
        }
        return true
    }
}
