import AVFoundation
import KodaCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

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
    @State private var showsQueue = false
    /// The height under the iPhone's player, down to the screen's edge: where the comments and
    /// the queue rest as sheets, leaving the video in sight.
    @State private var spaceUnderPlayer: CGFloat = 0
    /// The video's comments, made when its page loads and shared by the card and the sheet.
    @State private var comments: CommentsModel?

    init(video: Video) {
        _video = State(initialValue: video)
        _watch = State(initialValue: WatchModel(videoId: video.id))
    }

    private var playback: VideoPlayback { app.videos }
    private var docked: PresentationDetent? {
        !Platform.isMac && spaceUnderPlayer > 260 ? .height(spaceUnderPlayer) : nil
    }
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
        #if os(iOS)
        .fullScreenCover(isPresented: Platform.isMac ? .constant(false) : $playback.isFullScreen) {
            FullScreenVideoView(playback: playback, video: shown)
                .appEnvironment(app)
        }
        #endif
        .sheet(isPresented: $showsComments) {
            if let comments {
                CommentsSheet(model: comments, count: watch.state.value?.commentCount, videoId: video.id, docked: docked)
                    .appEnvironment(app)
            }
        }
        .sheet(isPresented: $showsQueue) {
            VideoQueueSheet(playback: playback, docked: docked).appEnvironment(app)
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
                playback.setChapters(page.chapters, for: video.id)
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
            // The queue where the thumb is: what's next, opening all of it.
            .safeAreaBar(edge: .bottom) {
                if let next = playback.queue.first {
                    QueueBar(next: next, count: playback.queue.count) { showsQueue = true }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.smooth, value: playback.queue.isEmpty)
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height - proxy.size.width * 9 / 16 + proxy.safeAreaInsets.bottom
        } action: { spaceUnderPlayer = $0 }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .background { InteractivePopEnabler().frame(width: 0, height: 0) }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in turned() }
        .onAppear { UIDevice.current.beginGeneratingDeviceOrientationNotifications() }
        .onDisappear { UIDevice.current.endGeneratingDeviceOrientationNotifications() }
        #endif
    }

    #if os(iOS)
    /// Sideways with a landscape video on, as in the TV app: full screen.
    private func turned() {
        guard playback.current?.id == video.id, playback.player.currentItem != nil, !playback.isFullScreen else { return }
        let size = playback.presentationSize
        guard size.width > size.height, UIDevice.current.orientation.isLandscape else { return }
        playback.isFullScreen = true
    }
    #endif

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

    /// The video as an object on the page: rounded, lifted by a soft shadow.
    private var macPlayer: some View {
        VideoPlayerView(playback: playback, video: shown)
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.22), radius: 22, y: 10)
    }

    // MARK: Parts

    private var details: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(shown.title)
                .font(Platform.isMac ? .scaled(.title2).bold() : .scaled(.title3).bold())
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            switch watch.state {
            case .loaded(let page):
                if Platform.isMac {
                    // The channel and Subscribe on the left, the actions on the right, as one row
                    // while the width allows; the actions under the channel when it doesn't.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) {
                            ChannelLine(channel: shown.channel, subscribers: page.subscribers, pageSubscribed: page.isSubscribed, isCompact: true)
                            Spacer(minLength: 12)
                            actionButtons(page)
                        }
                        VStack(alignment: .leading, spacing: 14) {
                            ChannelLine(channel: shown.channel, subscribers: page.subscribers, pageSubscribed: page.isSubscribed)
                            actions(page)
                        }
                    }
                } else {
                    ChannelLine(channel: shown.channel, subscribers: page.subscribers, pageSubscribed: page.isSubscribed)
                    actions(page)
                }
                VideoDescription(page: page)
                    .richLinks(videoId: video.id)
                if !page.chapters.isEmpty {
                    ChapterList(chapters: page.chapters, video: shown, playback: playback)
                }
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
                        .font(.scaled(.subheadline))
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
            actionButtons(page)
                .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    private func actionButtons(_ page: WatchPage) -> some View {
        HStack(spacing: 10) {
            RatingCapsule(videoId: video.id, page: page)
            if app.roster.active.isSignedIn {
                let saved = app.watchLater[video.id] == true
                ActionCapsule(title: saved ? "Saved" : "Watch Later", systemImage: saved ? "checkmark" : "clock") {
                    Task { _ = await app.setWatchLater(video.id, !saved) }
                }
                .contentTransition(.symbolEffect(.replace))
                .help(saved ? "Remove from Watch Later" : "Save to Watch Later")
            }
            ShareLink(item: video.watchURL, subject: Text(shown.title)) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .font(.scaled(.subheadline).weight(.semibold))
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
        .fixedSize()
    }

    /// Up Next with Autoplay beside it, as YouTube keeps the switch where the next video is.
    private var upNextHeader: some View {
        @Bindable var settings = app.settings
        return HStack {
            Text("Up Next").font(.scaled(.title3).bold())
            Spacer(minLength: 8)
            Toggle("Autoplay", isOn: $settings.autoplaysVideos)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.scaled(.subheadline))
                .foregroundStyle(.secondary)
                .help("When a video ends, the next one starts after a short countdown")
        }
    }

    /// What follows this video: the listener's own queue first (on the Mac; the iPhone keeps
    /// it in a bar along the bottom), then what YouTube suggests.
    private var upNext: some View {
        VStack(alignment: .leading, spacing: 24) {
            if Platform.isMac, !playback.queue.isEmpty { queue }
            suggestions
        }
    }

    /// The videos lined up with Play Next and Add to Queue, in the order they'll play. A click
    /// opens one; Edit opens the whole queue to reorder and remove.
    private var queue: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Queue").font(.scaled(.title3).bold())
                Spacer(minLength: 8)
                Button("Edit") { showsQueue = true }
                    .font(.scaled(.subheadline))
            }
            ForEach(playback.queue) { queued in
                NavigationLink(value: Route.video(queued)) {
                    VideoRow(video: queued, thumbnailWidth: Platform.isMac ? 168 : 156)
                }
                .buttonStyle(.plain)
                .contextMenu { VideoMenuItems(video: queued) }
            }
        }
    }

    @ViewBuilder
    private var suggestions: some View {
        switch watch.state {
        case .loaded(let page) where !page.related.videos.isEmpty:
            VStack(alignment: .leading, spacing: 14) {
                upNextHeader
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(page.related.videos) { related in
                        NavigationLink(value: Route.video(related)) {
                            VideoRow(video: related, thumbnailWidth: Platform.isMac ? 168 : 156)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { VideoMenuItems(video: related) }
                    }
                    if page.related.continuation != nil {
                        LoadMoreTrigger { await watch.loadMore(music: app.music) }
                    }
                }
            }
        case .loading:
            VStack(alignment: .leading, spacing: 14) {
                Text("Up Next").font(.scaled(.title3).bold())
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
    /// Subscribe right after the name, for a row that has more on its right.
    var isCompact = false

    var body: some View {
        HStack(spacing: 12) {
            if let channel {
                if let id = channel.id {
                    NavigationLink(value: Route.channel(id: id, name: channel.name)) { label(channel) }
                        .buttonStyle(.plain)
                } else {
                    label(channel)
                }
                if isCompact {
                    Spacer().frame(width: 6)
                } else {
                    Spacer(minLength: 8)
                }
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
                Text(channel.name).font(.scaled(.headline)).lineLimit(1)
                if let subscribers {
                    Text(subscribers).font(.scaled(.caption)).foregroundStyle(.secondary).lineLimit(1)
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
                    .font(.scaled(.subheadline).weight(.semibold))
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
    /// Return YouTube Dislike's estimate, with that setting on.
    @State private var dislikes: Int?

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
                HStack(spacing: 6) {
                    Image(systemName: status == .dislike ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                        .contentTransition(.symbolEffect(.replace))
                    if let dislikes {
                        Text((dislikes + (status == .dislike ? 1 : 0)).formatted(.number.notation(.compactName)))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                }
                    .padding(.leading, 12)
                    .padding(.trailing, 14)
                    .frame(height: 36)
                    .contentShape(.rect)
            }
            .accessibilityLabel(status == .dislike ? "Remove Dislike" : "Dislike")
        }
        .font(.scaled(.subheadline).weight(.semibold))
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .sensoryFeedback(.impact(weight: .light), trigger: status)
        .task(id: "\(videoId)|\(app.settings.showsDislikes)") {
            dislikes = app.settings.showsDislikes ? await ReturnDislike.dislikes(for: videoId) : nil
        }
        .help(dislikes == nil ? "" : "Dislikes estimated by Return YouTube Dislike")
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
                .font(.scaled(.subheadline).weight(.semibold))
                .padding(.horizontal, 14)
                .frame(height: 36)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

/// The video's chapters as a row of cards, as YouTube lists them: the frame, the title and where
/// it starts. A card jumps there (starting the video first if another is on); the one playing is
/// marked.
private struct ChapterList: View {
    let chapters: [VideoChapter]
    let video: Video
    let playback: VideoPlayback

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Chapters").font(.scaled(.headline))
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                        ChapterCard(chapter: chapter, isCurrent: isCurrent(index)) {
                            playback.play(video, startingAt: chapter.start)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }

    private func isCurrent(_ index: Int) -> Bool {
        guard playback.current?.id == video.id else { return false }
        let end = index + 1 < chapters.count ? chapters[index + 1].start : .infinity
        return playback.time >= chapters[index].start && playback.time < end
    }
}

private struct ChapterCard: View {
    let chapter: VideoChapter
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Rectangle()
                    .fill(.quaternary)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        if let thumbnail = chapter.thumbnail {
                            ArtworkView(artwork: thumbnail, size: 168, cornerRadius: 0, fillsFrame: true)
                        }
                    }
                    .clipShape(.rect(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: isCurrent ? 2.5 : 0)
                    }
                Text(chapter.title)
                    .font(.scaled(.subheadline).weight(.semibold))
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                Text(VideoScrubber.format(chapter.start))
                    .font(.scaled(.caption).monospacedDigit())
                    .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
            }
            .frame(width: CGFloat(168).scaled)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(chapter.title), at \(VideoScrubber.format(chapter.start))")
    }
}

/// Views and date, then the description, three lines until it's opened. Its links open and its
/// times jump the video there (`richLinks`).
private struct VideoDescription: View {
    let page: WatchPage
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text([page.viewCount ?? page.video.views, expanded ? page.date : page.video.published ?? page.date].compactMap { $0 }.joined(separator: " · "))
                .font(.scaled(.subheadline).weight(.semibold))
            if !page.description.isEmpty {
                Text(page.richDescription.attributed)
                    .font(.scaled(.subheadline))
                    .lineLimit(expanded ? nil : 3)
                    .textSelection(.enabled)
                Text(expanded ? "Show Less" : "Show More")
                    .font(.scaled(.subheadline).weight(.semibold))
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
                    Text("Comments").font(.scaled(.subheadline).weight(.semibold))
                    if let count { Text(count).font(.scaled(.subheadline)).foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.scaled(.footnote).weight(.semibold)).foregroundStyle(.tertiary)
                }
                HStack(alignment: .top, spacing: 10) {
                    CommentAvatar(url: top?.avatar, size: 24)
                    Text(top?.text ?? "A comment that runs to two lines while it loads, about the video.")
                        .font(.scaled(.subheadline))
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

/// All of a video's comments, top first, paging as they're scrolled; a comment's replies open
/// under it. On the iPhone the sheet rests under the player (`dockedUnderPlayer`), so the video
/// plays on above it and a time tapped in a comment is seen to land. Signed in, the field along the bottom posts a comment or a reply, comments can be
/// liked, and the account's own deleted (swipe, or the menu). Times in a comment jump the video.
struct CommentsSheet: View {
    let model: CommentsModel
    let count: String?
    /// The video the comments are under: a time in one seeks it.
    let videoId: String
    let docked: PresentationDetent?
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var detent: PresentationDetent
    @State private var draft = ""
    @State private var replyingTo: VideoComment?
    @State private var deleting: VideoComment?
    @FocusState private var isComposing: Bool

    init(model: CommentsModel, count: String?, videoId: String, docked: PresentationDetent? = nil) {
        self.model = model
        self.count = count
        self.videoId = videoId
        self.docked = docked
        _detent = State(initialValue: docked ?? .medium)
    }

    private var canWrite: Bool {
        let profile = app.roster.active
        return profile.isSignedIn && !profile.isExpired
    }

    private var canSend: Bool {
        !model.isSending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

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
            .safeAreaBar(edge: .bottom) {
                // YouTube hands the means to post only to an account, and not with comments closed.
                if canWrite, model.createParams != nil || replyingTo != nil { composer }
            }
        }
        .richLinks(videoId: videoId, leaving: { dismiss() })
        .dockedUnderPlayer(docked, detent: $detent)
        // Typing wants the room: the keyboard would leave a docked sheet a sliver.
        .onChange(of: isComposing) { _, composing in
            if composing { detent = .large }
        }
        .frame(minWidth: Platform.isMac ? 520 : nil, minHeight: Platform.isMac ? 620 : nil)
        .task { await model.loadIfNeeded(music: app.music) }
        .confirmationDialog("Delete Comment?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { comment in
            Button("Delete", role: .destructive) { Task { await model.delete(comment, app: app) } }
        } message: { _ in
            Text("It's removed from YouTube for everyone.")
        }
        .alert("Couldn't Reach YouTube", isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.failure ?? "")
        }
    }

    private func list(_ comments: [VideoComment]) -> some View {
        List {
            ForEach(comments) { comment in
                row(comment, isReply: false)
                if let thread = model.replies[comment.id], thread.isOpen {
                    ForEach(thread.comments) { reply in
                        row(reply, isReply: true)
                    }
                    if thread.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .listRowSeparator(.hidden)
                    } else if thread.continuation != nil {
                        Button("Show More Replies") { Task { await model.loadReplies(of: comment.id, music: app.music) } }
                            .font(.scaled(.footnote).weight(.semibold))
                            .buttonStyle(.borderless)
                            .padding(.leading, CommentRow.replyIndent)
                            .listRowSeparator(.hidden)
                    }
                }
            }
            if model.canLoadMore {
                LoadMoreTrigger { await model.loadMore(music: app.music) }
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
    }

    private func row(_ comment: VideoComment, isReply: Bool) -> some View {
        CommentRow(comment: comment, isReply: isReply, thread: isReply ? nil : model.replies[comment.id], canWrite: canWrite,
                   like: { Task { await model.toggleLike(comment, app: app) } },
                   reply: {
                       replyingTo = comment
                       isComposing = true
                   },
                   toggleReplies: { Task { await model.toggleReplies(of: comment, music: app.music) } })
            .listRowSeparator(.hidden)
            .contextMenu {
                Button("Copy", systemImage: "doc.on.doc") { PlatformImages.copy(comment.text) }
                if comment.deleteAction != nil {
                    Button("Delete", systemImage: "trash", role: .destructive) { deleting = comment }
                }
            }
            .swipeActions(edge: .trailing) {
                // Asked about first, so no destructive role: that would pull the row out at once.
                if comment.deleteAction != nil {
                    Button("Delete", systemImage: "trash") { deleting = comment }.tint(.red)
                }
            }
    }

    /// The field a comment or a reply is typed in, with who it answers above it.
    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let replyingTo {
                HStack(spacing: 6) {
                    Text("Replying to \(replyingTo.author)")
                        .font(.scaled(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button("Cancel Reply", systemImage: "xmark.circle.fill") { self.replyingTo = nil }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(replyingTo == nil ? "Add a comment" : "Add a reply", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($isComposing)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20, style: .continuous))
                Button(action: send) {
                    if model.isSending {
                        ProgressView().frame(width: 36, height: 36)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.scaledSystem(size: 32))
                            .frame(width: 36, height: 36)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSend ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                .disabled(!canSend)
                .accessibilityLabel(replyingTo == nil ? "Post Comment" : "Post Reply")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func send() {
        let text = draft
        let parent = replyingTo
        Task {
            guard await model.post(text, replyingTo: parent, app: app) else { return }
            draft = ""
            replyingTo = nil
            isComposing = false
        }
    }
}

/// One comment, or a reply set in under the comment it answers: who wrote it, the text with its
/// links, and its likes, Reply and replies.
private struct CommentRow: View {
    let comment: VideoComment
    var isReply = false
    /// Its replies as opened so far; nil for a reply or a thread never opened.
    var thread: CommentsModel.Replies?
    var canWrite = false
    var like: () -> Void = {}
    var reply: () -> Void = {}
    var toggleReplies: () -> Void = {}

    static let replyIndent: CGFloat = 46

    private var likes: String { comment.isLiked ? comment.likesIfLiked : comment.likes }

    private var repliesTitle: String {
        switch comment.replies {
        case "": "Replies"
        case "1": "1 reply"
        default: "\(comment.replies) replies"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CommentAvatar(url: comment.avatar, size: isReply ? 26 : 34)
            VStack(alignment: .leading, spacing: 4) {
                if comment.isPinned {
                    Label("Pinned", systemImage: "pin.fill")
                        .font(.scaled(.caption2))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Text(comment.author)
                        .font(.scaled(.footnote).weight(.semibold))
                        .padding(.horizontal, comment.isCreator ? 6 : 0)
                        .padding(.vertical, comment.isCreator ? 1 : 0)
                        .background(comment.isCreator ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.clear), in: .capsule)
                    if comment.isVerified {
                        Image(systemName: "checkmark.seal.fill").font(.scaled(.caption2)).foregroundStyle(.secondary)
                            .accessibilityLabel("Verified")
                    }
                    Text("· \(comment.published)").font(.scaled(.footnote)).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Text(comment.content.attributed)
                    .font(.scaled(.subheadline))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                actions
            }
        }
        .padding(.leading, isReply ? Self.replyIndent : 0)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    private var actions: some View {
        HStack(spacing: Platform.isMac ? 18 : 22) {
            if comment.likeAction != nil || comment.unlikeAction != nil {
                Button(action: like) {
                    Label(likes.isEmpty ? "Like" : likes, systemImage: comment.isLiked ? "hand.thumbsup.fill" : "hand.thumbsup")
                        .contentTransition(.symbolEffect(.replace))
                        .touchTarget()
                }
                .tint(comment.isLiked ? Color.accentColor : .secondary)
                .sensoryFeedback(.impact(weight: .light), trigger: comment.isLiked)
                .accessibilityLabel(comment.isLiked ? "Remove Like" : "Like")
                .accessibilityValue(likes)
            } else {
                Label(likes.isEmpty ? "0" : likes, systemImage: "hand.thumbsup")
            }
            if comment.isHearted {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.red)
                    .accessibilityLabel("Loved by the creator")
            }
            if canWrite, comment.replyParams != nil {
                Button(action: reply) { Text("Reply").touchTarget() }.tint(.secondary)
            }
            if !isReply, comment.repliesToken != nil || thread?.comments.isEmpty == false {
                Button(action: toggleReplies) {
                    HStack(spacing: 4) {
                        Text(repliesTitle)
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(thread?.isOpen == true ? 180 : 0))
                    }
                    .fontWeight(.semibold)
                    .touchTarget()
                }
                .accessibilityHint(thread?.isOpen == true ? "Hides the replies" : "Shows the replies")
            }
        }
        .font(.scaled(Platform.isMac ? .caption : .footnote))
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        // Borderless, so each takes its own taps inside the list row.
        .buttonStyle(.borderless)
        .padding(.top, Platform.isMac ? 2 : 0)
    }
}

/// What plays after this video, in full, as Music lays out its queue: the video that's on, the
/// listener's queue (tap one to play it now, hold and drag to reorder, swipe to remove), then
/// YouTube's own pick with the Autoplay switch. On the iPhone it rests under the player.
struct VideoQueueSheet: View {
    let playback: VideoPlayback
    let docked: PresentationDetent?
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var detent: PresentationDetent

    init(playback: VideoPlayback, docked: PresentationDetent? = nil) {
        self.playback = playback
        self.docked = docked
        _detent = State(initialValue: docked ?? .medium)
    }

    var body: some View {
        @Bindable var settings = app.settings
        NavigationStack {
            List {
                if let current = playback.current {
                    Section("Now Playing") {
                        VideoRow(video: current, thumbnailWidth: 112)
                            .listRowSeparator(.hidden)
                    }
                }
                Section("Next in Queue") {
                    ForEach(playback.queue) { video in
                        Button {
                            playback.playFromQueue(video)
                        } label: {
                            VideoRow(video: video, thumbnailWidth: 112)
                        }
                        .buttonStyle(.plain)
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button("Remove", systemImage: "minus.circle") { playback.removeFromQueue([video.id]) }
                                .tint(.red)
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { playback.queueNext(video) }
                                .tint(.indigo)
                        }
                        .contextMenu {
                            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { playback.queueNext(video) }
                            Button("Remove from Queue", systemImage: "minus.circle", role: .destructive) { playback.removeFromQueue([video.id]) }
                        }
                    }
                    .onMove { playback.moveQueue(fromOffsets: $0, toOffset: $1) }
                    if playback.queue.isEmpty {
                        Text("Choose Play Next or Add to Queue from any video's menu.")
                            .font(.scaled(.subheadline))
                            .foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                    }
                }
                if let suggested = playback.suggested {
                    Section {
                        VideoRow(video: suggested, thumbnailWidth: 112)
                            .opacity(settings.autoplaysVideos ? 1 : 0.45)
                            .listRowSeparator(.hidden)
                    } header: {
                        Toggle(playback.queue.isEmpty ? "Autoplay" : "Autoplay After the Queue", isOn: $settings.autoplaysVideos)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Queue")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear") { withAnimation { playback.clearQueue() } }
                        .disabled(playback.queue.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .dockedUnderPlayer(docked, detent: $detent)
        .frame(minWidth: Platform.isMac ? 480 : nil, minHeight: Platform.isMac ? 520 : nil)
    }
}

/// The queue within the thumb's reach on the iPhone's watch page: what's next and how many
/// wait, along the bottom; a tap opens the whole queue.
private struct QueueBar: View {
    let next: Video
    let count: Int
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                VideoThumbnail(video: next, cornerRadius: 7, width: 72, showsProgress: false)
                    .frame(width: 72)
                VStack(alignment: .leading, spacing: 1) {
                    Text(count == 1 ? "Next in Queue" : "Next in Queue · \(count) Videos")
                        .font(.scaled(.caption).weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(next.title)
                        .font(.scaled(.subheadline).weight(.semibold))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.up")
                    .font(.scaled(.footnote).weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 6)
            }
            .padding(8)
            .contentShape(.rect(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .accessibilityLabel("Queue, \(count) \(count == 1 ? "video" : "videos"). Next: \(next.title)")
    }
}

extension View {
    /// A sheet of the watch page's. On the iPhone it rests in the space under the player
    /// (`docked`, measured by the page), where the video stays in sight and its controls still
    /// take touches, and scrolling moves its list rather than the sheet; pulled up by its bar it
    /// covers the page. The Mac shows it large.
    func dockedUnderPlayer(_ docked: PresentationDetent?, detent: Binding<PresentationDetent>) -> some View {
        modifier(DockedSheet(docked: docked, detent: detent))
    }
}

private struct DockedSheet: ViewModifier {
    let docked: PresentationDetent?
    @Binding var detent: PresentationDetent

    func body(content: Content) -> some View {
        if Platform.isMac {
            content.presentationDetents([.large])
        } else {
            let rest = docked ?? .medium
            content
                .presentationDetents([rest, .large], selection: $detent)
                .presentationBackgroundInteraction(.enabled(upThrough: rest))
                .presentationContentInteraction(.scrolls)
                .presentationDragIndicator(.visible)
        }
    }
}

private extension View {
    /// Room for a finger around a small text button on the iPhone, without spreading the row.
    func touchTarget() -> some View {
        frame(minHeight: Platform.isMac ? nil : 34).contentShape(.rect)
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
