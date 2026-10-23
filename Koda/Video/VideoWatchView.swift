import AVFoundation
import KodaCore
import SwiftUI
import UIKit

/// A video playing, with its details, its channel, what can be done with it, its comments and
/// Up Next.
///
/// iPhone: no bar; the video sits right under the status bar with its back button on it (the
/// edge swipe still goes back), the tab bar steps away, and the details and Up Next scroll under
/// the video. Turning the phone sideways takes a landscape video full screen; a swipe down the
/// video leaves the page with the video carrying on in the mini player.
/// Mac: the window's toolbar as usual; a wide window puts Up Next in a column of its own.
///
/// The page follows the player: when a video ends and Up Next starts by itself, the page becomes
/// that video's, as YouTube's does.
struct VideoWatchView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var video: Video
    @State private var watch: WatchModel
    @State private var size: CGSize = .zero
    @State private var showsComments = false
    /// The video's comments, made when its page loads and shared by the card and the sheet.
    @State private var comments: CommentsModel?

    init(video: Video) {
        _video = State(initialValue: video)
        _watch = State(initialValue: WatchModel(videoId: video.id))
    }

    private var playback: VideoPlayback { app.videos }
    /// The page's video as best known: the watch page's details over the row it came from.
    private var shown: Video { (watch.state.value?.video ?? video).merged(over: video) }

    var body: some View {
        @Bindable var playback = playback
        Group {
            if Platform.isMac { macBody } else { phoneBody }
        }
        .navigationTitle(Platform.isMac ? shown.title : "")
        // On the iPhone full screen is a cover; the Mac draws it over the whole window instead
        // (MacRootView), since a cover presented while the window goes full screen got lost.
        .fullScreenCover(isPresented: Platform.isMac ? .constant(false) : $playback.isFullScreen) {
            FullScreenVideoView(playback: playback, video: shown)
                .appEnvironment(app)
        }
        .sheet(isPresented: $showsComments) {
            if let comments {
                CommentsSheet(model: comments, count: watch.state.value?.commentCount)
                    .appEnvironment(app)
            }
        }
        .task(id: video.id) {
            playback.play(video)
            if watch.videoId != video.id {
                watch = WatchModel(videoId: video.id)
                comments = nil
            }
            await watch.load(music: app.music)
            if let page = watch.state.value {
                playback.update(page.video.merged(over: video))
                playback.setUpNext(page.next, after: video.id)
                comments = page.commentsToken.map(CommentsModel.init(token:))
            }
        }
        .onAppear { playback.pageAppeared(video.id) }
        .onDisappear { playback.pageDisappeared(video.id) }
        // Up Next started by itself at the end: this page is now that video's.
        .onChange(of: playback.autoplayed?.to.id) {
            guard let autoplayed = playback.autoplayed, autoplayed.from == video.id else { return }
            playback.pageDisappeared(video.id)
            withAnimation(.smooth) { video = autoplayed.to }
            playback.pageAppeared(autoplayed.to.id)
        }
    }

    // MARK: iPhone

    private var phoneBody: some View {
        VStack(spacing: 0) {
            VideoPlayerView(playback: playback, video: shown, onBack: { dismiss() }, onMinimize: { dismiss() })
                .aspectRatio(16 / 9, contentMode: .fit)
                .zIndex(1)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    details
                    upNext
                }
                .padding(.horizontal, VideoMetrics.side)
                .padding(.top, 14)
                .padding(.bottom, 32)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .background { InteractivePopEnabler().frame(width: 0, height: 0) }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in turned() }
        .onAppear { UIDevice.current.beginGeneratingDeviceOrientationNotifications() }
        .onDisappear { UIDevice.current.endGeneratingDeviceOrientationNotifications() }
    }

    /// Sideways with a landscape video on, as in the TV app: full screen.
    private func turned() {
        guard playback.current?.id == video.id, playback.player.currentItem != nil, !playback.isFullScreen else { return }
        let size = playback.presentationSize
        guard size.width > size.height, UIDevice.current.orientation.isLandscape else { return }
        playback.isFullScreen = true
    }

    // MARK: Mac

    private var macBody: some View {
        let wide = size.width >= 1020
        return Group {
            if app.settings.videoTheater {
                theaterBody(wide: wide)
            } else if wide {
                HStack(alignment: .top, spacing: 28) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            macPlayer
                            details
                        }
                        .padding(.vertical, 20)
                        .padding(.leading, MacMetrics.gutter)
                        .frame(minWidth: 0, maxWidth: .infinity)
                    }
                    ScrollView {
                        upNext.padding(.vertical, 20).padding(.trailing, MacMetrics.gutter)
                    }
                    .frame(width: 380)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        macPlayer
                        details
                        upNext
                    }
                    .padding(.vertical, 20)
                    .padding(.horizontal, MacMetrics.gutter)
                    .frame(minWidth: 0, maxWidth: .infinity)
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: video.watchURL, subject: Text(shown.title)) { Label("Share", systemImage: "square.and.arrow.up") }
            }
        }
    }

    /// Theater mode, as YouTube's site has it: the video across the page on black, as tall as
    /// the window allows while leaving the title in sight; the details and Up Next under it,
    /// side by side in a wide window.
    private func theaterBody(wide: Bool) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    VideoPlayerView(playback: playback, video: shown)
                        .aspectRatio(16 / 9, contentMode: .fit)
                }
                .frame(height: max(240, min(size.width * 9 / 16, size.height * 0.78)))
                let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 28)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
                layout {
                    details.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    upNext.frame(width: wide ? 380 : nil)
                }
                .padding(.horizontal, MacMetrics.gutter)
                .padding(.vertical, 20)
            }
            .frame(minWidth: 0, maxWidth: .infinity)
        }
    }

    private var macPlayer: some View {
        VideoPlayerView(playback: playback, video: shown)
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 14, style: .continuous))
    }

    // MARK: Parts

    private var details: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(shown.title)
                .font(Platform.isMac ? .title2.bold() : .title3.bold())
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            switch watch.state {
            case .loaded(let page):
                ChannelLine(channel: shown.channel, subscribers: page.subscribers, pageSubscribed: page.isSubscribed)
                actions(page)
                VideoDescription(page: page)
                if let comments {
                    CommentsCard(model: comments, count: page.commentCount) { showsComments = true }
                }
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't Load Details", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await watch.load(music: app.music) } }.buttonStyle(.glass)
                }
            case .loading:
                // The loaded layout, redacted, so nothing moves when it arrives.
                VStack(alignment: .leading, spacing: 16) {
                    ChannelLine(channel: shown.channel ?? ChannelRef(id: nil, name: "Channel name"), subscribers: "1M subscribers",
                                pageSubscribed: nil)
                    HStack(spacing: 10) {
                        ActionCapsule(title: "12K", systemImage: "hand.thumbsup") {}
                        ActionCapsule(title: "Share", systemImage: "square.and.arrow.up") {}
                    }
                    Text("1,234,567 views · Jan 1, 2026\nA description that runs to a couple of lines while it loads.")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(.fill.quinary, in: .rect(cornerRadius: 16, style: .continuous))
                }
                .loadingPlaceholder()
            }
        }
    }

    /// Like and dislike, Share and, on the iPhone, the comments: a row of glass capsules that
    /// scrolls sideways when it runs out of room.
    private func actions(_ page: WatchPage) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                RatingCapsule(videoId: video.id, page: page)
                ShareLink(item: video.watchURL, subject: Text(shown.title)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                if page.commentsToken != nil {
                    ActionCapsule(title: page.commentCount.map { "Comments \($0)" } ?? "Comments", systemImage: "text.bubble") {
                        showsComments = true
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    @ViewBuilder
    private var upNext: some View {
        switch watch.state {
        case .loaded(let page) where !page.related.videos.isEmpty:
            VStack(alignment: .leading, spacing: 14) {
                Text("Up Next").font(.title3.bold())
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(page.related.videos) { related in
                        NavigationLink(value: Route.video(related)) {
                            VideoRow(video: related, thumbnailWidth: Platform.isMac ? 168 : 156)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { VideoMenuItems(video: related) }
                    }
                    if page.related.continuation != nil {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .task { await watch.loadMore(music: app.music) }
                    }
                }
            }
        case .loading:
            VStack(alignment: .leading, spacing: 14) {
                Text("Up Next").font(.title3.bold())
                ForEach(Video.placeholders.prefix(5)) { VideoRow(video: $0, thumbnailWidth: Platform.isMac ? 168 : 156) }
            }
            .loadingPlaceholder()
        default:
            EmptyView()
        }
    }
}

/// The channel under a video: its picture, name and subscribers, opening its page, and Subscribe
/// for a signed-in profile.
private struct ChannelLine: View {
    let channel: ChannelRef?
    let subscribers: String?
    let pageSubscribed: Bool?

    var body: some View {
        HStack(spacing: 12) {
            if let channel {
                if let id = channel.id {
                    NavigationLink(value: Route.channel(id: id, name: channel.name)) { label(channel) }
                        .buttonStyle(.plain)
                } else {
                    label(channel)
                }
                Spacer(minLength: 8)
                if let id = channel.id {
                    SubscribeButton(channelId: id, pageSubscribed: pageSubscribed)
                }
            }
        }
    }

    private func label(_ channel: ChannelRef) -> some View {
        HStack(spacing: 12) {
            ChannelAvatar(avatar: channel.avatar, size: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name).font(.headline).lineLimit(1)
                if let subscribers {
                    Text(subscribers).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .contentShape(.rect)
    }
}

/// Subscribe or Subscribed, sent to the signed-in account; hidden for a device profile. What it
/// shows is the account's: a change made anywhere in Koda this run, else what the page said.
struct SubscribeButton: View {
    let channelId: String
    let pageSubscribed: Bool?
    @Environment(AppModel.self) private var app
    /// What was just tapped, shown until the account answers.
    @State private var sending: Bool?
    @State private var confirmsUnsubscribe = false

    private var isSubscribed: Bool { sending ?? app.isSubscribed(channelId, page: pageSubscribed) ?? false }

    var body: some View {
        let profile = app.roster.active
        if profile.isSignedIn, !profile.isExpired {
            Button {
                if isSubscribed { confirmsUnsubscribe = true } else { send(true) }
            } label: {
                Label(isSubscribed ? "Subscribed" : "Subscribe", systemImage: isSubscribed ? "checkmark" : "plus")
                    .font(.subheadline.weight(.semibold))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(isSubscribed ? AnyPrimitiveButtonStyle(.glass) : AnyPrimitiveButtonStyle(.glassProminent))
            .disabled(sending != nil)
            .animation(.smooth(duration: 0.2), value: isSubscribed)
            .sensoryFeedback(.success, trigger: isSubscribed) { _, now in now }
            .confirmationDialog("Unsubscribe?", isPresented: $confirmsUnsubscribe) {
                Button("Unsubscribe", role: .destructive) { send(false) }
            }
        }
    }

    private func send(_ on: Bool) {
        sending = on
        Task {
            _ = await app.setSubscribed(channelId, on)
            sending = nil
        }
    }
}

/// Like and dislike in one capsule, the count on the like side. The rating is the account's;
/// signed out a tap asks to sign in.
private struct RatingCapsule: View {
    let videoId: String
    let page: WatchPage
    @Environment(AppModel.self) private var app
    /// What was just tapped, shown at once and kept if the account takes it.
    @State private var tapped: LikeStatus?
    @State private var asksToSignIn = false

    private var status: LikeStatus { tapped ?? app.videoRatings[videoId] ?? page.likeStatus }

    var body: some View {
        HStack(spacing: 0) {
            Button { rate(.like) } label: {
                Label {
                    Text(page.likeCounts[status == .like ? .like : .indifferent] ?? "Like")
                        .monospacedDigit()
                        .contentTransition(.numericText())
                } icon: {
                    Image(systemName: status == .like ? "hand.thumbsup.fill" : "hand.thumbsup")
                        .contentTransition(.symbolEffect(.replace))
                }
                .padding(.leading, 14)
                .padding(.trailing, 12)
                .frame(height: 36)
                .contentShape(.rect)
            }
            .accessibilityLabel(status == .like ? "Remove Like" : "Like")
            .accessibilityValue(page.likeCounts[.indifferent].map { "\($0) likes" } ?? "")
            Divider().frame(height: 18)
            Button { rate(.dislike) } label: {
                Image(systemName: status == .dislike ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    .contentTransition(.symbolEffect(.replace))
                    .padding(.leading, 12)
                    .padding(.trailing, 14)
                    .frame(height: 36)
                    .contentShape(.rect)
            }
            .accessibilityLabel(status == .dislike ? "Remove Dislike" : "Dislike")
        }
        .font(.subheadline.weight(.semibold))
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .sensoryFeedback(.impact(weight: .light), trigger: status)
        .alert("Sign In to Rate Videos", isPresented: $asksToSignIn) {
            Button("Not Now", role: .cancel) {}
            Button("Sign In") { app.isProfilePresented = true }
        } message: {
            Text("Likes and dislikes go to your YouTube account, where they shape what it recommends.")
        }
    }

    /// Tapping the rating already given clears it, as on YouTube.
    private func rate(_ choice: LikeStatus) {
        let profile = app.roster.active
        guard profile.isSignedIn, !profile.isExpired else { return asksToSignIn = true }
        let target: LikeStatus = status == choice ? .indifferent : choice
        withAnimation(.smooth(duration: 0.2)) { tapped = target }
        Task {
            _ = await app.rate(videoId, target)
            // Kept by `videoRatings` if it went; the page's own answer again if it didn't.
            withAnimation(.smooth(duration: 0.2)) { tapped = nil }
        }
    }
}

/// A glass capsule with a symbol and a word, for the watch page's actions.
private struct ActionCapsule: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(height: 36)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

/// Views and date, then the description, three lines until it's opened. Links in it open.
private struct VideoDescription: View {
    let page: WatchPage
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text([page.viewCount ?? page.video.views, expanded ? page.date : page.video.published ?? page.date].compactMap { $0 }.joined(separator: " · "))
                .font(.subheadline.weight(.semibold))
            if !page.description.isEmpty {
                Text(Self.linked(page.description))
                    .font(.subheadline)
                    .lineLimit(expanded ? nil : 3)
                    .textSelection(.enabled)
                Text(expanded ? "Show Less" : "Show More")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.fill.quinary, in: .rect(cornerRadius: 16, style: .continuous))
        .contentShape(.rect(cornerRadius: 16, style: .continuous))
        .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(expanded ? "Shows less of the description" : "Shows the whole description")
    }

    /// The description with its web addresses made into links.
    private static func linked(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return attributed }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, let range = Range(match.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed) else { continue }
            attributed[lower..<upper].link = url
        }
        return attributed
    }
}

/// The comments under the description, as YouTube's app shows them: the count and the top
/// comment, opening all of them.
private struct CommentsCard: View {
    let model: CommentsModel
    let count: String?
    let open: () -> Void
    @Environment(AppModel.self) private var app

    private var top: VideoComment? { model.state.value?.first }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("Comments").font(.subheadline.weight(.semibold))
                    if let count { Text(count).font(.subheadline).foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                HStack(alignment: .top, spacing: 10) {
                    CommentAvatar(url: top?.avatar, size: 24)
                    Text(top?.text ?? "A comment that runs to two lines while it loads, about the video.")
                        .font(.subheadline)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .redacted(reason: top == nil ? .placeholder : [])
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.fill.quinary, in: .rect(cornerRadius: 16, style: .continuous))
            .contentShape(.rect(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        // One request per video; the sheet shows the same page and only asks for more.
        .task(id: model.token) { await model.loadIfNeeded(music: app.music) }
    }
}

/// All of a video's comments, top first, paging as they're scrolled.
struct CommentsSheet: View {
    let model: CommentsModel
    let count: String?
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch model.state {
                case .loading:
                    list(VideoComment.placeholders).loadingPlaceholder()
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Couldn't Load Comments", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try Again") { Task { await model.load(music: app.music) } }.buttonStyle(.glass)
                    }
                case .loaded(let comments) where comments.isEmpty:
                    ContentUnavailableView("No Comments Yet", systemImage: "text.bubble")
                case .loaded(let comments):
                    list(comments)
                }
            }
            .navigationTitle("Comments")
            .navigationSubtitle(count.map { "\($0) comments" } ?? "")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .presentationDetents(Platform.isMac ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
        .frame(minWidth: Platform.isMac ? 520 : nil, minHeight: Platform.isMac ? 620 : nil)
        .task { await model.loadIfNeeded(music: app.music) }
    }

    private func list(_ comments: [VideoComment]) -> some View {
        List {
            ForEach(comments) { comment in
                CommentRow(comment: comment)
                    .listRowSeparator(.hidden)
            }
            if model.canLoadMore {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                    .task { await model.loadMore(music: app.music) }
            }
        }
        .listStyle(.plain)
    }
}

private struct CommentRow: View {
    let comment: VideoComment

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CommentAvatar(url: comment.avatar, size: 34)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(comment.author)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, comment.isCreator ? 6 : 0)
                        .padding(.vertical, comment.isCreator ? 1 : 0)
                        .background(comment.isCreator ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.clear), in: .capsule)
                    if comment.isVerified {
                        Image(systemName: "checkmark.seal.fill").font(.caption2).foregroundStyle(.secondary)
                            .accessibilityLabel("Verified")
                    }
                    Text("· \(comment.published)").font(.footnote).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Text(comment.text)
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    Label(comment.likes.isEmpty ? "0" : comment.likes, systemImage: "hand.thumbsup")
                    if !comment.replies.isEmpty {
                        Label(comment.replies == "1" ? "1 reply" : "\(comment.replies) replies", systemImage: "arrowshape.turn.up.left")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

/// A commenter's round picture.
private struct CommentAvatar: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        ArtworkView(artwork: url.map { Artwork(url: $0, width: 88, height: 88) }, size: size, circle: true)
            .frame(width: size, height: size)
    }
}

extension VideoComment {
    /// The stand-ins the comments draw, redacted, while they load.
    static let placeholders = (0..<8).map {
        VideoComment(id: "placeholder-\($0)", author: "@commenter", authorChannelId: nil, avatar: nil,
                     text: "A comment about the video that runs to a couple of lines while the real ones load.",
                     published: "2 days ago", likes: "1.2K", replies: "", isCreator: false, isVerified: false)
    }
}

/// A button style chosen at run time (Subscribe is prominent, Subscribed isn't).
struct AnyPrimitiveButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: PrimitiveButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}
