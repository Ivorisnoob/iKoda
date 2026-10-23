import Foundation
import Observation

/// What happened to one frame sent to Discord.
enum DiscordSendResult: Equatable, Sendable {
    case accepted
    /// Discord answered and refused the card, with its reason.
    case rejected(String)
    /// The connection is gone.
    case failed
}

/// A live connection to Discord; a protocol so tests can stand in for the Discord app.
protocol DiscordConnection: AnyObject, Sendable {
    /// Shows `activity` on the profile; nil takes the card down.
    func setActivity(_ activity: DiscordActivity?) async -> DiscordSendResult
    func isAlive() async -> Bool
    func close() async
}

/// Shows what Koda is playing on the listener's Discord profile, through the Discord app on
/// this Mac. The Mac counterpart of Koda for Android's presence, with the same application.
///
/// When a card is on the profile:
/// - Only while the listener has it on and listening history is on (`isAllowed`).
/// - A playing song shows straight away. A frame goes only when something the card shows
///   changes, or when its progress bar has drifted (a seek, a long buffer); Discord runs the
///   bar on its own clock, so steady playback sends nothing.
/// - A pause swaps in the same card without a bar, taken down after `pauseLinger`. A pause
///   never puts a card up on its own: a session restored paused at launch stays off the
///   profile until it plays.
///
/// With no card to show, the connection is let go too. While one should show and Discord
/// isn't there, Koda looks for it again every `retryInterval`, and checks a live connection
/// as often, so quitting and reopening Discord brings the card back. Playback never waits on
/// any of this: everything here runs beside it and every failure is swallowed.
@MainActor
@Observable
public final class DiscordPresence {
    public enum Status: Equatable, Sendable {
        /// Turned off, or listening history is off.
        case off
        /// On, with nothing playing.
        case waiting
        /// A song should show and Discord isn't open (or isn't answering).
        case unavailable
        case showing
        /// Discord is open and refused the song's card.
        case refused
    }

    /// Koda's application in the Discord Developer Portal, the same one Koda for Android uses.
    /// Public by design; it is not a secret.
    public nonisolated static let applicationID = "1556607739231346708"

    struct Timing {
        /// The least time between two frames for the same card.
        var pushInterval: TimeInterval = 5
        /// How far the bar's end may move before it is worth a frame.
        var seekDrift: TimeInterval = 3
        /// How long a paused card stays before it is taken down.
        var pauseLinger: TimeInterval = 60
        /// How often a missing Discord is looked for, and a live one checked.
        var retryInterval: TimeInterval = 15
        /// Discord takes this many activity updates per `rateWindow`; more are dropped.
        var rateLimit = 5
        var rateWindow: TimeInterval = 20
    }

    public private(set) var status: Status = .off

    @ObservationIgnored private let isAllowedSource: @MainActor () -> Bool
    @ObservationIgnored private let nowPlayingSource: @MainActor (Date) -> DiscordNowPlaying?
    @ObservationIgnored private let connector: @Sendable () async -> (any DiscordConnection)?
    @ObservationIgnored private let timing: Timing

    @ObservationIgnored private var connection: (any DiscordConnection)?
    /// The card on the profile, without its bar; nil when none is showing.
    @ObservationIgnored private var shown: DiscordActivity?
    /// When the shown card's bar runs out; nil when it has none.
    @ObservationIgnored private var shownEnd: TimeInterval?
    /// Discord refused the newer fields on this connection: send the basic card.
    @ObservationIgnored private var sendsBasic = false
    @ObservationIgnored private var pushes: [Date] = []
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private var nextCheck = Date.distantPast
    @ObservationIgnored private var pausedSince: Date?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var needsSync = false
    @ObservationIgnored private var wake: Task<Void, Never>?

    /// `isAllowed` and `nowPlaying` are watched: whatever observable state they read
    /// brings the profile up to date when it changes.
    public convenience init(isAllowed: @escaping @MainActor () -> Bool, player: Player) {
        self.init(isAllowed: isAllowed, nowPlaying: { [player] date in
            guard let song = player.current else { return nil }
            return DiscordNowPlaying(song: song, duration: player.duration, position: player.position(at: date),
                                     isPlaying: player.wantsToPlay)
        }, connector: Self.discordApp)
    }

    init(isAllowed: @escaping @MainActor () -> Bool, nowPlaying: @escaping @MainActor (Date) -> DiscordNowPlaying?,
         connector: @escaping @Sendable () async -> (any DiscordConnection)?, timing: Timing = Timing()) {
        isAllowedSource = isAllowed
        nowPlayingSource = nowPlaying
        self.connector = connector
        self.timing = timing
        observe()
    }

    private nonisolated static let discordApp: @Sendable () async -> (any DiscordConnection)? = {
        #if canImport(Darwin)
        await DiscordIPCConnection.connect(clientID: DiscordPresence.applicationID)
        #else
        nil
        #endif
    }

    // MARK: Watching

    private func observe() {
        withObservationTracking({
            _ = isAllowedSource()
            _ = nowPlayingSource(Date())
        }, onChange: Self.changeHandler(self))
        schedule()
    }

    /// Observation calls back on whichever thread made the change, so the handler is built
    /// outside the main actor and hops back to it.
    private nonisolated static func changeHandler(_ presence: DiscordPresence) -> @Sendable () -> Void {
        { Task { @MainActor in presence.observe() } }
    }

    /// Runs `sync` until nothing is left to do, never two at once.
    private func schedule() {
        needsSync = true
        guard worker == nil else { return }
        worker = Task {
            while needsSync {
                needsSync = false
                await sync()
            }
            worker = nil
        }
    }

    // MARK: Bringing the profile up to date

    private func sync() async {
        let now = Date()
        guard isAllowedSource() else {
            await takeDown()
            status = .off
            return
        }
        guard let song = nowPlayingSource(now), let card = DiscordActivity(song, now: now) else {
            await takeDown()
            status = .waiting
            return
        }
        if song.isPlaying {
            pausedSince = nil
        } else {
            // Nothing on the profile: a pause has no card to replace.
            guard shown != nil else {
                await takeDown()
                status = .waiting
                return
            }
            let since = pausedSince ?? now
            pausedSince = since
            if now.timeIntervalSince(since) >= timing.pauseLinger {
                await takeDown()
                status = .waiting
                return
            }
        }

        // A connection that went quiet is checked now and then, so a Discord that quit and
        // came back gets the card again.
        if let live = connection, now >= nextCheck {
            nextCheck = now.addingTimeInterval(timing.retryInterval)
            let alive = await live.isAlive()
            if !alive { drop(live) }
        }

        let end = DiscordActivity.endTime(song, now: now)
        if connection != nil, shown == card.content {
            let drifted = switch (end, shownEnd) {
            case let (end?, shownEnd?): abs(end - shownEnd) > timing.seekDrift
            case (nil, nil): false
            default: true
            }
            guard drifted else { return armWake(now) }
            if let last = pushes.last, now.timeIntervalSince(last) < timing.pushInterval {
                return armWake(now, at: last.addingTimeInterval(timing.pushInterval))
            }
        }
        pushes.removeAll { now.timeIntervalSince($0) >= timing.rateWindow }
        if pushes.count >= timing.rateLimit, let oldest = pushes.first {
            return armWake(now, at: oldest.addingTimeInterval(timing.rateWindow))
        }

        guard let live = await connect(now) else {
            status = .unavailable
            return armWake(now)
        }
        // The state may have moved on while connecting; the loop in `schedule` runs again for it.
        var result = await live.setActivity(sendsBasic ? card.basic : card)
        if case .rejected = result, !sendsBasic {
            // An older Discord that doesn't take the newer fields still takes the rest.
            sendsBasic = true
            pushes.append(now)
            result = await live.setActivity(card.basic)
        }
        pushes.append(now)
        switch result {
        case .accepted:
            shown = card.content
            shownEnd = end
            status = .showing
        case .rejected:
            // Remembered as shown, so the same refused card isn't sent again and again.
            shown = card.content
            shownEnd = end
            status = .refused
        case .failed:
            drop(live)
            lastAttempt = now
            status = .unavailable
        }
        armWake(now)
    }

    /// The live connection, or a new one when the retry interval allows.
    private func connect(_ now: Date) async -> (any DiscordConnection)? {
        if let connection { return connection }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < timing.retryInterval { return nil }
        lastAttempt = now
        guard let fresh = await connector() else { return nil }
        // Let go while connecting (turned off, the song ended): the next sync takes it down.
        connection = fresh
        sendsBasic = false
        lastAttempt = nil
        nextCheck = Date().addingTimeInterval(timing.retryInterval)
        return fresh
    }

    private func drop(_ live: any DiscordConnection) {
        guard connection === live else { return }
        connection = nil
        shown = nil
        shownEnd = nil
        Task { await live.close() }
    }

    /// Takes the card down and lets go of Discord, so Koda never keeps it busy for nothing.
    private func takeDown() async {
        pausedSince = nil
        wake?.cancel()
        wake = nil
        let wasShown = shown != nil
        shown = nil
        shownEnd = nil
        guard let live = connection else { return }
        connection = nil
        if wasShown { _ = await live.setActivity(nil) }
        await live.close()
    }

    /// Comes back at `date`, or at the next moment something is due: the end of a pause,
    /// a retry, or a check on the connection.
    private func armWake(_ now: Date, at date: Date? = nil) {
        var due = [date, now.addingTimeInterval(timing.retryInterval)].compactMap { $0 }
        if let pausedSince { due.append(pausedSince.addingTimeInterval(timing.pauseLinger)) }
        let delay = max(0.05, (due.min() ?? now).timeIntervalSince(now))
        wake?.cancel()
        wake = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.schedule()
        }
    }
}
