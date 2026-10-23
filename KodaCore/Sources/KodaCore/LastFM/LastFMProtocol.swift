import CryptoKit
import Foundation

/// Last.fm's wire format: request signing and the few responses Koda reads.
/// https://www.last.fm/api/authspec, https://www.last.fm/api/scrobbling
public enum LastFMProtocol {
    public static let endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")!

    /// The `api_sig` of a call: every parameter but `format` and `callback`, sorted by name,
    /// names and values run together, the shared secret on the end, as an MD5 in hex.
    public static func signature(_ parameters: [String: String], secret: String) -> String {
        let text = parameters
            .filter { !["format", "callback", "api_sig"].contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { $0.key + $0.value }
            .joined() + secret
        return Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Where the listener approves Koda's token in their browser.
    public static func authorizationURL(apiKey: String, token: String) -> URL {
        var components = URLComponents(string: "https://www.last.fm/api/auth/")!
        components.queryItems = [URLQueryItem(name: "api_key", value: apiKey), URLQueryItem(name: "token", value: token)]
        return components.url!
    }

    /// An API key or shared secret as Last.fm issues them: 32 hex digits.
    public static func isCredential(_ text: String) -> Bool {
        text.count == 32 && text.allSatisfy(\.isHexDigit)
    }

    // MARK: Reading responses

    /// Last.fm answers a single item as an object and several as an array.
    static func objects(_ value: Any?) -> [[String: Any]] {
        if let array = value as? [[String: Any]] { return array }
        if let object = value as? [String: Any] { return [object] }
        return []
    }

    /// The largest image Last.fm offers over HTTPS; it lists them smallest first.
    static func imageURL(_ value: Any?) -> URL? {
        objects(value).reversed()
            .compactMap { $0["#text"] as? String }
            .first { $0.hasPrefix("https://") }
            .flatMap(URL.init(string:))
    }

    static func string(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    public static func recentTracks(_ root: [String: Any]) -> [LastFMTrack] {
        let tracks = (root["recenttracks"] as? [String: Any])?["track"]
        return objects(tracks).compactMap { track in
            let title = string(track["name"])
            guard !title.isEmpty else { return nil }
            let date = (track["date"] as? [String: Any]).flatMap { TimeInterval(string($0["uts"])) }
            return LastFMTrack(
                title: title,
                artist: string((track["artist"] as? [String: Any])?["#text"]),
                album: string((track["album"] as? [String: Any])?["#text"]),
                artwork: imageURL(track["image"]),
                isNowPlaying: string((track["@attr"] as? [String: Any])?["nowplaying"]) == "true",
                playedAt: date.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil })
        }
    }

    public static func profile(_ root: [String: Any]) -> LastFMProfile? {
        guard let user = root["user"] as? [String: Any] else { return nil }
        let registered = TimeInterval(string((user["registered"] as? [String: Any])?["unixtime"]))
        return LastFMProfile(
            name: string(user["name"]),
            realName: string(user["realname"]),
            country: { let c = string(user["country"]); return c == "None" ? "" : c }(),
            avatar: imageURL(user["image"]),
            playCount: Int(string(user["playcount"])) ?? 0,
            registered: registered.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil },
            isSubscriber: string(user["subscriber"]) == "1")
    }

    /// The `ignoredMessage` code of a one-track `track.scrobble`: 0 when accepted.
    public static func scrobbleCode(_ root: [String: Any]) throws -> Int {
        guard let result = root["scrobbles"] as? [String: Any],
              let scrobble = objects(result["scrobble"]).first,
              let ignored = scrobble["ignoredMessage"] as? [String: Any],
              let code = Int(string(ignored["code"])) else { throw LastFMError.unexpectedResponse }
        return code
    }
}

/// A play in the listener's Last.fm history.
public struct LastFMTrack: Hashable, Codable, Sendable, Identifiable {
    public var title: String
    public var artist: String
    public var album: String
    public var artwork: URL?
    public var isNowPlaying: Bool
    public var playedAt: Date?

    public var id: String { "\(playedAt?.timeIntervalSince1970 ?? -1)|\(artist)|\(title)" }
}

/// The listener's public Last.fm profile.
public struct LastFMProfile: Hashable, Codable, Sendable {
    public var name: String
    public var realName: String
    public var country: String
    public var avatar: URL?
    public var playCount: Int
    public var registered: Date?
    public var isSubscriber: Bool
}

/// Why a Last.fm call didn't go through, worded for the listener.
public enum LastFMError: LocalizedError, Equatable {
    case invalidCredentials
    case notConnected
    case paused
    case noPendingSignIn
    case signInExpired
    case notApprovedYet
    case sessionRevoked
    case rateLimited
    case dailyLimit
    case unexpectedResponse
    case network
    /// The Keychain wouldn't give up the sign-in yet: the device is locked, or Koda started before it was first unlocked.
    case credentialsLocked
    case api(Int, String)

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials: "An API key and shared secret are each 32 letters and digits. Copy them from your Last.fm API account."
        case .notConnected: "Connect your Last.fm account first."
        case .paused: "Last.fm is off."
        case .noPendingSignIn: "Start signing in again."
        case .signInExpired: "That sign-in expired after an hour. Start again."
        case .notApprovedYet: "Approve Koda on the Last.fm page first, then come back."
        case .sessionRevoked: "Last.fm no longer accepts this sign-in. Connect again."
        case .rateLimited: "Last.fm asked Koda to slow down. Plays wait and send in a few minutes."
        case .dailyLimit: "Last.fm's daily scrobble limit is reached. Plays wait and send later."
        case .unexpectedResponse: "Last.fm sent something Koda didn't understand."
        case .network: "Couldn't reach Last.fm. Plays wait and send when you're back online."
        case .credentialsLocked: "Your Last.fm sign-in can't be read while the device is locked. Plays wait and send after you unlock it."
        case .api(let code, let message): message.isEmpty ? "Last.fm error \(code)." : "\(message) (Last.fm error \(code))"
        }
    }

    /// Errors after which the queue waits five minutes rather than trying again at once.
    var coolsDown: Bool {
        switch self {
        case .network, .rateLimited, .dailyLimit, .credentialsLocked: true
        case .api(let code, _): [8, 11, 16, 29].contains(code)
        default: false
        }
    }

    static func fromAPI(code: Int, message: String) -> LastFMError {
        switch code {
        case 9: .sessionRevoked
        case 14: .notApprovedYet
        case 15: .signInExpired
        case 29: .rateLimited
        default: .api(code, message)
        }
    }
}

/// Counts what was actually heard of one play, the way Last.fm defines a scrobble: a track
/// over 30 seconds, heard for half its length or four minutes, whichever comes first.
/// Seeking never adds time; the player reports only seconds of sound.
public struct LastFMListeningClock: Sendable {
    public private(set) var occurrence: UUID?
    public private(set) var heard: TimeInterval = 0
    public private(set) var startedAt: Date?
    public private(set) var isSubmitted = false

    public init() {}

    public mutating func start(_ occurrence: UUID, at date: Date) {
        self.occurrence = occurrence
        heard = 0
        startedAt = date
        isSubmitted = false
    }

    public mutating func reset() {
        self = LastFMListeningClock()
    }

    /// Adds `seconds` of sound; true the moment the play first qualifies.
    public mutating func add(_ seconds: TimeInterval, to occurrence: UUID, duration: TimeInterval, at date: Date) -> Bool {
        if occurrence != self.occurrence { start(occurrence, at: date.addingTimeInterval(-seconds)) }
        heard += max(0, min(seconds, 6))
        guard !isSubmitted, Self.qualifies(heard: heard, duration: duration) else { return false }
        isSubmitted = true
        return true
    }

    public static func qualifies(heard: TimeInterval, duration: TimeInterval) -> Bool {
        duration > 30 && heard >= min(duration / 2, 240)
    }
}

extension Song {
    /// The artist a scrobble is filed under: the first one credited, as Last.fm keeps one
    /// artist per track, or the whole byline when YouTube didn't split it.
    public var scrobbleArtist: String {
        let first = artists.first?.name.trimmingCharacters(in: .whitespaces) ?? ""
        return first.isEmpty ? artistLine : first
    }
}
