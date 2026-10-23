import Foundation
import Observation
import Testing
@testable import KodaCore

/// Which of the player's observed parts a queue change touches. Every song row in the app
/// watches `current`, so a change elsewhere in the queue must leave it alone.
@MainActor
struct PlayerObservationTests {
    /// Set from an observation's change handler.
    final class Flag: @unchecked Sendable {
        var raised = false
    }

    func watch(_ read: @escaping @MainActor () -> Void) -> Flag {
        let flag = Flag()
        withObservationTracking { read() } onChange: { flag.raised = true }
        return flag
    }

    @Test func repeatChangesOnlyRepeat() {
        let player = Player(music: YouTubeMusic(defaultsSuite: "koda.observationtests"))
        let song = watch { _ = player.current }
        let upcoming = watch { _ = player.upcoming }
        let repeatMode = watch { _ = player.repeatMode }

        player.setRepeat(.all)

        #expect(repeatMode.raised)
        #expect(player.repeatMode == .all)
        #expect(!song.raised, "changing repeat redrew everything showing the playing song")
        #expect(!upcoming.raised)
    }

    @Test func shuffleChangesOnlyShuffle() {
        let player = Player(music: YouTubeMusic(defaultsSuite: "koda.observationtests"))
        let song = watch { _ = player.current }
        let shuffled = watch { _ = player.isShuffled }

        player.setShuffle(true)

        #expect(shuffled.raised)
        #expect(player.isShuffled)
        #expect(!song.raised)
    }
}
