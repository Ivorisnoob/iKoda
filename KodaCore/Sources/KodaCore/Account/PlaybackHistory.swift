import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Telling YouTube what was played, so the signed-in account's history and recommendations
/// follow Koda, as the web player does: a signed `/player` call hands back tracking URLs, and
/// the `videostatsPlaybackUrl` ping files the play. Koda for Android's PlaybackHistory.kt,
/// which verified it against FEmusic_history (September–October 2026).
extension YouTubeMusic {
    /// File one play in the active account's history. Throws `MusicError.signedOut` with no
    /// session or when YouTube answers as signed out: a dead session still gets tracking URLs
    /// and a 204 on the ping, and the play goes nowhere, so `logged_in` is the only honest check.
    public func reportPlayback(videoId: String) async throws {
        guard let profile = await accounts.active?.profileID else { throw MusicError.signedOut }
        let cpn = HistoryPing.cpn()
        let sent = await signatures.current()
        var root = try await api.music("player", HistoryPing.playerPayload(videoId: videoId, cpn: cpn, signatureTimestamp: sent),
                                       signing: .required)
        if !root["playbackTracking"].exists, let retry = await signatures.refreshAfterRejection(sent) {
            // A signatureTimestamp YouTube no longer takes looks exactly like an unavailable video.
            root = try await api.music("player", HistoryPing.playerPayload(videoId: videoId, cpn: cpn, signatureTimestamp: retry),
                                       signing: .required)
        }
        guard let base = root["playbackTracking"]["videostatsPlaybackUrl"]["baseUrl"].nonEmpty,
              let url = HistoryPing.trackingURL(base, cpn: cpn) else { throw MusicError.badResponse(200) }
        // The ping is the write that reaches the account: never as another profile switched to meanwhile.
        guard await accounts.active?.profileID == profile else { return }
        try await api.ping(url, referer: "https://music.youtube.com/watch?v=\(videoId)")
    }
}

/// One video's reporting to the account's YouTube history: filed as watched when it starts, then
/// told how far it got. Koda for Android's VideoWatchTracker (WEB watchtime and FEhistory
/// readback verified September 2026).
public struct VideoWatchSession: Sendable {
    public let videoId: String
    let profile: UUID
    let cpn: String
    let watchtimeURL: String
}

extension YouTubeMusic {
    /// File `videoId` in the active account's YouTube history, as www.youtube.com's player does:
    /// a signed WEB `/player` hands back tracking URLs, and the playback ping files the watch.
    /// The session it returns carries the watch-time pings, which say how much was seen (the
    /// red bar under the video on YouTube).
    public func beginVideoHistory(videoId: String, at position: TimeInterval) async throws -> VideoWatchSession {
        guard let profile = await accounts.active?.profileID else { throw MusicError.signedOut }
        let cpn = HistoryPing.cpn()
        let sent = await signatures.current()
        var root = try await api.web("player", HistoryPing.playerPayload(videoId: videoId, cpn: cpn, signatureTimestamp: sent),
                                     signing: .required)
        if !root["playbackTracking"].exists, let retry = await signatures.refreshAfterRejection(sent) {
            root = try await api.web("player", HistoryPing.playerPayload(videoId: videoId, cpn: cpn, signatureTimestamp: retry),
                                     signing: .required)
        }
        let tracking = root["playbackTracking"]
        guard let playback = tracking["videostatsPlaybackUrl"]["baseUrl"].nonEmpty,
              let watchtime = tracking["videostatsWatchtimeUrl"]["baseUrl"].nonEmpty,
              let url = HistoryPing.videoTrackingURL(playback, cpn: cpn, from: position, to: position, final: false)
        else { throw MusicError.badResponse(200) }
        guard await accounts.active?.profileID == profile else { throw MusicError.signedOut }
        try await api.ping(url, referer: "https://www.youtube.com/watch?v=\(videoId)", origin: "https://www.youtube.com")
        return VideoWatchSession(videoId: videoId, profile: profile, cpn: cpn, watchtimeURL: watchtime)
    }

    /// Tell YouTube the span from `start` to `position` was watched. Seeks end a span: a skipped
    /// part is never claimed as seen.
    public func reportVideoWatchtime(_ session: VideoWatchSession, from start: TimeInterval, to position: TimeInterval,
                                     final: Bool) async throws {
        guard await accounts.active?.profileID == session.profile else { throw MusicError.signedOut }
        guard let url = HistoryPing.videoTrackingURL(session.watchtimeURL, cpn: session.cpn, from: start, to: position, final: final)
        else { throw MusicError.badResponse(200) }
        try await api.ping(url, referer: "https://www.youtube.com/watch?v=\(session.videoId)", origin: "https://www.youtube.com")
    }
}

enum HistoryPing {
    /// Where a history ping may carry the account's cookies: the hosts `/player` returns
    /// tracking URLs on [verified September 2026, signed in].
    static let trackingHosts: Set<String> = ["s.youtube.com", "www.youtube.com"]

    /// The client playback nonce the web player makes per play: 16 URL-safe characters.
    static func cpn() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return String((0..<16).map { _ in alphabet.randomElement()! })
    }

    static func playerPayload(videoId: String, cpn: String, signatureTimestamp: Int) -> [String: Any] {
        ["videoId": videoId, "cpn": cpn,
         "playbackContext": ["contentPlaybackContext": ["signatureTimestamp": signatureTimestamp]]]
    }

    /// The ping URL: https on a YouTube tracking host only, with this play's `cpn`, `ver` and
    /// `c` set (replacing any the URL carries rather than sending them twice).
    static func trackingURL(_ base: String, cpn: String) -> URL? {
        tracking(base, setting: ["cpn": cpn, "ver": "2", "c": "WEB_REMIX"])
    }

    /// A video's ping: the WEB client's, with the watched span (`st`…`et`, `cmt` where it is now)
    /// and whether it's the last for this watch.
    static func videoTrackingURL(_ base: String, cpn: String, from start: TimeInterval, to position: TimeInterval, final: Bool) -> URL? {
        let position = max(0, position)
        let seconds = { (value: TimeInterval) in String(format: "%.3f", value) }
        return tracking(base, setting: [
            "cpn": cpn, "ver": "2", "c": "WEB", "cver": Clients.webVersion,
            "cmt": seconds(position), "st": seconds(min(max(0, start), position)), "et": seconds(position),
            "state": final ? "paused" : "playing", "final": final ? "1" : "0",
        ])
    }

    /// `base` with `set` replacing any of the same names, on a YouTube tracking host over https only.
    private static func tracking(_ base: String, setting set: [String: String]) -> URL? {
        guard var components = URLComponents(string: base), components.scheme == "https",
              let host = components.host, trackingHosts.contains(host) else { return nil }
        var items = (components.queryItems ?? []).filter { set[$0.name] == nil }
        items += set.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        components.queryItems = items
        return components.url
    }
}

/// The `playbackContext.contentPlaybackContext.signatureTimestamp` a history `/player` call must
/// carry. Without it WEB_REMIX answers every video "Video unavailable" with no tracking URLs
/// [verified October 2026, Koda for Android]. It is the player script's build day counted from
/// the epoch, and YouTube takes about the last seven months of them, so it comes in three
/// layers, most exact first:
///
/// 1. The live value from the current player script: `iframe_api` names the player (1 KB);
///    its `base.js` holds `signatureTimestamp:<n>` (~3 MB, read only when the player changes,
///    about weekly). Kept, and the player rechecked at most once a day.
/// 2. Otherwise today's date less a fortnight, never below a kept live value: no network, so
///    history keeps working when YouTube reshapes the script.
/// 3. `refreshAfterRejection`: a `/player` without tracking asks for a fresh read and retries
///    once if the value changed.
actor PlayerSignatureTimestamp {
    private let session: URLSession
    private let defaults: UserDefaults
    private var refreshing: Task<Void, Never>?

    static let day: TimeInterval = 86_400
    static let recheck: TimeInterval = day
    static let staleAfter: TimeInterval = 14 * day
    static let failureBackoff: TimeInterval = 3600
    static let forcedRefreshMinimum: TimeInterval = 600
    static let estimateLagDays = 14

    init(session: URLSession, suite: String?) {
        self.session = session
        defaults = suite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    /// The value to send now, refreshing the live read when it is due.
    func current(now: Date = Date()) async -> Int {
        if now.timeIntervalSince(date(Keys.checkedAt)) >= Self.recheck,
           now.timeIntervalSince(date(Keys.failedAt)) >= Self.failureBackoff {
            await refresh()
        }
        return best(now: now)
    }

    /// After a `/player` came back without tracking: a value worth retrying with, or nil when it
    /// would only repeat `rejected` (a video really unavailable mustn't cost a second call).
    func refreshAfterRejection(_ rejected: Int, now: Date = Date()) async -> Int? {
        if now.timeIntervalSince(max(date(Keys.checkedAt), date(Keys.failedAt))) >= Self.forcedRefreshMinimum {
            await refresh()
        }
        let next = best(now: now)
        if next != rejected { return next }
        // The live read was what got rejected: the date estimate is the one independent answer left.
        let estimate = Self.estimate(now: now)
        return estimate != rejected ? estimate : nil
    }

    private func best(now: Date) -> Int {
        let stored = defaults.integer(forKey: Keys.value)
        let fresh = now.timeIntervalSince(date(Keys.checkedAt)) < Self.staleAfter
        return stored > 0 && fresh ? stored : max(stored, Self.estimate(now: now))
    }

    static func estimate(now: Date) -> Int {
        Int(now.timeIntervalSince1970 / day) - estimateLagDays
    }

    private func refresh() async {
        if let refreshing { return await refreshing.value }
        let task = Task { await readLive() }
        refreshing = task
        await task.value
        refreshing = nil
    }

    private func readLive() async {
        guard let iframe = await fetch(URL(string: "https://www.youtube.com/iframe_api")!),
              let playerId = Self.playerId(inIframeAPI: iframe) else { return failed() }
        if defaults.integer(forKey: Keys.value) > 0, defaults.string(forKey: Keys.playerId) == playerId {
            defaults.set(Date(), forKey: Keys.checkedAt)
            return
        }
        guard let script = await fetch(URL(string: "https://www.youtube.com/s/player/\(playerId)/player_ias.vflset/en_US/base.js")!),
              let value = Self.signatureTimestamp(inPlayer: script) else { return failed() }
        defaults.set(value, forKey: Keys.value)
        defaults.set(playerId, forKey: Keys.playerId)
        defaults.set(Date(), forKey: Keys.checkedAt)
    }

    private func failed() {
        defaults.set(Date(), forKey: Keys.failedAt)
    }

    private func fetch(_ url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(Clients.browserUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func date(_ key: String) -> Date {
        defaults.object(forKey: key) as? Date ?? .distantPast
    }

    /// `iframe_api` writes the player path with escaped slashes: `\/s\/player\/<id>\/`.
    static func playerId(inIframeAPI text: String) -> String? {
        firstGroup(#"\\?/s\\?/player\\?/([A-Za-z0-9_-]{8})\\?/"#, in: text)
    }

    static func signatureTimestamp(inPlayer text: String) -> Int? {
        firstGroup(#"signatureTimestamp[=:]"?(\d{5,})"#, in: text).flatMap(Int.init)
    }

    private static func firstGroup(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private enum Keys {
        static let value = "koda.sts.value"
        static let playerId = "koda.sts.playerId"
        static let checkedAt = "koda.sts.checkedAt"
        static let failedAt = "koda.sts.failedAt"
    }
}

/// When a play counts for the account's history: once per occurrence, after 15 seconds heard
/// (half the song for one shorter than 30), as Koda for Android waits 15 seconds. Skips and a
/// song restored but never played don't count.
public struct HeardThreshold: Sendable {
    private var occurrence: UUID?
    private var heard: TimeInterval = 0
    private var reported = false

    public init() {}

    /// Add listening to `occurrence`; true exactly once, when it crosses the threshold.
    public mutating func add(_ seconds: TimeInterval, to occurrence: UUID, duration: TimeInterval?) -> Bool {
        if occurrence != self.occurrence {
            self.occurrence = occurrence
            heard = 0
            reported = false
        }
        guard !reported, seconds > 0 else { return false }
        heard += seconds
        let needed = min(15, max(1, (duration ?? 30) / 2))
        guard heard >= needed else { return false }
        reported = true
        return true
    }
}
