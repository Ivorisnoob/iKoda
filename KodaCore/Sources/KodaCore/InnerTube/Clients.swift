import Foundation

/// The InnerTube identities Koda speaks as. Versions go stale after a few
/// months (HTTP 400 on browse is the symptom); bump them together, from the
/// bootstrap HTML of music.youtube.com and www.youtube.com.
enum Clients {
    /// The public key every YouTube web client embeds. Not a secret: it is in
    /// YouTube's own JavaScript and names only the client type.
    static let apiKey = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"

    /// Sent wherever Koda speaks as a web client; must look plausible against the versions below.
    static let browserUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

    static let webVersion = "2.20260903.01.00"
    static let webRemixVersion = "1.20260901.12.00"

    /// The standard YouTube web client on www.youtube.com.
    enum Web {
        static let name = "WEB"
        static let version = webVersion
        static let id = "1"
        static let origin = "https://www.youtube.com"
    }

    /// The stream client: one `/player` call under Koda's own visitorData,
    /// plain URLs on every format, whole files served in ranges.
    /// [verified October 2026: AAC itags 139/140 with URLs, no cipher]
    enum VisionOS {
        static let name = "VISIONOS"
        static let version = "1.02"
        static let id = "101"
        static let userAgent = "com.google.visionos.youtube/1.02(RealityDevice14,1; U; CPU visionOS 25_6_0 like Mac OS X; GB)"
        static let fields: [String: String] = [
            "clientScreen": "WATCH",
            "platform": "MOBILE",
            "deviceMake": "Apple",
            "deviceModel": "RealityDevice14,1",
            "osName": "visionOS",
            "osVersion": "25.6.0.23O471",
        ]
    }
}
