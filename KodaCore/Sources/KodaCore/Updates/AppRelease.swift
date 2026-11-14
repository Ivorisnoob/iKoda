import Foundation

/// A version as Koda's releases are numbered ("0.4", "v1.2.3"): numbers compared one by one,
/// a missing one counting as zero, so "1.0" equals "1" and "0.10" is newer than "0.9".
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespaces)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        // "1.2-beta" counts as 1.2: the releases Koda reads are never pre-releases.
        let core = text.prefix { $0.isNumber || $0 == "." }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }

    public func hash(into hasher: inout Hasher) {
        var trimmed = parts
        while trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
    }
}

/// A published release of Koda on GitHub, as the updater needs it.
public struct AppRelease: Equatable, Sendable {
    public let version: AppVersion
    public let title: String
    /// The release notes, Markdown as written on GitHub.
    public let notes: String
    public let page: URL
    public let published: Date?
    /// The Mac's disk image and the iPhone's app, when attached.
    public let dmg: Asset?
    public let ipa: Asset?

    public struct Asset: Equatable, Sendable {
        public let url: URL
        public let size: Int
    }

    public init(version: AppVersion, title: String, notes: String, page: URL, published: Date?, dmg: Asset?, ipa: Asset?) {
        self.version = version
        self.title = title
        self.notes = notes
        self.page = page
        self.published = published
        self.dmg = dmg
        self.ipa = ipa
    }

    /// GitHub's `releases/latest` answer; nil for a draft, a pre-release or a tag that isn't a version.
    public init?(gitHub data: Data) {
        struct Raw: Decodable {
            struct RawAsset: Decodable {
                let name: String
                let size: Int
                let browser_download_url: URL
            }
            let tag_name: String
            let name: String?
            let body: String?
            let html_url: URL
            let draft: Bool?
            let prerelease: Bool?
            let published_at: String?
            let assets: [RawAsset]?
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data), raw.draft != true, raw.prerelease != true,
              let version = AppVersion(raw.tag_name) else { return nil }
        let assets = raw.assets ?? []
        func asset(_ suffix: String) -> Asset? {
            assets.first { $0.name.lowercased().hasSuffix(suffix) }.map { Asset(url: $0.browser_download_url, size: $0.size) }
        }
        self.init(
            version: version,
            title: raw.name?.isEmpty == false ? raw.name! : "Koda \(version)",
            notes: (raw.body ?? "").replacingOccurrences(of: "\r\n", with: "\n"),
            page: raw.html_url,
            published: raw.published_at.flatMap { ISO8601DateFormatter().date(from: $0) },
            dmg: asset(".dmg"),
            ipa: asset(".ipa"))
    }
}

/// When to look for a new release and whether to bring one up: once a day on its own, never a
/// version the listener skipped, and not again before a "remind me later" runs out. A check the
/// listener asks for always looks and always answers.
public struct UpdatePolicy: Equatable, Sendable {
    public var lastCheck: Date?
    public var skipped: AppVersion?
    public var remindAfter: Date?

    public static let checkInterval: TimeInterval = 24 * 60 * 60

    public init(lastCheck: Date? = nil, skipped: AppVersion? = nil, remindAfter: Date? = nil) {
        self.lastCheck = lastCheck
        self.skipped = skipped
        self.remindAfter = remindAfter
    }

    /// Whether an automatic check is due.
    public func isDue(at now: Date) -> Bool {
        guard let lastCheck else { return true }
        // A clock set back counts as due rather than waiting out the difference.
        return now.timeIntervalSince(lastCheck) >= Self.checkInterval || now < lastCheck
    }

    /// Whether `release` is worth bringing up to someone running `current`.
    public func shouldOffer(_ release: AppRelease, over current: AppVersion, at now: Date, asked: Bool) -> Bool {
        guard release.version > current else { return false }
        if asked { return true }
        if let skipped, release.version <= skipped { return false }
        if let remindAfter, now < remindAfter { return false }
        return true
    }
}
