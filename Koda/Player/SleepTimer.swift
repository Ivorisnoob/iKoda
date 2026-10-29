import KodaCore
import SwiftUI

/// Pauses playback after a while, or when the playing song ends.
@MainActor
@Observable
final class SleepTimer {
    enum Mode: Equatable {
        case off
        case at(Date)
        case endOfSong
    }

    private(set) var mode: Mode = .off
    private let player: Player
    private var task: Task<Void, Never>?

    static let presets = [5, 10, 15, 30, 45, 60, 90]

    init(player: Player) {
        self.player = player
    }

    var isActive: Bool { mode != .off }

    func start(minutes: Int) {
        cancel()
        let end = Date().addingTimeInterval(TimeInterval(minutes * 60))
        mode = .at(end)
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled, let self, self.mode == .at(end) else { return }
            self.player.pause(from: "the sleep timer")
            self.mode = .off
        }
    }

    func stopAtEndOfSong() {
        cancel()
        mode = .endOfSong
        player.stopsAtEndOfSong = true
        // The player clears the flag when it pauses; follow it so the timer shows off again.
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.mode == .endOfSong else { return }
                if !self.player.stopsAtEndOfSong {
                    self.mode = .off
                    return
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if mode == .endOfSong { player.stopsAtEndOfSong = false }
        mode = .off
    }

    /// "12:04 left", "End of song", for the indicator in Now Playing.
    func label(at date: Date) -> String {
        switch mode {
        case .off: return ""
        case .endOfSong: return "End of song"
        case .at(let end):
            let left = max(0, end.timeIntervalSince(date))
            return Duration.seconds(left.rounded(.up)).formatted(.time(pattern: left >= 3600 ? .hourMinuteSecond : .minuteSecond))
        }
    }
}

/// The sleep timer's choices, for a menu.
struct SleepTimerMenu: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let timer = app.sleepTimer
        Menu {
            if timer.isActive {
                Button("Turn Off Timer", systemImage: "moon.zzz", role: .destructive) { timer.cancel() }
            }
            Section("Stop Playing After") {
                ForEach(SleepTimer.presets, id: \.self) { minutes in
                    Button(minutes < 60 ? "\(minutes) minutes" : minutes == 60 ? "1 hour" : "1 hour \(minutes - 60) minutes") {
                        timer.start(minutes: minutes)
                    }
                }
                Button("End of Song", systemImage: "music.note") { timer.stopAtEndOfSong() }
            }
        } label: {
            Label("Sleep Timer", systemImage: timer.isActive ? "moon.fill" : "moon")
        }
    }
}
