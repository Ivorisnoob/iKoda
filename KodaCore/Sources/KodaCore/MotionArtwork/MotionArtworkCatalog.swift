import Foundation

/// Reading Apple Music's catalogue for an album's animated cover: which catalogue song is
/// the one playing, which loop to take from its HLS ladder, and the one file that loop is.
/// Everything here is pure, so it is tested against real responses.
public enum MotionArtworkCatalog {
    /// The two shapes Apple publishes: the square cover, and the tall one Music shows
    /// full screen on the Lock Screen.
    public enum Shape: String, Sendable, CaseIterable, Codable, CodingKeyRepresentable {
        case square, tall

        /// Width over height.
        public var aspect: Double { self == .square ? 1 : 3.0 / 4 }
    }

    /// An album's animated covers, as the catalogue lists them.
    public struct Covers: Sendable, Equatable, Codable {
        /// Apple's album id, which names the files cached for it.
        public var albumID: String
        /// Each shape's HLS master playlist.
        public var masters: [Shape: URL]
        /// Each shape's still first frame, a template with `{w}` and `{h}`.
        public var previews: [Shape: String]

        public func preview(_ shape: Shape, pixels: Int) -> URL? {
            guard let template = previews[shape] ?? previews[.square] else { return nil }
            let height = Int((Double(pixels) / shape.aspect).rounded())
            let filled = template.replacingOccurrences(of: "{w}", with: String(pixels))
                .replacingOccurrences(of: "{h}", with: String(height))
            return URL(string: filled).flatMap { isMediaURL($0) ? $0 : nil }
        }
    }

    // MARK: Matching

    /// The catalogue search for a song. YouTube Music's album names come from the same
    /// distributors as Apple's, so title, artist and album together pin the release.
    static func searchURL(for song: Song) -> URL? {
        var components = URLComponents(string: "https://amp-api-edge.music.apple.com/v1/catalog/us/search")
        let artist = song.artists.first?.name ?? song.artistLine
        components?.queryItems = [
            URLQueryItem(name: "term", value: "\(song.title) \(artist)"),
            URLQueryItem(name: "types", value: "songs"),
            URLQueryItem(name: "include[songs]", value: "albums"),
            URLQueryItem(name: "format[resources]", value: "map"),
            URLQueryItem(name: "extend", value: "editorialVideo"),
            URLQueryItem(name: "l", value: "en-US"),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "platform", value: "web"),
        ]
        return components?.url
    }

    /// Only songs from an album are looked up: a music video or an upload has no album
    /// whose cover could be the one playing, and a near miss would show someone else's art.
    static func isLookable(_ song: Song) -> Bool {
        guard !song.isVideo, let album = song.album?.title, !normalized(album).isEmpty else { return false }
        return !normalized(song.title).isEmpty && !normalized(song.artistLine).isEmpty
    }

    /// The animated covers of the album the playing song is on, or nil when the catalogue
    /// has none for it. A result counts only when its title, artist and album all agree and
    /// its length is within 8 seconds: a wrong animated cover is worse than the still one.
    public static func covers(in json: JSON, for song: Song) -> Covers? {
        let songs = json["resources"]["songs"]
        let albums = json["resources"]["albums"]
        for result in json["results"]["songs"]["data"].array {
            guard let id = result["id"].string else { continue }
            let entry = songs[id]
            guard matches(song, entry["attributes"]),
                  let albumID = entry["relationships"]["albums"]["data"][0]["id"].string else { continue }
            let video = albums[albumID]["attributes"]["editorialVideo"]
            var masters: [Shape: URL] = [:]
            var previews: [Shape: String] = [:]
            for (shape, keys) in [(Shape.square, ["motionDetailSquare", "motionSquareVideo1x1"]),
                                  (Shape.tall, ["motionDetailTall", "motionTallVideo3x4"])] {
                for key in keys {
                    guard let url = video[key]["video"].string.flatMap(URL.init(string:)), isMediaURL(url) else { continue }
                    masters[shape] = url
                    previews[shape] = video[key]["previewFrame"]["url"].string
                    break
                }
            }
            if masters[.square] != nil { return Covers(albumID: albumID, masters: masters, previews: previews) }
        }
        return nil
    }

    static func matches(_ song: Song, _ candidate: JSON) -> Bool {
        guard isLookable(song) else { return false }
        let theirArtist = normalized(candidate["artistName"].string ?? "")
        let ours = [song.artistLine, song.artists.first?.name ?? ""].map(normalized)
        guard !theirArtist.isEmpty, ours.contains(theirArtist) else { return false }
        guard title(song.title) == title(candidate["name"].string ?? "") else { return false }
        guard album(song.album?.title ?? "") == album(candidate["albumName"].string ?? "") else { return false }
        if let duration = song.duration, duration > 0, let millis = candidate["durationInMillis"].double, millis > 0 {
            return abs(duration - millis / 1000) <= 8
        }
        return true
    }

    /// Letters and digits only, lowercased, so "Man’s" and "Man's" agree.
    static func normalized(_ value: String) -> String {
        let folded = value.precomposedStringWithCompatibilityMapping.lowercased()
        var out = ""
        var gap = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                if gap, !out.isEmpty { out.append(" ") }
                out.unicodeScalars.append(scalar)
                gap = false
            } else {
                gap = true
            }
        }
        return out
    }

    /// One service writes "(feat. X)" into the title and the other doesn't.
    static func title(_ value: String) -> String {
        normalized(value.replacingOccurrences(of: #"\s*[\(\[](?:feat\.?|ft\.?|featuring|with)\s[^\)\]]*[\)\]]"#,
                                              with: "", options: [.regularExpression, .caseInsensitive]))
    }

    /// Apple names a single "X - Single" and an EP "X - EP"; YouTube Music names both "X".
    static func album(_ value: String) -> String {
        normalized(value.replacingOccurrences(of: #"\s+-\s+(?:Single|EP)$"#, with: "", options: .regularExpression))
    }

    // MARK: The loop

    struct Variant: Equatable {
        var url: URL
        var width: Int
        var height: Int
        var bandwidth: Int
        var hevc: Bool
    }

    /// The video rungs of a master playlist (I-frame-only trick play rungs are left out).
    static func variants(master: URL, playlist: String) -> [Variant] {
        guard isMediaURL(master), playlist.hasPrefix("#EXTM3U") else { return [] }
        var variants: [Variant] = []
        var attributes: [String: String]?
        for raw in playlist.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                attributes = parseAttributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
            } else if !line.isEmpty, !line.hasPrefix("#") {
                defer { attributes = nil }
                guard let a = attributes,
                      let size = a["RESOLUTION"]?.split(separator: "x").compactMap({ Int($0) }), size.count == 2,
                      // The average follows the file's size; the peak doesn't.
                      let bandwidth = (a["AVERAGE-BANDWIDTH"] ?? a["BANDWIDTH"]).flatMap({ Int($0) }),
                      let url = URL(string: line, relativeTo: master)?.absoluteURL, isMediaURL(url) else { continue }
                let codecs = (a["CODECS"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                let hevc = codecs.contains { $0.hasPrefix("hvc1.") || $0.hasPrefix("hev1.") }
                guard hevc || codecs.contains(where: { $0.hasPrefix("avc1.") }) else { continue }
                // Every cover probed is SDR; anything else would need the whole surface to change.
                if let range = a["VIDEO-RANGE"], range != "SDR" { continue }
                variants.append(Variant(url: url, width: size[0], height: size[1], bandwidth: bandwidth, hevc: hevc))
            }
        }
        return variants
    }

    /// Larger rungs than this cost several times the bytes for nothing a phone or a Mac
    /// window shows: a full-width cover on a 3x phone is about 1080 pixels.
    static let largestWidth = 1080

    /// The cheapest rung that fills `pixels` across: the smallest size that does, at its
    /// leanest encode (often HEVC; every device Koda runs on decodes it in hardware).
    static func pick(_ variants: [Variant], pixels: Int) -> Variant? {
        // A moving picture hides a slight upscale, so a rung within 15 % of the size will do.
        let wanted = Int(Double(min(pixels, largestWidth)) * 0.85)
        let byCost: (Variant, Variant) -> Bool = { a, b in
            a.width != b.width ? a.width < b.width : a.bandwidth < b.bandwidth
        }
        let fitting = variants.filter { $0.width >= wanted && $0.width <= largestWidth }
        if let best = fitting.min(by: byCost) { return best }
        // Nothing that large: the largest there is.
        return variants.filter { $0.width <= largestWidth }.max { a, b in byCost(b, a) }
    }

    /// The one file a rung's media playlist cuts into byte ranges. Apple serves each loop as a
    /// single fragmented MP4, which plays as a local file once downloaded whole; a playlist of
    /// separate segments would need stitching, so it gives no file and the cover stays still.
    static func singleFile(media: URL, playlist: String) -> URL? {
        guard playlist.hasPrefix("#EXTM3U"), playlist.contains("#EXT-X-ENDLIST") else { return nil }
        var files = Set<URL>()
        var expectedOffset = 0
        for raw in playlist.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-MAP:") {
                let a = parseAttributes(String(line.dropFirst("#EXT-X-MAP:".count)))
                guard let uri = a["URI"], let url = URL(string: uri, relativeTo: media)?.absoluteURL,
                      let range = a["BYTERANGE"].flatMap(byteRange), range.offset == 0 else { return nil }
                files.insert(url)
                expectedOffset = range.length
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                guard let range = byteRange(String(line.dropFirst("#EXT-X-BYTERANGE:".count))),
                      range.offset == expectedOffset else { return nil }
                expectedOffset += range.length
            } else if !line.isEmpty, !line.hasPrefix("#") {
                guard let url = URL(string: line, relativeTo: media)?.absoluteURL else { return nil }
                files.insert(url)
            }
        }
        guard files.count == 1, let file = files.first, isMediaURL(file), expectedOffset > 0 else { return nil }
        return file
    }

    private static func byteRange(_ value: String) -> (length: Int, offset: Int)? {
        let parts = value.split(separator: "@")
        guard parts.count == 2, let length = Int(parts[0]), let offset = Int(parts[1]), length > 0 else { return nil }
        return (length, offset)
    }

    private static func parseAttributes(_ list: String) -> [String: String] {
        var out: [String: String] = [:]
        var key = ""
        var value = ""
        var inKey = true
        var quoted = false
        for character in list {
            if inKey {
                if character == "=" { inKey = false } else if character != "," { key.append(character) }
            } else if character == "\"" {
                quoted.toggle()
            } else if character == ",", !quoted {
                out[key.trimmingCharacters(in: .whitespaces)] = value
                key = ""
                value = ""
                inKey = true
            } else {
                value.append(character)
            }
        }
        if !key.isEmpty { out[key.trimmingCharacters(in: .whitespaces)] = value }
        return out
    }

    // MARK: Hosts and the web token

    /// Apple's video and image hosts, over HTTPS; nothing in a response sends Koda elsewhere.
    static func isMediaURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, let host = url.host() else { return false }
        return host.hasSuffix(".itunes.apple.com") || host.hasSuffix(".mzstatic.com")
    }

    /// Music on the web, where the public token comes from (it redirects to a storefront path).
    static func isWebURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil && url.host() == "music.apple.com"
    }

    /// The web player's script bundle, named in its page.
    static func scriptPath(inPage html: String) -> String? {
        html.firstMatch(of: /\/assets\/[^"'<>\s]*index[^"'<>\s]*\.js/).map { String($0.output) }
    }

    /// The anonymous token Music on the web reads the catalogue with, from its script bundle.
    static func webToken(inScript script: String, now: Date) -> String? {
        for match in script.matches(of: /eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/) {
            let token = String(match.output)
            if isUsableToken(token, now: now) { return token }
        }
        return nil
    }

    /// Music on the web's own token (issuer AMPWebPlay), good for at least another hour.
    static func isUsableToken(_ token: String, now: Date) -> Bool {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return false }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload), let json = try? JSON(data: data),
              json["iss"].string == "AMPWebPlay", let expiry = json["exp"].double else { return false }
        return expiry > now.timeIntervalSince1970 + 3600
    }
}
