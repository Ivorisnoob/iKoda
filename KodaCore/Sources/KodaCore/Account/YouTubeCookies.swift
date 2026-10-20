import Foundation

/// The cookie arithmetic a YouTube session is made of: reading values out of a
/// cookie header, tidying what the browser hands over, and folding Google's
/// rotated values back in. Pure string work, so it is fully unit-testable.
///
/// The session itself is not a Google OAuth token. Signing in on YouTube hands
/// Koda the same cookies the web client holds — `SID`, `SAPISID` and friends —
/// and every authenticated request signs with a SAPISIDHASH built from them.
/// `SAPISID` lives for years; only the `*SIDTS` pair is reissued every few
/// hours, which is what the merge below keeps fresh.
enum YouTubeCookies {
    /// Names that carry the secret a SAPISIDHASH is built from. YouTube hands
    /// out the same value under the legacy name and its partitioned twin, so
    /// a jar that is missing one usually still has the other.
    static let sapisidNames = ["SAPISID", "__Secure-3PAPISID"]

    /// Cookies Google rotates during a live session, on top of whatever the
    /// jar already carries. The `*SIDTS` pair in particular is reissued every
    /// few hours, and a session that keeps replaying the value captured at
    /// login eventually gets answered as signed out — `logged_in: 0` in the
    /// response context, an empty subscriptions feed, a blank account name —
    /// all while the SAPISIDHASH still computes fine. [verified on Koda for
    /// Android, August 2026]
    static let refreshableNames: Set<String> = [
        "SID", "HSID", "SSID", "APISID", "SAPISID", "LOGIN_INFO", "SIDCC",
        "__Secure-1PSID", "__Secure-3PSID",
        "__Secure-1PAPISID", "__Secure-3PAPISID",
        "__Secure-1PSIDTS", "__Secure-3PSIDTS",
        "__Secure-1PSIDCC", "__Secure-3PSIDCC",
    ]

    /// A cookie value: `SID=abc; SAPISID=q w; __Secure-3PAPISID=q w`.
    /// The first line the name appears on wins.
    static func value(_ name: String, in cookieString: String) -> String? {
        for part in cookieString.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.first?.trimmingCharacters(in: .whitespaces) == name else { continue }
            // limit = 2: values are base64-ish and can carry '=' padding, so
            // only the first separator delimits name from value.
            let value = pair.dropFirst().first?.trimmingCharacters(in: .whitespaces) ?? ""
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// The SAPISID value to sign with, under whichever name it arrived.
    static func sapisid(in cookieString: String) -> String? {
        sapisidNames.lazy.compactMap { value($0, in: cookieString) }.first
    }

    /// Names missing from a cookie string that no session can work without: a
    /// SAPISID to sign requests with, and the SID session itself. Deliberately
    /// the same bar the login capture applies — a stricter check here would
    /// reject sessions that actually work.
    static func missing(_ cookieString: String) -> [String] {
        var missing: [String] = []
        if sapisid(in: cookieString) == nil { missing.append("SAPISID") }
        if value("SID", in: cookieString) == nil { missing.append("SID") }
        return missing
    }

    /// Fold freshly issued cookie values into the stored cookie string.
    ///
    /// Only names already present, or in `refreshableNames`, are taken: every
    /// response also sets throwaway cookies (`YSC`, `VISITOR_INFO1_LIVE`, ad
    /// and consent state) that would bloat the header without authenticating
    /// anything. Order is preserved and nothing is ever removed: this can
    /// only make a session fresher, never tear one down.
    static func merge(existing: String, adding updates: [String: String]) -> String {
        var merged = [String: String]()
        var order = [String]()
        for part in existing.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = pair.first?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { continue }
            if merged[name] == nil { order.append(name) }
            merged[name] = pair.count > 1 ? String(pair[1]) : ""
        }
        for (name, pairValue) in updates {
            guard !pairValue.isEmpty, refreshableNames.contains(name) || merged[name] != nil else { continue }
            if merged[name] == nil { order.append(name) }
            merged[name] = pairValue
        }
        return order.compactMap { name in
            merged[name].map { "\(name)=\($0)" }
        }.joined(separator: "; ")
    }

    /// The cookie header a browser's jar becomes: YouTube's own cookies only,
    /// in a stable order, with expired ones left out.
    ///
    /// Only `youtube.com` is read. Mid-login the page sits on
    /// `accounts.google.com`, whose jar also carries a SAPISID, and taking
    /// that one signs in as "logged in but anonymous" — the session belongs to
    /// Google's sign-in page, not to YouTube. [verified on Koda for Android,
    /// August 2026]
    static func header(for cookies: [HTTPCookie]) -> String? {
        let now = Date()
        let mine = cookies.filter { cookie in
            guard isYouTube(cookie.domain) else { return false }
            if let expires = cookie.expiresDate, expires <= now { return false }
            return !cookie.value.isEmpty
        }
        guard !mine.isEmpty else { return nil }
        // Sorted, so the same jar always produces the same header.
        let pairs = mine.sorted { $0.name < $1.name }.map { "\($0.name)=\($0.value)" }
        return pairs.joined(separator: "; ")
    }

    /// Whether a cookie domain is one of YouTube's own.
    static func isYouTube(_ domain: String) -> Bool {
        let name = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return name == "youtube.com" || name.hasSuffix(".youtube.com")
    }

    /// The `Set-Cookie` values one response carries, by name.
    ///
    /// URLSession hands back every `Set-Cookie` of a response as one line with
    /// them joined by commas, and an `Expires` date holds a comma of its own.
    /// The header is split where a comma is followed by another cookie's name,
    /// which is the only place a new cookie can start, and each piece is then
    /// read on its own.
    static func setCookieValues(_ headers: [String], for url: URL) -> [String: String] {
        var values = [String: String]()
        for header in headers {
            for piece in splitSetCookie(header) {
                for cookie in HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": piece], for: url) {
                    values[cookie.name] = cookie.value
                }
            }
        }
        return values
    }

    /// One `Set-Cookie` header into its separate cookies.
    ///
    /// A comma only starts a new cookie when a cookie's name follows it; the
    /// comma inside an `Expires=Wed, 21 Oct 2026` date is followed by a
    /// weekday, and the one inside a `Expires=Thu, 01 Jan 1970` value is
    /// followed by a time.
    static func splitSetCookie(_ header: String) -> [String] {
        guard let separator = try? NSRegularExpression(pattern: #",\s*(?=[A-Za-z0-9_!#$%&'*+.^`|~-]+=)"#) else {
            return [header]
        }
        let range = NSRange(location: 0, length: header.utf16.count)
        var pieces: [String] = []
        var last = header.startIndex
        separator.enumerateMatches(in: header, options: [], range: range) { match, _, _ in
            guard let match, let at = Range(match.range, in: header) else { return }
            pieces.append(String(header[last..<at.lowerBound]))
            // The next piece starts at the cookie's name, not at the comma
            // that ended the one before it.
            last = at.upperBound
        }
        pieces.append(String(header[last...]))
        return pieces.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
