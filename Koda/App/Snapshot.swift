import Foundation

/// Pages as they were last shown, kept on disk so a cold launch draws them at once and then
/// refreshes them in place, instead of opening on empty placeholders while the network answers.
///
/// Small JSON files in Caches: the system may clear them, and then the page simply loads as
/// it would have without one.
nonisolated enum Snapshot {
    private static let directory = URL.cachesDirectory.appending(path: "Snapshots")

    /// The snapshot saved under `name`, decoded; nil when there is none or it no longer decodes.
    static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appending(path: name + ".json")) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func remove(_ name: String) {
        try? FileManager.default.removeItem(at: directory.appending(path: name + ".json"))
    }

    /// Writes `value` under `name`, off the main thread.
    static func save<T: Encodable & Sendable>(_ value: T, _ name: String) {
        let url = directory.appending(path: name + ".json")
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(value) else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}
