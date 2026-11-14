#if canImport(ActivityKit) && os(iOS)
import ActivityKit
import KodaCore
import SwiftUI

/// Shows downloads on their way as a Live Activity: "3 of 12" and a bar on the Lock Screen and
/// in the Dynamic Island, from the first song asked for until the last arrives. The system's
/// own switch (Settings → Koda → Live Activities) turns it off.
///
/// Downloads only run while Koda does, so each update says it goes stale in a minute and a
/// half: left in the background with nothing playing, the activity then says they're paused
/// instead of showing a bar that no longer moves.
@MainActor
final class DownloadActivityController {
    private let downloads: Downloads
    private var activity: Activity<DownloadActivityAttributes>?
    private var shown: DownloadActivityAttributes.ContentState?
    private var lastUpdate = Date.distantPast

    init(downloads: Downloads) {
        self.downloads = downloads
        // One left over from a run the app was closed in the middle of.
        for stale in Activity<DownloadActivityAttributes>.activities {
            Self.end(Handle(activity: stale), with: nil, lingering: nil)
        }
        observe()
    }

    private func observe() {
        withObservationTracking({ _ = downloads.progress }, onChange: Self.changeHandler(self))
        sync()
    }

    /// Observation calls back on whichever thread made the change, so the handler is built
    /// outside the main actor and hops back to it.
    private nonisolated static func changeHandler(_ controller: DownloadActivityController) -> @Sendable () -> Void {
        { Task { @MainActor in controller.observe() } }
    }

    private func sync() {
        guard let progress = downloads.progress else { return finish() }
        let state = DownloadActivityAttributes.ContentState(finished: progress.finished, total: progress.total,
                                                            fraction: progress.fraction, current: progress.current)
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(90))
        guard let activity else {
            // Only from the foreground; a run picked up in the background starts it at the next change there.
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            self.activity = try? Activity.request(attributes: DownloadActivityAttributes(), content: content)
            shown = state
            lastUpdate = Date()
            return
        }
        // The bar moves with every megabyte; the system wants updates far apart. A song
        // arriving or starting is said at once, the bar between them every couple of seconds.
        let counted = shown.map { $0.finished != state.finished || $0.total != state.total || $0.current != state.current } ?? true
        guard counted || Date().timeIntervalSince(lastUpdate) >= 2 else { return }
        shown = state
        lastUpdate = Date()
        Self.update(Handle(activity: activity), with: content)
    }

    /// An activity's calls run off the main actor. `Activity` isn't marked Sendable, though it
    /// is only a handle to what the system keeps; this carries it across.
    private nonisolated struct Handle: @unchecked Sendable {
        let activity: Activity<DownloadActivityAttributes>
    }

    private nonisolated static func update(_ handle: Handle, with content: ActivityContent<DownloadActivityAttributes.ContentState>) {
        Task.detached { await handle.activity.update(content) }
    }

    /// Ends it at once, or leaves its last word up until `lingering`.
    private nonisolated static func end(_ handle: Handle, with content: ActivityContent<DownloadActivityAttributes.ContentState>?,
                                        lingering: Date?) {
        Task.detached { await handle.activity.end(content, dismissalPolicy: lingering.map { .after($0) } ?? .immediate) }
    }

    /// Nothing left on its way: say so for a few seconds, then go.
    private func finish() {
        guard let activity else { return }
        self.activity = nil
        var state = shown ?? .init(finished: 0, total: 0, fraction: 1)
        // Removed rather than arrived (the count never filled): nothing to announce.
        let completed = state.finished >= state.total && state.total > 0
        state.fraction = 1
        state.current = nil
        state.isDone = completed
        shown = nil
        let content = ActivityContent(state: state, staleDate: nil)
        Self.end(Handle(activity: activity), with: content, lingering: completed ? Date().addingTimeInterval(4) : nil)
    }
}
#endif
