import Foundation
import os
#if os(iOS)
import UIKit
#endif

/// The app's end of `WidgetTaps` (issue #10): it notes the taps the app's own copies of the
/// widget intents receive, and on iPhone carries out the taps the widget extension handed over.
///
/// A tap could in principle reach both copies of an intent. Toggling twice would undo it, so a
/// tap runs once: a handed-over tap waits a moment and is skipped if the app's own copy ran the
/// same action around then, and the app's own copy is skipped if a handed-over one just ran it.
@MainActor
final class WidgetTapRelay {
    static let shared = WidgetTapRelay()

    /// Two runs of one action closer than this are taken for one tap seen twice. Short, so two
    /// quick taps on Next by the listener still skip twice (each goes the same way, and only a
    /// run from the other side is checked).
    private static let sameTap: TimeInterval = 2

    private weak var app: AppModel?
    private var handled: [UUID] = []
    private var ranHere: [WidgetTaps.Action: Date] = [:]
    private var ranHandedOver: [WidgetTaps.Action: Date] = [:]

    /// The app's own copy of an intent received a tap. False when a handed-over tap already ran
    /// this action, so the intent does nothing more.
    func ranInApp(_ action: WidgetTaps.Action) -> Bool {
        let now = Date()
        if let other = ranHandedOver[action], now.timeIntervalSince(other) < Self.sameTap {
            WidgetTaps.record(.app, action, note: "already run from the widget's hand-over", at: now)
            return false
        }
        ranHere[action] = now
        WidgetTaps.record(.app, action, at: now)
        return true
    }

    /// Listen for taps the extension hands over. iPhone only, and only with a shared folder.
    func start(app: AppModel) {
        #if os(iOS)
        guard self.app == nil, SharedContainer.directory != nil else { return }
        self.app = app
        // Taps written before this launch are past acting on.
        handled = WidgetTaps.commands().map(\.id)
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, widgetCommandPosted,
                                        WidgetTaps.darwinName as CFString, nil, .deliverImmediately)
        // A notification posted while the app was suspended may not arrive; a fresh tap waiting
        // when it comes back still runs.
        _ = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { WidgetTapRelay.shared.runWaiting() }
        }
        #endif
    }

    func runWaiting() {
        guard let app else { return }
        let now = Date()
        for command in WidgetTaps.commands() where !handled.contains(command.id) {
            handled.append(command.id)
            guard now.timeIntervalSince(command.at) < WidgetTaps.freshFor else {
                WidgetTaps.record(.handedOver, command.action, note: "too old to run", at: now)
                continue
            }
            Task { await run(command, on: app) }
        }
        handled = Array(handled.suffix(100))
    }

    private func run(_ command: WidgetTaps.Command, on app: AppModel) async {
        // Give the app's own copy, if the system ran it too, time to land first.
        try? await Task.sleep(for: .milliseconds(600))
        if let own = ranHere[command.action], abs(own.timeIntervalSince(command.at)) < Self.sameTap {
            WidgetTaps.record(.handedOver, command.action, note: "the app already ran this tap")
            return
        }
        ranHandedOver[command.action] = Date()
        IntentLog.logger.notice("Widget hand-over: \(command.action.rawValue, privacy: .public)")
        WidgetTaps.record(.handedOver, command.action)
        command.action.run(on: app, shuffle: command.shuffle ?? true, songId: command.songId)
    }
}

#if os(iOS)
/// The Darwin centre calls a plain C function with no context, so this only wakes the relay.
private nonisolated func widgetCommandPosted(_ center: CFNotificationCenter?, _ observer: UnsafeMutableRawPointer?,
                                             _ name: CFNotificationName?, _ object: UnsafeRawPointer?, _ userInfo: CFDictionary?) {
    Task { @MainActor in WidgetTapRelay.shared.runWaiting() }
}
#endif
