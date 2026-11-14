import SwiftUI
import WidgetKit

// MARK: - Downloads Live Activity

#if canImport(ActivityKit) && os(iOS)
import ActivityKit

/// Downloads on their way: the Lock Screen's banner and the Dynamic Island.
struct DownloadActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            let state = context.state
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: state.isDone ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.headline(state, isStale: context.isStale)).font(.headline).lineLimit(1)
                        Text(Self.detail(state, isStale: context.isStale)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if !state.isDone {
                        Text("\(state.finished) of \(state.total)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                ProgressView(value: state.fraction)
                    .tint(context.isStale ? .secondary : .accentColor)
            }
            .padding(16)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: state.isDone ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(state.finished) of \(state.total)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(Self.headline(state, isStale: context.isStale)).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(Self.detail(state, isStale: context.isStale)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        ProgressView(value: state.fraction)
                    }
                }
            } compactLeading: {
                Image(systemName: state.isDone ? "checkmark.circle.fill" : "arrow.down.circle")
                    .foregroundStyle(.tint)
            } compactTrailing: {
                ProgressView(value: state.fraction)
                    .progressViewStyle(.circular)
                    .frame(width: 18, height: 18)
            } minimal: {
                ProgressView(value: state.fraction)
                    .progressViewStyle(.circular)
                    .frame(width: 18, height: 18)
            }
        }
    }

    private static func headline(_ state: DownloadActivityAttributes.ContentState, isStale: Bool) -> String {
        if state.isDone { return state.total == 1 ? "Song Downloaded" : "\(state.total) Songs Downloaded" }
        return isStale ? "Downloads Paused" : state.total == 1 ? "Downloading 1 Song" : "Downloading \(state.total) Songs"
    }

    private static func detail(_ state: DownloadActivityAttributes.ContentState, isStale: Bool) -> String {
        if state.isDone { return "Ready to play offline" }
        if isStale { return "Open Koda to carry on" }
        return state.current ?? "Waiting for a connection"
    }
}
#endif
