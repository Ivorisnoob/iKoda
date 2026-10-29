import KodaCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var tuningTaste = false

    var body: some View {
        @Bindable var player = player
        @Bindable var settings = app.settings
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $player.autoplay) {
                        SettingLabel("Autoplay", systemImage: "infinity", tint: .indigo)
                    }
                    Toggle(isOn: $player.normalizesVolume) {
                        SettingLabel("Normalize Volume", systemImage: "speaker.wave.2.fill", tint: .pink)
                    }
                    Picker(selection: $player.transitions) {
                        Text("AutoMix").tag(Player.Transitions.autoMix)
                        Text("Crossfade").tag(Player.Transitions.crossfade)
                        Text("Off").tag(Player.Transitions.off)
                    } label: {
                        SettingLabel("Song Transitions", systemImage: "wave.3.right", tint: .teal)
                    }
                    if player.transitions == .crossfade {
                        VStack(alignment: .leading, spacing: 4) {
                            LabeledContent("Overlap", value: "\(Int(player.crossfadeDuration)) s")
                            Slider(value: $player.crossfadeDuration, in: 1...12, step: 1) {
                                Text("Overlap")
                            } minimumValueLabel: {
                                Text("1 s")
                            } maximumValueLabel: {
                                Text("12 s")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    Toggle(isOn: $settings.showsSkipButtons) {
                        SettingLabel("Skip Buttons", systemImage: settings.skipInterval.forwardSymbol, tint: .orange)
                    }
                    if settings.showsSkipButtons {
                        Picker(selection: $settings.skipInterval) {
                            ForEach(AppSettings.SkipInterval.allCases) { Text($0.title).tag($0) }
                        } label: {
                            SettingLabel("Skip By", systemImage: "timer", tint: .gray)
                        }
                    }
                } header: {
                    Text("Playback")
                } footer: {
                    Text("Autoplay keeps the music going with songs like the last one when the queue ends. Normalize Volume plays loud masters at a similar level to everything else. AutoMix blends songs like a DJ, lining up beats and skipping silence; Crossfade overlaps the end of one song with the start of the next. Both give skips a short fade. Skip Buttons jump back or ahead within the song from Now Playing.")
                }

                Section {
                    Toggle(isOn: $settings.videoModeEnabled) {
                        SettingLabel("Video Mode", systemImage: "play.rectangle.fill", tint: .red)
                    }
                    if settings.videoModeEnabled {
                        Picker(selection: $settings.videoQuality) {
                            ForEach(AppSettings.videoQualities, id: \.self) { Text(VideoQualityName.long($0)).tag($0) }
                        } label: {
                            SettingLabel("Default Quality", systemImage: "sparkles.tv.fill", tint: .purple)
                        }
                        Toggle(isOn: $settings.autoplaysVideos) {
                            SettingLabel("Autoplay Next Video", systemImage: "play.square.stack.fill", tint: .red)
                        }
                        Toggle(isOn: $settings.holdsToSpeedUp) {
                            SettingLabel("Hold to Speed Up", systemImage: "forward.fill", tint: .blue)
                        }
                        Toggle(isOn: $settings.swipesForBrightness) {
                            SettingLabel("Swipe for Brightness", systemImage: "sun.max.fill", tint: .yellow)
                        }
                    }
                } header: {
                    Text("Videos")
                } footer: {
                    if !settings.videoModeEnabled {
                        Text("Video Mode adds YouTube itself beside your music: a Music and Video switch on Home, with videos, subscriptions and the video player.")
                    } else {
                        Text("Video Mode adds a Music and Video switch on Home. Each video starts at the Default Quality, or the best it has below it; Auto follows the connection. The player's menu changes the quality of the video playing. Double-tap either side of a video to skip 10 seconds, and keep tapping to skip further. Hold to Speed Up plays at 2× while you hold, and sliding sideways changes the speed. Swipe up on a video for full screen and down to leave it; in full screen, Swipe for Brightness sets the screen from the left half, and pinching fills the screen.")
                    }
                }

                Section {
                    NavigationLink {
                        LyricsSettingsView()
                    } label: {
                        SettingLabel("Lyrics", systemImage: "quote.bubble.fill", tint: .purple)
                    }
                    Picker(selection: $settings.theme) {
                        ForEach(AppSettings.Theme.allCases) { Text($0.title).tag($0) }
                    } label: {
                        SettingLabel("Appearance", systemImage: "circle.lefthalf.filled", tint: .blue)
                    }
                    Toggle(isOn: $settings.animatesPlayerBackground) {
                        SettingLabel("Moving Player Colours", systemImage: "wand.and.stars", tint: .orange)
                    }
                } header: {
                    Text("Look and Feel")
                } footer: {
                    Text("The colours of the playing song's cover drift behind Now Playing. Turned off, they hold still. They always hold still with Reduce Motion on.")
                }

                Section {
                    if Platform.isMac {
                        Button {
                            app.isProfilePresented = false
                            app.requestedMacSection = .lastFM
                        } label: {
                            HStack {
                                SettingLabel("Last.fm", systemImage: "dot.radiowaves.left.and.right", tint: .red)
                                Spacer()
                                Text(app.lastFM.isConnected ? (app.lastFM.isEnabled ? "On" : "Off") : "Not Connected")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
                        NavigationLink {
                            LastFMSettingsView()
                        } label: {
                            LabeledContent {
                                Text(app.lastFM.isConnected ? (app.lastFM.isEnabled ? "On" : "Off") : "Not Connected")
                            } label: {
                                SettingLabel("Last.fm", systemImage: "dot.radiowaves.left.and.right", tint: .red)
                            }
                        }
                    }
                } header: {
                    Text("Scrobbling")
                } footer: {
                    Text("Keep a record of what you play on your Last.fm profile.")
                }

                Section {
                    Button {
                        tuningTaste = true
                    } label: {
                        SettingLabel("Your Taste", systemImage: "sparkles", tint: .pink)
                    }
                    .foregroundStyle(.primary)
                } footer: {
                    Text("The artists, genres and songs Home starts from.")
                }

                Section {
                    NavigationLink {
                        PrivacySettingsView()
                    } label: {
                        SettingLabel("History and Privacy", systemImage: "hand.raised.fill", tint: .teal)
                    }
                    NavigationLink {
                        StorageSettingsView()
                    } label: {
                        SettingLabel("Storage", systemImage: "internaldrive.fill", tint: .gray)
                    }
                    NavigationLink {
                        BackupSettingsView()
                    } label: {
                        SettingLabel("Back Up and Restore", systemImage: "arrow.up.doc.fill", tint: .green)
                    }
                } header: {
                    Text("Your Data")
                } footer: {
                    Text("Your library, history and stats stay on this iPhone.")
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                    Link(destination: URL(string: "https://github.com/Ivorisnoob/Koda-iOS")!) {
                        Label("Koda on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    Link(destination: URL(string: "https://github.com/Ivorisnoob/Koda")!) {
                        Label("Koda for Android", systemImage: "iphone.gen3")
                    }
                } header: {
                    Text("About")
                } footer: {
                    Text("Koda is an unofficial client and is not affiliated with YouTube or Google. Lyrics come from YouLyPlus, BetterLyrics and LRCLIB. App icon by sameerasw (github.com/sameerasw).")
                }
            }
            .navigationTitle("Settings")
            // Its own sheet: Settings is itself a sheet, which one from the root can't cover.
            .sheet(isPresented: $tuningTaste) {
                OnboardingView(start: .taste, music: app.music, library: library).appEnvironment(app)
            }
            .scrollEdgeEffectStyle(.soft, for: .all)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
    }
}

/// A setting's name beside a coloured symbol tile, as the Settings app draws them.
struct SettingLabel: View {
    let title: String
    let systemImage: String
    let tint: Color

    init(_ title: String, systemImage: String, tint: Color) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 29, height: 29)
                .background(tint.gradient, in: .rect(cornerRadius: 7, style: .continuous))
        }
    }
}

// MARK: - Lyrics

struct LyricsSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                ForEach(settings.lyricsSourceOrder) { source in
                    Toggle(isOn: Binding(get: { settings.isEnabled(source) }, set: { settings.setEnabled(source, $0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.title)
                            Text(source.detail).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(settings.isEnabled(source) && settings.lyricsSources.count == 1)
                }
                .onMove { settings.lyricsSourceOrder.move(fromOffsets: $0, toOffset: $1) }
            } header: {
                Text("Sources")
            } footer: {
                Text("Koda asks every source at once. Word-by-word lyrics win; among equals, the higher source wins. Drag to reorder. At least one source stays on.")
            }

            Section {
                Picker("Text Size", selection: $settings.lyricsSize) {
                    ForEach(AppSettings.LyricsSize.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Word Motion", isOn: $settings.lyricsMotion)
                Toggle("Backing Vocals", isOn: $settings.showsBackingVocals)
                Toggle("Duet Sides", isOn: $settings.duetSides)
            } header: {
                Text("Display")
            } footer: {
                Text("Word Motion lifts each word as it is sung and lets long notes swell. Backing vocals appear smaller under their line. Duet Sides puts the second singer's lines on the right.")
            }

            Section {
                Button("Look Up Lyrics Again") {
                    Task { await app.lyrics.clearCache() }
                }
            } footer: {
                Text("Lyrics found earlier are kept until Koda closes. This forgets them, so the next song you open asks the sources again.")
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Lyrics")
    }
}

// MARK: - History and privacy

struct PrivacySettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(Library.self) private var library
    @State private var confirm: Confirmation?

    private enum Confirmation: Identifiable {
        case history, searches, stats
        var id: Self { self }
    }

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                Toggle("Save Listening History", isOn: $settings.savesListeningHistory)
                Toggle("Save Search History", isOn: $settings.savesSearchHistory)
            } footer: {
                Text("With listening history off, songs you play aren't added to Recently Played, Quick picks, Your Mix or your stats. What is already saved stays until you clear it.")
            }
            Section {
                NavigationLink {
                    SuggestLessView()
                } label: {
                    LabeledContent("Suggest Less", value: library.notInterested.isEmpty ? "" : "\(library.notInterested.songs.count + library.notInterested.artists.count)")
                }
            }
            Section {
                Button("Clear Listening History", role: .destructive) { confirm = .history }
                    .disabled(library.recent.isEmpty)
                Button("Clear Search History", role: .destructive) { confirm = .searches }
                    .disabled(library.searches.isEmpty)
                Button("Reset Listening Stats", role: .destructive) { confirm = .stats }
                    .disabled(library.songStats.isEmpty)
            }
        }
        .navigationTitle("History and Privacy")
        .confirmationDialog(title, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible,
                            presenting: confirm) { item in
            Button(buttonTitle(item), role: .destructive) {
                switch item {
                case .history: library.clearHistory()
                case .searches: library.clearSearches()
                case .stats: library.clearStats()
                }
            }
        } message: { item in
            Text(message(item))
        }
    }

    private var title: String {
        switch confirm {
        case .history: "Clear your listening history?"
        case .searches: "Clear your search history?"
        case .stats: "Reset your listening stats?"
        case nil: ""
        }
    }

    private func buttonTitle(_ item: Confirmation) -> String {
        switch item {
        case .history: "Clear History"
        case .searches: "Clear Searches"
        case .stats: "Reset Stats"
        }
    }

    private func message(_ item: Confirmation) -> String {
        switch item {
        case .history: "Recently Played and Quick picks start over. Liked songs and stats stay."
        case .searches: "Recent searches are removed."
        case .stats: "Play counts, listening time and streaks start over. Liked songs and history stay."
        }
    }
}

// MARK: - Storage

struct StorageSettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @Environment(Downloads.self) private var downloads
    @State private var artworkBytes: Int?
    @State private var cacheBytes: Int64?
    @State private var cleared = 0
    @State private var confirmsRemoveAll = false

    var body: some View {
        @Bindable var player = player
        @Bindable var downloads = downloads
        @Bindable var settings = app.settings
        Form {
            Section {
                LabeledContent("Downloads", value: downloads.bytes.formatted(.byteCount(style: .file)))
                Toggle("Download over Mobile Data", isOn: $downloads.allowsCellular)
                Button("Remove All Downloads", role: .destructive) { confirmsRemoveAll = true }
                    .disabled(downloads.songs.isEmpty)
            } header: {
                Text("Downloads")
            } footer: {
                Text("Downloaded songs play without a connection and stay until you remove them.")
            }
            Section {
                Toggle("Keep Songs You Play", isOn: $player.cachesWhileStreaming)
                Picker("Up To", selection: $settings.cacheLimit) {
                    ForEach(AppSettings.CacheLimit.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: settings.cacheLimit) { _, limit in
                    downloads.store.cacheLimit = limit.rawValue
                    Task { await measure() }
                }
                LabeledContent("Used") {
                    if let cacheBytes {
                        Text(cacheBytes.formatted(.byteCount(style: .file))).contentTransition(.numericText())
                    } else {
                        ProgressView()
                    }
                }
                Button("Clear Listening Cache", role: .destructive) {
                    downloads.store.clearCache()
                    cleared += 1
                    Task { await measure() }
                }
                .disabled((cacheBytes ?? 0) == 0)
            } header: {
                Text("Listening Cache")
            } footer: {
                Text("Songs are kept as you play them, so they start at once next time and play without a connection. Past the limit, the ones played longest ago are removed.")
            }
            Section {
                LabeledContent("Artwork") {
                    if let artworkBytes {
                        Text(artworkBytes.formatted(.byteCount(style: .file)))
                            .contentTransition(.numericText())
                    } else {
                        ProgressView()
                    }
                }
                Button("Clear Artwork Cache", role: .destructive) {
                    Task {
                        await ImagePipeline.shared.clear()
                        cleared += 1
                        await measure()
                    }
                }
                .disabled((artworkBytes ?? 0) == 0)
            } footer: {
                Text("Covers are kept so pages open quickly and work with a weak connection. Cleared, they download again as you browse. Koda never keeps more than 300 MB.")
            }
        }
        .navigationTitle("Storage")
        .sensoryFeedback(.success, trigger: cleared)
        .confirmationDialog("Remove all downloads?", isPresented: $confirmsRemoveAll, titleVisibility: .visible) {
            Button("Remove All Downloads", role: .destructive) { downloads.removeAll() }
        } message: {
            Text("They'll play from YouTube again, which needs a connection.")
        }
        .task { await measure() }
    }

    private func measure() async {
        let bytes = await ImagePipeline.shared.diskUsage()
        let store = downloads.store
        let audio = await Task.detached { store.cacheBytes }.value
        withAnimation {
            artworkBytes = bytes
            cacheBytes = audio
        }
    }
}

// MARK: - Backup

/// A library backup as a file for the share sheet and Files.
extension AndroidImportSummary {
    /// What importing takes, said beside the button.
    static let explanation = "Adds liked songs, listening history and stats, searches, the playlists you made and the albums and playlists you saved from a Koda for Android backup file. Nothing here is replaced. Videos, subscriptions, settings and songs that were files on the phone stay behind."

    /// What was added, as one sentence.
    var sentence: String {
        guard !isEmpty else { return "Everything in that backup is already in your library." }
        func count(_ n: Int, _ one: String, _ many: String) -> String? { n > 0 ? "\(n.formatted()) \(n == 1 ? one : many)" : nil }
        let parts = [
            count(likedSongs, "liked song", "liked songs"),
            count(playlists, "playlist", "playlists"),
            count(saved, "saved album or playlist", "saved albums and playlists"),
            count(plays, "play", "plays"),
            count(searches, "search", "searches"),
        ].compactMap { $0 }
        return "Added \(parts.formatted(.list(type: .and)))."
    }
}

extension View {
    /// Picks a Koda for Android backup and adds what Koda can use from it to the library.
    func androidBackupImporter(isPresented: Binding<Bool>, outcome: Binding<String?>) -> some View {
        modifier(AndroidBackupImporter(isPresented: isPresented, outcome: outcome))
    }
}

private struct AndroidBackupImporter: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var outcome: String?
    @Environment(Library.self) private var library

    func body(content: Content) -> some View {
        // Android's backup is a zip, whatever name or extension it arrived with.
        content.fileImporter(isPresented: $isPresented, allowedContentTypes: [.zip, .data]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let backup = try AndroidBackup.read(Data(contentsOf: url))
                outcome = library.importAndroid(backup).sentence
            } catch let error as AndroidBackup.ReadError {
                outcome = error.localizedDescription
            } catch {
                outcome = "Koda couldn't read that file."
            }
        }
    }
}

struct LibraryBackupDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct BackupSettingsView: View {
    @Environment(Library.self) private var library
    @State private var exportDocument: LibraryBackupDocument?
    @State private var importing = false
    @State private var importingAndroid = false
    @State private var pendingRestore: Data?
    @State private var outcome: String?

    var body: some View {
        Form {
            Section {
                Button {
                    if let data = library.backupData() { exportDocument = LibraryBackupDocument(data: data) }
                } label: {
                    Label("Back Up Library", systemImage: "square.and.arrow.up")
                }
            } footer: {
                Text("Saves liked songs, playlists you made, saved albums, playlists and artists, history, stats and lyric timings to one file you can keep in Files or iCloud Drive.")
            }
            Section {
                Button {
                    importing = true
                } label: {
                    Label("Restore from Backup", systemImage: "square.and.arrow.down")
                }
            } footer: {
                Text("Replaces everything in your library with what the backup holds.")
            }
            Section {
                // On the button rather than the form: two file importers on one view, and
                // only one of them opens.
                Button {
                    importingAndroid = true
                } label: {
                    Label("Import from Koda for Android", systemImage: "square.and.arrow.down.on.square")
                }
                .androidBackupImporter(isPresented: $importingAndroid, outcome: $outcome)
            } footer: {
                Text(AndroidImportSummary.explanation)
            }
        }
        .navigationTitle("Back Up and Restore")
        .fileExporter(isPresented: Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
                      document: exportDocument, contentType: .json,
                      defaultFilename: "Koda Library \(Date().formatted(.iso8601.year().month().day()))") { result in
            if case .success = result { outcome = "Your library is backed up." }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) {
                pendingRestore = data
            } else {
                outcome = "Koda couldn't read that file."
            }
        }
        .confirmationDialog("Replace your library with this backup?", isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
                            titleVisibility: .visible) {
            Button("Replace Library", role: .destructive) {
                guard let data = pendingRestore else { return }
                do {
                    try library.restore(from: data)
                    outcome = "Your library is restored."
                } catch {
                    outcome = error.localizedDescription
                }
            }
        } message: {
            Text("What is in your library now is replaced.")
        }
        .alert(outcome ?? "", isPresented: Binding(get: { outcome != nil }, set: { if !$0 { outcome = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }
}
