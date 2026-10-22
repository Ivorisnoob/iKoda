import KodaCore
import SwiftUI

/// The listener's preferences, each saved the moment it changes.
@MainActor
@Observable
final class AppSettings {
    enum Theme: String, CaseIterable, Identifiable {
        case system, light, dark

        var id: Self { self }
        var title: String {
            switch self {
            case .system: "Automatic"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    enum LyricsSize: String, CaseIterable, Identifiable {
        case small, standard, large

        var id: Self { self }
        var title: String {
            switch self {
            case .small: "Small"
            case .standard: "Default"
            case .large: "Large"
            }
        }
        /// Point size of a sung line; backing vocals are drawn at 70% of it.
        var fontSize: CGFloat {
            switch self {
            case .small: 25
            case .standard: 30
            case .large: 35
            }
        }
    }

    /// The most the songs kept from listening may take; downloads don't count.
    enum CacheLimit: Int64, CaseIterable, Identifiable {
        case small = 500_000_000
        case standard = 1_000_000_000
        case large = 2_000_000_000
        case huge = 5_000_000_000

        var id: Self { self }
        var title: String { rawValue.formatted(.byteCount(style: .file)) }
    }

    /// How far the skip buttons jump. Each has an SF Symbol drawing its number.
    enum SkipInterval: Int, CaseIterable, Identifiable {
        case five = 5, ten = 10, fifteen = 15, thirty = 30

        var id: Self { self }
        var seconds: TimeInterval { TimeInterval(rawValue) }
        var title: String { "\(rawValue) Seconds" }
        var backSymbol: String { "gobackward.\(rawValue)" }
        var forwardSymbol: String { "goforward.\(rawValue)" }
    }

    /// Songs or videos: which the app is showing. Each has its own tabs (iPhone) and sidebar (Mac).
    enum Mode: String, CaseIterable, Identifiable {
        case music, video
        var id: Self { self }
        var title: String { self == .music ? "Music" : "Video" }
        var systemImage: String { self == .music ? "music.note" : "play.rectangle.fill" }
    }

    private let defaults = UserDefaults.standard

    var theme: Theme { didSet { defaults.set(theme.rawValue, forKey: Keys.theme) } }
    /// The cover's colours drift behind Now Playing; off, they hold still.
    var animatesPlayerBackground: Bool { didSet { defaults.set(animatesPlayerBackground, forKey: Keys.animatedBackground) } }
    /// Every lyrics service, best first; the order decides which answer wins.
    var lyricsSourceOrder: [LyricsSource] { didSet { defaults.set(lyricsSourceOrder.map(\.rawValue), forKey: Keys.lyricsOrder) } }
    var disabledLyricsSources: Set<LyricsSource> { didSet { defaults.set(disabledLyricsSources.map(\.rawValue), forKey: Keys.lyricsDisabled) } }
    /// Words rise as they start and held notes swell.
    var lyricsMotion: Bool { didSet { defaults.set(lyricsMotion, forKey: Keys.lyricsMotion) } }
    var lyricsSize: LyricsSize { didSet { defaults.set(lyricsSize.rawValue, forKey: Keys.lyricsSize) } }
    var showsBackingVocals: Bool { didSet { defaults.set(showsBackingVocals, forKey: Keys.backingVocals) } }
    /// The second singer of a duet on the right; off, every line sits on the left.
    var duetSides: Bool { didSet { defaults.set(duetSides, forKey: Keys.duetSides) } }
    /// Off, nothing played is added to history, Quick picks or stats.
    var savesListeningHistory: Bool { didSet { defaults.set(savesListeningHistory, forKey: Keys.listeningHistory) } }
    var savesSearchHistory: Bool { didSet { defaults.set(savesSearchHistory, forKey: Keys.searchHistory) } }
    var cacheLimit: CacheLimit { didSet { defaults.set(cacheLimit.rawValue, forKey: Keys.cacheLimit) } }
    /// Buttons beside previous and next that jump back or ahead within the song.
    var showsSkipButtons: Bool { didSet { defaults.set(showsSkipButtons, forKey: Keys.skipButtons) } }
    var skipInterval: SkipInterval { didSet { defaults.set(skipInterval.rawValue, forKey: Keys.skipInterval) } }
    /// The playing song on the listener's Discord profile, through the Discord app on the Mac.
    var sharesOnDiscord: Bool { didSet { defaults.set(sharesOnDiscord, forKey: Keys.discordPresence) } }
    var mode: Mode { didSet { defaults.set(mode.rawValue, forKey: Keys.mode) } }
    /// The tallest picture a video plays at, in lines (720, 1080…); 0 lets it follow the connection.
    var videoQuality: Int { didSet { defaults.set(videoQuality, forKey: Keys.videoQuality) } }
    /// The welcome and taste setup have been offered on this device, finished or skipped.
    var hasSeenOnboarding: Bool { didSet { defaults.set(hasSeenOnboarding, forKey: Keys.onboarding) } }

    private enum Keys {
        static let theme = "koda.theme"
        static let animatedBackground = "koda.player.animatedBackground"
        static let lyricsOrder = "koda.lyrics.order"
        static let lyricsDisabled = "koda.lyrics.disabled"
        static let lyricsMotion = "koda.lyrics.motion"
        static let lyricsSize = "koda.lyrics.size"
        static let backingVocals = "koda.lyrics.backingVocals"
        static let duetSides = "koda.lyrics.duetSides"
        static let listeningHistory = "koda.history.listening"
        static let searchHistory = "koda.history.search"
        static let cacheLimit = "koda.cache.limit"
        static let skipButtons = "koda.player.skipButtons"
        static let skipInterval = "koda.player.skipInterval"
        static let discordPresence = "koda.discord.presence"
        static let onboarding = "koda.onboarding.seen"
        static let mode = "koda.mode"
        static let videoQuality = "koda.video.quality"
    }

    init() {
        let d = UserDefaults.standard
        theme = d.string(forKey: Keys.theme).flatMap(Theme.init(rawValue:)) ?? .system
        animatesPlayerBackground = d.object(forKey: Keys.animatedBackground) as? Bool ?? true
        // Services added in a later version join at the end of a saved order.
        let saved = (d.stringArray(forKey: Keys.lyricsOrder) ?? []).compactMap(LyricsSource.init(rawValue:))
        lyricsSourceOrder = saved + LyricsSource.allCases.filter { !saved.contains($0) }
        disabledLyricsSources = Set((d.stringArray(forKey: Keys.lyricsDisabled) ?? []).compactMap(LyricsSource.init(rawValue:)))
        lyricsMotion = d.object(forKey: Keys.lyricsMotion) as? Bool ?? true
        lyricsSize = d.string(forKey: Keys.lyricsSize).flatMap(LyricsSize.init(rawValue:)) ?? .standard
        showsBackingVocals = d.object(forKey: Keys.backingVocals) as? Bool ?? true
        duetSides = d.object(forKey: Keys.duetSides) as? Bool ?? true
        savesListeningHistory = d.object(forKey: Keys.listeningHistory) as? Bool ?? true
        savesSearchHistory = d.object(forKey: Keys.searchHistory) as? Bool ?? true
        cacheLimit = (d.object(forKey: Keys.cacheLimit) as? Int64).flatMap(CacheLimit.init(rawValue:)) ?? .standard
        showsSkipButtons = d.object(forKey: Keys.skipButtons) as? Bool ?? true
        skipInterval = (d.object(forKey: Keys.skipInterval) as? Int).flatMap(SkipInterval.init(rawValue:)) ?? .ten
        sharesOnDiscord = d.object(forKey: Keys.discordPresence) as? Bool ?? false
        hasSeenOnboarding = d.bool(forKey: Keys.onboarding)
        mode = d.string(forKey: Keys.mode).flatMap(Mode.init(rawValue:)) ?? .music
        videoQuality = d.integer(forKey: Keys.videoQuality)
    }

    /// The services to ask, best first.
    var lyricsSources: [LyricsSource] { lyricsSourceOrder.filter { !disabledLyricsSources.contains($0) } }

    func isEnabled(_ source: LyricsSource) -> Bool { !disabledLyricsSources.contains(source) }

    /// The last enabled service cannot be turned off; lyrics need somewhere to come from.
    func setEnabled(_ source: LyricsSource, _ on: Bool) {
        if on {
            disabledLyricsSources.remove(source)
        } else if lyricsSources.count > 1 {
            disabledLyricsSources.insert(source)
        }
    }
}
