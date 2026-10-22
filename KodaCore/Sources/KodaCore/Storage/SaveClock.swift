import Foundation

/// Numbers each save, so a background write that has been overtaken by a newer
/// save is dropped instead of overwriting it.
final class SaveClock: @unchecked Sendable {
    private let lock = NSLock()
    private var newest = 0

    func next() -> Int {
        lock.withLock {
            newest += 1
            return newest
        }
    }

    func isNewest(_ version: Int) -> Bool {
        lock.withLock { version == newest }
    }
}
