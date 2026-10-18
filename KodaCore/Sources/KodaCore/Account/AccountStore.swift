import Foundation

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
///    done.
///
/// A session that cannot be read right now (the device is locked, the
/// unsigned Mac build's file fallback is unreadable) is still connected as
/// far as anyone knows, matching the Last.fm behaviour: requests simply go
/// out signed out until the store answers again.
public actor AccountStore {
    private let store: SessionStore
    private var cookies: String?
    private var credentialsUnreadable = false
    /// YouTube has refused a session that exists and can be refreshed.
    public private(set) var isExpired = false

    /// - Parameter service: a unique Keychain service per test, so stores keep their cookies apart.
    public init(directory: URL?, service: String = "ivors.Koda.ytm") {
        let fallback = directory?.appending(path: "yt_session")
        store = SessionStore(service: service, fallback: fallback ?? URL(fileURLWithPath: "/dev/null"))
        switch store.read() {
        case .found(let string):
            cookies = string
        case .missing:
            credentialsUnreadable = false
        case .unreadable:
            credentialsUnreadable = true
        }
    }

    /// Whether an account is attached, made visible in Settings even while its
    /// cookies cannot be read at the moment.
    public var isLoggedIn: Bool { cookies != nil || credentialsUnreadable }

    public func clearSession() {
        credentialsUnreadable = false
        cookies = nil
        isExpired = false
        store.delete()
    }

    /// Save a cookie string from the login capture or the paste sheet.
    /// Returns the required names it is still missing, empty when accepted.
    @discardableResult
    public func addCookies(_ raw: String) -> [String] {
        let cookieString = YouTubeCookies.normalize(raw)
        let missing = YouTubeCookies.missing(cookieString)
        guard missing.isEmpty else { return missing }
        credentialsUnreadable = false
        cookies = cookieString
        isExpired = false
        store.write(cookieString)
        return []
    }

    /// The headers an authenticated request to `origin` signs with — nil when
    /// there is nothing to send, deliberate for the endpoints that read fine
    /// anonymously: an empty `Cookie` header is worse than none at all.
    /// Cookies are read fresh per call; a reply may have rotated them since.
    func requestHeaders(for origin: String) -> [String: String]? {
        guard let cookies else { return nil }
        var headers = ["Cookie": cookies]
        if let authorization = SAPISIDHash.header(cookieString: cookies, origin: origin) {
            headers["Authorization"] = authorization
            headers["X-Goog-AuthUser"] = "0"
        }
        return headers
    }

    /// Apply what a response to an authenticated call said: rotated cookie
    /// values, and YouTube's verdict on the session. A response to a signed-
    /// out call notes nothing, so an anonymous cookie jar can never write
    /// into the account.
    func note(response: HTTPURLResponse, body: Data, sentCookies: Bool) {
        guard sentCookies else { return }
        let verdict = SessionVerdict(from: body)
        if let loggedIn = verdict.isLoggedIn {
            isExpired = !loggedIn
        }
        let updates = Self.rotatedValues(from: response)
        guard !updates.isEmpty, let existing = cookies else { return }
        let merged = YouTubeCookies.merge(existing: existing, adding: updates)
        guard merged != existing else { return }
        cookies = merged
        store.write(merged)
    }

    /// The `Set-Cookie` values one response carries, by name. Multiples of
    /// the same header arrive merged into one comma-joined line (URLSession
    /// behaviour), which `HTTPCookie` reads; an `Expires` date with a comma
    /// can wedge two cookies together, and losing one throwaway value for a
    /// session is the cost of it — never a removed name, because merge never
    /// deletes.
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
        if let match = body.string?.firstMatch(of: pattern) {
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
    var `string`: String? { String(data: self, encoding: .utf8) }
}
