import Foundation
import Synchronization

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
/// The sections are tiny and every caller is brief, so a mutex beats an
/// actor: request building and the UI both want cookies synchronously, and
/// an actor would only churn every read into a hop.
public final class AccountStore: Sendable {
    struct State: Sendable {
        var cookies: String?
        var unreadable = false
        var expired = false
        /// YouTube's own account id, carried by every authenticated response
        /// verbatim, spaces included: it is only ever compared against
        /// another copy of itself. What lets the sign-in flow recognise an
        /// account Koda already knows (the profile roster uses it later).
        var datasyncId: String?
    }

    private let state: Mutex<State>
    private let store: SessionStore
    /// Fired whenever the state the UI mirrors — signed in, expired, identity
    /// — changes. Runs on whatever thread called the store; the observer hops.
    private let inbox: Mutex<(@Sendable () -> Void)?>

    /// - Parameter service: a unique Keychain service per test, so stores keep their cookies apart.
    public init(directory: URL?, service: String = "ivors.Koda.ytm") {
        let fallback = directory?.appending(path: "yt_session")
        store = SessionStore(service: service, fallback: fallback ?? URL(fileURLWithPath: "/dev/null"))
        switch store.read() {
        case .found(let string):
            state = Mutex(State(cookies: string))
        case .missing:
            state = Mutex(State())
        case .unreadable:
            state = Mutex(State(unreadable: true))
        }
        inbox = Mutex(nil)
    }

    /// Observes state changes for the UI mirror. One observer at a time; the
    /// last one wins.
    public func observeState(_ handler: @escaping @Sendable () -> Void) {
        inbox.withLock { $0 = handler }
    }

    /// Whether an account is attached, made visible in Settings even while
    /// its cookies cannot be read at the moment.
    public var isLoggedIn: Bool {
        state.withLock { $0.cookies != nil || $0.unreadable }
    }

    /// YouTube has refused a session that exists and can be refreshed.
    public var isExpired: Bool {
        state.withLock { $0.expired }
    }

    public var datasyncId: String? {
        state.withLock { $0.datasyncId }
    }

    /// Sign out: forget the cookie session. What YouTube keeps on its servers
    /// stays there; locally nothing is left to sign with.
    public func clearSession() {
        let changed = state.withLock { session -> Bool in
            let had = session.cookies != nil || session.unreadable
            session = State()
            return had
        }
        if changed { store.delete(); announce() }
    }

    /// Save a cookie string from the login capture or the paste sheet.
    /// Returns the required names it is still missing, empty when accepted.
    @discardableResult
    public func addCookies(_ raw: String) -> [String] {
        let cookieString = YouTubeCookies.normalize(raw)
        let missing = YouTubeCookies.missing(cookieString)
        guard missing.isEmpty else { return missing }
        state.withLock { session in
            session.cookies = cookieString
            session.unreadable = false
            session.expired = false
        }
        store.write(cookieString)
        announce()
        return []
    }

    /// The headers an authenticated request to `origin` signs with — nil when
    /// there is nothing to send, deliberate for the endpoints that read fine
    /// anonymously: an empty `Cookie` header is worse than none at all.
    /// Cookies are read fresh per call; a reply may have rotated them since.
    func requestHeaders(for origin: String) -> [String: String]? {
        guard let cookies = state.withLock({ $0.cookies }) else { return nil }
        var headers = ["Cookie": cookies]
        if let authorization = SAPISIDHash.header(cookieString: cookies, origin: origin) {
            headers["Authorization"] = authorization
            headers["X-Goog-AuthUser"] = "0"
        }
        return headers
    }

    /// Apply what a response to an authenticated call said: rotated cookie
    /// values, the verdict on the session, and the free-riding datasync id. A
    /// response to a signed-out call notes nothing, so an anonymous cookie
    /// jar can never write into the account.
    func note(response: HTTPURLResponse, body: Data, sentCookies: Bool) {
        guard sentCookies else { return }
        let verdict = SessionVerdict(from: body)
        let rotated = Self.rotatedValues(from: response)
        let freshId = Self.accountTag(from: body)
        var wroteCookies = false
        let changed = state.withLock { session -> Bool in
            // Nothing to judge without a session: a login that was cleared
            // while its request flew must not come back as expired.
            guard session.cookies != nil || session.unreadable else { return false }
            var changed = false
            if let loggedIn = verdict.isLoggedIn, session.expired != !loggedIn {
                session.expired = !loggedIn
                changed = true
            }
            if let freshId, freshId != session.datasyncId {
                session.datasyncId = freshId
                changed = true
            }
            guard !rotated.isEmpty, let existing = session.cookies else { return changed }
            let merged = YouTubeCookies.merge(existing: existing, adding: rotated)
            guard merged != existing else { return changed }
            session.cookies = merged
            wroteCookies = true
            return true
        }
        if wroteCookies, let merged = state.withLock({ $0.cookies }) {
            store.write(merged)
        }
        if changed { announce() }
    }

    /// The `Set-Cookie` values one response carries, by name. Multiples of
    /// the same header arrive merged into one comma-joined line (URLSession
    /// behaviour), which `HTTPCookie` reads; an `Expires` date holding a
    /// comma can wedge two cookies together, and losing one throwaway value
    /// for a session is the cost of it — never a removed name, because merge
    /// never deletes.
    private static func rotatedValues(from response: HTTPURLResponse) -> [String: String] {
        var headerFields = [String: String]()
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String, let value = value as? String else { continue }
            headerFields[key.lowercased()] = value
        }
        guard let raw = headerFields["set-cookie"] else { return [:] }
        let url = response.url ?? URL(string: "https://music.youtube.com")!
        var updates = [String: String]()
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": raw], for: url) {
            updates[cookie.name] = cookie.value
        }
        return updates
    }

    /// `responseContext.mainAppWebResponseContext.datasyncId`, present on
    /// every authenticated response.
    private static func accountTag(from body: Data) -> String? {
        guard let json = try? JSON(data: body) else { return nil }
        return json["responseContext"]["mainAppWebResponseContext"]["datasyncId"].nonEmpty
    }

    private func announce() {
        (inbox.withLock { $0 })?()
    }
}

/// How YouTube sees the account, read out of one InnerTube response.
struct SessionVerdict: Equatable {
    /// `true` when the response reports the account logged in; nil when it
    /// says nothing either way.
    let isLoggedIn: Bool?

    /// A signed-in response answers `logged_in` in its tracking params —
    /// decoded JSON inside the body, so a regex over the raw body reads it —
    /// and a handful also carry `mainAppWebResponseContext.loggedOut` beside
    /// it. HTTP 200 proves nothing: anonymous browse answers 200 too.
    init(from body: Data) {
        // Tolerant of the pretty-printed spacing so it matches either form.
        let pattern = "\"logged_in\"\\s*,\\s*\"value\"\\s*:\\s*\"([01])\""
        if let text = body.textContent, let match = try? text.firstMatch(of: pattern) {
            isLoggedIn = match.1 == "1"
            return
        }
        if let json = try? JSON(data: body) {
            let loggedOut = json["responseContext"]["mainAppWebResponseContext"]["loggedOut"].bool
            isLoggedIn = loggedOut.map { !$0 }
            return
        }
        isLoggedIn = nil
    }
}

extension Data {
    /// The body as text without a forced decode; nil only when nothing was sent.
    var textContent: String? { String(data: self, encoding: .utf8) }
}
