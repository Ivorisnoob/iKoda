import KodaCore
import SwiftUI

/// A channel: its banner, picture, name and counts, Subscribe, what it says about itself, and its
/// videos newest first, paging as they're scrolled.
struct ChannelView: View {
    let channelId: String
    let name: String
    @Environment(AppModel.self) private var app
    @State private var model: ChannelModel

    init(channelId: String, name: String) {
        self.channelId = channelId
        self.name = name
        _model = State(initialValue: ChannelModel(channelId: channelId))
    }

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                content(ChannelPage(channel: ChannelSummary(id: channelId, name: name, handle: "@channel", subscribers: "1M subscribers"),
                                    banner: nil, description: "A line or two about the channel.", videoCount: "100 videos",
                                    isSubscribed: false, videos: VideoPage(videos: Video.placeholders)))
                    .loadingPlaceholder()
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't Load Channel", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await model.load(music: app.music) } }.buttonStyle(.glass)
                }
            case .loaded(let page):
                content(page)
            }
        }
        .navigationTitle(model.state.value?.channel.name ?? name)
        .task { if model.state.value == nil { await model.load(music: app.music) } }
    }

    @ViewBuilder
    private func content(_ page: ChannelPage) -> some View {
        if Platform.isMac {
            MacPage(spacing: 28) {
                header(page).padding(.horizontal, MacMetrics.gutter)
                MacSectionTitle(title: "Videos").padding(.horizontal, MacMetrics.gutter)
                VideoCardGrid(videos: page.videos.videos, showsChannel: false)
                more(page)
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    header(page)
                    Text("Videos").font(.title3.bold())
                    ForEach(page.videos.videos) { video in
                        NavigationLink(value: Route.video(video)) { VideoCard(video: video, width: 420, showsChannel: false) }
                            .buttonStyle(.plain)
                    }
                    more(page)
                }
                .padding(.horizontal, VideoMetrics.side)
                .padding(.vertical, 12)
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private func more(_ page: ChannelPage) -> some View {
        if page.videos.continuation != nil {
            ProgressView()
                .frame(maxWidth: .infinity)
                .task { await model.loadMore(music: app.music) }
        }
    }

    private func header(_ page: ChannelPage) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let banner = page.banner {
                Color.clear
                    .aspectRatio(Platform.isMac ? 6.2 : 4, contentMode: .fit)
                    .overlay { ArtworkView(artwork: banner, size: 1200, cornerRadius: 16, fillsFrame: true) }
                    .clipShape(.rect(cornerRadius: 16, style: .continuous))
            }
            HStack(alignment: .center, spacing: 16) {
                ChannelAvatar(avatar: page.channel.avatar, size: Platform.isMac ? 96 : 76)
                VStack(alignment: .leading, spacing: 4) {
                    Text(page.channel.name)
                        .font(Platform.isMac ? .largeTitle.bold() : .title2.bold())
                        .lineLimit(2)
                    Text([page.channel.handle, page.channel.subscribers, page.videoCount].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                if Platform.isMac {
                    SubscribeButton(channelId: page.channel.id, isSubscribed: $model.isSubscribed)
                        .controlSize(.large)
                }
            }
            if !Platform.isMac {
                SubscribeButton(channelId: page.channel.id, isSubscribed: $model.isSubscribed)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
            }
            if let description = page.description {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
    }
}
