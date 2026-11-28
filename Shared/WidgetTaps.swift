import Foundation

/// Widget and Control Center taps, traced from both ends, and handed to the app when only the
/// widget extension saw them (issue #10).
///
/// The buttons run audio intents (PlaybackIntents.swift), which the system is meant to perform
/// in the app; the extension's copies were stubs that did nothing. On iOS 27.2.1 every button
/// but Play Liked Songs stopped working, and which side those taps reach isn't known yet. So
/// each side writes what it saw to `widget-taps.json` in the shared folder, and Settings →
/// Widget Taps shows it.
///
/// A tap that reaches only the extension is handed on: its copy of the intent writes the
/// command to `widget-commands.json` and posts a Darwin notification, and the app, which runs
/// in the background while it plays, carries it out (`WidgetTapRelay`). iPhone only: the Mac
/// widget may only read the shared folder.
nonisolated enum WidgetTaps {
    nonisolated enum Action: String, Codable, Sendable, CaseIterable {
        case playLiked, toggle, next, previous, playRecent

        var title: String {
            switch self {
            case .playLiked: "Play Liked Songs"
            case .toggle: "Play or Pause"
            case .next: "Next Song"
            case .previous: "Previous Song"
            case .playRecent: "Play Recent Song"
            }
        }
    }

    /// Who saw the tap: the extension's copy of the intent, the app's own copy, or the app
    /// running a tap the extension handed over.
    nonisolated enum Side: String, Codable, Sendable {
        case widget, app, handedOver
    }

    nonisolated struct Entry: Codable, Sendable, Identifiable, Equatable {
        var id = UUID()
        var at: Date
        var side: Side
        var action: Action
        var note: String?
    }

    nonisolated struct Command: Codable, Sendable, Identifiable, Equatable {
        var id = UUID()
        var at: Date
        var action: Action
        var shuffle: Bool?
        var songId: String?
    }

    static let traceFile = "widget-taps.json"
    static let commandsFile = "widget-commands.json"
    static let darwinName = "ivors.Koda.widget-command"
    /// A handed-over tap older than this is one the listener has given up on, not one to act on.
    static let freshFor: TimeInterval = 10
    static let traceLength = 60

    /// Both processes write the trace, so a tap that lands as the other side writes can be
    /// lost from it. It is a record to look at, and the commands file doesn't depend on it.
    static func record(_ side: Side, _ action: Action, note: String? = nil, at date: Date = Date()) {
        var entries = trace()
        entries.append(Entry(at: date, side: side, action: action, note: note))
        SharedContainer.save(Array(entries.suffix(traceLength)), to: traceFile)
    }

    static func trace() -> [Entry] { SharedContainer.load([Entry].self, from: traceFile) ?? [] }

    static func clearTrace() { SharedContainer.save(nil as [Entry]?, to: traceFile) }

    static func commands() -> [Command] { SharedContainer.load([Command].self, from: commandsFile) ?? [] }

    #if WIDGET_EXTENSION
    /// What an intent's copy in the extension does: note the tap and, on iPhone, hand it to the app.
    static func extensionReceived(_ action: Action, shuffle: Bool? = nil, songId: String? = nil) {
        #if os(iOS)
        let now = Date()
        let waiting = commands().filter { now.timeIntervalSince($0.at) < freshFor }
        SharedContainer.save(waiting + [Command(at: now, action: action, shuffle: shuffle, songId: songId)], to: commandsFile)
        record(.widget, action, note: "handed to the app", at: now)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(darwinName as CFString), nil, nil, true)
        #endif
    }
    #endif
}
