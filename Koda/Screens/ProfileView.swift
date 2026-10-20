import Charts
import KodaCore
import PhotosUI
import SwiftUI

/// Listening figures worked out from the library's counts.
struct ListeningSummary {
    struct Day: Identifiable {
        let date: Date
        let minutes: Double
        var id: Date { date }
    }

    struct ArtistTotal: Identifiable {
        let name: String
        let ref: ArtistRef?
        let artwork: Artwork?
        let seconds: TimeInterval
        let plays: Int
        var id: String { name }
    }

    let days: [Day]
    let totalSeconds: TimeInterval
    let topSongs: [SongStats]
    let topArtists: [ArtistTotal]
    let totalPlays: Int
    let streak: Int
    let firstPlayed: Date?

    @MainActor
    init(library: Library, days count: Int, now: Date = Date(), calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        days = (0..<count).reversed().compactMap { back in
            guard let date = calendar.date(byAdding: .day, value: -back, to: today) else { return nil }
            return Day(date: date, minutes: library.listening(on: date, calendar: calendar) / 60)
        }
        totalSeconds = days.reduce(0) { $0 + $1.minutes * 60 }
        let stats = Array(library.songStats.values)
        topSongs = stats.sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.plays > $1.plays }
        totalPlays = stats.reduce(0) { $0 + $1.plays }
        firstPlayed = stats.map(\.firstPlayed).min()
        streak = library.streak(asOf: now, calendar: calendar)

        // One entry per lead artist; a song credited to several counts for the first.
        var byArtist: [String: (ref: ArtistRef?, artwork: Artwork?, seconds: TimeInterval, plays: Int)] = [:]
        for stat in stats {
            let ref = stat.song.artists.first
            let name = ref?.name ?? stat.song.artistLine
            guard !name.isEmpty else { continue }
            var entry = byArtist[name] ?? (ref: ref, artwork: stat.song.artwork, seconds: 0, plays: 0)
            entry.seconds += stat.seconds
            entry.plays += stat.plays
            if entry.ref?.id == nil, ref?.id != nil { entry.ref = ref }
            byArtist[name] = entry
        }
        topArtists = byArtist.map { ArtistTotal(name: $0.key, ref: $0.value.ref, artwork: $0.value.artwork, seconds: $0.value.seconds, plays: $0.value.plays) }
            .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.plays > $1.plays }
    }
}

extension TimeInterval {
    /// "2 hr 5 min", "42 min", "under a minute".
    var listeningText: String {
        let minutes = Int(self / 60)
        if minutes == 0 { return self > 0 ? "Under a minute" : "0 min" }
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) hr" : "\(minutes / 60) hr \(minutes % 60) min"
    }
}

/// The listener's page: who they are on this phone and what they have been playing.
struct ProfileView: View {
    @Environment(AppModel.self) private var app
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var photo: PhotosPickerItem?
    @State private var editingName = false
    @State private var draftName = ""
    @State private var showsSettings = false
    @State private var showsAccount = false

    var body: some View {
        let summary = ListeningSummary(library: library, days: 7)
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    header(summary)
                    switchProfileRow
                    if app.account.profile.kind == .youtube { accountRow }
                    tiles(summary)
                    WeekChart(days: summary.days)
                        .padding(.horizontal, 20)
                    topSongs(summary)
                    topArtists(summary)
                    NavigationLink(value: Route.stats) {
                        Label("All Listening Stats", systemImage: "chart.bar.xaxis")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .padding(.horizontal, 20)
                }
                .padding(.vertical, 12)
            }
            .background { ProfileGlow() }
            .routeDestinations()
            .navigationTitle("Profile")
            .scrollEdgeEffectStyle(.soft, for: .all)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { showsSettings = true }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
            .sheet(isPresented: $showsSettings) { SettingsView().appEnvironment(app) }
            .sheet(isPresented: $showsAccount) { AccountSettingsView().appEnvironment(app) }
            .alert("Your Name", isPresented: $editingName) {
                TextField("Name", text: $draftName)
                    .textContentType(.givenName)
                Button("Cancel", role: .cancel) {}
                Button("Save") { app.profile.setName(draftName.trimmingCharacters(in: .whitespacesAndNewlines)) }
            } message: {
                Text("Shown on your profile and the playlists you make. It stays on this iPhone.")
            }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                Task {
                    let data = try? await item.loadTransferable(type: Data.self)
                    app.profile.setPhoto(data)
                    photo = nil
                }
            }
        }
    }

    // MARK: Header

    private func header(_ summary: ListeningSummary) -> some View {
        // A profile on this device has a name and a photo of its own; an
        // account's are YouTube's, and there is nothing to edit.
        let isLocal = app.profile.profile.kind == .local
        return VStack(spacing: 12) {
            if isLocal {
                PhotosPicker(selection: $photo, matching: .images) {
                    AvatarView(size: 112)
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "camera.fill")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.primary)
                                .frame(width: 32, height: 32)
                                .glassEffect(.regular.interactive(), in: .circle)
                        }
                        .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Change Photo")
                .contextMenu {
                    if app.profile.photo != nil {
                        Button("Remove Photo", systemImage: "trash", role: .destructive) { app.profile.setPhoto(nil) }
                    }
                }
            } else {
                AvatarView(size: 112)
                    .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
            }

            if isLocal {
                Button {
                    draftName = app.profile.name
                    editingName = true
                } label: {
                    HStack(spacing: 6) {
                        Text(app.profile.name).font(.title.bold())
                        Image(systemName: "pencil").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Edit your name")
            } else {
                Text(app.profile.name).font(.title.bold())
            }

            if let first = summary.firstPlayed {
                Text("Listening since \(first.formatted(.dateTime.month(.wide).year()))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("Play something and your stats start here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private func tiles(_ summary: ListeningSummary) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            StatTile(title: "This week", value: summary.totalSeconds.listeningText, systemImage: "headphones", tint: .accentColor)
            StatTile(title: "Day streak", value: summary.streak == 1 ? "1 day" : "\(summary.streak) days", systemImage: "flame.fill", tint: .orange)
            StatTile(title: "Songs played", value: summary.totalPlays.formatted(), systemImage: "music.note", tint: .pink)
            StatTile(title: "Liked songs", value: library.liked.count.formatted(), systemImage: "heart.fill", tint: .red)
        }
        .padding(.horizontal, 20)
    }

    // MARK: The signed-in account

    /// The profile the app is being right now, and the way to another one.
    private var switchProfileRow: some View {
        NavigationLink {
            ProfileSwitcherView()
        } label: {
            HStack(spacing: 12) {
                ProfileAvatar(profile: app.profile.profile, photo: app.profile.photo, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.profile.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(app.account.roster.count > 1 ? "Switch profile" : "Profiles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
    }

    /// The YouTube Music account on this device, with the way into its
    /// settings. The listener's own profile above stays their own.
    private var accountRow: some View {
        Button { showsAccount = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "play.rectangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Color.red.gradient, in: .rect(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.account.name.isEmpty ? "YouTube Music" : app.account.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(app.account.status == .expired ? "Needs signing in again" : "Signed in to YouTube Music")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .glassEffect(.regular, in: .rect(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
    }

    // MARK: Top lists
    @ViewBuilder
    private func topSongs(_ summary: ListeningSummary) -> some View {
        if !summary.topSongs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Your top songs")
                TopSongsList(stats: Array(summary.topSongs.prefix(5)))
            }
            .padding(.horizontal, 20)
        }
    }

    @ViewBuilder
    private func topArtists(_ summary: ListeningSummary) -> some View {
        if !summary.topArtists.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Your top artists")
                    .padding(.horizontal, 20)
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(Array(summary.topArtists.prefix(10).enumerated()), id: \.element.id) { index, artist in
                            TopArtistCard(rank: index + 1, artist: artist)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .contentMargins(.horizontal, 20, for: .scrollContent)
            }
        }
    }
}

/// A headline number with its label.
struct StatTile: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(tint.gradient, in: .rect(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                Text(title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Minutes per day as bars; tap or drag across to read one.
struct WeekChart: View {
    let days: [ListeningSummary.Day]
    var title = "Last 7 days"
    @State private var selected: Date?

    private var shown: ListeningSummary.Day? {
        guard let selected else { return nil }
        return days.first { Calendar.current.isDate($0.date, inSameDayAs: selected) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                if let shown {
                    Text("\(shown.date.formatted(.dateTime.weekday(.wide))) · \((shown.minutes * 60).listeningText)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                } else {
                    Text("Average \((days.reduce(0) { $0 + $1.minutes } * 60 / Double(max(days.count, 1))).listeningText) a day")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Chart(days) { day in
                BarMark(x: .value("Day", day.date, unit: .day), y: .value("Minutes", day.minutes), width: .ratio(0.55))
                    .cornerRadius(4)
                    .foregroundStyle(Color.accentColor.opacity(shown == nil || shown?.id == day.id ? 1 : 0.35))
            }
            .chartXSelection(value: $selected)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.25))
                    AxisValueLabel {
                        if let minutes = value.as(Double.self) { Text("\(Int(minutes))m") }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: days.count > 10 ? 7 : 1)) { _ in
                    AxisValueLabel(format: days.count > 10 ? Date.FormatStyle.dateTime.day().month(.abbreviated) : Date.FormatStyle.dateTime.weekday(.narrow), centered: true)
                }
            }
            .frame(height: 160)
            .animation(.easeOut(duration: 0.2), value: selected)
            .accessibilityLabel(title)
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
    }
}

/// Ranked songs with how much they were played; a tap plays from that song on.
struct TopSongsList: View {
    let stats: [SongStats]
    @Environment(Player.self) private var player

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(stats.enumerated()), id: \.element.song.id) { index, stat in
                SongRow(song: stat.song, subtitle: "\(stat.song.artistLine) · \(stat.plays == 1 ? "1 play" : "\(stat.plays) plays")") {
                    player.play(stats.map(\.song), startAt: index)
                }
                .overlay(alignment: .leading) {
                    Text("\(index + 1)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(.black.opacity(0.55), in: .capsule)
                        .offset(x: -4, y: -16)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

private struct TopArtistCard: View {
    let rank: Int
    let artist: ListeningSummary.ArtistTotal
    var body: some View {
        NavigationLink(value: artist.ref?.id.map { Route.artist(ArtistSummary(id: $0, name: artist.name)) }) {
            VStack(spacing: 8) {
                ArtworkView(artwork: artist.artwork, size: 96, circle: true)
                    .overlay(alignment: .topLeading) {
                        Text("\(rank)")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .frame(width: 26, height: 26)
                            .glassEffect(.regular, in: .circle)
                    }
                VStack(spacing: 1) {
                    Text(artist.name).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(artist.seconds.listeningText).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 104)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(artist.ref?.id == nil)
    }
}

/// A soft wash of the accent colour behind the profile header.
private struct ProfileGlow: View {
    var body: some View {
        RadialGradient(colors: [Color.accentColor.opacity(0.35), .clear], center: .top, startRadius: 0, endRadius: 420)
            .frame(height: 460)
            .frame(maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Every listening figure, over a week, a month or all of it.
struct StatsView: View {
    enum Span: String, CaseIterable, Identifiable {
        case week = "Week", month = "Month", year = "Year"
        var id: Self { self }
        var days: Int {
            switch self {
            case .week: 7
            case .month: 30
            case .year: 365
            }
        }
    }

    @Environment(Library.self) private var library
    @State private var range: Span = .week
    @State private var confirmReset = false

    var body: some View {
        if Platform.isMac { macBody } else { phoneBody }
    }

    /// The Mac's stats as a dashboard: totals and the chart across the top, then top songs and
    /// top artists side by side.
    private var macBody: some View {
        let summary = ListeningSummary(library: library, days: range.days)
        return MacPage(spacing: 28) {
            MacPageTitle(title: "Listening Stats", subtitle: "Library") {
                Picker("Range", selection: $range) {
                    ForEach(Span.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                if !library.songStats.isEmpty {
                    Button("Reset…", role: .destructive) { confirmReset = true }
                        .buttonStyle(.glass)
                }
            }
            if summary.topSongs.isEmpty {
                ContentUnavailableView("No Listening Yet", systemImage: "chart.bar",
                                       description: Text("Your stats fill in as you play music."))
                    .frame(maxWidth: .infinity, minHeight: 360)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 16) {
                        StatTile(title: "Listened", value: summary.totalSeconds.listeningText, systemImage: "headphones", tint: .accentColor)
                        StatTile(title: "Day streak", value: summary.streak == 1 ? "1 day" : "\(summary.streak) days", systemImage: "flame.fill", tint: .orange)
                    }
                    .frame(width: 240)
                    if range != .year {
                        WeekChart(days: summary.days, title: range == .week ? "Last 7 days" : "Last 30 days")
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, MacMetrics.gutter)
                HStack(alignment: .top, spacing: 40) {
                    VStack(alignment: .leading, spacing: 8) {
                        MacSectionTitle(title: "Top songs", subtitle: "All time")
                        TopSongsList(stats: Array(summary.topSongs.prefix(25)))
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    if !summary.topArtists.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            MacSectionTitle(title: "Top artists", subtitle: "All time")
                            ForEach(Array(summary.topArtists.prefix(10).enumerated()), id: \.element.id) { index, artist in
                                HStack(spacing: 12) {
                                    Text("\(index + 1)")
                                        .font(.callout.monospacedDigit().weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 24)
                                    ArtworkView(artwork: artist.artwork, size: 40, circle: true)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(artist.name).font(.callout.weight(.medium)).lineLimit(1)
                                        Text("\(artist.seconds.listeningText) · \(artist.plays == 1 ? "1 play" : "\(artist.plays) plays")")
                                            .font(.subheadline).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 3)
                            }
                        }
                        .frame(width: 340, alignment: .topLeading)
                    }
                }
                .padding(.horizontal, MacMetrics.gutter)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: range)
        .navigationTitle("Listening Stats")
        .confirmationDialog("Reset your listening stats?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset Stats", role: .destructive) { library.clearStats() }
        } message: {
            Text("Play counts and listening time start over. Liked songs and history stay.")
        }
    }

    private var phoneBody: some View {
        let summary = ListeningSummary(library: library, days: range.days)
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Picker("Range", selection: $range) {
                    ForEach(Span.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    StatTile(title: "Listened", value: summary.totalSeconds.listeningText, systemImage: "headphones", tint: .accentColor)
                    StatTile(title: "Day streak", value: summary.streak == 1 ? "1 day" : "\(summary.streak) days", systemImage: "flame.fill", tint: .orange)
                }
                .padding(.horizontal, 20)

                if range != .year {
                    WeekChart(days: summary.days, title: range == .week ? "Last 7 days" : "Last 30 days")
                        .padding(.horizontal, 20)
                }

                if !summary.topSongs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "Top songs · all time")
                        TopSongsList(stats: Array(summary.topSongs.prefix(25)))
                    }
                    .padding(.horizontal, 20)
                }
                if !summary.topArtists.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "Top artists · all time")
                        ForEach(Array(summary.topArtists.prefix(10).enumerated()), id: \.element.id) { index, artist in
                            HStack(spacing: 12) {
                                Text("\(index + 1)")
                                    .font(.body.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24)
                                ArtworkView(artwork: artist.artwork, size: 44, circle: true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(artist.name).font(.body).lineLimit(1)
                                    Text("\(artist.seconds.listeningText) · \(artist.plays == 1 ? "1 play" : "\(artist.plays) plays")")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                if summary.topSongs.isEmpty {
                    ContentUnavailableView("No Listening Yet", systemImage: "chart.bar",
                                           description: Text("Your stats fill in as you play music."))
                }
            }
            .padding(.vertical, 12)
            .animation(.easeInOut(duration: 0.25), value: range)
        }
        .navigationTitle("Listening Stats")
        .toolbar {
            if !library.songStats.isEmpty {
                Menu("More", systemImage: "ellipsis") {
                    Button("Reset Stats", systemImage: "arrow.counterclockwise", role: .destructive) { confirmReset = true }
                }
            }
        }
        .confirmationDialog("Reset your listening stats?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset Stats", role: .destructive) { library.clearStats() }
        } message: {
            Text("Play counts and listening time start over. Liked songs and history stay.")
        }
    }
}
