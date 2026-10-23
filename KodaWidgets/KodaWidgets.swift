import AppIntents
import SwiftUI
import WidgetKit

// Koda's widgets: quick ways in that need nothing from the app to draw, since the builds
// Koda ships can't share a container with an extension. What's playing is already on the
// Lock Screen and in Control Center through the system's own Now Playing controls.

@main
struct KodaWidgets: WidgetBundle {
    var body: some Widget {
        QuickPlayWidget()
        #if !targetEnvironment(macCatalyst)
        LikedSongsControl()
        PlayPauseControl()
        #endif
    }
}

/// Koda's accent, as the app's asset catalog has it.
private extension Color {
    static let koda = Color(red: 0x3D / 255, green: 0x5A / 255, blue: 0xFE / 255)
    static let kodaLight = Color(red: 0x86 / 255, green: 0x9C / 255, blue: 0xFF / 255)
}

// MARK: - Quick Play

struct QuickPlayEntry: TimelineEntry {
    let date: Date
}

struct QuickPlayProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickPlayEntry { QuickPlayEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (QuickPlayEntry) -> Void) { completion(QuickPlayEntry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickPlayEntry>) -> Void) {
        completion(Timeline(entries: [QuickPlayEntry(date: .now)], policy: .never))
    }
}

struct QuickPlayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "QuickPlay", provider: QuickPlayProvider()) { _ in
            QuickPlayView()
        }
        .configurationDisplayName("Quick Play")
        .description("Shuffle your liked songs, or play and pause, without opening Koda.")
        .supportedFamilies(Self.families)
    }

    private static var families: [WidgetFamily] {
        #if targetEnvironment(macCatalyst)
        [.systemSmall, .systemMedium]
        #else
        [.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular]
        #endif
    }
}

struct QuickPlayView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemMedium: medium
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        default: small
        }
    }

    /// The whole widget is the button: liked songs, shuffled.
    private var small: some View {
        Button(intent: PlayLikedSongsIntent(shuffle: true)) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: "heart.fill")
                    .font(.title.weight(.semibold))
                Spacer(minLength: 0)
                Text("Liked Songs")
                    .font(.headline)
                Label("Shuffle", systemImage: "shuffle")
                    .font(.caption.weight(.semibold))
                    .opacity(0.8)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .containerBackground(for: .widget) { background }
    }

    private var medium: some View {
        HStack(spacing: 12) {
            tile("Shuffle Liked Songs", systemImage: "heart.fill", intent: PlayLikedSongsIntent(shuffle: true))
            tile("Play or Pause", systemImage: "playpause.fill", intent: TogglePlaybackIntent())
        }
        .containerBackground(for: .widget) { background }
    }

    private func tile(_ title: String, systemImage: String, intent: some AppIntent) -> some View {
        Button(intent: intent) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: systemImage)
                    .font(.title2.weight(.semibold))
                Spacer(minLength: 0)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
            }
            .foregroundStyle(.white)
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(.white.opacity(0.16), in: .rect(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var circular: some View {
        Button(intent: PlayLikedSongsIntent(shuffle: true)) {
            Image(systemName: "heart.fill")
                .font(.title2.weight(.semibold))
                .widgetAccentable()
        }
        .buttonStyle(.plain)
        .containerBackground(for: .widget) { AccessoryWidgetBackground() }
        .accessibilityLabel("Shuffle Liked Songs")
    }

    private var rectangular: some View {
        Button(intent: PlayLikedSongsIntent(shuffle: true)) {
            VStack(alignment: .leading, spacing: 2) {
                Label("Liked Songs", systemImage: "heart.fill")
                    .font(.headline)
                    .widgetAccentable()
                Text("Tap to shuffle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .containerBackground(for: .widget) { Color.clear }
    }

    private var background: some View {
        LinearGradient(colors: [.kodaLight, .koda], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Control Center

#if !targetEnvironment(macCatalyst)
struct LikedSongsControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "LikedSongsControl") {
            ControlWidgetButton(action: PlayLikedSongsIntent(shuffle: true)) {
                Label("Liked Songs", systemImage: "heart.fill")
            }
        }
        .displayName("Shuffle Liked Songs")
        .description("Shuffles your liked songs in Koda.")
    }
}

struct PlayPauseControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "PlayPauseControl") {
            ControlWidgetButton(action: TogglePlaybackIntent()) {
                Label("Koda", systemImage: "playpause.fill")
            }
        }
        .displayName("Play or Pause Koda")
        .description("Plays or pauses Koda.")
    }
}
#endif
