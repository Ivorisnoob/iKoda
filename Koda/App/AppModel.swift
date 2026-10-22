import KodaCore
import MediaPlayer
import SwiftUI

/// The app's long-lived objects, shared through the environment.
@MainActor
@Observable
final class AppModel {
    let music: YouTubeMusic
    let player: Player
    let library: Library
    let lyrics = LyricsClient()
    let sleepTimer: SleepTimer
    /// Everyone who uses Koda on this device; the library is the active profile's.
    let roster: ProfileRoster
    let profilePhotos: ProfilePhotos
    /// The active profile's Home, shared by the phone's tab and the Mac's page; a new one per profile.
    private(set) var home: HomeModel
    let settings = AppSettings()
    let downloads: Downloads
    let lastFM: LastFM
    /// The playing song on Discord; the Mac only, where the Discord app takes it from Koda directly.
    let discord: DiscordPresence?

    var isNowPlayingPresented = false
    /// The panel Now Playing should show when it next opens or is already open: the Mac's
    /// player bar and menu bar open lyrics and the queue directly.
    var requestedPanel: NowPlayingView.Panel?
    /// Profile and Settings, opened from Home or from the Mac's Settings menu item.
    var isProfilePresented = false
    /// A sidebar place for the Mac's window to go to, asked for from elsewhere, e.g. Settings.
    var requestedMacSection: MacSection?
    /// The playing song's colours, kept ready for Now Playing while it is closed.
    let nowPlayingPalette = PaletteModel()
    /// Set to switch tabs from anywhere, e.g. "Go to artist" inside Now Playing.
    var selectedTab: AppTab = .home
    /// A page to open on the current tab's stack.
    var pendingRoute: Route?
    /// Songs waiting for the listener to pick a playlist for them.
    var playlistTarget: PlaylistTarget?
    /// A shared link that could not be opened, shown as an alert.
    var linkError: String?
    /// The sheet that adds a profile, asked for from a toolbar menu, the profile page or the Mac's sidebar.
    var isAddingProfile = false
    /// The pane the Mac's Settings window should show when it next opens or is already open.
    var requestedSettingsPane: MacSettingsPane?

    struct PlaylistTarget: Identifiable {
        let id = UUID()
        let songs: [Song]
    }

    init() {
        let directory = URL.applicationSupportDirectory.appending(path: "Koda")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        music = YouTubeMusic()
        player = Player(music: music, storageDirectory: directory)
        // Before profiles the name lived in the defaults and the library at the top of the folder;
        // the roster moves both into the first profile.
        roster = ProfileRoster(root: directory, legacyName: UserDefaults.standard.string(forKey: "koda.profile.name"))
        profilePhotos = ProfilePhotos(roster: roster)
        library = Library(directory: roster.folder(for: roster.activeID))
        home = HomeModel(profile: roster.activeID)
        sleepTimer = SleepTimer(player: player)
        let settings = settings
        // Songs can be gigabytes; they come back from YouTube, so they stay out of iCloud backups.
        var audioDirectory = directory.appending(path: "Audio")
        try? FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? audioDirectory.setResourceValues(values)
        let audio = AudioStore(directory: audioDirectory, cacheLimit: settings.cacheLimit.rawValue)
        player.audioStore = audio
        downloads = Downloads(store: audio, music: music)
        player.onSongStarted = { [library] song in
            if settings.savesListeningHistory { library.recordPlay(song) }
        }
        player.onListened = { [library] song, seconds in
            if settings.savesListeningHistory { library.addListening(seconds, to: song) }
        }
        player.isUnwanted = { [library] song in library.isHidden(song) }
        let lastFM = LastFM(directory: directory)
        self.lastFM = lastFM
        player.onItemStarted = { [lastFM, player] item in
            let song = item.song
            lastFM.started(item.id, artist: song.scrobbleArtist, track: song.title, album: song.album?.title ?? "",
                           duration: song.duration ?? player.duration, isVideo: song.isVideo)
        }
        lastFM.isPaused = !settings.savesListeningHistory
        // Plays that waited out a network failure or a rate limit go when it's over.
        Task { [lastFM] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                lastFM.syncSoon()
            }
        }
        player.onItemHeard = { [lastFM, player] item, seconds in
            let song = item.song
            lastFM.heard(seconds, of: item.id, artist: song.scrobbleArtist, track: song.title, album: song.album?.title ?? "",
                         duration: song.duration ?? player.duration, isVideo: song.isVideo)
        }
        // Paused listening history keeps the song off Discord too, as it does Last.fm.
        discord = Platform.isMac
            ? DiscordPresence(isAllowed: { [settings] in settings.sharesOnDiscord && settings.savesListeningHistory }, player: player)
            : nil
        if Platform.isMac, UserDefaults.standard.object(forKey: "volume") != nil {
            player.volume = UserDefaults.standard.float(forKey: "volume")
        }
        player.artworkLoader = { @MainActor url in
            guard let image = await ImagePipeline.shared.image(url, pixels: 600) else { return nil }
            return ImagePipeline.nowPlayingArtwork(image)
        }
    }

    /// Make another profile the active one: its library replaces this one's everywhere at once.
    /// The queue keeps playing; what is listened to from here on counts for the new profile.
    func switchProfile(to id: UUID) {
        guard id != roster.activeID, roster.profile(id) != nil else { return }
        library.open(directory: roster.folder(for: id))
        home = HomeModel(profile: id)
        roster.setActive(id)
    }

    /// Delete a profile and what it keeps on this device; another takes over if it was active.
    func deleteProfile(_ id: UUID) {
        roster.delete(id) { next in
            library.open(directory: roster.folder(for: next))
            home = HomeModel(profile: next)
        }
        Snapshot.remove("home-\(id.uuidString)")
    }

    /// Open a page from outside a navigation stack: closes Now Playing and pushes it on the current tab.
    func open(_ route: Route) {
        isNowPlayingPresented = false
        pendingRoute = route
    }

    /// Open Now Playing on one of its panels.
    func showNowPlaying(_ panel: NowPlayingView.Panel) {
        guard player.current != nil else { return }
        requestedPanel = panel
        isNowPlayingPresented = true
    }

    /// Switch tabs from the menu bar, closing Now Playing if it covers them.
    func go(to tab: AppTab) {
        isNowPlayingPresented = false
        selectedTab = tab
    }

    enum Collection {
        case album(AlbumSummary)
        case playlist(PlaylistSummary)
    }

    /// Play an album or playlist from its card, without opening its page.
    func playCollection(_ collection: Collection) {
        Task {
            do {
                let songs = switch collection {
                case .album(let album): try await music.album(album.id).songs
                case .playlist(let playlist): try await music.playlist(playlist.id).songs
                }
                guard !songs.isEmpty else { return }
                player.play(songs)
            } catch {
                linkError = error.friendlyMessage
            }
        }
    }

    func addToPlaylist(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        playlistTarget = PlaylistTarget(songs: songs)
    }

    /// Open a YouTube, YouTube Music or koda:// link: a song plays with its radio, anything else opens its page.
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard let link = YouTubeLink(url) else { return false }
        openLink(link)
        return true
    }

    func openLink(_ link: YouTubeLink) {
        switch link {
        case .song(let videoId):
            Task { await playLinkedSong(videoId) }
        case .album(let browseId):
            open(.album(AlbumSummary(id: browseId, title: "", artistLine: "")))
        case .playlist(let id):
            open(.playlist(PlaylistSummary(id: id, title: "")))
        case .artist(let channelId):
            open(.artist(ArtistSummary(id: channelId, name: "")))
        }
    }

    /// A video id alone carries no title or artist; its radio starts with the song itself, which has both.
    private func playLinkedSong(_ videoId: String) async {
        do {
            let radio = try await music.radio(for: videoId)
            guard let seed = radio.songs.first(where: { $0.id == videoId }) ?? radio.songs.first else {
                linkError = "That song isn't available."
                return
            }
            player.play([seed] + radio.songs.filter { $0.id != seed.id })
            isNowPlayingPresented = true
        } catch {
            linkError = error.friendlyMessage
        }
    }

    /// The app is leaving the screen: write what is only kept in memory.
    func saveState() {
        player.persistQueueNow()
        library.flush()
        downloads.store.flush()
        if Platform.isMac { UserDefaults.standard.set(player.volume, forKey: "volume") }
    }
}

enum AppTab: Hashable {
    case home, library, search
}
