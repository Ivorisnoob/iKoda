import AppIntents
import SwiftUI
import WidgetKit

// What's playing in Koda, on the Home Screen, the Lock Screen, in StandBy and on the Mac's
// desktop: the cover on its own colours, the song, where it has got to, the transport, and
// (large) what's next. The app writes it to the shared folder and reloads the widget whenever
// it changes (`WidgetBridge`); with nothing playing, or in a build with no shared folder, it is
// a way in: liked songs, shuffled.

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    var snapshot: NowPlayingSnapshot?
}

struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry { NowPlayingEntry(date: .now, snapshot: .preview) }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        completion(NowPlayingEntry(date: .now, snapshot: NowPlayingSnapshot.load() ?? (context.isPreview ? .preview : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        let now = NowPlayingEntry(date: .now, snapshot: NowPlayingSnapshot.load())
        var entries = [now]
        // The app says when anything changes. If it was closed mid-song it can't, so half a
        // minute past the song's end the widget stops claiming it's playing.
        if let snapshot = now.snapshot, snapshot.isPlaying, snapshot.duration > 0 {
            var stopped = snapshot
            stopped.isPlaying = false
            stopped.position = snapshot.duration
            let end = snapshot.date.addingTimeInterval(max(0, snapshot.duration - snapshot.position) + 30)
            entries.append(NowPlayingEntry(date: max(end, Date().addingTimeInterval(1)), snapshot: stopped))
        }
        completion(Timeline(entries: entries, policy: .never))
    }
}

private extension NowPlayingSnapshot {
    /// The widget gallery's stand-in, before anything has played.
    static let preview = NowPlayingSnapshot(
        song: WidgetSong(id: "preview", title: "Your Song", artist: "Koda"), isPlaying: true, position: 72,
        date: .now, duration: 214, colors: nil,
        upNext: [WidgetSong(id: "1", title: "Up Next", artist: "Koda"), WidgetSong(id: "2", title: "And After", artist: "Koda")])
}

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: NowPlayingSnapshot.widgetKind, provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
        }
        .configurationDisplayName("Now Playing")
        .description("The song playing in Koda, on its cover's colours, with play, pause and skip.")
        .supportedFamilies(Self.families)
        .contentMarginsDisabled()
    }

    private static var families: [WidgetFamily] {
        #if os(iOS)
        [.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryCircular]
        #else
        [.systemSmall, .systemMedium, .systemLarge]
        #endif
    }
}

struct NowPlayingWidgetView: View {
    let entry: NowPlayingEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            #if os(iOS)
            case .accessoryRectangular: rectangular
            case .accessoryCircular: circular
            #endif
            case .systemMedium: content(medium)
            case .systemLarge: content(large)
            default: content(small)
            }
        }
        .containerBackground(for: .widget) {
            if isAccessory {
                accessoryBackground
            } else if let snapshot = entry.snapshot {
                CoverBackground(colors: snapshot.colors)
            } else {
                KodaBackground()
            }
        }
    }

    /// The Lock Screen's round backdrop under the circular family; none under the others.
    @ViewBuilder
    private var accessoryBackground: some View {
        #if os(iOS)
        AccessoryWidgetBackground().opacity(family == .accessoryCircular ? 1 : 0)
        #endif
    }

    private var isAccessory: Bool {
        #if os(iOS)
        family == .accessoryRectangular || family == .accessoryCircular
        #else
        false
        #endif
    }

    /// A Home Screen family: the song, or the way in while nothing plays.
    private func content<Playing: View>(_ playing: (NowPlayingSnapshot) -> Playing) -> some View {
        Group {
            if let snapshot = entry.snapshot { playing(snapshot) } else { idle }
        }
        .foregroundStyle(.white)
        .padding(family == .systemSmall ? 14 : 16)
    }

    // MARK: Home Screen and desktop

    /// The cover and the play button over the song and its progress.
    private func small(_ snapshot: NowPlayingSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                WidgetCover(name: snapshot.song.cover, radius: 12)
                    .frame(width: 64, height: 64)
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                Spacer(minLength: 0)
                playButton(snapshot, size: 40)
            }
            Spacer(minLength: 8)
            titles(snapshot.song, title: .subheadline.weight(.bold), artist: .caption)
            progress(snapshot).padding(.top, 8)
        }
    }

    /// The cover filling the height beside the song, its progress and the transport.
    private func medium(_ snapshot: NowPlayingSnapshot) -> some View {
        HStack(spacing: 16) {
            WidgetCover(name: snapshot.song.cover, radius: 16)
                .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
            VStack(alignment: .leading, spacing: 0) {
                WidgetEyebrow(title: snapshot.isPlaying ? "Now Playing" : "Paused",
                              systemImage: snapshot.isPlaying ? "waveform" : "pause.fill")
                Spacer(minLength: 4)
                titles(snapshot.song, title: .headline.weight(.bold), artist: .subheadline)
                Spacer(minLength: 8)
                progress(snapshot)
                times(snapshot).padding(.top, 3)
                transport(snapshot).padding(.top, 6)
            }
        }
    }

    /// Medium's layout over what plays next, each with its cover.
    private func large(_ snapshot: NowPlayingSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                WidgetCover(name: snapshot.song.cover, radius: 16)
                    .frame(width: 116, height: 116)
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
                VStack(alignment: .leading, spacing: 0) {
                    WidgetEyebrow(title: snapshot.isPlaying ? "Now Playing" : "Paused",
                                  systemImage: snapshot.isPlaying ? "waveform" : "pause.fill")
                    Spacer(minLength: 4)
                    titles(snapshot.song, title: .title3.weight(.bold), artist: .subheadline)
                    Spacer(minLength: 0)
                    transport(snapshot)
                }
            }
            .frame(height: 116)
            VStack(spacing: 3) {
                progress(snapshot)
                times(snapshot)
            }
            Rectangle().fill(.white.opacity(0.16)).frame(height: 0.5)
            VStack(alignment: .leading, spacing: 8) {
                WidgetEyebrow(title: "Up Next", systemImage: "list.bullet")
                if snapshot.upNext.isEmpty {
                    Text("Nothing queued after this song.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.75))
                } else {
                    ForEach(snapshot.upNext.prefix(3)) { next in
                        HStack(spacing: 10) {
                            WidgetCover(name: next.cover, radius: 7)
                                .frame(width: 34, height: 34)
                            titles(next, title: .subheadline.weight(.semibold), artist: .caption)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Nothing playing: liked songs, shuffled, as the Quick Play widget offers.
    private var idle: some View {
        Button(intent: PlayLikedSongsIntent(shuffle: true)) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: "play.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.kodaInk)
                    .frame(width: 44, height: 44)
                    .background(.white, in: .circle)
                Spacer(minLength: 8)
                Text("Nothing Playing")
                    .font(.headline.weight(.bold))
                Label("Shuffle Liked Songs", systemImage: "shuffle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: Lock Screen

    #if os(iOS)
    /// The song, its progress, and a tap to play or pause.
    @ViewBuilder
    private var rectangular: some View {
        if let snapshot = entry.snapshot {
            Button(intent: TogglePlaybackIntent()) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
                            .font(.caption.weight(.bold))
                            .widgetAccentable()
                        Text(snapshot.song.title).font(.headline).lineLimit(1)
                    }
                    Text(snapshot.song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    progress(snapshot, tint: .primary).padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(snapshot.isPlaying ? "Pause \(snapshot.song.title)" : "Play \(snapshot.song.title)")
        } else {
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
    }

    /// A ring that fills as the song plays, around play or pause.
    @ViewBuilder
    private var circular: some View {
        if let snapshot = entry.snapshot {
            Button(intent: TogglePlaybackIntent()) {
                ZStack {
                    ring(snapshot)
                    Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3.weight(.bold))
                        .widgetAccentable()
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(snapshot.isPlaying ? "Pause \(snapshot.song.title)" : "Play \(snapshot.song.title)")
        } else {
            Button(intent: PlayLikedSongsIntent(shuffle: true)) {
                Image(systemName: "shuffle")
                    .font(.title3.weight(.bold))
                    .widgetAccentable()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Shuffle Liked Songs")
        }
    }

    @ViewBuilder
    private func ring(_ snapshot: NowPlayingSnapshot) -> some View {
        let position = snapshot.position(at: entry.date)
        if snapshot.isPlaying, snapshot.duration > 0, position < snapshot.duration {
            let start = entry.date.addingTimeInterval(-position)
            ProgressView(timerInterval: start...start.addingTimeInterval(snapshot.duration), countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .progressViewStyle(.circular)
            .widgetAccentable()
        } else {
            ProgressView(value: snapshot.duration > 0 ? min(position, snapshot.duration) : 0, total: max(snapshot.duration, 1))
                .progressViewStyle(.circular)
                .widgetAccentable()
        }
    }
    #endif

    // MARK: Parts

    private func titles(_ song: WidgetSong, title: Font, artist: Font) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(song.title).font(title).lineLimit(1)
            Text(song.artist).font(artist).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// While the song plays the bar runs by itself from where the app last said it was.
    @ViewBuilder
    private func progress(_ snapshot: NowPlayingSnapshot, tint: Color = .white) -> some View {
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
            .tint(tint)
            .accessibilityLabel("Progress")
        }
    }

    /// Time played and time left, running by themselves while the song plays.
    @ViewBuilder
    private func times(_ snapshot: NowPlayingSnapshot) -> some View {
        let position = snapshot.position(at: entry.date)
        HStack {
            if snapshot.isPlaying, position < snapshot.duration {
                let start = entry.date.addingTimeInterval(-position)
                let end = start.addingTimeInterval(snapshot.duration)
                Text(start, style: .timer)
                Spacer(minLength: 0)
                Text(timerInterval: entry.date...end, countsDown: true)
                    .multilineTextAlignment(.trailing)
            } else {
                Text(Self.clock(position))
                Spacer(minLength: 0)
                Text("-" + Self.clock(max(0, snapshot.duration - position)))
            }
        }
        .font(.caption2.weight(.semibold).monospacedDigit())
        .foregroundStyle(.white.opacity(0.7))
        .accessibilityHidden(true)
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    private func playButton(_ snapshot: NowPlayingSnapshot, size: CGFloat) -> some View {
        Button(intent: TogglePlaybackIntent()) {
            Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(Color.kodaInk)
                .frame(width: size, height: size)
                .background(.white, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(snapshot.isPlaying ? "Pause" : "Play")
    }

    private func transport(_ snapshot: NowPlayingSnapshot) -> some View {
        HStack(spacing: 0) {
            skipButton("backward.fill", label: "Previous", intent: PreviousSongIntent())
            Spacer(minLength: 0)
            playButton(snapshot, size: 40)
            Spacer(minLength: 0)
            skipButton("forward.fill", label: "Next", intent: NextSongIntent())
        }
        .padding(.horizontal, 6)
    }

    private func skipButton(_ symbol: String, label: String, intent: some AppIntent) -> some View {
        Button(intent: intent) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .bold))
                .frame(width: 40, height: 36)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
