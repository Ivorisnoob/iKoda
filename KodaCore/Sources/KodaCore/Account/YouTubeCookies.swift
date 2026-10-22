import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A signed-in account's youtube.com cookies, in the order they were captured.
///
/// Only youtube.com's cookies belong here. The sign-in web view's jar also holds
/// google.com's, including a SAPISID of their own; signing with that one is answered
/// as "logged in" but anonymous, so cookies from any other domain are dropped.
public struct YouTubeCookies: Sendable, Codable, Hashable {
    public struct Cookie: Sendable, Codable, Hashable {
        public var name: String
        public var value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    public private(set) var cookies: [Cookie]

    /// Cookies by name; a repeated name keeps its first value.
    public init(cookies: [Cookie]) {
        var seen = Set<String>()
        self.cookies = cookies.filter { !$0.name.isEmpty && !$0.value.isEmpty && seen.insert($0.name).inserted }
    }

    /// A `Cookie` header as pasted or stored: `a=1; b=2`, tolerating a leading
    /// `Cookie:`, surrounding quotes and line breaks.
    public init(header: String) {
        var text = header.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 { text = String(text.dropFirst().dropLast()) }
        if text.lowercased().hasPrefix("cookie:") { text = String(text.dropFirst("cookie:".count)) }
        let pairs = text.split(whereSeparator: { $0 == ";" || $0 == "\n" || $0 == "\r" }).compactMap { part -> Cookie? in
            // Only the first "=" separates: values are base64-ish and can end in "=".
            let piece = part.trimmingCharacters(in: .whitespaces)
            guard let eq = piece.firstIndex(of: "=") else { return nil }
            let name = String(piece[..<eq]).trimmingCharacters(in: .whitespaces)
            return Cookie(name: name, value: String(piece[piece.index(after: eq)...]))
        }
        self.init(cookies: pairs)
    }

    /// The sign-in web view's cookies, keeping youtube.com's only. Where a name is set
    /// both for the whole domain and for one host, the domain-wide cookie wins: that is
    /// the one every youtube.com host is sent.
    public init(_ httpCookies: [HTTPCookie], now: Date = Date()) {
        let kept = httpCookies.filter { Self.isYouTubeDomain($0.domain) && ($0.expiresDate.map { $0 > now } ?? true) }
        let ordered = kept.filter { Self.isDomainWide($0.domain) } + kept.filter { !Self.isDomainWide($0.domain) }
        self.init(cookies: ordered.map { Cookie(name: $0.name, value: $0.value) })
    }

    public subscript(name: String) -> String? {
        cookies.first { $0.name == name }?.value
    }

    public var isEmpty: Bool { cookies.isEmpty }

    /// The `Cookie` request header.
    public var header: String {
        cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// The secret requests are signed with. YouTube hands the same value out under the
    /// legacy name and its partitioned twin, so a jar missing one usually has the other.
    public var sapisid: String? {
        self["SAPISID"] ?? self["__Secure-3PAPISID"]
    }

    /// Has what a signed-in session can't work without: a SAPISID to sign with and the
    /// SID session itself. The same bar Koda for Android applies; a stricter one turns
    /// away sessions that work.
    public var looksSignedIn: Bool {
        sapisid != nil && self["SID"] != nil
    }

    // MARK: Rotation

    /// Cookies Google re-issues during a live session. The `*PSIDTS` pair in particular
    /// is replaced every few hours, and a session that keeps replaying the value it
    /// signed in with is eventually answered as signed out (Koda for Android, August 2026).
    static let rotating: Set<String> = [
        "SID", "HSID", "SSID", "APISID", "SAPISID", "LOGIN_INFO", "SIDCC",
        "__Secure-1PSID", "__Secure-3PSID", "__Secure-1PAPISID", "__Secure-3PAPISID",
        "__Secure-1PSIDTS", "__Secure-3PSIDTS", "__Secure-1PSIDCC", "__Secure-3PSIDCC",
    ]

    /// These cookies with a response's fresh values folded in.
    ///
    /// Only names already here, or ones Google rotates, are taken: every response also
    /// sets throwaway cookies (YSC, VISITOR_INFO1_LIVE, consent) that authenticate
    /// nothing. Deletions are never applied, so one odd response can't sign anyone out;
    /// the session's fate is YouTube's `logged_in` verdict, not a cookie going missing.
    /// A cookie whose value changed since `sent` went out is left alone: several signed
    /// requests are in flight together, and an older response must not roll back a
    /// newer rotation.
    func merging(_ updates: [SetCookie], sent: YouTubeCookies) -> YouTubeCookies {
        var merged = cookies
        for update in updates where !update.isDeletion && !update.value.isEmpty {
            let current = merged.firstIndex { $0.name == update.name }
            guard current != nil || Self.rotating.contains(update.name) else { continue }
            guard sent[update.name] == current.map({ merged[$0].value }) else { continue }
            if let current {
                merged[current].value = update.value
            } else {
                merged.append(Cookie(name: update.name, value: update.value))
            }
        }
        return YouTubeCookies(cookies: merged)
    }

    static func isYouTubeDomain(_ domain: String) -> Bool {
        let host = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host == "youtube.com" || host.hasSuffix(".youtube.com")
    }

    private static func isDomainWide(_ domain: String) -> Bool {
        domain.lowercased() == ".youtube.com" || domain.lowercased() == "youtube.com"
    }
}

extension YouTubeCookies: CustomStringConvertible {
    /// Never the values: they are the account.
    public var description: String { "YouTubeCookies(\(cookies.map(\.name).joined(separator: ", ")))" }
}

/// One cookie from a `Set-Cookie` header.
struct SetCookie: Equatable {
    var name: String
    var value: String
    /// Expired already, or `Max-Age` zero or less: the server asking for it to go.
    var isDeletion: Bool

    /// Every cookie in `Set-Cookie` header values. URLSession joins several headers into
    /// one with commas, and `Expires` dates hold a comma of their own ("Wed, 21 Oct"),
    /// so a comma starts a new cookie only where a `name=` follows it. Cookies for a
    /// domain other than youtube.com are dropped.
    static func parse(_ headers: [String], now: Date = Date()) -> [SetCookie] {
        headers.flatMap(split).compactMap { parseOne($0, now: now) }
    }

    private static func split(_ header: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var rest = Substring(header)
        while let comma = rest.firstIndex(of: ",") {
            let after = rest[rest.index(after: comma)...]
            current += rest[..<comma]
            if startsCookie(after) {
                parts.append(current)
                current = ""
            } else {
                current += ","
            }
            rest = after
        }
        current += rest
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Whether text begins with `token=`, as a cookie does and a date ("21 Oct 2026") does not.
    private static func startsCookie(_ text: Substring) -> Bool {
        let trimmed = text.drop { $0 == " " }
        guard let eq = trimmed.firstIndex(of: "=") else { return false }
        let name = trimmed[..<eq]
        return !name.isEmpty && name.allSatisfy { !" ;,\t".contains($0) }
    }

    private static func parseOne(_ text: String, now: Date) -> SetCookie? {
        let fields = text.split(separator: ";", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = fields.first, let eq = first.firstIndex(of: "=") else { return nil }
        let name = String(first[..<eq]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        var value = String(first[first.index(after: eq)...])
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }

        var maxAge: Int?
        var expires: Date?
        for field in fields.dropFirst() {
            let pair = field.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            switch pair[0].lowercased() {
            case "max-age" where pair.count == 2: maxAge = Int(pair[1])
            case "expires" where pair.count == 2: expires = httpDate(pair[1])
            case "domain" where pair.count == 2:
                if !YouTubeCookies.isYouTubeDomain(pair[1]) { return nil }
            default: break
            }
        }
        // Max-Age outranks Expires when both are present (RFC 6265 §5.3).
        let deleted = maxAge.map { $0 <= 0 } ?? expires.map { $0 <= now } ?? false
        return SetCookie(name: name, value: value, isDeletion: deleted || value.isEmpty)
    }

    private static func httpDate(_ text: String) -> Date? {
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, dd-MMM-yyyy HH:mm:ss zzz", "EEE, dd-MMM-yy HH:mm:ss zzz"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
