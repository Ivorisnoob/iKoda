import Foundation
import os

/// AutoMix's diary: what each song measured, which transition was planned and why, and how
/// the handover actually went. Always on, unlike `trace`, because tuning transitions means
/// reading what happened after hearing it. Lines go to the unified log (subsystem Koda,
/// category AutoMix), to standard output, and to `automix.log` beside the queue file.
public enum AutoMixLog {
    private static let logger = Logger(subsystem: "Koda", category: "AutoMix")
    private static let queue = DispatchQueue(label: "koda.automix.log", qos: .utility)
    nonisolated(unsafe) private static var file: URL?
    private static let started = Date()

    /// Where the log file is, once the player has a folder.
    public static var fileURL: URL? { queue.sync { file } }

    static func configure(directory: URL?) {
        guard let directory else { return }
        let url = directory.appending(path: "automix.log")
        queue.async {
            file = url
            // Kept short: past 2 MB the older half goes.
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 2_000_000,
               let data = try? Data(contentsOf: url) {
                try? data.suffix(1_000_000).write(to: url, options: .atomic)
            }
        }
    }

    static func note(_ message: @autoclosure () -> String) {
        let line = message()
        logger.notice("\(line, privacy: .public)")
        let stamp = Self.stamp()
        print("[AutoMix \(stamp)] \(line)")
        queue.async {
            guard let file else { return }
            let data = Data("\(Date().formatted(.iso8601)) \(line)\n".utf8)
            if let handle = try? FileHandle(forWritingTo: file) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: file)
            }
        }
    }

    private static func stamp() -> String {
        String(format: "%.3f", Date().timeIntervalSince(started))
    }
}

extension Double {
    /// Seconds or decibels as short log text.
    var s2: String { String(format: "%.2f", self) }
    var s1: String { String(format: "%.1f", self) }
}
