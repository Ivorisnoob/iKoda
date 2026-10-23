import Foundation
import Testing
@testable import KodaCore

struct ByteRangesTests {
    @Test func mergesOverlappingAndTouchingRanges() {
        var ranges = ByteRanges()
        ranges.insert(10..<20)
        ranges.insert(30..<40)
        ranges.insert(20..<25)
        #expect(ranges.ranges == [10..<25, 30..<40])
        ranges.insert(24..<31)
        #expect(ranges.ranges == [10..<40])
        #expect(ranges.count == 30)
    }

    @Test func findsGapsAndContiguousRuns() {
        var ranges = ByteRanges()
        ranges.insert(0..<100)
        ranges.insert(200..<300)
        #expect(ranges.contiguousLength(from: 50) == 50)
        #expect(ranges.contiguousLength(from: 150) == 0)
        #expect(ranges.contains(0..<100))
        #expect(!ranges.contains(50..<150))
        #expect(ranges.firstMissing(before: 400) == 100)
        #expect(ranges.gapEnd(from: 100, before: 400) == 200)
        #expect(ranges.firstMissing(from: 200, before: 400) == 300)
        #expect(ranges.gapEnd(from: 300, before: 400) == 400)
        #expect(ranges.firstMissing(from: 0, before: 100) == nil)
    }
}

struct AudioStoreTests {
    func makeStore(limit: Int64 = 1_000_000) throws -> (AudioStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "audiostore-\(UUID().uuidString)")
        return (AudioStore(directory: directory, cacheLimit: limit), directory)
    }

    func stream(_ id: String, length: Int64) -> ResolvedStream {
        ResolvedStream(videoId: id, url: URL(string: "https://example.com/\(id)")!, userAgent: "test", itag: 140,
                       contentLength: length, duration: 200, loudnessDb: 1.5, expiresAt: nil)
    }

    @Test func fillsAFileOutOfOrderAndPlaysItWhole() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.prepare(stream("a", length: 10), song: nil)
        try store.write(Data([5, 6, 7, 8, 9]), at: 5, for: "a")
        #expect(store.completeStream("a") == nil)
        #expect(store.firstGap("a") == 0..<5)
        #expect(store.read("a", at: 5, count: 5) == Data([5, 6, 7, 8, 9]))
        #expect(store.read("a", at: 3, count: 5) == nil, "bytes the file doesn't hold were read")

        try store.write(Data([0, 1, 2, 3, 4]), at: 0, for: "a")
        let file = try #require(store.completeStream("a"))
        #expect(file.url.isFileURL)
        #expect(file.duration == 200)
        #expect(file.loudnessDb == 1.5)
        #expect(try Data(contentsOf: file.url) == Data(0..<10))
    }

    @Test func remembersWhatItHoldsAcrossLaunches() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.prepare(stream("a", length: 4), song: nil)
        try store.write(Data([1, 2, 3, 4]), at: 0, for: "a")
        store.flush()
        let reopened = AudioStore(directory: directory)
        #expect(reopened.completeStream("a") != nil)
    }

    @Test func evictsTheLeastRecentlyPlayedButNeverADownload() throws {
        let (store, directory) = try makeStore(limit: 10)
        defer { try? FileManager.default.removeItem(at: directory) }
        let kept = Song(id: "kept", title: "Kept", artistLine: "Artist")
        store.markDownloaded([kept])
        store.prepare(stream("kept", length: 8), song: kept)
        try store.write(Data(count: 8), at: 0, for: "kept")
        for id in ["old", "new"] {
            store.prepare(stream(id, length: 6), song: nil)
            try store.write(Data(count: 6), at: 0, for: id)
        }
        // 12 bytes of cache over a limit of 10: the older song goes; the download doesn't count.
        #expect(store.entry("old") == nil)
        #expect(store.entry("new")?.isComplete == true)
        #expect(store.entry("kept")?.isComplete == true)
        #expect(store.downloads.map(\.videoId) == ["kept"])
    }

    @Test func aSongInUseIsNotEvicted() throws {
        let (store, directory) = try makeStore(limit: 5)
        defer { try? FileManager.default.removeItem(at: directory) }
        store.prepare(stream("playing", length: 6), song: nil)
        store.beginUse("playing")
        try store.write(Data(count: 6), at: 0, for: "playing")
        #expect(store.entry("playing")?.isComplete == true)
        store.endUse("playing")
        #expect(store.entry("playing") == nil)
    }

    @Test func aDifferentFormatStartsTheFileAgain() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.prepare(stream("a", length: 4), song: nil)
        try store.write(Data(count: 4), at: 0, for: "a")
        store.prepare(stream("a", length: 6), song: nil)
        #expect(store.entry("a")?.bytes == 0)
        #expect(store.completeStream("a") == nil)
    }
}
