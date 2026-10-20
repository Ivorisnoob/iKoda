import KodaCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A part of the Mac's Settings window.
enum MacSettingsPane: String, CaseIterable, Identifiable {
    case profile, youtube, playback, lyrics, appearance, lastFM, discord, privacy, storage, backup, about

    var id: Self { self }

    var title: String {
        switch self {
        case .profile: "Profile"
        case .youtube: "YouTube Music"
        case .playback: "Playback"
        case .lyrics: "Lyrics"
        case .appearance: "Appearance"
        case .lastFM: "Last.fm"
        case .discord: "Discord"
        case .privacy: "History & Privacy"
        case .storage: "Storage"
        case .backup: "Back Up & Restore"
        case .about: "About Koda"
        }
    }

    var systemImage: String {
        switch self {
        case .profile: "person.crop.circle.fill"
        case .youtube: "play.rectangle.fill"
        case .playback: "play.fill"
        case .lyrics: "quote.bubble.fill"
        case .appearance: "circle.lefthalf.filled"
        case .lastFM: "dot.radiowaves.left.and.right"
        case .discord: "bubble.left.and.bubble.right.fill"
        case .privacy: "hand.raised.fill"
        case .storage: "internaldrive.fill"
        case .backup: "arrow.up.doc.fill"
        case .about: "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .profile: .accentColor
        case .youtube: .red
        case .playback: .indigo
        case .lyrics: .purple
        case .appearance: .blue
        case .lastFM: .red
        case .discord: Color(red: 0.345, green: 0.396, blue: 0.949)
        case .privacy: .teal
        case .storage: .gray
        case .backup: .green
        case .about: .secondary
        }
    }
}

/// Koda's Settings on the Mac: its own window, a sidebar of panes as System Settings has, and
/// on the right each setting on a row of its own, name and explanation on the left, its
/// control on the right, in rounded groups.
struct MacSettingsView: View {
    static let windowID = "settings"
    @State private var pane: MacSettingsPane = .playback

    var body: some View {
        NavigationSplitView {
            List {
                ForEach(MacSettingsPane.allCases) { item in
                    Button { pane = item } label: {
                        MacSettingsSidebarRow(pane: item, isSelected: pane == item)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, 30)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 12) {
                        MacSettingsTile(systemImage: pane.systemImage, tint: pane.tint, size: 32)
                        Text(pane.title).font(.title2.bold())
                    }
                    content
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(pane.title)
        }
        .frame(minWidth: 720, minHeight: 500)
    }

    @ViewBuilder
    private var content: some View {
        switch pane {
        case .profile: MacProfilePane()
        case .youtube: MacYouTubePane()
        case .playback: MacPlaybackPane()
        case .lyrics: MacLyricsPane()
        case .appearance: MacAppearancePane()
        case .lastFM: MacLastFMPane()
        case .discord: MacDiscordPane()
        case .privacy: MacPrivacyPane()
        case .storage: MacStoragePane()
        case .backup: MacBackupPane()
        case .about: MacAboutPane()
        }
    }
}

// MARK: - Building blocks

/// A pane's symbol on a small coloured square, as System Settings draws them.
struct MacSettingsTile: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: .rect(cornerRadius: size * 0.24, style: .continuous))
    }
}

private struct MacSettingsSidebarRow: View {
    let pane: MacSettingsPane
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            MacSettingsTile(systemImage: pane.systemImage, tint: pane.tint)
            Text(pane.title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .frame(height: 30)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.primary.opacity(hovering ? 0.05 : 0)))
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }
}

/// A rounded group of rows, with a title above and a note below when there is one.
struct MacSettingsGroup<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.leading, 2)
            }
            VStack(spacing: 0) {
                Group(subviews: content()) { rows in
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { Divider().padding(.leading, 12) }
                        row
                    }
                }
            }
            .background(.background.secondary, in: .rect(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

/// One setting: its name, and a line on what it does, on the left; its control on the right.
struct MacSettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(minHeight: 38)
    }
}

/// A toggle row, the switch on the right as on the Mac.
struct MacSettingsToggle: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        MacSettingsRow(title: title, detail: detail) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

private func byteText(_ bytes: Int64?) -> String {
    bytes.map { $0.formatted(.byteCount(style: .file)) } ?? "…"
}

// MARK: - Panes

/// The profiles on this Mac: who the app is being, and who else it could be.
private struct MacProfilePane: View {
    @Environment(AppModel.self) private var app
    @State private var photo: PhotosPickerItem?
    @State private var showsSignIn = false

    var body: some View {
        Group {
            MacSettingsGroup(title: "Profiles",
                             footer: "Each profile keeps its own liked songs, history and playlists. Switching is instant and works without a connection.") {
                ForEach(app.account.roster) { profile in
                    profileRow(profile)
                }
            }
            if app.profile.profile.kind == .local {
                MacSettingsGroup(title: "Your Profile", footer: "Your name and photo are shown on the profile and on the playlists it makes. They stay on this Mac.") {
                    MacSettingsRow(title: "Name") {
                        TextField("Your name", text: Binding(
                            get: { app.profile.name },
                            set: { app.profile.setName($0) }))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                    }
                    MacSettingsRow(title: "Photo") {
                        HStack(spacing: 8) {
                            PhotosPicker("Choose Photo…", selection: $photo, matching: .images)
                            if app.profile.photo != nil {
                                Button("Remove Photo") { app.profile.setPhoto(nil) }
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }
            MacSettingsGroup {
                MacSettingsRow(title: "Add YouTube Account", detail: "Sign in with a Google account to bring its liked songs and playlists with you.") {
                    Button("Add…") { showsSignIn = true }
                }
                MacSettingsRow(title: "Add On-Device Profile", detail: "A profile with no account behind it.") {
                    Button("Add…") { app.switchProfile(to: app.profiles.addLocal().id) }
                }
            }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                app.profile.setPhoto(data)
                photo = nil
            }
        }
        .sheet(isPresented: $showsSignIn) {
            YouTubeSignInView { header in
                Task { await app.account.signIn(cookieHeader: header) }
            }
        }
        .task { app.profile.preparePhotos(for: app.account.roster) }
    }

    /// One profile in the roster: its picture, its name, and whether it is
    /// the one in use.
    private func profileRow(_ profile: KodaProfile) -> some View {
        HStack(spacing: 12) {
            ProfileAvatar(profile: profile, photo: app.profile.photo(for: profile), size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.displayName)
                    .font(.system(size: 13, weight: profile.id == app.profiles.activeID ? .semibold : .regular))
                    .lineLimit(1)
                Text(detail(for: profile))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if profile.id == app.profiles.activeID {
                Label("In use", systemImage: "checkmark")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 11))
                    .foregroundStyle(.tint)
            } else {
                Button("Use") { app.switchProfile(to: profile.id) }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(minHeight: 38)
    }

    private func detail(for profile: KodaProfile) -> String {
        if app.account.needsSignIn.contains(profile.id) { return "Needs signing in" }
        return profile.subtitle
    }
}

/// The YouTube Music account of the active profile: who is signed in, what
/// Koda has read from it, and the way in and out.
private struct MacYouTubePane: View {
    @Environment(AppModel.self) private var app
    @Environment(Library.self) private var library
    @State private var showsSignIn = false
    @State private var confirmsSignOut = false

    var body: some View {
        Group {
            if app.account.profile.kind == .youtube {
                signedIn
            } else {
                signedOut
            }
        }
        .sheet(isPresented: $showsSignIn) {
            YouTubeSignInView { header in
                Task { await app.account.signIn(cookieHeader: header) }
            }
        }
        .confirmationDialog("Sign out of YouTube Music?", isPresented: $confirmsSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { app.account.signOut() }
        } message: {
            Text("The session is forgotten on this Mac. Your library on this Mac stays as it is.")
        }
    }

    private var signedOut: some View {
        MacSettingsGroup(footer: "Signing in opens Google's own page in a secure web view. The session is read straight out of it and kept in the Keychain, on this Mac only.") {
            MacSettingsRow(title: "Not connected",
                           detail: "Sign in and Koda shows your liked songs, your playlists and a Home made for you.") {
                Button("Sign In…") { showsSignIn = true }
            }
        }
    }

    private var signedIn: some View {
        @Bindable var settings = app.settings
        return Group {
            MacSettingsGroup(title: "Account") {
                MacSettingsRow(title: app.account.name.isEmpty ? "YouTube Music" : app.account.name,
                               detail: "Signed in to YouTube Music") {
                    ProfileAvatar(profile: app.account.profile, photo: app.profile.photo(for: app.account.profile), size: 30)
                }
                if app.account.needsSignIn.contains(app.account.profile.id) || app.account.status == .expired {
                    MacSettingsRow(title: "Needs signing in",
                                   detail: app.account.status == .expired
                                   ? "YouTube has stopped accepting this session."
                                   : "This profile has no session on this Mac.") {
                        Button("Sign In Again…") { showsSignIn = true }
                    }
                }
            }
            MacSettingsGroup(title: "Your YouTube Music Library",
                             footer: "Koda reads your liked songs and your playlists from YouTube Music. Nothing of your own library is sent there.") {
                MacSettingsRow(title: "Liked songs", detail: "As of the last sync") {
                    Text(library.accountLiked.count.formatted()).foregroundStyle(.secondary)
                }
                MacSettingsRow(title: "Playlists", detail: "As of the last sync") {
                    Text(library.accountPlaylists.count.formatted()).foregroundStyle(.secondary)
                }
                MacSettingsRow(title: "Last synced", detail: lastSynced) {
                    Button(app.account.isSyncing ? "Syncing…" : "Sync Now") {
                        Task { await app.account.sync(force: true) }
                    }
                    .disabled(app.account.isSyncing)
                }
                MacSettingsToggle(title: "Personalized Home",
                                  detail: "With an account signed in, Home shows that account's own shelves and recommendations.",
                                  isOn: $settings.personalizedHome)
            }
            MacSettingsGroup {
                MacSettingsRow(title: "Sign out", detail: "The session is forgotten on this Mac.") {
                    Button("Sign Out…", role: .destructive) { confirmsSignOut = true }
                }
            }
        }
    }

    private var lastSynced: String {
        guard let date = app.account.lastSynced else { return "Never" }
        return date.formatted(.relative(presentation: .named))
    }
}

private struct MacPlaybackPane: View {
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player

    var body: some View {
        @Bindable var player = player
        @Bindable var settings = app.settings
        MacSettingsGroup {
            MacSettingsToggle(title: "Autoplay", detail: "When the queue ends, keep going with songs like the last one.",
                              isOn: $player.autoplay)
            MacSettingsToggle(title: "Normalize volume", detail: "Play loud masters at a similar level to everything else.",
                              isOn: $player.normalizesVolume)
        }
        MacSettingsGroup(title: "Crossfade", footer: "Skipping a song with crossfade on fades it out quickly instead of cutting it off.") {
            MacSettingsToggle(title: "Crossfade songs", detail: "The end of one song overlaps the start of the next.",
                              isOn: $player.crossfades)
            MacSettingsRow(title: "Overlap") {
                HStack(spacing: 8) {
                    Slider(value: $player.crossfadeDuration, in: 1...12, step: 1)
                        .frame(width: 180)
                    Text("\(Int(player.crossfadeDuration)) s")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
                .controlSize(.small)
            }
            .disabled(!player.crossfades)
        }
        MacSettingsGroup(title: "Skipping", footer: "⌥⌘← and ⌥⌘→ skip back and ahead too, with the buttons shown or not.") {
            MacSettingsToggle(title: "Skip buttons", detail: "Beside play in the player bar and Now Playing, to jump within the song.",
                              isOn: $settings.showsSkipButtons)
            MacSettingsRow(title: "Skip by") {
                Picker("Skip by", selection: $settings.skipInterval) {
                    ForEach(AppSettings.SkipInterval.allCases) { Text("\($0.rawValue) s").tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
        MacSettingsGroup(title: "Volume", footer: "A Mac app can't set the system volume, so this is Koda's own level, under the system's. ⌘↑ and ⌘↓ change it too.") {
            MacSettingsRow(title: "Koda's volume") {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { Double(player.volume) }, set: { player.volume = Float($0) }), in: 0...1)
                        .frame(width: 180)
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }
                .controlSize(.small)
            }
        }
    }
}

private struct MacLyricsPane: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        let order = settings.lyricsSourceOrder
        MacSettingsGroup(title: "Sources",
                         footer: "Koda asks every source at once. Word-by-word lyrics win; among equals, the higher source wins. At least one stays on.") {
            ForEach(Array(order.enumerated()), id: \.element) { index, source in
                MacSettingsRow(title: source.title, detail: source.detail) {
                    HStack(spacing: 4) {
                        Button { settings.lyricsSourceOrder.move(fromOffsets: [index], toOffset: index - 1) } label: {
                            Image(systemName: "chevron.up")
                        }
                        .disabled(index == 0)
                        .help("Move Up")
                        Button { settings.lyricsSourceOrder.move(fromOffsets: [index], toOffset: index + 2) } label: {
                            Image(systemName: "chevron.down")
                        }
                        .disabled(index == order.count - 1)
                        .help("Move Down")
                        Toggle(source.title, isOn: Binding(get: { settings.isEnabled(source) }, set: { settings.setEnabled(source, $0) }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .disabled(settings.isEnabled(source) && settings.lyricsSources.count == 1)
                            .padding(.leading, 6)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        MacSettingsGroup(title: "Display") {
            MacSettingsRow(title: "Text size") {
                Picker("Text size", selection: $settings.lyricsSize) {
                    ForEach(AppSettings.LyricsSize.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            MacSettingsToggle(title: "Word motion", detail: "Each word lifts as it's sung, and long notes swell.", isOn: $settings.lyricsMotion)
            MacSettingsToggle(title: "Backing vocals", detail: "Shown smaller, under their line.", isOn: $settings.showsBackingVocals)
            MacSettingsToggle(title: "Duet sides", detail: "The second singer's lines sit on the right.", isOn: $settings.duetSides)
        }
        MacSettingsGroup(footer: "Lyrics found earlier are kept until Koda quits. This forgets them, so the next song asks the sources again.") {
            MacSettingsRow(title: "Look up lyrics again") {
                Button("Forget Found Lyrics") { Task { await app.lyrics.clearCache() } }
            }
        }
    }
}

private struct MacAppearancePane: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        MacSettingsGroup {
            MacSettingsRow(title: "Appearance") {
                Picker("Appearance", selection: $settings.theme) {
                    ForEach(AppSettings.Theme.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            MacSettingsToggle(title: "Moving player colours",
                              detail: "The playing song's colours drift behind Now Playing. They always hold still with Reduce Motion on.",
                              isOn: $settings.animatesPlayerBackground)
        }
    }
}

private struct MacLastFMPane: View {
    @Environment(AppModel.self) private var app
    @Environment(LastFM.self) private var lastFM

    var body: some View {
        MacSettingsGroup(footer: "Keep a record of what you play on your Last.fm profile. Your account, history and connection live on the Last.fm page in the sidebar.") {
            MacSettingsRow(title: lastFM.isConnected ? "Connected as \(lastFM.user)" : "Not connected",
                           detail: lastFM.isConnected ? LastFMUI.status(lastFM) : "Connect with your own free Last.fm API account.") {
                Button(lastFM.isConnected ? "Open Last.fm" : "Connect…") { app.requestedMacSection = .lastFM }
            }
            if lastFM.isConnected {
                MacSettingsToggle(title: "Scrobble", isOn: Binding(get: { lastFM.isEnabled }, set: { lastFM.setEnabled($0) }))
            }
        }
    }
}

private struct MacDiscordPane: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        MacSettingsGroup(footer: "Your Discord profile shows “Listening to” the song, with its cover and a link to it on YouTube Music. It needs the Discord app open on this Mac, and the song leaves your profile a minute after you pause.") {
            MacSettingsToggle(title: "Show what you're playing", isOn: $settings.sharesOnDiscord)
            if settings.sharesOnDiscord {
                MacSettingsRow(title: "Status", detail: detail) {
                    Text(status).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var status: String {
        guard app.settings.savesListeningHistory else { return "Paused" }
        return switch app.discord?.status ?? .off {
        case .off, .waiting: "Waiting for a song"
        case .unavailable: "Discord isn't open"
        case .showing: "On your profile"
        case .refused: "Not accepted"
        }
    }

    private var detail: String? {
        guard app.settings.savesListeningHistory else { return "Nothing is shared while listening history is off." }
        return switch app.discord?.status ?? .off {
        case .unavailable: "Koda keeps looking, and shows the song once Discord opens."
        case .refused: "Discord didn't accept this song's details."
        default: nil
        }
    }
}

private struct MacPrivacyPane: View {
    @Environment(AppModel.self) private var app
    @Environment(Library.self) private var library
    @State private var confirm: Confirm?

    private enum Confirm: Identifiable {
        case history, searches, stats
        var id: Self { self }
    }

    var body: some View {
        @Bindable var settings = app.settings
        MacSettingsGroup(footer: "With listening history off, songs you play don't reach Recently Played, Quick picks, Your Mix, your stats, Last.fm or Discord. What's saved stays until you clear it.") {
            MacSettingsToggle(title: "Save listening history", isOn: $settings.savesListeningHistory)
            MacSettingsToggle(title: "Save search history", isOn: $settings.savesSearchHistory)
        }
        MacSettingsGroup(title: "Clear") {
            MacSettingsRow(title: "Listening history", detail: "Recently Played and Quick picks start over.") {
                Button("Clear…") { confirm = .history }.disabled(library.recent.isEmpty)
            }
            MacSettingsRow(title: "Search history") {
                Button("Clear…") { confirm = .searches }.disabled(library.searches.isEmpty)
            }
            MacSettingsRow(title: "Listening stats", detail: "Play counts, listening time and streaks.") {
                Button("Reset…") { confirm = .stats }.disabled(library.songStats.isEmpty)
            }
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible, presenting: confirm) { item in
            Button(item == .stats ? "Reset Stats" : "Clear", role: .destructive) {
                switch item {
                case .history: library.clearHistory()
                case .searches: library.clearSearches()
                case .stats: library.clearStats()
                }
            }
        }
    }

    private var confirmTitle: String {
        switch confirm {
        case .history: "Clear your listening history?"
        case .searches: "Clear your search history?"
        case .stats: "Reset your listening stats?"
        case nil: ""
        }
    }
}

private struct MacStoragePane: View {
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @Environment(Downloads.self) private var downloads
    @State private var artworkBytes: Int64?
    @State private var cacheBytes: Int64?
    @State private var confirmsRemoveAll = false

    var body: some View {
        @Bindable var player = player
        @Bindable var settings = app.settings
        MacSettingsGroup(title: "Downloads", footer: "Downloaded songs play without a connection and stay until you remove them.") {
            MacSettingsRow(title: "Downloaded songs", detail: "\(downloads.songs.count) songs · \(downloads.bytes.formatted(.byteCount(style: .file)))") {
                Button("Remove All…") { confirmsRemoveAll = true }.disabled(downloads.songs.isEmpty)
            }
        }
        MacSettingsGroup(title: "Listening cache",
                         footer: "Songs are kept as you play them, so they start at once next time and play offline. Past the limit, the ones played longest ago go first.") {
            MacSettingsToggle(title: "Keep songs you play", isOn: $player.cachesWhileStreaming)
            MacSettingsRow(title: "Up to") {
                Picker("Up to", selection: $settings.cacheLimit) {
                    ForEach(AppSettings.CacheLimit.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: settings.cacheLimit) { _, limit in
                    downloads.store.cacheLimit = limit.rawValue
                    Task { await measure() }
                }
            }
            MacSettingsRow(title: "Used", detail: byteText(cacheBytes)) {
                Button("Clear") {
                    downloads.store.clearCache()
                    Task { await measure() }
                }
                .disabled((cacheBytes ?? 0) == 0)
            }
        }
        MacSettingsGroup(title: "Artwork", footer: "Covers are kept so pages open quickly. Cleared, they download again as you browse. Never more than 300 MB.") {
            MacSettingsRow(title: "Used", detail: byteText(artworkBytes)) {
                Button("Clear") {
                    Task {
                        await ImagePipeline.shared.clear()
                        await measure()
                    }
                }
                .disabled((artworkBytes ?? 0) == 0)
            }
        }
        .confirmationDialog("Remove all downloads?", isPresented: $confirmsRemoveAll, titleVisibility: .visible) {
            Button("Remove All Downloads", role: .destructive) { downloads.removeAll() }
        } message: {
            Text("They'll play from YouTube again, which needs a connection.")
        }
        .task { await measure() }
    }

    private func measure() async {
        let artwork = await ImagePipeline.shared.diskUsage()
        let store = downloads.store
        let audio = await Task.detached { store.cacheBytes }.value
        artworkBytes = Int64(artwork)
        cacheBytes = audio
    }
}

private struct MacBackupPane: View {
    @Environment(AppModel.self) private var app
    @Environment(Library.self) private var library
    @State private var exportDocument: LibraryBackupDocument?
    @State private var importing = false
    @State private var importingAndroid = false
    @State private var pendingRestore: Data?
    @State private var outcome: String?

    var body: some View {
        MacSettingsGroup(footer: "A backup holds liked songs, your playlists, saved albums, playlists and artists, history, stats and lyric timings. Your profiles go with it; Last.fm sign-in doesn't.") {
            MacSettingsRow(title: "Back up library", detail: "Save everything to one file.") {
                Button("Back Up…") {
                    if let data = library.backupData(roster: app.profiles.rosterData()) {
                        exportDocument = LibraryBackupDocument(data: data)
                    }
                }
            }
            MacSettingsRow(title: "Restore from backup", detail: "Replaces everything in your library with what the backup holds.") {
                Button("Restore…") { importing = true }
            }
        }
        MacSettingsGroup(title: "Koda for Android", footer: AndroidImportSummary.explanation) {
            MacSettingsRow(title: "Import from Koda for Android", detail: "Choose the backup file you made in Koda on your phone.") {
                Button("Import…") { importingAndroid = true }
                    // Its own importer, on its own button: two on one view and only one opens.
                    .androidBackupImporter(isPresented: $importingAndroid, outcome: $outcome)
            }
        }
        .fileExporter(isPresented: Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
                      document: exportDocument, contentType: .json,
                      defaultFilename: "Koda Library \(Date().formatted(.iso8601.year().month().day()))") { result in
            if case .success = result { outcome = "Your library is backed up." }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) { pendingRestore = data } else { outcome = "Koda couldn't read that file." }
        }
        .confirmationDialog("Replace your library with this backup?",
                            isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
                            titleVisibility: .visible) {
            Button("Replace Library", role: .destructive) {
                guard let data = pendingRestore else { return }
                do {
                    try library.restore(from: data)
                    // The profiles come back with the library; the accounts
                    // have to be signed into again.
                    if let roster = Library.roster(in: data) {
                        app.profiles.restoreRoster(from: roster)
                    }
                    outcome = "Your library is restored."
                } catch {
                    outcome = error.localizedDescription
                }
            }
        } message: {
            Text("What's in your library now is replaced.")
        }
        .alert(outcome ?? "", isPresented: Binding(get: { outcome != nil }, set: { if !$0 { outcome = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }
}

private struct MacAboutPane: View {
    var body: some View {
        MacSettingsGroup(footer: "Koda is an unofficial client and isn't affiliated with YouTube or Google. Lyrics come from YouLyPlus, BetterLyrics and LRCLIB. App icon by sameerasw (github.com/sameerasw).") {
            MacSettingsRow(title: "Version") {
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                    .foregroundStyle(.secondary)
            }
            MacSettingsRow(title: "Koda on GitHub") {
                Link("Open", destination: URL(string: "https://github.com/Ivorisnoob/Koda-iOS")!)
            }
            MacSettingsRow(title: "Koda for Android") {
                Link("Open", destination: URL(string: "https://github.com/Ivorisnoob/Koda")!)
            }
        }
    }
}
