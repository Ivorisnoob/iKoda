import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

// MARK: - Chapters

/// A chapter of a video: where it starts and what it's called, as the creator (or YouTube's
/// automatic chapters) set it out.
public struct VideoChapter: Sendable, Hashable, Codable {
    public var title: String
    /// Seconds from the start.
    public var start: TimeInterval
    public var thumbnail: Artwork?

    public init(title: String, start: TimeInterval, thumbnail: Artwork? = nil) {
        self.title = title
        self.start = start
        self.thumbnail = thumbnail
    }

    /// The chapter playing at `seconds`, from chapters in order.
    public static func current(in chapters: [VideoChapter], at seconds: TimeInterval) -> VideoChapter? {
        chapters.last { $0.start <= seconds }
    }
}

extension VideoPages {
    /// The watch page's chapters: the player bar's `markersMap`, the creator's own
    /// (`DESCRIPTION_CHAPTERS`) before YouTube's automatic ones (`AUTO_CHAPTERS`). In order, and
    /// only when there are at least two (one chapter is the whole video).
    static func chapters(_ root: JSON) -> [VideoChapter] {
        let markers = root.first("multiMarkersPlayerBarRenderer")["markersMap"].array
        let preferred = ["DESCRIPTION_CHAPTERS", "AUTO_CHAPTERS"]
        let ranked = markers.sorted {
            (preferred.firstIndex(of: $0["key"].string ?? "") ?? 9) < (preferred.firstIndex(of: $1["key"].string ?? "") ?? 9)
        }
        for marker in ranked {
            let chapters = marker["value"]["chapters"].array.compactMap { item -> VideoChapter? in
                let chapter = item["chapterRenderer"]
                guard let millis = chapter["timeRangeStartMillis"].double else { return nil }
                let title = chapter["title"].text
                return VideoChapter(title: title.isEmpty ? "Chapter" : title, start: millis / 1000,
                                    thumbnail: chapter["thumbnail"].bestThumbnail)
            }
            .sorted { $0.start < $1.start }
            if chapters.count >= 2 { return chapters }
        }
        return []
    }
}

// MARK: - Storyboard

/// The sheets of small frames YouTube draws over its timeline as the pointer moves along it.
/// The player's `storyboards` spec: a URL template, then a level per size, each
/// `width#height#count#columns#rows#intervalMs#name#sigh`. Each sheet holds columns × rows frames.
public struct VideoStoryboard: Sendable, Hashable {
    public struct Level: Sendable, Hashable {
        public var index: Int
        public var width: Int
        public var height: Int
        public var count: Int
        public var columns: Int
        public var rows: Int
        /// Milliseconds between frames; 0 spreads them over the whole video.
        public var interval: Int
        public var name: String
        public var signature: String
    }

    public var template: String
    public var levels: [Level]

    public init?(spec: String) {
        let parts = spec.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts[0].hasPrefix("https://") else { return nil }
        template = parts[0]
        levels = parts.dropFirst().enumerated().compactMap { offset, level in
            let fields = level.split(separator: "#", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 8, let width = Int(fields[0]), let height = Int(fields[1]), let count = Int(fields[2]),
                  let columns = Int(fields[3]), let rows = Int(fields[4]), let interval = Int(fields[5]),
                  count > 0, columns > 0, rows > 0 else { return nil }
            return Level(index: offset, width: width, height: height, count: count, columns: columns, rows: rows,
                         interval: interval, name: fields[6], signature: fields[7])
        }
        guard !levels.isEmpty else { return nil }
    }

    /// One frame: the sheet it's on and where on the sheet, in the sheet's pixels.
    public struct Frame: Sendable, Hashable {
        public var sheet: URL
        public var rect: CGRect
        public var columns: Int
        public var rows: Int
    }

    /// The frame nearest `seconds` at the largest size, or nil when the video has none.
    public func frame(at seconds: TimeInterval, duration: TimeInterval) -> Frame? {
        guard let level = levels.max(by: { $0.width < $1.width }) else { return nil }
        let index: Int
        if level.interval > 0 {
            index = Int(max(0, seconds) * 1000 / Double(level.interval))
        } else {
            guard duration > 0 else { return nil }
            index = Int(max(0, seconds) / duration * Double(level.count))
        }
        let clamped = min(max(0, index), level.count - 1)
        let perSheet = level.columns * level.rows
        let page = clamped / perSheet
        let within = clamped % perSheet
        let name = level.name.replacingOccurrences(of: "$M", with: String(page))
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "$&+=")
        let signature = level.signature.addingPercentEncoding(withAllowedCharacters: allowed) ?? level.signature
        let address = template.replacingOccurrences(of: "$L", with: String(level.index))
            .replacingOccurrences(of: "$N", with: name) + "&sigh=" + signature
        guard let url = URL(string: address) else { return nil }
        let rect = CGRect(x: (within % level.columns) * level.width, y: (within / level.columns) * level.height,
                          width: level.width, height: level.height)
        return Frame(sheet: url, rect: rect, columns: level.columns, rows: level.rows)
    }
}

// MARK: - Search filters

/// YouTube's search filters, as its own Filters panel offers them. Sent as the search's
/// `params`: a small protobuf, sort in field 1, the filters in a message in field 2
/// (upload date 1, type 2, length 3). [verified November 2026 against live results; sorting by
/// upload date no longer reorders, so it isn't offered]
public struct VideoSearchFilters: Sendable, Hashable {
    public enum UploadDate: Int, Sendable, CaseIterable {
        case lastHour = 1, today, thisWeek, thisMonth, thisYear
    }

    public enum ResultType: Int, Sendable, CaseIterable {
        case videos = 1, channels
    }

    public enum Length: Int, Sendable, CaseIterable {
        case underFourMinutes = 1, overTwentyMinutes, fourToTwentyMinutes
    }

    public enum Sort: Int, Sendable, CaseIterable {
        case relevance = 0, viewCount = 3
    }

    public var uploadDate: UploadDate?
    public var type: ResultType?
    public var length: Length?
    public var sort: Sort = .relevance

    public init(uploadDate: UploadDate? = nil, type: ResultType? = nil, length: Length? = nil, sort: Sort = .relevance) {
        self.uploadDate = uploadDate
        self.type = type
        self.length = length
        self.sort = sort
    }

    public var isEmpty: Bool { self == VideoSearchFilters() }

    /// The `params` for these filters; nil for none. A length or date asks for videos only, as
    /// YouTube's own panel does (channels have neither).
    public var params: String? {
        var bytes: [UInt8] = []
        if sort != .relevance { bytes += [0x08, UInt8(sort.rawValue)] }
        var filters: [UInt8] = []
        if let uploadDate { filters += [0x08, UInt8(uploadDate.rawValue)] }
        let type = self.type ?? ((uploadDate != nil || length != nil) ? .videos : nil)
        if let type { filters += [0x10, UInt8(type.rawValue)] }
        if let length { filters += [0x18, UInt8(length.rawValue)] }
        if !filters.isEmpty { bytes += [0x12, UInt8(filters.count)] + filters }
        return bytes.isEmpty ? nil : Data(bytes).base64EncodedString()
    }
}

// MARK: - SponsorBlock

/// A part of a video the SponsorBlock community marked to skip.
public struct SponsorSegment: Sendable, Hashable {
    public enum Category: String, Sendable, CaseIterable {
        case sponsor, selfpromo, interaction, intro, outro

        public var title: String {
            switch self {
            case .sponsor: "Sponsor"
            case .selfpromo: "Self-Promotion"
            case .interaction: "Subscribe Reminder"
            case .intro: "Intro"
            case .outro: "Outro"
            }
        }
    }

    public var id: String
    public var category: Category
    public var start: TimeInterval
    public var end: TimeInterval
}

/// SponsorBlock (sponsor.ajay.app), asked privately: only the first four characters of the
/// SHA-256 of the video's id are sent, the answer holds every video sharing them, and the one
/// wanted is picked out here. Only skippable segments of the known categories are kept.
public enum SponsorBlock {
    public static func segments(for videoId: String, session: URLSession = .shared) async -> [SponsorSegment] {
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: Data(videoId.utf8)).map { String(format: "%02x", $0) }.joined()
        let prefix = String(digest.prefix(4))
        var components = URLComponents(string: "https://sponsor.ajay.app/api/skipSegments/\(prefix)")!
        let categories = SponsorSegment.Category.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ",")
        components.queryItems = [URLQueryItem(name: "categories", value: "[\(categories)]")]
        guard let url = components.url,
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSON(data: data) else { return [] }
        return parse(root, videoId: videoId)
        #else
        return []
        #endif
    }

    static func parse(_ root: JSON, videoId: String) -> [SponsorSegment] {
        guard let entry = root.array.first(where: { $0["videoID"].string == videoId }) else { return [] }
        return entry["segments"].array.compactMap { segment in
            guard segment["actionType"].string == "skip",
                  let category = segment["category"].string.flatMap(SponsorSegment.Category.init(rawValue:)) else { return nil }
            let range = segment["segment"].array
            guard range.count == 2, let start = range[0].double, let end = range[1].double, end > start + 0.5 else { return nil }
            return SponsorSegment(id: segment["UUID"].string ?? "\(start)", category: category, start: start, end: end)
        }
        .sorted { $0.start < $1.start }
    }
}

// MARK: - Dislikes

/// Return YouTube Dislike's estimate of a video's dislikes (YouTube hides the real count).
/// Sends the video's id to returnyoutubedislikeapi.com, so it's only asked when switched on.
public enum ReturnDislike {
    public static func dislikes(for videoId: String, session: URLSession = .shared) async -> Int? {
        var components = URLComponents(string: "https://returnyoutubedislikeapi.com/votes")!
        components.queryItems = [URLQueryItem(name: "videoId", value: videoId)]
        guard let url = components.url,
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSON(data: data) else { return nil }
        return parse(root)
    }

    static func parse(_ root: JSON) -> Int? {
        root["dislikes"].int
    }
}
