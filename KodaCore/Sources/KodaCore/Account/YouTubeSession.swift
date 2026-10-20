import Foundation

/// The public face of a YouTube session, for the app's sign-in.
///
/// The cookie arithmetic itself lives inside KodaCore; this is what the app
/// needs to read a session out of WebKit's cookie store and to tell whether
/// the session it holds is one YouTube will accept.
public enum YouTubeSession {
    /// The cookie header of a YouTube session, taken from a browser's cookie
    /// jar. Only YouTube's own cookies are read: mid-sign-in the page sits on
    /// `accounts.google.com`, whose jar also carries a SAPISID, and taking
    /// that one signs in as "logged in but anonymous".
    public static func header(from cookies: [HTTPCookie]) -> String? {
        YouTubeCookies.header(for: cookies)
    }

    /// Whether a cookie header holds a session Koda can sign with: a SAPISID
    /// to sign requests with, and the SID session itself.
    public static func isComplete(_ header: String) -> Bool {
        YouTubeCookies.missing(header).isEmpty
    }

    /// The names a cookie header is still missing, empty when it is complete.
    public static func missingNames(in header: String) -> [String] {
        YouTubeCookies.missing(header)
    }
}
