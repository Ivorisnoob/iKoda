import Foundation

/// The cookie arithmetic a YouTube session is made of: reading values out of
/// a cookie string, tidying a hand-pasted one, folding Google's rotated
/// values back in. Pure string work, so it is fully unit-testable.
///
/// The session itself is not a Google OAuth token. Signing in on YouTube
/// hands Koda the same cookies the web client holds — `SID`, `SAPISID` and
/// friends — and every authenticated request signs with a SAPISIDHASH built
/// from them. `SAPISID` lives for years; only the `*SIDTS` pair is reissued
/// every few hours, which is what the merge below keeps fresh.
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
    /// the same bar the login screen applies — a stricter check here would
    /// reject sessions that actually work.
    static func missing(_ cookieString: String) -> [String] {
        var missing: [String] = []
        if sapisid(in: cookieString) == nil { missing.append("SAPISID") }
        if value("SID", in: cookieString) == nil { missing.append("SID") }
        return missing
    }

    /// Tidy a hand-pasted cookie header into the single line `k=v; k=v` that
    /// the login capture produces. Handles the shapes people actually paste:
    /// a DevTools copy of the request header with the `Cookie:` name still
    /// attached, a wrapped multi-line copy, stray surrounding quotes.
    static func normalize(_ raw: String) -> String {
        var string = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if string.count > 1, string.first == "\"", string.last == "\"" {
            string = String(string.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for prefix in ["Cookie:", "cookie:"] where string.hasPrefix(prefix) {
            string = String(string.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        string = string.replacingOccurrences(of: "\\s*[\\r\\n]+\\s*", with: " ", options: .regularExpression)
        return string.trimmingCharacters(in: CharacterSet(charactersIn: "; "))
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
}
