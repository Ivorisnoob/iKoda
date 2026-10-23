#if canImport(Darwin)
import Darwin
import Foundation
import os

private let log = Logger(subsystem: "Koda", category: "Discord")

/// A connection to the Discord app on this Mac over its local socket, the one every
/// desktop Rich Presence uses. No sign-in and no token: the card is published as Koda's
/// Discord application.
///
/// Socket calls block, so they run one at a time on a queue of the connection's own, each
/// bounded by a timeout, and `fd` is only touched there. Each frame sent waits for Discord's
/// reply to it, which keeps the socket drained and tells a refused card from a dead connection.
final class DiscordIPCConnection: DiscordConnection, @unchecked Sendable {
    private let queue: DispatchQueue
    private var fd: Int32
    private let pid = ProcessInfo.processInfo.processIdentifier
    /// How long one read or write may wait on Discord.
    static let timeout = timeval(tv_sec: 3, tv_usec: 0)

    private init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
    }

    deinit {
        if fd >= 0 { Darwin.close(fd) }
    }

    /// Connects and handshakes with the first Discord that answers, or returns nil when none
    /// is running or it refuses Koda's application.
    static func connect(clientID: String, paths: [String] = socketPaths()) async -> DiscordIPCConnection? {
        let queue = DispatchQueue(label: "Koda.DiscordIPC")
        return await withCheckedContinuation { continuation in
            queue.async {
                for path in paths {
                    guard let fd = openSocket(path) else { continue }
                    let connection = DiscordIPCConnection(fd: fd, queue: queue)
                    if connection.handshake(clientID: clientID) {
                        continuation.resume(returning: connection)
                        return
                    }
                    connection.closeNow()
                }
                continuation.resume(returning: nil)
            }
        }
    }

    /// Where Discord may have put its socket, in the order its own clients look: the first
    /// of these folders that is set, `discord-ipc-0` to `-9` in each.
    static func socketPaths(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var directories = ["XDG_RUNTIME_DIR", "TMPDIR", "TMP", "TEMP"].compactMap { environment[$0] }.filter { !$0.isEmpty }
        // The user's own temporary folder, where Discord on the Mac listens, whatever this
        // process's environment says.
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 {
            directories.append(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        directories.append("/tmp")
        var seen = Set<String>()
        var paths: [String] = []
        for directory in directories {
            let base = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
            guard !base.isEmpty, seen.insert(base).inserted else { continue }
            paths += (0..<10).map { "\(base)/discord-ipc-\($0)" }
        }
        return paths
    }

    // MARK: DiscordConnection

    func setActivity(_ activity: DiscordActivity?) async -> DiscordSendResult {
        await perform { $0.send(activity) }
    }

    func isAlive() async -> Bool {
        await perform { $0.checkAlive() }
    }

    func close() async {
        await perform { $0.closeNow() }
    }

    private func perform<T: Sendable>(_ body: @escaping @Sendable (DiscordIPCConnection) -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body(self)) }
        }
    }

    // MARK: On the queue

    private static func openSocket(_ path: String) -> Int32? {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        // A write to a socket Discord closed would otherwise raise SIGPIPE and end Koda.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = Self.timeout
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            Darwin.close(fd)
            return nil
        }
        return fd
    }

    private func handshake(clientID: String) -> Bool {
        guard writeFrame(.handshake, DiscordIPC.handshake(clientID: clientID)) else { return false }
        for _ in 0..<4 {
            guard let (opcode, payload) = readFrame() else { return false }
            switch opcode {
            case .frame:
                if DiscordIPC.reply(payload) == .ready { return true }
            case .ping:
                guard writeFrame(.pong, payload) else { return false }
            case .close:
                // An application id Discord doesn't know, or a Discord refusing RPC.
                log.error("Discord closed the handshake: \(String(decoding: payload, as: UTF8.self), privacy: .public)")
                return false
            default:
                continue
            }
        }
        return false
    }

    private func send(_ activity: DiscordActivity?) -> DiscordSendResult {
        guard fd >= 0 else { return .failed }
        let nonce = UUID().uuidString
        guard writeFrame(.frame, DiscordIPC.setActivity(activity, pid: pid, nonce: nonce)) else { return fail() }
        // Discord answers each command; anything else first (a ping, an event) is handled and skipped.
        for _ in 0..<16 {
            guard let (opcode, payload) = readFrame() else { return fail() }
            switch opcode {
            case .frame:
                switch DiscordIPC.reply(payload) {
                case .success(let replyNonce) where replyNonce == nonce:
                    return .accepted
                case .error(let replyNonce, let message) where replyNonce == nonce || replyNonce == nil:
                    log.error("Discord refused the activity: \(message, privacy: .public)")
                    return .rejected(message)
                default:
                    continue
                }
            case .ping:
                guard writeFrame(.pong, payload) else { return fail() }
            case .close:
                return fail()
            default:
                continue
            }
        }
        return fail()
    }

    /// Whether Discord is still there, answering any ping that waits, without blocking.
    private func checkAlive() -> Bool {
        while fd >= 0 {
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, 0)
            if ready < 0, errno == EINTR { continue }
            if ready < 0 || poller.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { break }
            if ready == 0 { return true }
            // Something to read. A closed socket reads as zero bytes.
            var byte: UInt8 = 0
            let peeked = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
            if peeked < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return true }
            guard peeked > 0, let (opcode, payload) = readFrame() else { break }
            if opcode == .close { break }
            if opcode == .ping, !writeFrame(.pong, payload) { break }
        }
        closeNow()
        return false
    }

    private func fail() -> DiscordSendResult {
        closeNow()
        return .failed
    }

    private func closeNow() {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
    }

    private func readFrame() -> (opcode: DiscordIPC.Opcode?, payload: Data)? {
        guard let head = readBytes(8), let header = DiscordIPC.header(head), header.length <= DiscordIPC.maxPayload,
              let payload = readBytes(header.length) else { return nil }
        return (DiscordIPC.Opcode(rawValue: header.opcode), payload)
    }

    private func readBytes(_ count: Int) -> Data? {
        var data = Data(count: count)
        var done = 0
        while done < count {
            let read = data.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + done, count - done, 0) }
            if read > 0 {
                done += read
            } else if read < 0, errno == EINTR {
                continue
            } else {
                // Closed, or the timeout ran out.
                return nil
            }
        }
        return data
    }

    private func writeFrame(_ opcode: DiscordIPC.Opcode, _ payload: Data) -> Bool {
        guard fd >= 0 else { return false }
        let frame = DiscordIPC.frame(opcode, payload)
        var done = 0
        while done < frame.count {
            let written = frame.withUnsafeBytes { Darwin.send(fd, $0.baseAddress! + done, frame.count - done, 0) }
            if written > 0 {
                done += written
            } else if written < 0, errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }
}
#endif
