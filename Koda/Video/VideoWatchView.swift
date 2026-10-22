import AVFoundation
import KodaCore
import SwiftUI
import UIKit

/// A video playing, with its details, its channel and Up Next.
///
/// iPhone: no bar; the video sits right under the status bar with its back button on it (the
/// edge swipe still goes back), the tab bar steps away, and the details and Up Next scroll under
/// the video. Turning the phone sideways takes a landscape video full screen.
/// Mac: the window's toolbar as usual; a wide window puts Up Next in a column of its own.
struct VideoWatchView: View {
    let video: Video
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var watch: WatchModel
    @State private var width: CGFloat = 0

    init(video: Video) {
        self.video = video
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
        .fullScreenCover(isPresented: $playback.isFullScreen) {
            FullScreenVideoView(playback: playback, video: shown)
        }
        .task {
            playback.play(video)
            await watch.load(music: app.music)
            if let page = watch.state.value { playback.update(page.video.merged(over: video)) }
        }
        .onDisappear {
            // Another video's page took over, or the video went to picture in picture: leave it be.
            if playback.current?.id == video.id, !playback.isInPictureInPicture, !playback.isFullScreen { playback.pause() }
        }
    }

    // MARK: iPhone

    private var phoneBody: some View {
        VStack(spacing: 0) {
            VideoPlayerView(playback: playback, video: shown, onBack: { dismiss() })
                .aspectRatio(16 / 9, contentMode: .fit)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    details
                    upNext
                }
                .padding(.horizontal, VideoMetrics.side)
                .padding(.vertical, 16)
            }
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
        let wide = width >= 1020
        return Group {
            if wide {
                HStack(alignment: .top, spacing: 28) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
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
                    VStack(alignment: .leading, spacing: 18) {
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
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: video.watchURL, subject: Text(shown.title)) { Label("Share", systemImage: "square.and.arrow.up") }
            }
        }
    }

    private var macPlayer: some View {
        VideoPlayerView(playback: playback, video: shown)
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 14, style: .continuous))
    }

    // MARK: Parts

    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(shown.title)
                .font(Platform.isMac ? .title2.bold() : .title3.bold())
                .textSelection(.enabled)
            if let page = watch.state.value {
                ChannelLine(channel: shown.channel, subscribers: page.subscribers, isSubscribed: $watch.isSubscribed)
                if !Platform.isMac {
                    ShareLink(item: video.watchURL, subject: Text(shown.title)) {
                        Label("Share", systemImage: "square.and.arrow.up").font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.glass)
                }
                VideoDescription(page: page)
            } else if case .failed(let message) = watch.state {
                Text(message).font(.subheadline).foregroundStyle(.secondary)
            } else {
                ChannelLine(channel: shown.channel ?? ChannelRef(id: nil, name: "Channel name"), subscribers: "1M subscribers",
                            isSubscribed: .constant(false))
                    .loadingPlaceholder()
            }
        }
    }

    @ViewBuilder
    private var upNext: some View {
        if let page = watch.state.value, !page.related.videos.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Up Next").font(.headline)
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(page.related.videos) { related in
                        NavigationLink(value: Route.video(related)) {
                            VideoRow(video: related, thumbnailWidth: Platform.isMac ? 168 : 156)
                        }
                        .buttonStyle(.plain)
                    }
                    if page.related.continuation != nil {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .task { await watch.loadMore(music: app.music) }
                    }
                }
            }
        }
    }
}

/// The channel under a video: its picture, name and subscribers, opening its page, and Subscribe
/// for a signed-in profile.
private struct ChannelLine: View {
    let channel: ChannelRef?
    let subscribers: String?
    @Binding var isSubscribed: Bool

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
                    SubscribeButton(channelId: id, isSubscribed: $isSubscribed)
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

/// Subscribe or Subscribed, sent to the signed-in account; hidden for a device profile.
struct SubscribeButton: View {
    let channelId: String
    @Binding var isSubscribed: Bool
    @Environment(AppModel.self) private var app
    @State private var isSending = false

    var body: some View {
        let profile = app.roster.active
        if profile.isSignedIn, !profile.isExpired {
            Button {
                let target = !isSubscribed
                isSubscribed = target
                isSending = true
                Task {
                    if await !app.setSubscribed(channelId, target) { isSubscribed = !target }
                    isSending = false
                }
            } label: {
                Text(isSubscribed ? "Subscribed" : "Subscribe")
                    .font(.subheadline.weight(.semibold))
                    .contentTransition(.identity)
            }
            .buttonStyle(isSubscribed ? AnyPrimitiveButtonStyle(.glass) : AnyPrimitiveButtonStyle(.glassProminent))
            .disabled(isSending)
            .sensoryFeedback(.success, trigger: isSubscribed) { _, now in now }
        }
    }
}

/// Views and date, then the description, three lines until it's opened. Links in it open.
private struct VideoDescription: View {
    let page: WatchPage
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text([page.viewCount ?? page.video.views, expanded ? page.date : page.video.published].compactMap { $0 }.joined(separator: " · "))
                .font(.subheadline.weight(.semibold))
            if !page.description.isEmpty {
                Text(Self.linked(page.description))
                    .font(.subheadline)
                    .lineLimit(expanded ? nil : 3)
                    .textSelection(.enabled)
                Button(expanded ? "Show Less" : "Show More") {
                    withAnimation(.snappy) { expanded.toggle() }
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderless)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.fill.quinary, in: .rect(cornerRadius: 16, style: .continuous))
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
