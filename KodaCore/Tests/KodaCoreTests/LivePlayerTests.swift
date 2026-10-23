import Foundation
import Testing
@testable import KodaCore

/// The real pipeline against live streams, muted. Run with
/// `KODA_LIVE=1 swift test --filter LivePlayerTests`.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["KODA_LIVE"] == "1"))
struct LivePlayerTests {
    /// Wait until `condition` holds, polling, or fail after `timeout`.
    func waitFor(_ what: String, timeout: TimeInterval = 20, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                Issue.record("timed out waiting for \(what)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    func makePlayer() async throws -> (Player, [Song]) {
        let music = YouTubeMusic(defaultsSuite: "koda.livetests")
        let player = Player(music: music)
        player.isMuted = true
        player.autoplay = false
        let radio = try await music.radio(for: "J7p4bzqLvCw")
        return (player, Array(radio.songs.prefix(4)))
    }

    @Test func playsPreloadsAndAdvancesExactlyOnce() async throws {
        let (player, songs) = try await makePlayer()
        player.play(songs)
        try await waitFor("first song to play") { player.phase == .ready && player.timeAnchor.rate > 0 }
        #expect(player.current?.id == songs[0].id)
        try await waitFor("next song to preload") { player.loadedItemCount == 2 }

        // Let the first song run out by itself.
        player.seek(to: player.duration - 2)
        try await waitFor("automatic advance", timeout: 15) { player.current?.id == songs[1].id }
        try await Task.sleep(for: .seconds(2))
        #expect(player.current?.id == songs[1].id, "advanced once, not twice")
        #expect(player.position() < 6)
        #expect(player.queue.currentIndex == 1)
        player.stop()
    }

    @Test func crossfadesIntoTheNextSongExactlyOnce() async throws {
        let (player, songs) = try await makePlayer()
        player.crossfades = true
        player.crossfadeDuration = 4
        player.play(songs)
        try await waitFor("preload") { player.phase == .ready && player.loadedItemCount == 2 }
        // Just before the fade starts, so playback runs across it.
        player.seek(to: player.duration - 7)
        try await waitFor("crossfade starts", timeout: 15) { player.current?.id == songs[1].id }
        #expect(player.isFadingOut, "the first song fades out on the side")
        #expect(player.position() < 3, "the next song starts from its beginning")
        try await Task.sleep(for: .seconds(6))
        #expect(!player.isFadingOut, "the fade ends and lets the song go")
        #expect(player.current?.id == songs[1].id, "advanced once, not twice")
        #expect(player.queue.currentIndex == 1)
        player.stop()
    }

    @Test func aSkipFadesTheOldSongOutQuickly() async throws {
        let (player, songs) = try await makePlayer()
        player.crossfades = true
        player.play(songs)
        try await waitFor("preload") { player.phase == .ready && player.loadedItemCount == 2 && player.timeAnchor.rate > 0 }
        player.next()
        #expect(player.isFadingOut)
        try await waitFor("skip") { player.current?.id == songs[1].id && player.timeAnchor.rate > 0 }
        try await Task.sleep(for: .seconds(1.5))
        #expect(!player.isFadingOut)
        // A skip to a song that isn't preloaded fades too, while the new one loads.
        player.jump(to: player.queue.items[3].id)
        #expect(player.isFadingOut)
        try await waitFor("jump") { player.current?.id == songs[3].id && player.timeAnchor.rate > 0 }
        player.stop()
        #expect(!player.isFadingOut)
    }

    @Test func skipUsesThePreloadedSongAndPreviousGoesBack() async throws {
        let (player, songs) = try await makePlayer()
        player.play(songs)
        try await waitFor("preload") { player.phase == .ready && player.loadedItemCount == 2 }
        player.next()
        try await waitFor("skip") { player.current?.id == songs[1].id && player.timeAnchor.rate > 0 }
        try await waitFor("preload after skip") { player.loadedItemCount == 2 }
        player.previous()
        try await waitFor("previous") { player.current?.id == songs[0].id && player.timeAnchor.rate > 0 }
        player.stop()
    }

    @Test func repeatOneLoopsTheSameSong() async throws {
        let (player, songs) = try await makePlayer()
        player.setRepeat(.one)
        player.play(songs)
        try await waitFor("play") { player.phase == .ready && player.loadedItemCount == 2 }
        player.seek(to: player.duration - 2)
        try await waitFor("the end to be reached", timeout: 15) { player.position() > player.duration - 1 }
        try await waitFor("the song to start again", timeout: 15) { player.position() < 6 && player.timeAnchor.rate > 0 }
        #expect(player.current?.id == songs[0].id)
        #expect(player.queue.currentIndex == 0)
        player.stop()
    }

    @Test func repeatOneCrossfadesIntoItsOwnStartAndCountsAPlay() async throws {
        let (player, songs) = try await makePlayer()
        player.crossfades = true
        player.crossfadeDuration = 4
        player.setRepeat(.one)
        var starts = 0
        player.onItemStarted = { _ in starts += 1 }
        player.play(songs)
        try await waitFor("the song on standby") { player.phase == .ready && player.loadedItemCount == 2 && player.timeAnchor.rate > 0 }
        #expect(starts == 1)
        player.seek(to: player.duration - 7)
        try await waitFor("the fade back to the start", timeout: 15) { player.isFadingOut }
        #expect(player.position() < 3, "the same song starts again from its beginning")
        try await waitFor("the repeat to count as a play") { starts == 2 }
        #expect(player.current?.id == songs[0].id)
        #expect(player.queue.currentIndex == 0)
        player.stop()
    }

    @Test func shuffleMidSongKeepsPlayingAndRepreloads() async throws {
        let (player, songs) = try await makePlayer()
        player.play(songs)
        try await waitFor("play") { player.phase == .ready && player.loadedItemCount == 2 }
        let playing = player.current?.id
        player.setShuffle(true)
        #expect(player.current?.id == playing)
        try await waitFor("re-preload for the shuffled order") { player.loadedItemCount == 2 }
        player.setShuffle(false)
        #expect(player.queue.items.map(\.song.id) == songs.map(\.id))
        player.stop()
    }

    @Test func aFailingSongIsRetriedNotSkipped() async throws {
        let (player, songs) = try await makePlayer()
        var broken: Set<String> = [songs[1].id]
        player.streamRewriter = { stream in
            guard broken.remove(stream.videoId) != nil else { return stream }
            var bad = stream
            bad.url = URL(string: "https://rr1---sn-invalid.googlevideo.com/videoplayback?expire=1")!
            return bad
        }
        player.play(songs)
        try await waitFor("play") { player.phase == .ready && player.timeAnchor.rate > 0 }
        try await waitFor("the broken song to be preloaded") { broken.isEmpty }
        player.seek(to: player.duration - 2)
        try await waitFor("the retried song to play", timeout: 25) { player.current?.id == songs[1].id && player.timeAnchor.rate > 0 && player.phase == .ready }
        try await Task.sleep(for: .seconds(2))
        #expect(player.queue.currentIndex == 1, "the failed song played after a retry instead of being skipped")
        player.stop()
    }

    @Test func autoplayCarriesOnWithRadio() async throws {
        let (player, songs) = try await makePlayer()
        player.autoplay = true
        player.play([songs[0]])
        try await waitFor("play") { player.phase == .ready && player.timeAnchor.rate > 0 }
        try await waitFor("radio appended", timeout: 15) { player.queue.items.count > 5 }
        player.seek(to: player.duration - 2)
        try await waitFor("next radio song plays", timeout: 15) { player.queue.currentIndex == 1 && player.timeAnchor.rate > 0 }
        #expect(player.current?.id != songs[0].id)
        player.stop()
    }

    @Test func endOfQueueWithoutAutoplayStops() async throws {
        let (player, songs) = try await makePlayer()
        player.play([songs[0]])
        try await waitFor("play") { player.phase == .ready && player.timeAnchor.rate > 0 }
        player.seek(to: player.duration - 2)
        try await waitFor("stop at the end", timeout: 15) { !player.wantsToPlay }
        #expect(player.current?.id == songs[0].id)
        player.stop()
    }
}
