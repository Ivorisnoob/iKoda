import Foundation

/// What Apple Music's catalogue says about an artist, for their page in Koda: the moving
/// portrait Music shows at the top of it, the editorial biography, where they come from, the
/// portrait's colours and their newest release. Found by name and kept only when Apple's songs
/// and albums for that name are the YouTube artist's own (see `MotionArtworkCatalog.artist`).
public struct AppleArtist: Sendable, Equatable, Codable {
    /// Apple's artist id.
    public var id: String
    public var name: String
    /// Apple Music's editorial biography, as Markdown (its italics and bold kept).
    public var bio: String?
    /// "Los Angeles, CA, United States".
    public var origin: String?
    /// The day a person was born, or the day a group formed, as Apple writes it: "June 13, 2013".
    public var bornOrFormed: String?
    public var isGroup: Bool
    public var genre: String?
    /// The portrait's own colours, `RRGGBB`: what it sits on, then four colours for text on that.
    public var background: String?
    public var textColors: [String]
    /// Their newest release, as Apple dates it.
    public var latest: Release?
    /// The moving portrait (square and wide), when Apple has one; most smaller artists don't.
    public var motion: MotionArtworkCatalog.Covers?

    public struct Release: Sendable, Equatable, Codable {
        /// The release's title, without Apple's " - Single" or " - EP".
        public var title: String
        /// The day it came out, or comes out when announced ahead.
        public var date: Date?
        public var isSingle: Bool

        public init(title: String, date: Date?, isSingle: Bool) {
            self.title = title
            self.date = date
            self.isSingle = isSingle
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = try c.decode(String.self, forKey: .title)
            date = try c.decodeIfPresent(Date.self, forKey: .date)
            isSingle = try c.decodeIfPresent(Bool.self, forKey: .isSingle) ?? false
        }
    }

    public init(id: String, name: String, bio: String? = nil, origin: String? = nil, bornOrFormed: String? = nil,
                isGroup: Bool = false, genre: String? = nil, background: String? = nil, textColors: [String] = [],
                latest: Release? = nil, motion: MotionArtworkCatalog.Covers? = nil) {
        self.id = id
        self.name = name
        self.bio = bio
        self.origin = origin
        self.bornOrFormed = bornOrFormed
        self.isGroup = isGroup
        self.genre = genre
        self.background = background
        self.textColors = textColors
        self.latest = latest
        self.motion = motion
    }

    /// Kept on disk between launches: a field added later must not make an older file unreadable.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        bio = try c.decodeIfPresent(String.self, forKey: .bio)
        origin = try c.decodeIfPresent(String.self, forKey: .origin)
        bornOrFormed = try c.decodeIfPresent(String.self, forKey: .bornOrFormed)
        isGroup = try c.decodeIfPresent(Bool.self, forKey: .isGroup) ?? false
        genre = try c.decodeIfPresent(String.self, forKey: .genre)
        background = try c.decodeIfPresent(String.self, forKey: .background)
        textColors = try c.decodeIfPresent([String].self, forKey: .textColors) ?? []
        latest = try c.decodeIfPresent(Release.self, forKey: .latest)
        motion = try c.decodeIfPresent(MotionArtworkCatalog.Covers.self, forKey: .motion)
    }
}

extension MotionArtworkCatalog {
    // MARK: Artists

    /// The catalogue's artists named like the YouTube artist.
    static func artistSearchURL(name: String) -> URL? {
        var components = URLComponents(string: "https://amp-api-edge.music.apple.com/v1/catalog/us/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: name),
            URLQueryItem(name: "types", value: "artists"),
            URLQueryItem(name: "l", value: "en-US"),
            URLQueryItem(name: "limit", value: "5"),
            URLQueryItem(name: "platform", value: "web"),
        ]
        return components?.url
    }

    /// Results whose name is the YouTube artist's (letters and digits alike), best first; at
    /// most three, since one request reads them all.
    static func artistCandidates(in json: JSON, name: String) -> [String] {
        let wanted = normalized(name)
        guard !wanted.isEmpty else { return [] }
        return Array(json["results"]["artists"]["data"].array
            .filter { normalized($0["attributes"]["name"].string ?? "") == wanted }
            .compactMap { $0["id"].string }
            .prefix(3))
    }

    /// Everything the page shows about each candidate, with the songs and albums that tell
    /// which of them is the YouTube artist, in one request.
    static func artistsURL(ids: [String]) -> URL? {
        guard !ids.isEmpty, ids.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        var components = URLComponents(string: "https://amp-api-edge.music.apple.com/v1/catalog/us/artists")
        components?.queryItems = [
            URLQueryItem(name: "ids", value: ids.joined(separator: ",")),
            URLQueryItem(name: "extend", value: "artistBio,bornOrFormed,editorialVideo,isGroup,origin"),
            URLQueryItem(name: "views", value: "top-songs,full-albums,latest-release"),
            URLQueryItem(name: "l", value: "en-US"),
            URLQueryItem(name: "platform", value: "web"),
        ]
        return components?.url
    }

    /// The candidate that is the YouTube artist, or nil. Two artists can share a name (there
    /// are two BTS), so a candidate counts only when at least two of the YouTube artist's own
    /// song and album titles are among Apple's for it (one, if YouTube lists only one): the
    /// wrong face on someone's page is worse than none.
    public static func artist(in json: JSON, candidates: [String], titles: [String]) -> AppleArtist? {
        let ours = Set(titles.map(releaseKey).filter { !$0.isEmpty })
        guard !ours.isEmpty else { return nil }
        let needed = min(2, ours.count)
        let byID = Dictionary(json["data"].array.compactMap { entry in entry["id"].string.map { ($0, entry) } },
                              uniquingKeysWith: { first, _ in first })
        for id in candidates {
            guard let entry = byID[id] else { continue }
            let views = entry["views"]
            let theirs = (views["top-songs"]["data"].array + views["full-albums"]["data"].array + views["latest-release"]["data"].array)
                .compactMap { $0["attributes"]["name"].string }
            guard ours.intersection(theirs.map(releaseKey)).count >= needed else { continue }
            return profile(entry)
        }
        return nil
    }

    static func profile(_ entry: JSON) -> AppleArtist? {
        guard let id = entry["id"].string else { return nil }
        let attributes = entry["attributes"]
        let artwork = attributes["artwork"]
        let latest = entry["views"]["latest-release"]["data"][0]["attributes"]
        let release = latest["name"].string.map { name in
            AppleArtist.Release(title: name.replacingOccurrences(of: #"\s+-\s+(?:Single|EP)$"#, with: "", options: .regularExpression),
                                date: latest["releaseDate"].string.flatMap(releaseDate),
                                isSingle: latest["isSingle"].bool ?? name.hasSuffix(" - Single"))
        }
        return AppleArtist(
            id: id,
            name: attributes["name"].string ?? "",
            bio: attributes["artistBio"].string.flatMap(markdown(fromHTML:)),
            origin: attributes["origin"].string.flatMap { $0.isEmpty ? nil : $0 },
            bornOrFormed: attributes["bornOrFormed"].string.flatMap { $0.isEmpty ? nil : $0 },
            isGroup: attributes["isGroup"].bool ?? false,
            genre: attributes["genreNames"][0].string.flatMap { $0 == "Music" ? nil : $0 },
            background: artwork["bgColor"].string.flatMap(hexColor),
            textColors: ["textColor1", "textColor2", "textColor3", "textColor4"].compactMap { artwork[$0].string.flatMap(hexColor) },
            latest: release,
            motion: portraits(id: id, attributes["editorialVideo"]))
    }

    /// The moving portrait, square and wide; nil without the square, which every page uses.
    static func portraits(id: String, _ video: JSON) -> Covers? {
        var masters: [Shape: URL] = [:]
        var previews: [Shape: String] = [:]
        for (shape, keys) in [(Shape.square, ["motionArtistSquare1x1"]),
                              (Shape.wide, ["motionArtistWide16x9", "motionArtistFullscreen16x9"])] {
            for key in keys {
                guard let url = video[key]["video"].string.flatMap(URL.init(string:)), isMediaURL(url) else { continue }
                masters[shape] = url
                previews[shape] = video[key]["previewFrame"]["url"].string
                break
            }
        }
        guard masters[.square] != nil else { return nil }
        return Covers(albumID: "artist\(id)", masters: masters, previews: previews)
    }

    /// Whether two titles name the same song or release, across the two services' spellings.
    public static func sameRelease(_ a: String, _ b: String) -> Bool {
        let key = releaseKey(a)
        return !key.isEmpty && key == releaseKey(b)
    }

    /// Song and album titles as both services can agree on them: no "(feat. X)", no " - Single".
    static func releaseKey(_ value: String) -> String {
        album(value.replacingOccurrences(of: #"\s*[\(\[](?:feat\.?|ft\.?|featuring|with)\s[^\)\]]*[\)\]]"#,
                                         with: "", options: [.regularExpression, .caseInsensitive]))
    }

    /// Apple's colours are six hex digits; anything else is left out.
    static func hexColor(_ value: String) -> String? {
        let hex = value.lowercased()
        return hex.count == 6 && hex.allSatisfy(\.isHexDigit) ? hex : nil
    }

    /// "2026-07-17", a calendar day wherever the listener is.
    static func releaseDate(_ value: String) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar(identifier: .gregorian).date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    /// Apple's biographies are HTML with a few tags: italics and bold become Markdown, line
    /// breaks stay, and any other tag goes.
    static func markdown(fromHTML html: String) -> String? {
        var text = html
        let swaps: [(String, String)] = [
            (#"<br\s*/?>"#, "\n"), (#"</?(?:i|em)>"#, "*"), (#"</?(?:b|strong)>"#, "**"), (#"<[^>]+>"#, ""),
        ]
        for (pattern, replacement) in swaps {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }
        for (entity, character) in [("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
