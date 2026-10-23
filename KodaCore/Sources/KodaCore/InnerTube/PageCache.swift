import Foundation

/// Pages already fetched, kept for a few minutes so going back to one, or switching away and
/// back, shows it at once instead of loading it again. In memory only; the newest are kept.
actor PageCache {
    private struct Entry {
        let value: any Sendable
        let date: Date
    }

    private var entries: [String: Entry] = [:]
    private let lifetime: TimeInterval
    private let limit: Int

    init(lifetime: TimeInterval = 600, limit: Int = 80) {
        self.lifetime = lifetime
        self.limit = limit
    }

    /// The cached page for `key` if it is fresh, otherwise `load`'s, which is then kept.
    /// Failures are never cached.
    func value<T: Sendable>(_ key: String, load: @Sendable () async throws -> T) async throws -> T {
        if let entry = entries[key], Date().timeIntervalSince(entry.date) < lifetime, let value = entry.value as? T {
            return value
        }
        let value = try await load()
        entries[key] = Entry(value: value, date: Date())
        if entries.count > limit, let oldest = entries.min(by: { $0.value.date < $1.value.date })?.key {
            entries[oldest] = nil
        }
        return value
    }

    func removeAll() {
        entries = [:]
    }
}
