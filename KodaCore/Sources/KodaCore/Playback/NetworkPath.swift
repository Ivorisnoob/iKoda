import Foundation
import Network
import os

/// Whether the network the device is on right now costs the listener: mobile data or a
/// personal hotspot (expensive), or Low Data Mode (constrained). Read when a song's stream
/// is chosen, so the choice follows the listener from Wi‑Fi onto the street.
nonisolated final class NetworkPath: Sendable {
    static let shared = NetworkPath()

    private struct State {
        var isExpensive = false
        var isConstrained = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [state] path in
            state.withLock {
                $0.isExpensive = path.isExpensive
                $0.isConstrained = path.isConstrained
            }
        }
        monitor.start(queue: DispatchQueue(label: "Koda.NetworkPath", qos: .utility))
    }

    var isExpensive: Bool { state.withLock { $0.isExpensive } }
    var isConstrained: Bool { state.withLock { $0.isConstrained } }
}
