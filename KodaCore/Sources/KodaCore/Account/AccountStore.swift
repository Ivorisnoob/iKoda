import Foundation
import Observation

/// The signed-in YouTube account of this install: the live cookie session.
///
/// There is no OAuth token and no refresh token. Signing in stores the
/// session cookies the web client itself holds, and staying signed in means
/// two things kept fresh:
///
/// 1. **Rotations.** Google reissues `__Secure-*PSIDTS` and friends every few
///    hours. Every response to an authenticated call has its response
///    `Set-Cookie` values folded back into the store. A rotation is not a new
///    login; the session is never compared cookie-against-cookie to ask
///    whether it is still the one login started with.
/// 2. **The verdict.** Every InnerTube response reports how YouTube sees the
///    account (`logged_in` in its tracking params). A `logged_in: 0` against
///    a request that carried cookies marks the session expired — surfaced as
///    "reconnect", not signed-out — and a later `1` heals it again, because a
///    session revived by a rotation can come back without anything being
///    done. [verified on Koda for Android, August 2026]
///
/// A session that cannot be read right now (the device is locked, the
/// unsigned Mac build's file fallback is unreadable) is still connected as
/// far as anyone knows, matching the Last.fm behaviour: requests simply go
/// out signed out until the store answers again.
///
/// Each profile has its own session, kept in the Keychain under its own id,
/// so switching profiles moves the session with it rather than copying it.
@MainActor
@Observable
public final class AccountStore {
    // MARK: State the app reads

    /// The profile whose session signs the requests.
    public private(set) var activeProfileID: UUID?
    /// A session is attached: requests go out signed in.
    public private(set) var isConnected = false
    /// YouTube has refused a session that exists and can be refreshed.
    public private(set) var isExpired = false
    /// Bumped whenever the session changes: a sign-in, a sign-out, a switch
    /// to another profile. Anything fetching for the account checks it
    /// afterwards, so a late answer cannot land in the wrong profile.
    public private(set) var generation = 0

    // MARK: Private

    private let service: String
    private let directory: URL?
    private var cookies: String?
    private var sessions: [UUID: SessionStore] = [:]

    /// - Parameter service: a unique Keychain service per test, so stores keep their cookies apart.
    public init(directory: URL?, service: String = "ivors.Koda.youtube") {
        self.service = service
        self.directory = directory
    }

    /// The session store of one profile.
    private func session(_ id: UUID) -> SessionStore {
        if let store = sessions[id] { return store }
        let store = SessionStore(service: service,
                                 account: id.uuidString,
                                 fallback: directory?.appending(path: "yt_session-\(id.uuidString)")
                                    ?? URL(fileURLWithPath: "/dev/null"))
        sessions[id] = store
        return store
    }

    // MARK: Which profile

    /// Point the store at a profile: its session, if it has one, becomes the
    /// one that signs the requests.
    public func activate(profileID: UUID?) {
        activeProfileID = profileID
        cookies = nil
        isExpired = false
        isConnected = false
        if let profileID {
            switch session(profileID).read() {
            case .found(let string):
                cookies = string
                isConnected = true
            case .missing:
                break
            case .unreadable:
                // Something is saved but cannot be read right now. That is not
                // being signed out: the session is still there.
                isConnected = true
            }
        }
        generation += 1
    }

    /// Whether a profile has a session stored, without taking it out.
    public func hasSession(for profileID: UUID) -> Bool {
        switch session(profileID).read() {
        case .found: true
        case .missing: false
        case .unreadable: true
        }
    }

    /// Forget the session of a profile that is leaving the roster: the
    /// credential goes with it.
    public func forget(profileID: UUID) {
        session(profileID).delete()
        if activeProfileID == profileID {
            activate(profileID: nil)
        }
    }

    // MARK: Signing in and out

    /// Whether a cookie header holds a session complete enough to sign in
    /// with: a SAPISID to sign requests with, and the SID session itself.
    /// The login capture checks this before offering the sign-in. A stricter
    /// bar here would reject sessions that actually work.
    public func isComplete(_ header: String) -> Bool {
        YouTubeCookies.missing(header).isEmpty
    }

    /// Take a session from the login capture, for the active profile. Returns
    /// the required names it is still missing, empty when accepted.
    @discardableResult
    public func signIn(cookieHeader: String) -> [String] {
        guard let profileID = activeProfileID else { return ["account"] }
        let header = cookieHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        let missing = YouTubeCookies.missing(header)
        guard missing.isEmpty else { return missing }
        cookies = header
        isConnected = true
        isExpired = false
        session(profileID).write(header)
        generation += 1
        return []
    }

    /// Sign out: forget the cookie session of the active profile. What
    /// YouTube keeps on its servers stays there; locally nothing is left to
    /// sign with, and the profile keeps its place in the roster.
    public func signOut() {
        guard let profileID = activeProfileID else { return }
        cookies = nil
        isConnected = false
        isExpired = false
        session(profileID).delete()
        generation += 1
    }

    // MARK: Signing requests

    /// The headers an authenticated request to `origin` signs with — nil when
    /// there is nothing to send, deliberate for the endpoints that read fine
    /// anonymously: an empty `Cookie` header is worse than none at all.
    /// Cookies are read fresh per call; a reply may have rotated them since.
    public func requestHeaders(for origin: String) -> [String: String]? {
        guard let cookies else { return nil }
        var headers = ["Cookie": cookies]
        if let authorization = SAPISIDHash.header(cookieString: cookies, origin: origin) {
            headers["Authorization"] = authorization
            headers["X-Goog-AuthUser"] = "0"
            headers["X-Origin"] = origin
        }
        return headers
    }

    /// Apply what a response to an authenticated call said: rotated cookie
    /// values and the verdict on the session. A response to a signed-out call
    /// notes nothing, so an anonymous cookie jar can never write into the
    /// account.
    ///
    /// The reply belongs to the session that was sent for: `generation` is
    /// what the request carried, and if the store has moved on to another
    /// profile since, this answer is not ours — it belongs to the profile
    /// that was left, and writing it here would break the one that is active.
    func note(response: HTTPURLResponse, body: Data, cookies: [String: String], sentSession: Bool, generation: Int) {
        guard sentSession, generation == self.generation else { return }
        let verdict = SessionVerdict(body: body)
        if let loggedIn = verdict.isLoggedIn {
            isExpired = !loggedIn
        }
        if !cookies.isEmpty, let existing = self.cookies {
            let merged = YouTubeCookies.merge(existing: existing, adding: cookies)
            if merged != existing {
                self.cookies = merged
                if let profileID = activeProfileID {
                    session(profileID).write(merged)
                }
            }
        }
    }
}

/// How YouTube sees the account, read out of one InnerTube response.
struct SessionVerdict: Equatable {
    /// `true` when the response reports the account logged in; nil when it
    /// says nothing either way.
    let isLoggedIn: Bool?

    init(isLoggedIn: Bool?) {
        self.isLoggedIn = isLoggedIn
    }

    /// A signed-in response answers `logged_in` in its tracking params —
    /// decoded JSON inside the body, so a regex over the raw body reads it —
    /// and a handful also carry `mainAppWebResponseContext.loggedOut` beside
    /// it. HTTP 200 proves nothing: anonymous browse answers 200 too.
    init(body: Data) {
        // Tolerant of the pretty-printed spacing so it matches either form.
        // NSRegularExpression rather than the Swift Regex API: with a string
        // pattern the overload set resolves differently per toolchain, and
        // collection building wants nothing more to resolve.
        if let text = String(data: body, encoding: .utf8),
           let match = Self.trackingParam.firstMatch(
               in: text, options: [], range: NSRange(location: 0, length: text.utf16.count)),
           let value = Range(match.range(at: 1), in: text).map({ text[$0] }) {
            isLoggedIn = value == "1"
            return
        }
        if let json = try? JSON(data: body) {
            let loggedOut = json["responseContext"]["mainAppWebResponseContext"]["loggedOut"].bool
            isLoggedIn = loggedOut.map { !$0 }
            return
        }
        isLoggedIn = nil
    }

    /// Every signed-in response answers `logged_in` in its tracking params:
    /// `{"key":"logged_in","value":"1"}` decoded inside the body.
    private static let trackingParam = try! NSRegularExpression(
        pattern: "\"logged_in\"\\s*,\\s*\"value\"\\s*:\\s*\"([01])\"")
}
