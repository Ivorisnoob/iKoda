#if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit
import Foundation

/// Downloads on their way, as a Live Activity on the Lock Screen and in the Dynamic Island. The
/// app starts and updates it (`DownloadActivityController`); the widget extension draws it.
nonisolated struct DownloadActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable {
        var finished: Int
        var total: Int
        /// The share of the whole run that is here, 0 to 1.
        var fraction: Double
        /// The song being fetched; nil while they wait for a connection.
        var current: String?
        /// Every song arrived: shown for a moment before the activity goes.
        var isDone = false
    }
}
#endif
