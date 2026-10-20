import CryptoKit
import Foundation

/// The `Authorization` header of every authenticated InnerTube call.
///
/// The hash format is `SAPISIDHASH {unix-timestamp}_{sha1("{ts} {SAPISID} {origin}")}`
/// and it is **per-origin**: a hash built for `https://music.youtube.com` is
/// refused on `https://www.youtube.com` and the other way round. No signature
/// key, no OAuth token: the SAPISID cookie value is the secret, which is why
/// a session never needs refreshing the way a token would.
enum SAPISIDHash {
    static func header(cookieString: String, origin: String) -> String? {
        header(cookieString: cookieString, origin: origin, timestamp: Int(Date().timeIntervalSince1970))
    }

    /// The timestamp is separate only so tests can pin an exact signature.
    static func header(cookieString: String, origin: String, timestamp: Int) -> String? {
        guard let sapisid = YouTubeCookies.sapisid(in: cookieString) else { return nil }
        let input = "\(timestamp) \(sapisid) \(origin)"
        let digest = Data(input.utf8).withUnsafeBytes { Insecure.SHA1.hash(data: $0) }
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "SAPISIDHASH \(timestamp)_\(hex)"
    }
}
