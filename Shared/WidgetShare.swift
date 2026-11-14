#if os(iOS)
import Foundation

// What the app tells its widgets, through a folder both can reach (an App Group). The app
// writes; the widget extension only reads.

/// The app group's folder, when this build has one.
///
/// Koda ships unsigned and is signed by whoever installs it. AltStore and SideStore sign with
/// the installer's own Apple ID, which can't own `group.ivors.Koda`, so they make a group of
/// their own (`group.ivors.Koda.<team>`) and write the names they used into each bundle's
/// Info.plist as `ALTAppGroups`. A build signed without any group gets nil here, and the
/// widgets fall back to what they can do alone.
nonisolated enum SharedContainer {
    static let group = "group.ivors.Koda"

    static let directory: URL? = {
        let renamed = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] ?? []
        for name in renamed.filter({ $0.hasPrefix(group) }) + [group] {
            guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: name) else { continue }
            let folder = container.appending(path: "Widgets")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }
        return nil
    }()
}

/// What's playing, as the Now Playing widget draws it.
nonisolated struct NowPlayingSnapshot: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var title: String
        var artist: String
    }

    var songId: String
    var title: String
    var artist: String
    var isPlaying: Bool
    /// Where the song was at `date`; while it plays, the widget's bar runs on from there by itself.
    var position: TimeInterval
    var date: Date
    var duration: TimeInterval
    /// The cover's file beside this one; nil until it has been fetched.
    var cover: String?
    var upNext: [Entry]

    static let widgetKind = "NowPlaying"
    private static let fileName = "now-playing.json"

    /// Where the song is at `moment`, going by when this was written.
    func position(at moment: Date) -> TimeInterval {
        guard isPlaying else { return position }
        return min(max(duration, position), position + max(0, moment.timeIntervalSince(date)))
    }

    static func load() -> NowPlayingSnapshot? {
        guard let file = SharedContainer.directory?.appending(path: fileName), let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(NowPlayingSnapshot.self, from: data)
    }

    /// Nil clears it: nothing is playing.
    static func save(_ snapshot: NowPlayingSnapshot?) {
        guard let file = SharedContainer.directory?.appending(path: fileName) else { return }
        guard let snapshot, let data = try? JSONEncoder().encode(snapshot) else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try? data.write(to: file, options: .atomic)
    }
}
#endif
