import Foundation
import Testing
@testable import KodaCore

/// Comments in full: replies, the links and times YouTube marks in text, and what an account can
/// do with a comment. The replies and timestamps pages are real WEB responses captured signed
/// out on 12 November 2026 (tracking fields dropped). YouTube only hands the like, reply and
/// delete commands to an account, so `web-comments-signed-in` and `web-comment-created` are the
/// real signed-out page with those parts filled in where Koda for Android reads them.
@Suite struct VideoCommentsTests {
    @Test func topLevelCommentsKeepTheirOrderAndOpenTheirReplies() throws {
        let page = VideoPages.comments(try fixture("web-comments"))
        #expect(page.comments.count == 20)
        let first = try #require(page.comments.first)
        #expect(first.id == "Ugxzbv_ZeZXNRcfwsSF4AaABAg")
        #expect(first.replies == "711")
        #expect(first.repliesToken?.isEmpty == false)
        #expect(first.repliesToken != page.continuation)
        // Signed out there is nothing to send.
        #expect(first.likeAction == nil)
        #expect(first.replyParams == nil)
        #expect(page.createParams == nil)
    }

    @Test func aPageOfRepliesReadsBareCommentsAndTheButtonForMore() throws {
        let page = VideoPages.comments(try fixture("web-comment-replies"))
        #expect(page.comments.count == 10)
        #expect(page.comments.allSatisfy { !$0.author.isEmpty && !$0.text.isEmpty && $0.repliesToken == nil })
        #expect(page.continuation?.isEmpty == false)
    }

    @Test func timesInACommentAreTheLinksYouTubeMarked() throws {
        let page = VideoPages.comments(try fixture("web-comments-timestamps"))
        let comment = try #require(page.comments.first { !$0.links.isEmpty })
        let units = Array(comment.text.utf16)
        let first = try #require(comment.links.first)
        #expect(first.target == .timestamp(seconds: 310, videoId: "HSsqzzuGTPo"))
        #expect(String(utf16CodeUnits: Array(units[first.range]), count: first.range.count) == "5:10")
        // In order and apart, so they can be laid over the text as they are.
        for (a, b) in zip(comment.links, comment.links.dropFirst()) { #expect(a.range.upperBound <= b.range.lowerBound) }
    }

    @Test func descriptionLinksLeaveYouTubesRedirect() throws {
        let page = try #require(VideoPages.watch(try fixture("web-watch"), id: "aqz-KE-bpKQ"))
        #expect(page.richDescription.text == page.description)
        #expect(page.richDescription.links.count == 2)
        #expect(page.richDescription.links.first?.target == .url(URL(string: "https://studio.blender.org/projects/big-buck-bunny/")!))
    }

    @Test func linkRangesCountInUTF16AndDropTrailingSpace() throws {
        let node = try JSON(data: Data(#"""
        {"content": "🎵 Intro 0:42 \nnext", "commandRuns": [
          {"startIndex": 9, "length": 6, "onTap": {"innertubeCommand": {"watchEndpoint": {"videoId": "abcdefghijk", "startTimeSeconds": 42}}}},
          {"startIndex": 10, "length": 2, "onTap": {"innertubeCommand": {"watchEndpoint": {"videoId": "abcdefghijk"}}}},
          {"startIndex": 99, "length": 4, "onTap": {"innertubeCommand": {"urlEndpoint": {"url": "https://example.com"}}}}
        ]}
        """#.utf8))
        let text = RichText(node)
        // The emoji is two units, so "0:42" starts at 9; the run's trailing space and line break go.
        #expect(text.links == [RichText.Link(range: 9..<13, target: .timestamp(seconds: 42, videoId: "abcdefghijk"))])
    }

    @Test func anAccountsPageCarriesWhatItCanSend() throws {
        let page = VideoPages.comments(try fixture("web-comments-signed-in"))
        #expect(page.createParams == "CREATE-PARAMS")
        #expect(page.comments.count == 2)
        let liked = page.comments[0], own = page.comments[1]
        #expect(liked.isLiked)
        #expect(liked.likeAction == "LIKE-0")
        #expect(liked.unlikeAction == "UNLIKE-0")
        #expect(liked.replyParams == "REPLY-0")
        #expect(liked.deleteAction == nil)
        #expect(!liked.isOwn)
        #expect(own.isOwn)
        #expect(!own.isLiked)
        #expect(own.deleteAction == "DELETE-1")
    }

    @Test func aPostedCommentComesBackOnlyWhenItTook() throws {
        let root = try fixture("web-comment-created")
        let comment = try #require(VideoPages.createdComment(root))
        #expect(comment.isOwn)
        #expect(comment.deleteAction == "DELETE-1")
        #expect(comment.replyParams == "REPLY-1")
        let refused = try JSON(data: Data(#"{"actionResult": {"status": "STATUS_FAILED"}}"#.utf8))
        #expect(VideoPages.createdComment(refused) == nil)
        #expect(!VideoPages.commentActionSucceeded(refused))
        #expect(VideoPages.commentActionSucceeded(try JSON(data: Data("{}".utf8))))
    }
}
