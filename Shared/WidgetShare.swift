import Foundation
import SwiftUI

// What the app tells its widgets, through a folder both can reach. The app writes; the widget
// extension only reads. Compiled into the app (iPhone and Mac) and the widget extensions.

/// The folder the app and its widgets share, when this build has one.
///
/// iPhone: an App Group. Koda ships unsigned and is signed by whoever installs it. AltStore and
/// SideStore sign with the installer's own Apple ID, which can't own `group.ivors.Koda`, so they
/// make a group of their own (`group.ivors.Koda.<team>`) and write the names they used into each
/// bundle's Info.plist as `ALTAppGroups`. A build signed without any group gets nil here, and the
/// widgets fall back to what they can do alone.
///
/// Mac: the app is ad-hoc signed, which can't hold an App Group, and macOS runs widgets only
/// sandboxed. So the app (not sandboxed) writes to a folder of its own in the listener's Library,
/// and the widget's sandbox is given read-only access to exactly that folder
/// (`KodaWidgets-macOS.entitlements`). The path is built from the real home folder: inside the
/// sandbox `NSHomeDirectory()` is the widget's container.
nonisolated enum SharedContainer {
    static let group = "group.ivors.Koda"

    static let directory: URL? = {
        #if os(macOS)
        guard let home = getpwuid(getuid())?.pointee.pw_dir else { return nil }
        let folder = URL(fileURLWithPath: String(cString: home), isDirectory: true)
            .appending(path: "Library/Application Support/Koda/Widgets", directoryHint: .isDirectory)
        // Fails harmlessly in the widget, which may only read; the app makes it.
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
        #else
        let renamed = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] ?? []
        for name in renamed.filter({ $0.hasPrefix(group) }) + [group] {
            guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: name) else { continue }
            let folder = container.appending(path: "Widgets")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }
        return nil
        #endif
    }()

    /// Covers live in a folder of their own, one file per song (`<songId>.jpg`).
    static var covers: URL? { directory?.appending(path: "covers", directoryHint: .isDirectory) }

    static func cover(_ name: String?) -> URL? {
        guard let name else { return nil }
        return covers?.appending(path: name)
    }

    static func load<T: Decodable>(_ type: T.Type, from fileName: String) -> T? {
        guard let file = directory?.appending(path: fileName), let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Nil removes the file.
    static func save<T: Encodable>(_ value: T?, to fileName: String) {
        guard let file = directory?.appending(path: fileName) else { return }
        guard let value, let data = try? JSONEncoder().encode(value) else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try? data.write(to: file, options: .atomic)
    }
}

/// A colour taken from a cover, kept as linear sRGB so it comes back exactly as resolved.
nonisolated struct WidgetColor: Codable, Equatable, Sendable {
    var red: Float
    var green: Float
    var blue: Float

    init(_ resolved: Color.Resolved) {
        red = resolved.linearRed
        green = resolved.linearGreen
        blue = resolved.linearBlue
    }

    var color: Color {
        Color(Color.Resolved(colorSpace: .sRGBLinear, red: red, green: green, blue: blue))
    }
}

/// One song as a widget shows it.
nonisolated struct WidgetSong: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var artist: String
    /// The cover's file in `SharedContainer.covers`; nil until it has been fetched.
    var cover: String?
}

/// What's playing, as the Now Playing widget draws it.
nonisolated struct NowPlayingSnapshot: Codable, Equatable, Sendable {
    var song: WidgetSong
    var isPlaying: Bool
    /// Where the song was at `date`; while it plays, the widget's bar runs on from there by itself.
    var position: TimeInterval
    var date: Date
    var duration: TimeInterval
    /// The cover's colours, nine in reading order for a 3×3 mesh, deepened for white type.
    var colors: [WidgetColor]?
    var upNext: [WidgetSong]

    static let widgetKind = "NowPlaying"
    static let fileName = "now-playing.json"

    /// Where the song is at `moment`, going by when this was written.
    func position(at moment: Date) -> TimeInterval {
        guard isPlaying else { return position }
        return min(max(duration, position), position + max(0, moment.timeIntervalSince(date)))
    }

    static func load() -> NowPlayingSnapshot? { SharedContainer.load(Self.self, from: fileName) }
    /// Nil clears it: nothing is playing.
    static func save(_ snapshot: NowPlayingSnapshot?) { SharedContainer.save(snapshot, to: fileName) }
}

/// The listener's recent songs and listening, for the Recently Played and Listening widgets.
nonisolated struct ListeningSnapshot: Codable, Equatable, Sendable {
    /// Newest first.
    var recent: [WidgetSong]
    /// The newest cover's colours, for Recently Played's background.
    var recentColors: [WidgetColor]?
    /// Seconds listened per day (`WidgetDay.key`), for the last week and a day.
    var days: [String: TimeInterval]
    /// Days in a row with listening, up to `streakEnds` (a day key).
    var streak: Int
    var streakEnds: String?
    /// The artist played most over the last seven days, and how many plays.
    var topArtist: String?
    var topArtistPlays: Int

    static let recentKind = "RecentlyPlayed"
    static let listeningKind = "Listening"
    static let fileName = "listening.json"

    func seconds(on date: Date) -> TimeInterval { days[WidgetDay.key(date)] ?? 0 }

    /// The streak as of `date`: it still stands while the last day listened is today or yesterday.
    func streak(asOf date: Date) -> Int {
        guard let streakEnds else { return 0 }
        let today = WidgetDay.key(date)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: date).map { WidgetDay.key($0) }
        return streakEnds == today || streakEnds == yesterday ? streak : 0
    }

    static func load() -> ListeningSnapshot? { SharedContainer.load(Self.self, from: fileName) }
    static func save(_ snapshot: ListeningSnapshot?) { SharedContainer.save(snapshot, to: fileName) }
}

/// Day keys as the library keeps them (`Library.dayKey`), which the extension can't import.
nonisolated enum WidgetDay {
    static func key(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
