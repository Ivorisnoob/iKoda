#if !targetEnvironment(macCatalyst)
import AppIntents
import SwiftUI
import UIKit
import WidgetKit

// What's playing in Koda, on the Home Screen, the Lock Screen and in StandBy: the cover, the
// song, where it has got to, the transport, and (large) what's next. The app writes it to the
// app group's folder and reloads the widget whenever it changes (`WidgetBridge`); with nothing
// playing, or in a build with no app group, it is a way in: liked songs, shuffled.

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    var snapshot: NowPlayingSnapshot?
    var cover: UIImage?
}

struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry { NowPlayingEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        completion(Self.entry(at: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        let now = Self.entry(at: .now)
        var entries = [now]
        // The app says when anything changes. If it was closed mid-song it can't, so half a
        // minute past the song's end the widget stops claiming it's playing.
        if let snapshot = now.snapshot, snapshot.isPlaying, snapshot.duration > 0 {
            var stopped = snapshot
            stopped.isPlaying = false
            stopped.position = snapshot.duration
            let end = snapshot.date.addingTimeInterval(max(0, snapshot.duration - snapshot.position) + 30)
            entries.append(NowPlayingEntry(date: max(end, Date().addingTimeInterval(1)), snapshot: stopped, cover: now.cover))
        }
        completion(Timeline(entries: entries, policy: .never))
    }

    private static func entry(at date: Date) -> NowPlayingEntry {
        let snapshot = NowPlayingSnapshot.load()
        let cover = snapshot?.cover.flatMap { name in
            SharedContainer.directory.flatMap { UIImage(contentsOfFile: $0.appending(path: name).path) }
        }
        return NowPlayingEntry(date: date, snapshot: snapshot, cover: cover)
    }
}

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: NowPlayingSnapshot.widgetKind, provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
        }
        .configurationDisplayName("Now Playing")
        .description("The song playing in Koda, with play, pause and skip.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
    }
}

struct NowPlayingWidgetView: View {
    let entry: NowPlayingEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                switch family {
                case .systemMedium: medium(snapshot)
                case .systemLarge: large(snapshot)
                case .accessoryRectangular: rectangular(snapshot)
                default: small(snapshot)
                }
            } else if family == .accessoryRectangular {
                idleRectangular
            } else {
                idle
            }
        }
        .containerBackground(for: .widget) { background }
    }

    // MARK: Families

    private func small(_ snapshot: NowPlayingSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                cover(side: 58, radius: 12)
                Spacer(minLength: 0)
                transportButton(snapshot.isPlaying ? "pause.fill" : "play.fill", label: snapshot.isPlaying ? "Pause" : "Play",
                                size: 20, intent: TogglePlaybackIntent())
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.18), in: .circle)
            }
            Spacer(minLength: 6)
            titles(snapshot, titleFont: .subheadline.weight(.semibold), artistFont: .caption)
            progress(snapshot).padding(.top, 8)
        }
        .foregroundStyle(.white)
    }

    private func medium(_ snapshot: NowPlayingSnapshot) -> some View {
        HStack(spacing: 14) {
            cover(side: nil, radius: 14)
            VStack(alignment: .leading, spacing: 0) {
                titles(snapshot, titleFont: .headline, artistFont: .subheadline)
                Spacer(minLength: 6)
                progress(snapshot)
                transport(snapshot).padding(.top, 10)
            }
        }
        .foregroundStyle(.white)
    }

    private func large(_ snapshot: NowPlayingSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                cover(side: 120, radius: 14)
                VStack(alignment: .leading, spacing: 0) {
                    titles(snapshot, titleFont: .headline, artistFont: .subheadline)
                    Spacer(minLength: 6)
                    progress(snapshot)
                    transport(snapshot).padding(.top, 10)
                }
            }
            .frame(height: 120)
            VStack(alignment: .leading, spacing: 8) {
                Text("Up Next")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .opacity(0.7)
                if snapshot.upNext.isEmpty {
                    Text("Nothing queued after this song.")
                        .font(.subheadline)
                        .opacity(0.8)
                } else {
                    ForEach(Array(snapshot.upNext.enumerated()), id: \.offset) { _, next in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(next.title).font(.subheadline.weight(.medium)).lineLimit(1)
                            Text(next.artist).font(.caption).opacity(0.75).lineLimit(1)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
    }

    /// The Lock Screen: the song, and a tap to play or pause.
    private func rectangular(_ snapshot: NowPlayingSnapshot) -> some View {
        Button(intent: TogglePlaybackIntent()) {
            HStack(spacing: 8) {
                Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3.weight(.semibold))
                    .widgetAccentable()
                VStack(alignment: .leading, spacing: 1) {
                    Text(snapshot.title).font(.headline).lineLimit(1)
                    Text(snapshot.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(snapshot.isPlaying ? "Pause \(snapshot.title)" : "Play \(snapshot.title)")
    }

    /// Nothing playing: liked songs, shuffled, as the Quick Play widget offers.
    private var idle: some View {
        Button(intent: PlayLikedSongsIntent(shuffle: true)) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: "play.circle.fill")
                    .font(.largeTitle.weight(.semibold))
                Spacer(minLength: 0)
                Text("Nothing Playing")
                    .font(.headline)
                Label("Shuffle Liked Songs", systemImage: "shuffle")
                    .font(.caption.weight(.semibold))
                    .opacity(0.8)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private var idleRectangular: some View {
        Button(intent: PlayLikedSongsIntent(shuffle: true)) {
            VStack(alignment: .leading, spacing: 2) {
                Label("Nothing Playing", systemImage: "play.circle.fill")
                    .font(.headline)
                    .widgetAccentable()
                Text("Tap to shuffle liked songs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    // MARK: Parts

    private func titles(_ snapshot: NowPlayingSnapshot, titleFont: Font, artistFont: Font) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(snapshot.title).font(titleFont).lineLimit(1)
            Text(snapshot.artist).font(artistFont).opacity(0.8).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The cover, square; `side` nil fills the height it is given.
    private func cover(side: CGFloat?, radius: CGFloat) -> some View {
        Color.white.opacity(0.14)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let cover = entry.cover {
                    Image(uiImage: cover)
                        .resizable()
                        // Tinted and clear Home Screens keep the cover as it is.
                        .widgetAccentedRenderingMode(.fullColor)
                        .scaledToFill()
                } else {
                    Image(systemName: "music.note")
                        .font(.title2)
                        .opacity(0.7)
                }
            }
            .clipShape(.rect(cornerRadius: radius, style: .continuous))
            .frame(width: side, height: side)
            .accessibilityHidden(true)
    }

    /// While the song plays the bar runs by itself from where the app last said it was.
    @ViewBuilder
    private func progress(_ snapshot: NowPlayingSnapshot) -> some View {
        let position = snapshot.position(at: entry.date)
        if snapshot.duration > 0 {
            Group {
                if snapshot.isPlaying, position < snapshot.duration {
                    let start = entry.date.addingTimeInterval(-position)
                    ProgressView(timerInterval: start...start.addingTimeInterval(snapshot.duration), countsDown: false) {
                        EmptyView()
                    } currentValueLabel: {
                        EmptyView()
                    }
                } else {
                    ProgressView(value: min(position, snapshot.duration), total: snapshot.duration)
                }
            }
            .progressViewStyle(.linear)
            .tint(.white)
            .accessibilityLabel("Progress")
        }
    }

    private func transport(_ snapshot: NowPlayingSnapshot) -> some View {
        HStack(spacing: 0) {
            transportButton("backward.fill", label: "Previous", size: 18, intent: PreviousSongIntent())
            Spacer(minLength: 0)
            transportButton(snapshot.isPlaying ? "pause.fill" : "play.fill", label: snapshot.isPlaying ? "Pause" : "Play",
                            size: 24, intent: TogglePlaybackIntent())
            Spacer(minLength: 0)
            transportButton("forward.fill", label: "Next", size: 18, intent: NextSongIntent())
        }
        .padding(.horizontal, 8)
    }

    private func transportButton(_ symbol: String, label: String, size: CGFloat, intent: some AppIntent) -> some View {
        Button(intent: intent) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(minWidth: 36, minHeight: 32)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// The cover, blurred and darkened so white type reads over any of them; Koda's colours
    /// with no cover.
    @ViewBuilder
    private var background: some View {
        if family == .accessoryRectangular {
            Color.clear
        } else if let cover = entry.cover, entry.snapshot != nil {
            Image(uiImage: cover)
                .resizable()
                .scaledToFill()
                .blur(radius: 28)
                .overlay(Color.black.opacity(0.42))
        } else {
            LinearGradient(colors: [Color(red: 0x86 / 255, green: 0x9C / 255, blue: 0xFF / 255),
                                    Color(red: 0x3D / 255, green: 0x5A / 255, blue: 0xFE / 255)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

// MARK: - Downloads Live Activity

#if canImport(ActivityKit)
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
#endif
