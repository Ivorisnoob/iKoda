import KodaCore
import MediaPlayer
import SwiftUI

/// The app's long-lived objects, shared through the environment.
@MainActor
@Observable
final class AppModel {
    let music: YouTubeMusic
    let videos: YouTubeVideos
    let player: Player
    let videoPlayback: VideoPlayback
    let videoModel: VideoModel
    let library: Library
    let lyrics = LyricsClient()
    let sleepTimer: SleepTimer
    /// The listener's profile: the active one in the roster, and its picture.
    let profile: Profile
    /// The roster of profiles: the one on this device and the accounts.
    let profiles: ProfileManager
    let settings = AppSettings()
    let downloads: Downloads
    let lastFM: LastFM
    /// The signed-in YouTube Music account: the session in the Keychain, who
    /// it is, and the account's library mirrored into Koda's.
    let account: AccountModel
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

    struct PlaylistTarget: Identifiable {
        let id = UUID()
        let songs: [Song]
    }

    init() {
        let directory = URL.applicationSupportDirectory.appending(path: "Koda")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The roster comes first: the session belongs to a profile, and the
        // library belongs to one too.
        let profiles = ProfileManager(directory: directory)
        let session = AccountStore(directory: directory)
        session.activate(profileID: profiles.activeID)
        music = YouTubeMusic(account: session)
        videos = YouTubeVideos(account: session)
        player = Player(music: music, storageDirectory: directory)
        videoPlayback = VideoPlayback(videos: videos)
        // A video and a song must not play at once: the picture wins and the music steps aside.
        videoPlayback.onStart = { [player] in player.pause() }
        videoModel = VideoModel(videos: videos)
        library = Library(directory: directory, profileID: profiles.activeID)
        sleepTimer = SleepTimer(player: player)
        profile = Profile(manager: profiles, directory: directory)
        self.profiles = profiles
        account = AccountModel(store: session, music: music, library: library, profiles: profiles)
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

    /// Make another profile the active one: the session, the library and the
    /// pages built for the old profile all move together.
    func switchProfile(to id: UUID) {
        account.activate(id)
        profile.reload()
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
    case home, library, search, videos
}
