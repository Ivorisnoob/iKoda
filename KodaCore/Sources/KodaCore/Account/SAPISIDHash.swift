import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// The `Authorization` a signed-in YouTube web client sends:
/// `SAPISIDHASH <time>_<sha1("<time> <SAPISID> <origin>")>`.
///
/// The hash names its origin, so a request signed for www.youtube.com is refused on
/// music.youtube.com and the other way round. Koda for Android signs with this alone
/// (no SAPISID1PHASH/3PHASH variants) and that has held in production, so this does too.
public enum SAPISIDHash {
    public static let musicOrigin = "https://music.youtube.com"

    public static func authorization(sapisid: String, origin: String = musicOrigin, at date: Date = Date()) -> String {
        let time = Int(date.timeIntervalSince1970)
        return "SAPISIDHASH \(time)_\(SHA1.hex("\(time) \(sapisid) \(origin)"))"
    }

    /// The headers that carry an account on an InnerTube request. Without a SAPISID the
    /// cookies still go but nothing is signed: an empty Authorization is worse than none.
    static func headers(for cookies: YouTubeCookies, origin: String = musicOrigin, at date: Date = Date()) -> [String: String] {
        var headers = ["Cookie": cookies.header, "X-Origin": origin]
        if let sapisid = cookies.sapisid {
            headers["Authorization"] = authorization(sapisid: sapisid, origin: origin, at: date)
            headers["X-Goog-AuthUser"] = "0"
        }
        return headers
    }
}

/// SHA-1, which the signature needs; not used for anything that must be secure.
enum SHA1 {
    static func hex(_ text: String) -> String {
        digest(Array(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func digest(_ message: [UInt8]) -> [UInt8] {
        #if canImport(CryptoKit)
        return Array(Insecure.SHA1.hash(data: Data(message)))
        #else
        return portableDigest(message)
        #endif
    }

    /// FIPS 180-4 SHA-1, for platforms without CryptoKit (the Linux type-check); tested
    /// against CryptoKit's answers on Apple platforms.
    static func portableDigest(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
        var bytes = message
        let bitLength = UInt64(message.count) * 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift))) }

        var w = [UInt32](repeating: 0, count: 80)
        for chunk in stride(from: 0, to: bytes.count, by: 64) {
            for i in 0..<16 {
                let at = chunk + i * 4
                w[i] = UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
            }
            for i in 16..<80 { w[i] = rotate(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1) }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4]
            for i in 0..<80 {
                let f: UInt32, k: UInt32
                switch i {
                case 0..<20: f = (b & c) | (~b & d); k = 0x5A827999
                case 20..<40: f = b ^ c ^ d; k = 0x6ED9EBA1
                case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC
                default: f = b ^ c ^ d; k = 0xCA62C1D6
                }
                let next = rotate(a, 5) &+ f &+ e &+ k &+ w[i]
                e = d; d = c; c = rotate(b, 30); b = a; a = next
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e
        }
        return h.flatMap { word in [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: word >> UInt32($0)) } }
    }

    private static func rotate(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }
}
