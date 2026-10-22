import Foundation
import Security

/// The song facts a scrobble needs, taken from whatever is playing.
public struct LastFMPlay: Codable, Hashable, Sendable {
    public var artist: String
    public var track: String
    public var album: String
    /// Seconds; 0 when unknown.
    public var duration: TimeInterval
    /// When the listener started hearing it.
    public var startedAt: Date

    public init(artist: String, track: String, album: String, duration: TimeInterval, startedAt: Date) {
        self.artist = artist
        self.track = track
        self.album = album
        self.duration = duration
        self.startedAt = startedAt
    }

    var parameters: [String: String] {
        var parameters = ["artist": artist, "track": track]
        if !album.isEmpty { parameters["album"] = album }
        if duration > 0 { parameters["duration"] = String(Int(duration.rounded())) }
        return parameters
    }
}

/// Scrobbling to Last.fm, shared by the iPhone and the Mac.
///
/// Off until the listener turns it on, and it never asks for a password: each listener
/// registers their own Last.fm API account and Koda signs in with Last.fm's desktop flow
/// (a token approved in the browser, then exchanged for a session). Credentials live in the
/// Keychain on this device only; the queue and the cached profile in a file kept out of
/// backups, so restoring Koda elsewhere never turns scrobbling on for another account.
///
/// A play is queued once it qualifies and sent one at a time, each removed only after Last.fm
/// acknowledges it, so nothing is lost offline or when the app is closed. Pausing listening
/// history pauses scrobbling too: nothing heard while paused is ever sent.
@MainActor
@Observable
public final class LastFM {
    // MARK: State the settings read

    public private(set) var isEnabled = false
    /// A session exists: plays can be sent.
    public private(set) var isConnected = false
    public private(set) var user = ""
    /// The API key saved for this device, to prefill the form.
    public private(set) var apiKey = ""
    public private(set) var hasSecret = false
    /// A token waits for the listener to approve it in the browser.
    public private(set) var isSigningIn = false
    public private(set) var isBusy = false
    public private(set) var queued: [LastFMPlay] = []
    public private(set) var profile: LastFMProfile?
    public private(set) var recent: [LastFMTrack] = []
    public private(set) var refreshedAt: Date?
    public private(set) var lastSent: Date?
    public private(set) var error: LastFMError?
    /// Last.fm took a play but ignored it, with its reason, e.g. "Artist name was ignored".
    public private(set) var notice: String?

    /// Listening history is paused: nothing is recorded or sent until it isn't.
    public var isPaused = false {
        didSet {
            guard isPaused != oldValue else { return }
            if isPaused { invalidate() } else { syncSoon() }
        }
    }

    /// Plays waiting at most this many; beyond it new ones are dropped and the listener told.
    public static let queueLimit = 1000
    /// How long Koda waits after a network failure or rate limit before trying again.
    static let cooldown: TimeInterval = 300

    // MARK: Private

    private struct Credentials: Codable {
        var apiKey = ""
        var secret = ""
        var session = ""
        var user = ""
        var token = ""
        var tokenDate: Date?
    }

    private struct Stored: Codable {
        var enabled = false
        var queue: [LastFMPlay] = []
        var profile: LastFMProfile?
        var recent: [LastFMTrack] = []
        var refreshedAt: Date?
        var lastSent: Date?
        /// Who is signed in, kept outside the Keychain (it isn't secret), so Koda still knows
        /// it's connected on a launch where the Keychain can't be read yet.
        var connectedUser: String?
    }

    private var credentials = Credentials()
    /// The Keychain refused to be read at launch: locked, or Koda started in the background
    /// before the first unlock. That isn't being signed out, so nothing overwrites the saved
    /// credentials until they've been read; every call tries reading them again first.
    private var credentialsUnreadable = false
    private var connectedUser: String?
    private let stateFile: URL
    private let keychain: LastFMKeychain
    private let urlSession: URLSession
    /// Bumped whenever what Koda may do changes (off, paused, another account), so a call
    /// started before then never writes its result.
    private var generation = 0
    private var operation: Task<Void, Never>?
    private var retryAfter = Date.distantPast
    private var clock = LastFMListeningClock()

    public init(directory: URL, keychainService: String = "ivors.Koda.lastfm") {
        stateFile = directory.appending(path: "lastfm.json")
        keychain = LastFMKeychain(service: keychainService, fallback: directory.appending(path: "lastfm-credentials.json"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        urlSession = URLSession(configuration: configuration)
        load()
    }

    /// Plays can be recorded and sent right now.
    public var canScrobble: Bool { isEnabled && isConnected && !isPaused }

    // MARK: Settings

    public func setEnabled(_ enabled: Bool) {
        invalidate()
        isEnabled = enabled
        retryAfter = .distantPast
        if !enabled {
            // Off means off: unsent plays go, and nothing waits half signed in.
            queued = []
            credentials.token = ""
            credentials.tokenDate = nil
            isSigningIn = false
            saveCredentials()
        }
        error = nil
        save()
        if enabled { refreshSoon() }
    }

    /// Forget the account and the API keys on this device.
    public func disconnect() {
        invalidate()
        credentials = Credentials()
        credentialsUnreadable = false
        keychain.delete()
        isEnabled = false
        queued = []
        profile = nil
        recent = []
        refreshedAt = nil
        lastSent = nil
        error = nil
        notice = nil
        publishCredentials()
        save()
    }

    /// Step one of signing in: checks the keys, gets a token and returns the page where the
    /// listener approves it.
    public func beginSignIn(apiKey: String, secret: String) async throws -> URL {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard LastFMProtocol.isCredential(key), LastFMProtocol.isCredential(secret) else {
            error = .invalidCredentials
            throw LastFMError.invalidCredentials
        }
        if !isEnabled { setEnabled(true) }
        invalidate()
        credentials.apiKey = key
        credentials.secret = secret
        credentials.token = ""
        saveCredentials(replacing: true)
        return try await run { [self] in
            let response = try await request("auth.getToken", signed: true)
            guard let token = response["token"] as? String, !token.isEmpty else { throw LastFMError.unexpectedResponse }
            credentials.token = token
            credentials.tokenDate = Date()
            saveCredentials(replacing: true)
            return LastFMProtocol.authorizationURL(apiKey: key, token: token)
        }
    }

    /// Sign in again with the keys already saved.
    public func restartSignIn() async throws -> URL {
        try await beginSignIn(apiKey: credentials.apiKey, secret: credentials.secret)
    }

    /// Step two: exchange the approved token for a session. Another account than before
    /// starts from an empty queue, so no play is ever sent under the wrong name.
    public func finishSignIn() async throws {
        try await run { [self] in
            guard !credentials.token.isEmpty else { throw LastFMError.noPendingSignIn }
            if let date = credentials.tokenDate, Date().timeIntervalSince(date) > 3600 { throw LastFMError.signInExpired }
            let response = try await request("auth.getSession", ["token": credentials.token], signed: true)
            guard let session = response["session"] as? [String: Any],
                  let name = session["name"] as? String, let key = session["key"] as? String,
                  !name.isEmpty, !key.isEmpty else { throw LastFMError.unexpectedResponse }
            if name.caseInsensitiveCompare(credentials.user) != .orderedSame {
                queued = []
                profile = nil
                recent = []
                refreshedAt = nil
                lastSent = nil
            }
            credentials.session = key
            credentials.user = name
            credentials.token = ""
            credentials.tokenDate = nil
            saveCredentials(replacing: true)
            save()
            try await flush()
            try await refreshData()
        }
    }

    /// Send what is waiting and fetch the profile and recent plays.
    public func refresh() async {
        try? await run { [self] in
            try await flush()
            try await refreshData()
        }
    }

    public func dismissNotice() {
        notice = nil
        if error != nil, !isBusy { error = nil }
    }

    // MARK: Playback

    /// A song began playing. `occurrence` tells one play of a song from the next, including
    /// the same song repeated.
    public func started(_ occurrence: UUID, artist: String, track: String, album: String, duration: TimeInterval, isVideo: Bool) {
        guard canScrobble, Self.isScrobblable(artist: artist, track: track, isVideo: isVideo) else {
            clock.reset()
            return
        }
        // Called once per play: a song coming round again on repeat one is a new play, announced
        // and scrobbled again, though it is the same occurrence in the queue.
        clock.start(occurrence, at: Date())
        let play = LastFMPlay(artist: artist, track: track, album: album, duration: duration, startedAt: Date())
        Task { [self] in try? await nowPlaying(play) }
    }

    /// `seconds` more of a song were heard.
    public func heard(_ seconds: TimeInterval, of occurrence: UUID, artist: String, track: String, album: String,
                      duration: TimeInterval, isVideo: Bool) {
        guard canScrobble, Self.isScrobblable(artist: artist, track: track, isVideo: isVideo) else { return }
        guard clock.add(seconds, to: occurrence, duration: duration, at: Date()), let startedAt = clock.startedAt else { return }
        enqueue(LastFMPlay(artist: artist, track: track, album: album, duration: duration, startedAt: startedAt))
    }

    /// Music with a title and an artist. Videos are left out: their artist is often the
    /// channel that uploaded them, which would file a fan's upload under the wrong name.
    nonisolated static func isScrobblable(artist: String, track: String, isVideo: Bool) -> Bool {
        !isVideo && !artist.trimmingCharacters(in: .whitespaces).isEmpty && !track.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func enqueue(_ play: LastFMPlay) {
        guard queued.count < Self.queueLimit else {
            notice = "\(Self.queueLimit) plays are waiting to be sent, so new ones aren't being kept. Sync to send them."
            return
        }
        queued.append(play)
        save()
        syncSoon()
    }

    /// Try to send waiting plays, unless a call is running or Last.fm asked Koda to wait.
    public func syncSoon() {
        reloadCredentialsIfNeeded()
        guard canScrobble, !queued.isEmpty, operation == nil, Date() >= retryAfter else { return }
        Task { try? await run { [self] in try await flush() } }
    }

    private func refreshSoon() {
        reloadCredentialsIfNeeded()
        guard isEnabled, isConnected, !isPaused, operation == nil else { return }
        Task { await refresh() }
    }

    // MARK: Calls

    private func nowPlaying(_ play: LastFMPlay) async throws {
        // Best effort, and never in the way of sign-in or sending the queue.
        guard canScrobble, operation == nil, Date() >= retryAfter else { return }
        _ = try await request("track.updateNowPlaying", play.parameters, authenticated: true)
    }

    /// Send queued plays oldest first; each leaves the queue only once Last.fm answers for it.
    private func flush() async throws {
        while canScrobble, let play = queued.first {
            var parameters = play.parameters
            parameters["timestamp"] = String(Int(play.startedAt.timeIntervalSince1970))
            let code = try LastFMProtocol.scrobbleCode(try await request("track.scrobble", parameters, authenticated: true))
            if code == 5 {
                retryAfter = Date().addingTimeInterval(Self.cooldown)
                throw LastFMError.dailyLimit
            }
            if !queued.isEmpty { queued.removeFirst() }
            lastSent = Date()
            notice = code == 0 ? notice : Self.ignoredReason(code)
            save()
        }
    }

    private static func ignoredReason(_ code: Int) -> String {
        switch code {
        case 1: "Last.fm ignored a play: it didn't accept the artist's name."
        case 2: "Last.fm ignored a play: it didn't accept the song's title."
        case 3: "Last.fm ignored a play: its time was too far in the past."
        case 4: "Last.fm ignored a play: its time was in the future."
        default: "Last.fm ignored a play (reason \(code))."
        }
    }

    private func refreshData() async throws {
        guard isConnected, !user.isEmpty else { return }
        let info = try await request("user.getInfo", ["user": user])
        let tracks = try await request("user.getRecentTracks", ["user": user, "limit": "30", "extended": "0"])
        profile = LastFMProtocol.profile(info) ?? profile
        recent = LastFMProtocol.recentTracks(tracks)
        refreshedAt = Date()
        save()
    }

    /// Runs one operation at a time, publishing busy and errors, and drops its result if
    /// what Koda may do changed while it ran.
    @discardableResult
    private func run<T: Sendable>(_ body: @escaping @MainActor () async throws -> T) async throws -> T {
        guard isEnabled, !isPaused else { throw LastFMError.paused }
        guard Date() >= retryAfter else { throw LastFMError.rateLimited }
        while let running = operation { await running.value }
        let expected = generation
        isBusy = true
        error = nil
        let task = Task<T, Error> { try await body() }
        let marker = Task<Void, Never> { _ = try? await task.value }
        operation = marker
        defer {
            if operation == marker { operation = nil }
            if expected == generation { isBusy = false }
        }
        do {
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            return value
        } catch {
            let failure = (error as? LastFMError) ?? ((error is URLError) ? .network : .unexpectedResponse)
            if expected == generation, !(error is CancellationError) {
                if failure.coolsDown { retryAfter = Date().addingTimeInterval(Self.cooldown) }
                self.error = failure
            }
            throw failure
        }
    }

    private func request(_ method: String, _ parameters: [String: String] = [:], signed: Bool = false,
                         authenticated: Bool = false) async throws -> [String: Any] {
        guard isEnabled, !isPaused else { throw LastFMError.paused }
        guard reloadCredentialsIfNeeded() else { throw LastFMError.credentialsLocked }
        let expected = generation
        var all = parameters
        all["method"] = method
        all["api_key"] = credentials.apiKey
        if authenticated {
            guard isConnected else { throw LastFMError.notConnected }
            all["sk"] = credentials.session
        }
        if signed || authenticated { all["api_sig"] = LastFMProtocol.signature(all, secret: credentials.secret) }
        all["format"] = "json"

        var request: URLRequest
        if authenticated {
            request = URLRequest(url: LastFMProtocol.endpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(Self.formEncoded(all).utf8)
        } else {
            var components = URLComponents(url: LastFMProtocol.endpoint, resolvingAgainstBaseURL: false)!
            components.queryItems = all.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            request = URLRequest(url: components.url!)
        }
        request.setValue("Koda/1.0 (https://github.com/Ivorisnoob/Koda-iOS)", forHTTPHeaderField: "User-Agent")

        let data: Data
        do {
            (data, _) = try await urlSession.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw LastFMError.network
        }
        // Turned off, paused or signed out while the call was out: its answer no longer applies.
        guard generation == expected, isEnabled, !isPaused else { throw CancellationError() }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LastFMError.unexpectedResponse }
        if let code = (json["error"] as? NSNumber)?.intValue {
            if code == 9 {
                credentials.session = ""
                saveCredentials()
            }
            throw LastFMError.fromAPI(code: code, message: json["message"] as? String ?? "")
        }
        return json
    }

    private static func formEncoded(_ parameters: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return parameters.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
    }

    /// Stops calls in flight and anything they would have written.
    private func invalidate() {
        generation += 1
        operation = nil
        isBusy = false
        clock.reset()
    }

    // MARK: Storage

    private func load() {
        switch keychain.read(Credentials.self) {
        case .found(let saved): credentials = saved
        case .missing: credentials = Credentials()
        case .unreadable: credentialsUnreadable = true
        }
        if let data = try? Data(contentsOf: stateFile), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            isEnabled = stored.enabled
            queued = stored.queue
            profile = stored.profile
            recent = stored.recent
            refreshedAt = stored.refreshedAt
            lastSent = stored.lastSent
            connectedUser = stored.connectedUser
        }
        publishCredentials()
    }

    /// Read the credentials if launch couldn't. Returns false while they still can't be read.
    @discardableResult
    private func reloadCredentialsIfNeeded() -> Bool {
        guard credentialsUnreadable else { return true }
        switch keychain.read(Credentials.self) {
        case .found(let saved): credentials = saved
        case .missing: credentials = Credentials()
        case .unreadable: return false
        }
        credentialsUnreadable = false
        publishCredentials()
        return true
    }

    private func save() {
        let stored = Stored(enabled: isEnabled, queue: queued, profile: profile, recent: recent, refreshedAt: refreshedAt, lastSent: lastSent,
                            connectedUser: connectedUser)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: stateFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = stateFile
        try? url.setResourceValues(values)
    }

    /// `replacing` is for signing in, which means to set new credentials whatever was saved.
    private func saveCredentials(replacing: Bool = false) {
        // Never write over credentials that couldn't be read: they'd be lost for an empty set.
        guard reloadCredentialsIfNeeded() || replacing else { return }
        credentialsUnreadable = false
        keychain.write(credentials)
        publishCredentials()
    }

    private func publishCredentials() {
        if credentialsUnreadable {
            // Still signed in as far as anyone knows; plays queue up until the Keychain opens.
            isConnected = connectedUser != nil
            user = connectedUser ?? ""
            return
        }
        isConnected = !credentials.session.isEmpty
        user = credentials.user
        let signedIn = isConnected ? credentials.user : nil
        if connectedUser != signedIn {
            connectedUser = signedIn
            save()
        }
        apiKey = credentials.apiKey
        hasSecret = !credentials.secret.isEmpty
        isSigningIn = !credentials.token.isEmpty
    }
}

/// The Last.fm credentials in the Keychain, readable on this device only and never synced.
/// Where the Keychain refuses (an unsigned Mac build has no access group), a file only this
/// user can read stands in, so Last.fm still works rather than failing to open.
private struct LastFMKeychain {
    let service: String
    let fallback: URL
    private let account = "credentials"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    enum Read<T> {
        case found(T)
        /// Nothing saved: never signed in, or signed out.
        case missing
        /// Something is saved but can't be read right now (the device is locked).
        case unreadable
    }

    func read<T: Decodable>(_ type: T.Type) -> Read<T> {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, let value = try? JSONDecoder().decode(T.self, from: data) {
            return .found(value)
        }
        if let data = try? Data(contentsOf: fallback), let value = try? JSONDecoder().decode(T.self, from: data) {
            return .found(value)
        }
        // Not found, or no Keychain at all for this build (the file above stands in for it):
        // nothing is saved. Anything else is the Keychain saying "not now".
        return status == errSecItemNotFound || status == errSecMissingEntitlement || status == errSecSuccess ? .missing : .unreadable
    }

    func write<T: Encodable>(_ value: T) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemDelete(query as CFDictionary)
        if SecItemAdd(item as CFDictionary, nil) == errSecSuccess {
            try? FileManager.default.removeItem(at: fallback)
            return
        }
        try? data.write(to: fallback, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fallback.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = fallback
        try? url.setResourceValues(values)
    }

    func delete() {
        SecItemDelete(query as CFDictionary)
        try? FileManager.default.removeItem(at: fallback)
    }
}
