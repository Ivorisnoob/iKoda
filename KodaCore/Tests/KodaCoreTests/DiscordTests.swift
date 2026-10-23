import Foundation
import Observation
import Testing
@testable import KodaCore

private func song(id: String = "dQw4w9WgXcQ", title: String = "Never Gonna Give You Up", artist: String = "Rick Astley",
                  channel: String? = "UCuAXFkgsw1L7xaCfnd5JJOw", duration: TimeInterval = 213, position: TimeInterval = 13,
                  isPlaying: Bool = true) -> DiscordNowPlaying {
    DiscordNowPlaying(songID: id, title: title, artist: artist, artistChannelID: channel, album: "Whenever You Need Somebody",
                      artwork: URL(string: "https://lh3.googleusercontent.com/abc=w1024-h1024"),
                      duration: duration, position: position, isPlaying: isPlaying)
}

private func json(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

struct DiscordActivityTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func playingCardShowsTheSongTheArtistAndABar() throws {
        let card = try #require(DiscordActivity(song(), now: now))
        #expect(card.type == 2)
        #expect(card.statusDisplayType == 2)
        #expect(card.details == "Never Gonna Give You Up")
        #expect(card.detailsURL == "https://music.youtube.com/watch?v=dQw4w9WgXcQ")
        #expect(card.state == "Rick Astley")
        #expect(card.stateURL == "https://music.youtube.com/channel/UCuAXFkgsw1L7xaCfnd5JJOw")
        // 13 s into a 213 s song: the bar began 13 s ago and ends in 200.
        let bar = DiscordActivity.Timestamps(start: 1_799_999_987, end: 1_800_000_200)
        #expect(card.timestamps == bar)
        #expect(card.assets?.largeImage == "https://lh3.googleusercontent.com/abc=w1024-h1024")
        #expect(card.assets?.largeText == "Whenever You Need Somebody")
        #expect(card.buttons?.map(\.label) == ["Listen on YouTube Music", "Get Koda"])
    }

    @Test func pausedCardHasNoBar() throws {
        let card = try #require(DiscordActivity(song(isPlaying: false), now: now))
        #expect(card.timestamps == nil)
        #expect(card.content == DiscordActivity(song(), now: now)?.content)
    }

    @Test func unknownLengthHasNoBarAndAPositionPastTheEndNeverRunsBackwards() throws {
        #expect(DiscordActivity(song(duration: 0), now: now)?.timestamps == nil)
        let card = try #require(DiscordActivity(song(position: 500), now: now))
        #expect(card.timestamps?.end == 1_800_000_000)
    }

    @Test func artistWithoutAChannelLinksToASearch() throws {
        let card = try #require(DiscordActivity(song(artist: "She & Him", channel: nil), now: now))
        #expect(card.stateURL == "https://music.youtube.com/search?q=She%20%26%20Him")
    }

    @Test func notAYouTubeIDHasNoLinks() throws {
        let card = try #require(DiscordActivity(song(id: "local-file"), now: now))
        #expect(card.detailsURL == nil)
        #expect(card.assets?.largeURL == nil)
        #expect(card.buttons?.map(\.label) == ["Get Koda"])
    }

    @Test func noTitleNoCard() {
        #expect(DiscordActivity(song(title: "  "), now: now) == nil)
    }

    @Test func textIsPaddedOrCutToDiscordsLimits() throws {
        #expect(DiscordActivity.text("7") == "7\u{2800}")
        #expect(DiscordActivity.text("   ") == nil)
        let long = try #require(DiscordActivity.text(String(repeating: "a", count: 300)))
        #expect(long.utf16.count == 128)
        #expect(long.hasSuffix("…"))
        // Cut by whole characters: an emoji is never split in half.
        let emoji = try #require(DiscordActivity.text(String(repeating: "🎵", count: 100)))
        #expect(emoji.utf16.count <= 128)
        #expect(emoji.unicodeScalars.allSatisfy { $0.properties.isEmoji || $0 == "…" })
    }

    @Test func linksMustBeWebAndShort() {
        #expect(DiscordActivity.link("https://example.com") == "https://example.com")
        #expect(DiscordActivity.link("file:///Users/me/song.m4a") == nil)
        #expect(DiscordActivity.link("https://example.com/" + String(repeating: "a", count: 300)) == nil)
    }

    @Test func basicCardDropsTheNewerFields() throws {
        let card = try #require(DiscordActivity(song(), now: now)).basic
        #expect(card.statusDisplayType == nil)
        #expect(card.detailsURL == nil)
        #expect(card.stateURL == nil)
        #expect(card.assets?.largeURL == nil)
        #expect(card.assets?.largeImage != nil)
        #expect(card.details == "Never Gonna Give You Up")
    }

    @Test func setActivityFrameUsesDiscordsKeys() throws {
        let card = try #require(DiscordActivity(song(), now: now))
        let command = json(DiscordIPC.setActivity(card, pid: 42, nonce: "n1"))
        #expect(command["cmd"] as? String == "SET_ACTIVITY")
        #expect(command["nonce"] as? String == "n1")
        let args = try #require(command["args"] as? [String: Any])
        #expect(args["pid"] as? Int == 42)
        let activity = try #require(args["activity"] as? [String: Any])
        #expect(activity["status_display_type"] as? Int == 2)
        #expect(activity["details_url"] as? String == "https://music.youtube.com/watch?v=dQw4w9WgXcQ")
        #expect((activity["assets"] as? [String: Any])?["large_image"] as? String == "https://lh3.googleusercontent.com/abc=w1024-h1024")
        #expect((activity["timestamps"] as? [String: Any])?["end"] as? Int == 1_800_000_200)
    }

    @Test func clearingSendsANullActivity() throws {
        let command = json(DiscordIPC.setActivity(nil, pid: 42, nonce: "n2"))
        let args = try #require(command["args"] as? [String: Any])
        #expect(args["activity"] is NSNull)
    }

    @Test func framesAreLittleEndianOpcodeAndLength() throws {
        let frame = DiscordIPC.frame(.frame, Data("{}".utf8))
        #expect(Array(frame) == [1, 0, 0, 0, 2, 0, 0, 0, 0x7B, 0x7D])
        let header = try #require(DiscordIPC.header(frame))
        #expect(header.opcode == 1)
        #expect(header.length == 2)
        #expect(DiscordIPC.header(Data([1, 0, 0])) == nil)
        #expect(json(DiscordIPC.handshake(clientID: "123"))["client_id"] as? String == "123")
    }

    @Test func readsDiscordsReplies() {
        #expect(DiscordIPC.reply(Data(#"{"cmd":"DISPATCH","evt":"READY","data":{}}"#.utf8)) == .ready)
        #expect(DiscordIPC.reply(Data(#"{"cmd":"SET_ACTIVITY","evt":null,"nonce":"a","data":{}}"#.utf8)) == .success(nonce: "a"))
        #expect(DiscordIPC.reply(Data(#"{"cmd":"SET_ACTIVITY","evt":"ERROR","nonce":"b","data":{"code":4000,"message":"bad"}}"#.utf8))
                == .error(nonce: "b", message: "bad (4000)"))
        #expect(DiscordIPC.reply(Data("not json".utf8)) == .other)
    }
}

#if canImport(Darwin)
import Darwin

/// A stand-in for the Discord app: a Unix socket that accepts one client and follows a script.
private final class FakeDiscord: @unchecked Sendable {
    let path: String
    private let listener: Int32
    private let lock = NSLock()
    private var _received: [[String: Any]] = []
    var received: [[String: Any]] { lock.withLock { _received } }

    init() throws {
        // Short: a socket path has to fit in 104 bytes.
        let directory = NSTemporaryDirectory() + "kd-" + String(UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        path = directory + "/discord-ipc-0"
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(bound == 0)
        try #require(listen(listener, 1) == 0)
    }

    deinit {
        Darwin.close(listener)
        unlink(path)
    }

    /// Accepts one client and runs `script` with it, on a thread of its own.
    func serve(_ script: @escaping @Sendable (FakeDiscord, Int32) -> Void) {
        Thread { [self] in
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            script(self, client)
        }.start()
    }

    func read(_ fd: Int32) -> (opcode: UInt32, json: [String: Any])? {
        func bytes(_ count: Int) -> Data? {
            var data = Data(count: count)
            var done = 0
            while done < count {
                let n = data.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + done, count - done, 0) }
                guard n > 0 else { return nil }
                done += n
            }
            return data
        }
        guard let head = bytes(8), let header = DiscordIPC.header(head) else { return nil }
        let payload = header.length > 0 ? bytes(header.length) ?? Data() : Data()
        let object = json(payload)
        lock.withLock { _received.append(object) }
        return (header.opcode, object)
    }

    func write(_ fd: Int32, _ opcode: DiscordIPC.Opcode, _ text: String) {
        let frame = DiscordIPC.frame(opcode, Data(text.utf8))
        _ = frame.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!, frame.count, 0) }
    }
}

@Suite(.serialized)
struct DiscordIPCTests {
    @Test func handshakesSendsTheCardAndHearsBothAnswers() async throws {
        let discord = try FakeDiscord()
        discord.serve { discord, fd in
            guard discord.read(fd)?.opcode == 0 else { return }
            discord.write(fd, .frame, #"{"cmd":"DISPATCH","evt":"READY","data":{"v":1}}"#)
            // A ping before the answer is answered and skipped.
            guard let first = discord.read(fd) else { return }
            discord.write(fd, .ping, "{}")
            discord.write(fd, .frame, #"{"cmd":"SET_ACTIVITY","evt":null,"data":{},"nonce":"\#(first.json["nonce"] as? String ?? "")"}"#)
            guard discord.read(fd)?.opcode == 4, let second = discord.read(fd) else { return }
            discord.write(fd, .frame, #"{"cmd":"SET_ACTIVITY","evt":"ERROR","data":{"code":4000,"message":"no"},"nonce":"\#(second.json["nonce"] as? String ?? "")"}"#)
            // Discord quits.
            Darwin.close(fd)
        }
        let connection = try #require(await DiscordIPCConnection.connect(clientID: "1556607739231346708", paths: [discord.path]))
        let card = try #require(DiscordActivity(song(), now: Date()))
        #expect(await connection.setActivity(card) == .accepted)
        #expect(await connection.setActivity(card) == .rejected("no (4000)"))
        let handshake = discord.received.first
        #expect(handshake?["client_id"] as? String == "1556607739231346708")
        #expect(handshake?["v"] as? Int == 1)
        let sent = (discord.received[1]["args"] as? [String: Any])?["activity"] as? [String: Any]
        #expect(sent?["details"] as? String == "Never Gonna Give You Up")

        // Discord quit: the connection notices without sending anything.
        try await Task.sleep(for: .milliseconds(100))
        #expect(await connection.isAlive() == false)
        #expect(await connection.setActivity(card) == .failed)
    }

    @Test func refusedHandshakeIsNoConnection() async throws {
        let discord = try FakeDiscord()
        discord.serve { discord, fd in
            _ = discord.read(fd)
            discord.write(fd, .close, #"{"code":4000,"message":"Invalid Client ID"}"#)
            Darwin.close(fd)
        }
        #expect(await DiscordIPCConnection.connect(clientID: "1", paths: [discord.path]) == nil)
    }

    @Test func noDiscordIsNoConnection() async {
        #expect(await DiscordIPCConnection.connect(clientID: "1", paths: ["/tmp/koda-no-such-socket"]) == nil)
    }

    @Test func looksWhereDiscordDoesOnceEach() {
        let paths = DiscordIPCConnection.socketPaths(environment: ["TMPDIR": "/var/folders/x/T/", "TMP": "/var/folders/x/T"])
        #expect(paths.first == "/var/folders/x/T/discord-ipc-0")
        #expect(paths.filter { $0 == "/var/folders/x/T/discord-ipc-0" }.count == 1)
        #expect(paths.contains("/tmp/discord-ipc-9"))
    }
}
#endif

/// A stand-in for Discord that records every card and answers as told.
@MainActor
final class DiscordFakeConnection: DiscordConnection {
    var sent: [DiscordActivity?] = []
    var answers: [DiscordSendResult] = []
    var alive = true
    var closed = false

    func setActivity(_ activity: DiscordActivity?) async -> DiscordSendResult {
        sent.append(activity)
        return answers.isEmpty ? .accepted : answers.removeFirst()
    }

    func isAlive() async -> Bool { alive }
    func close() async { closed = true }
}

@MainActor
@Observable
final class DiscordFakeSource {
    var allowed = true
    var song: DiscordNowPlaying?
}

@MainActor
@Suite(.serialized)
struct DiscordPresenceTests {
    let source = DiscordFakeSource()
    let connection = DiscordFakeConnection()

    func makePresence(discordOpen: Bool = true, timing: DiscordPresence.Timing = .init()) -> (DiscordPresence, Counter) {
        let counter = Counter()
        let connection = connection
        let presence = DiscordPresence(isAllowed: { [source] in source.allowed },
                                       nowPlaying: { [source] _ in source.song },
                                       connector: { await counter.connect(discordOpen ? connection : nil) },
                                       timing: timing)
        return (presence, counter)
    }

    @MainActor
    final class Counter {
        var attempts = 0
        func connect(_ connection: DiscordFakeConnection?) -> (any DiscordConnection)? {
            attempts += 1
            return connection
        }
    }

    func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func showsThePlayingSongOnceAndIgnoresSmallDrift() async throws {
        source.song = song()
        let (presence, _) = makePresence()
        #expect(await eventually { presence.status == .showing })
        #expect(connection.sent.count == 1)
        #expect(connection.sent.first??.details == "Never Gonna Give You Up")
        // A second's difference in where the bar ends isn't worth a frame.
        source.song?.position += 1
        try await Task.sleep(for: .milliseconds(150))
        #expect(connection.sent.count == 1)
    }

    @Test func aNewSongIsANewCard() async {
        source.song = song()
        let (presence, _) = makePresence()
        #expect(await eventually { presence.status == .showing })
        source.song = song(id: "abcdefghijk", title: "Another")
        #expect(await eventually { connection.sent.count == 2 })
        #expect(connection.sent.last??.details == "Another")
    }

    @Test func aPauseDropsTheBarThenTakesTheCardDown() async {
        source.song = song()
        var timing = DiscordPresence.Timing()
        timing.pauseLinger = 0.3
        let (presence, _) = makePresence(timing: timing)
        #expect(await eventually { presence.status == .showing })
        source.song?.isPlaying = false
        #expect(await eventually { connection.sent.count == 2 })
        #expect(connection.sent[1]?.timestamps == nil)
        #expect(await eventually { connection.closed })
        #expect(connection.sent.last! == nil)
        #expect(presence.status == .waiting)
    }

    @Test func aSessionRestoredPausedStaysOffTheProfile() async throws {
        source.song = song(isPlaying: false)
        let (presence, counter) = makePresence()
        #expect(await eventually { presence.status == .waiting })
        try await Task.sleep(for: .milliseconds(100))
        #expect(counter.attempts == 0)
        #expect(connection.sent.isEmpty)
    }

    @Test func turningItOffTakesTheCardDown() async {
        source.song = song()
        let (presence, _) = makePresence()
        #expect(await eventually { presence.status == .showing })
        source.allowed = false
        #expect(await eventually { presence.status == .off })
        #expect(connection.sent.last! == nil)
        #expect(connection.closed)
    }

    @Test func noDiscordIsUnavailableAndLookedForAgain() async {
        source.song = song()
        var timing = DiscordPresence.Timing()
        timing.retryInterval = 0.1
        let (presence, counter) = makePresence(discordOpen: false, timing: timing)
        #expect(await eventually { presence.status == .unavailable })
        #expect(await eventually { counter.attempts >= 3 })
    }

    @Test func aRefusedCardIsSentAgainWithoutTheNewerFields() async {
        connection.answers = [.rejected("unknown field")]
        source.song = song()
        let (presence, _) = makePresence()
        #expect(await eventually { presence.status == .showing })
        #expect(connection.sent.count == 2)
        #expect(connection.sent[0]?.statusDisplayType == 2)
        #expect(connection.sent[1]?.statusDisplayType == nil)
    }

    @Test func aDiscordThatQuitIsFoundAgain() async {
        source.song = song()
        var timing = DiscordPresence.Timing()
        timing.retryInterval = 0.1
        let (presence, counter) = makePresence(timing: timing)
        #expect(await eventually { presence.status == .showing })
        connection.alive = false
        #expect(await eventually { counter.attempts >= 2 && connection.sent.count >= 2 })
    }

    @Test func aSeekMovesTheBar() async throws {
        source.song = song()
        var timing = DiscordPresence.Timing()
        timing.pushInterval = 0
        let (presence, _) = makePresence(timing: timing)
        #expect(await eventually { presence.status == .showing })
        source.song?.position = 150
        #expect(await eventually { connection.sent.count == 2 })
        let end = try #require(connection.sent[1]?.timestamps?.end)
        #expect(abs(Double(end) - (Date().timeIntervalSince1970 + 63)) < 2)
    }
}
