import Foundation
@testable import KodaCore
import Testing

@Suite("Video extras")
struct VideoExtrasTests {
    // A real WEB `next` for "Me at the zoo", trimmed to its player bar: three creator chapters.
    @Test func chaptersFromThePlayerBar() throws {
        let chapters = VideoPages.chapters(try fixture("next-web-chapters"))
        #expect(chapters.map(\.title) == ["Intro", "The cool thing", "End"])
        #expect(chapters.map(\.start) == [0, 5, 17])
        #expect(chapters.first?.thumbnail != nil)
        #expect(VideoChapter.current(in: chapters, at: 3)?.title == "Intro")
        #expect(VideoChapter.current(in: chapters, at: 12)?.title == "The cool thing")
    }

    @Test func noChaptersWithoutMarkers() {
        #expect(VideoPages.chapters(JSON([String: Any]())).isEmpty)
    }

    // A real visionOS `/player` for Big Buck Bunny, trimmed to its storyboard.
    @Test func storyboardFramesFromTheSpec() throws {
        let root = try fixture("player-visionos-storyboard")
        let spec = try #require(root["storyboards"]["playerStoryboardSpecRenderer"]["spec"].string)
        let board = try #require(VideoStoryboard(spec: spec))
        #expect(board.levels.count == 3)
        // The largest level: 160×90 frames, 5×5 to a sheet, one every 5 s.
        let first = try #require(board.frame(at: 0, duration: 635))
        #expect(first.rect == CGRect(x: 0, y: 0, width: 160, height: 90))
        #expect(first.sheet.absoluteString.contains("/storyboard3_L2/M0.jpg"))
        #expect(first.sheet.absoluteString.contains("&sigh=rs%24"))
        // 130 s is frame 26: the second sheet, its second frame.
        let later = try #require(board.frame(at: 130, duration: 635))
        #expect(later.sheet.absoluteString.contains("/M1.jpg"))
        #expect(later.rect == CGRect(x: 160, y: 0, width: 160, height: 90))
        // Past the end stays on the last frame.
        #expect(board.frame(at: 10_000, duration: 635) != nil)
    }

    @Test func storyboardRejectsNonsense() {
        #expect(VideoStoryboard(spec: "") == nil)
        #expect(VideoStoryboard(spec: "https://i.ytimg.com/sb/x/$L/$N.jpg") == nil)
    }

    /// Checked against live search results in November 2026.
    @Test func searchFilterParams() {
        #expect(VideoSearchFilters().params == nil)
        #expect(VideoSearchFilters(type: .channels).params == "EgIQAg==")
        #expect(VideoSearchFilters(uploadDate: .thisWeek).params == "EgQIAxAB")
        #expect(VideoSearchFilters(length: .underFourMinutes).params == "EgQQARgB")
        #expect(VideoSearchFilters(length: .overTwentyMinutes).params == "EgQQARgC")
        #expect(VideoSearchFilters(type: .videos, sort: .viewCount).params == "CAMSAhAB")
    }

    // A real SponsorBlock answer for hash prefix 5f6b (every video sharing it).
    @Test func sponsorSegmentsForOneVideo() throws {
        let root = try fixture("sponsorblock-5f6b")
        let segments = SponsorBlock.parse(root, videoId: "eXjGWlJOhWg")
        #expect(segments.first?.category == .intro)
        #expect(segments.first?.start == 0)
        #expect(segments.first.map { abs($0.end - 14.827) < 0.001 } == true)
        #expect(SponsorBlock.parse(root, videoId: "notInTheAnswer").isEmpty)
    }

    @Test func dislikeCount() throws {
        let root = try JSON(data: Data(#"{"id":"dQw4w9WgXcQ","likes":19498458,"dislikes":521733}"#.utf8))
        #expect(ReturnDislike.parse(root) == 521_733)
    }
}
