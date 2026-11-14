import AppIntents
import SwiftUI
import WidgetKit

// How much the listener has listened: today's time, the streak of days, the week as bars and
// the week's top artist, in Koda's own colours. Written by the app (`WidgetBridge`), at most
// every few minutes while music plays; today rolls over at midnight by itself.

struct ListeningEntry: TimelineEntry {
    let date: Date
    var snapshot: ListeningSnapshot?
}

struct ListeningProvider: TimelineProvider {
    func placeholder(in context: Context) -> ListeningEntry { ListeningEntry(date: .now, snapshot: .preview) }

    func getSnapshot(in context: Context, completion: @escaping (ListeningEntry) -> Void) {
        completion(ListeningEntry(date: .now, snapshot: ListeningSnapshot.load() ?? (context.isPreview ? .preview : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ListeningEntry>) -> Void) {
        let snapshot = ListeningSnapshot.load()
        var entries = [ListeningEntry(date: .now, snapshot: snapshot)]
        // A new day starts at nothing, even if the app isn't there to say so.
        if let midnight = Calendar.current.nextDate(after: .now, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime) {
            entries.append(ListeningEntry(date: midnight, snapshot: snapshot))
        }
        completion(Timeline(entries: entries, policy: .never))
    }
}

struct ListeningWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ListeningSnapshot.listeningKind, provider: ListeningProvider()) { entry in
            ListeningView(entry: entry)
        }
        .configurationDisplayName("Listening")
        .description("How long you've listened today, your streak, and your week.")
        .supportedFamilies(Self.families)
        .contentMarginsDisabled()
    }

    private static var families: [WidgetFamily] {
        #if os(iOS)
        [.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline]
        #else
        [.systemSmall, .systemMedium]
        #endif
    }
}

struct ListeningView: View {
    let entry: ListeningEntry
    @Environment(\.widgetFamily) private var family

    private var snapshot: ListeningSnapshot? { entry.snapshot }
    private var today: TimeInterval { snapshot?.seconds(on: entry.date) ?? 0 }
    private var streak: Int { snapshot?.streak(asOf: entry.date) ?? 0 }

    /// The last seven days, oldest first, ending today.
    private var week: [(date: Date, seconds: TimeInterval)] {
        (0..<7).reversed().compactMap { back in
            Calendar.current.date(byAdding: .day, value: -back, to: entry.date).map { ($0, snapshot?.seconds(on: $0) ?? 0) }
        }
    }

    var body: some View {
        Group {
            switch family {
            #if os(iOS)
            case .accessoryCircular: circular
            case .accessoryRectangular: rectangular
            case .accessoryInline: inline
            #endif
            case .systemMedium: medium.padding(16)
            default: small.padding(14)
            }
        }
        .containerBackground(for: .widget) {
            if isAccessory { accessoryBackground } else { KodaBackground() }
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
        family == .accessoryCircular || family == .accessoryRectangular || family == .accessoryInline
        #else
        false
        #endif
    }

    // MARK: Home Screen and desktop

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetEyebrow(title: "Today", systemImage: "headphones")
            Spacer(minLength: 4)
            bigTime(today, size: 38)
            streakLabel.padding(.top, 2)
            Spacer(minLength: 8)
            bars(height: 26, labels: false)
        }
        .foregroundStyle(.white)
    }

    private var medium: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 0) {
                WidgetEyebrow(title: "Today", systemImage: "headphones")
                Spacer(minLength: 4)
                bigTime(today, size: 40)
                streakLabel.padding(.top, 2)
                Spacer(minLength: 6)
                if let artist = snapshot?.topArtist, let plays = snapshot?.topArtistPlays, plays > 0 {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Top artist this week")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.6))
                        Text(artist)
                            .font(.caption.weight(.bold))
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("This Week")
                        .font(.caption2.weight(.bold))
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .foregroundStyle(.white.opacity(0.72))
                    Spacer(minLength: 4)
                    Text(Self.duration(week.reduce(0) { $0 + $1.seconds }))
                        .font(.caption.weight(.bold).monospacedDigit())
                }
                bars(height: nil, labels: true)
            }
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(.white)
    }

    // MARK: Lock Screen

    #if os(iOS)
    /// Today's minutes in a ring that fills toward the week's daily average.
    private var circular: some View {
        let goal = max(30 * 60, averageDay)
        return Gauge(value: min(today, goal), in: 0...goal) {
            Image(systemName: "headphones")
        } currentValueLabel: {
            Text("\(Int(today / 60))")
                .font(.system(.title3, design: .rounded).weight(.bold))
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .widgetAccentable()
        .accessibilityLabel("\(Int(today / 60)) minutes listened today")
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label {
                Text(Self.duration(today)).font(.headline)
            } icon: {
                Image(systemName: "headphones")
            }
            .widgetAccentable()
            Text("listened today")
                .font(.caption)
                .foregroundStyle(.secondary)
            if streak > 1 {
                Label("\(streak)-day streak", systemImage: "flame.fill")
                    .font(.caption.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inline: some View {
        Label("\(Self.duration(today)) listened today", systemImage: "headphones")
    }
    #endif

    // MARK: Parts

    /// The days the week had any listening, averaged: what a usual day of this listener's is.
    private var averageDay: TimeInterval {
        let days = week.filter { $0.seconds > 0 }
        return days.isEmpty ? 0 : days.reduce(0) { $0 + $1.seconds } / Double(days.count)
    }

    /// "47 min" or "2 h 05 min", numbers large and units small.
    private func bigTime(_ seconds: TimeInterval, size: CGFloat) -> some View {
        let minutes = Int(seconds / 60)
        let number = Font.system(size: size, weight: .bold, design: .rounded)
        let unit = Font.system(size: size * 0.42, weight: .bold, design: .rounded)
        let text: Text
        if minutes >= 60 {
            let hours = Text("\(minutes / 60)").font(number)
            let rest = Text(String(format: "%02d", minutes % 60)).font(number)
            text = Text("\(hours)\(Text(" h ").font(unit))\(rest)\(Text(" min").font(unit))")
        } else {
            text = Text("\(Text("\(minutes)").font(number))\(Text(" min").font(unit))")
        }
        return text
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .contentTransition(.numericText())
            .accessibilityLabel("\(Self.duration(seconds)) listened today")
    }

    @ViewBuilder
    private var streakLabel: some View {
        if streak > 1 {
            HStack(spacing: 3) {
                Image(systemName: "flame.fill").foregroundStyle(.orange)
                Text("\(streak)-day streak")
            }
            .font(.caption.weight(.semibold))
        } else {
            Text(today > 0 ? "Keep it going tomorrow" : "Nothing yet today")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    /// The week as bars, today's in lime; `height` nil fills what's given.
    private func bars(height: CGFloat?, labels: Bool) -> some View {
        let days = week
        let most = max(days.map(\.seconds).max() ?? 0, 60)
        let isToday = { (date: Date) in Calendar.current.isDate(date, inSameDayAs: entry.date) }
        return HStack(alignment: .bottom, spacing: labels ? 6 : 4) {
            ForEach(days, id: \.date) { day in
                VStack(spacing: 4) {
                    GeometryReader { geometry in
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: labels ? 5 : 3, style: .continuous)
                                .fill(isToday(day.date) ? Color.kodaLime : .white.opacity(day.seconds > 0 ? 0.45 : 0.15))
                                .frame(height: max(4, geometry.size.height * day.seconds / most))
                        }
                    }
                    if labels {
                        Text(day.date.formatted(.dateTime.weekday(.narrow)))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(isToday(day.date) ? 1 : 0.6))
                    }
                }
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("This week")
        .accessibilityValue(days.map { "\($0.date.formatted(.dateTime.weekday(.wide))): \(Self.duration($0.seconds))" }.joined(separator: ", "))
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60) h \(String(format: "%02d", minutes % 60)) min" : "\(minutes) min"
    }
}
