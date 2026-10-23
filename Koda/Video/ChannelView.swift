import KodaCore
import SwiftUI
import UIKit

/// A channel: its banner, picture, name and counts, Subscribe, what it says about itself (the
/// About sheet), and its videos or live streams, newest first or in another order, paging as
/// they're scrolled.
///
/// iPhone: the banner runs under the status bar as the artist page's photo does, fading into the
/// page, with the channel's picture over its foot; a channel without one gets a field of its
/// picture's colours instead. Mac: the banner as a wide strip over the header, then a grid.
struct ChannelView: View {
    let channelId: String
    let name: String
    @Environment(AppModel.self) private var app
    @State private var model: ChannelModel
    @State private var palette = PaletteModel()
    @State private var showsAbout = false

    private let bannerHeight: CGFloat = 190

    init(channelId: String, name: String) {
        self.channelId = channelId
        self.name = name
        _model = State(initialValue: ChannelModel(channelId: channelId))
    }

    private var placeholder: ChannelPage {
        ChannelPage(channel: ChannelSummary(id: channelId, name: name, handle: "@channel", subscribers: "1M subscribers"),
                    banner: nil, description: "A line or two about the channel, while it loads.", videoCount: "100 videos",
                    isSubscribed: nil, videos: VideoPage(videos: Video.placeholders))
    }

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                content(placeholder, isPlaceholder: true)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't Load Channel", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await model.load(music: app.music) } }.buttonStyle(.glass)
                }
            case .loaded(let page):
                content(page, isPlaceholder: false)
            }
        }
        .navigationTitle(model.state.value?.channel.name ?? name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: URL(string: "https://www.youtube.com/channel/\(channelId)")!) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        }
        .sheet(isPresented: $showsAbout) {
            if let page = model.state.value {
                ChannelAboutSheet(page: page, model: model).appEnvironment(app)
            }
        }
        .task { if model.state.value == nil { await model.load(music: app.music) } }
        .task(id: model.state.value?.channel.avatar?.url) { await palette.load(model.state.value?.channel.avatar) }
    }

    @ViewBuilder
    private func content(_ page: ChannelPage, isPlaceholder: Bool) -> some View {
        if Platform.isMac {
            MacPage(spacing: 24) {
                macHeader(page, isPlaceholder: isPlaceholder).padding(.horizontal, MacMetrics.gutter)
                tabBar(page).padding(.horizontal, MacMetrics.gutter)
                VideoCardGrid(videos: page.videos.videos, showsChannel: false)
                    .opacity(model.isSwitching ? 0.45 : 1)
                    .redacted(reason: isPlaceholder ? .placeholder : [])
                more(page)
            }
            .animation(.smooth(duration: 0.2), value: model.isSwitching)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    phoneHeader(page, isPlaceholder: isPlaceholder)
                    VStack(alignment: .leading, spacing: 18) {
                        tabBar(page)
                        LazyVStack(alignment: .leading, spacing: 24) {
                            ForEach(page.videos.videos) { video in
                                NavigationLink(value: Route.video(video)) { VideoCard(video: video, width: 420, showsChannel: false) }
                                    .buttonStyle(.plain)
                                    .contextMenu { ShareLink(item: video.watchURL, subject: Text(video.title)) { Label("Share", systemImage: "square.and.arrow.up") } }
                            }
                            more(page)
                        }
                        .opacity(model.isSwitching ? 0.45 : 1)
                        .animation(.smooth(duration: 0.2), value: model.isSwitching)
                    }
                    .padding(.horizontal, VideoMetrics.side)
                    .redacted(reason: isPlaceholder ? .placeholder : [])
                    .allowsHitTesting(!isPlaceholder)
                }
                .padding(.bottom, 32)
            }
            .ignoresSafeArea(edges: .top)
            .navigationBarTitleDisplayMode(.inline)
            .revealsTitle(page.channel.name, after: bannerHeight + 60)
            .refreshable { await model.load(music: app.music, fresh: true) }
        }
    }

    // MARK: iPhone

    private func phoneHeader(_ page: ChannelPage, isPlaceholder: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            backdrop(page)
                .frame(height: bannerHeight)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .bottom) {
                    // The banner fades into the page rather than ending on a hard edge.
                    LinearGradient(colors: [.clear, Color(uiColor: .systemBackground)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 70)
                }
                .clipped()
            VStack(alignment: .leading, spacing: 14) {
                ChannelAvatar(avatar: page.channel.avatar, size: 84)
                    .overlay(Circle().strokeBorder(Color(uiColor: .systemBackground), lineWidth: 3))
                    .padding(.top, -50)
                identity(page, nameFont: .title.bold())
                if let description = page.description {
                    Button { showsAbout = true } label: {
                        HStack(alignment: .lastTextBaseline, spacing: 4) {
                            Text(description)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(page.aboutToken == nil)
                    .accessibilityHint("Shows what the channel says about itself")
                }
                HStack(spacing: 10) {
                    SubscribeButton(channelId: page.channel.id, pageSubscribed: page.isSubscribed)
                        .controlSize(.large)
                    if page.aboutToken != nil {
                        Button("About", systemImage: "info.circle") { showsAbout = true }
                            .buttonStyle(.glass)
                            .controlSize(.large)
                    }
                }
            }
            .padding(.horizontal, VideoMetrics.side)
            .redacted(reason: isPlaceholder ? .placeholder : [])
        }
    }

    /// The banner, or the channel picture's colours where there is none.
    @ViewBuilder
    private func backdrop(_ page: ChannelPage) -> some View {
        if let banner = page.banner {
            Color.clear.overlay { ArtworkView(artwork: banner, size: 1200, cornerRadius: 0, fillsFrame: true) }
        } else {
            let colors = palette.palette.mesh
            LinearGradient(colors: [colors.first ?? .gray, colors.last ?? .gray], startPoint: .topLeading, endPoint: .bottomTrailing)
                .opacity(0.85)
        }
    }

    /// Name and tick, then handle, subscribers and video count.
    private func identity(_ page: ChannelPage, nameFont: Font) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(page.channel.name)
                    .font(nameFont)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .textSelection(.enabled)
                if page.isVerified {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Verified")
                }
            }
            Text([page.channel.handle, page.channel.subscribers, page.videoCount].compactMap { $0 }.joined(separator: " · "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    // MARK: Mac

    private func macHeader(_ page: ChannelPage, isPlaceholder: Bool) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            if page.banner != nil || isPlaceholder {
                Color.clear
                    .aspectRatio(6.2, contentMode: .fit)
                    .overlay { backdrop(page) }
                    .clipShape(.rect(cornerRadius: 16, style: .continuous))
            }
            HStack(alignment: .center, spacing: 20) {
                ChannelAvatar(avatar: page.channel.avatar, size: 104)
                VStack(alignment: .leading, spacing: 10) {
                    identity(page, nameFont: .largeTitle.bold())
                    if let description = page.description {
                        Text(description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .frame(maxWidth: 640, alignment: .leading)
                    }
                    HStack(spacing: 10) {
                        SubscribeButton(channelId: page.channel.id, pageSubscribed: page.isSubscribed)
                        if page.aboutToken != nil {
                            Button("About", systemImage: "info.circle") { showsAbout = true }
                                .buttonStyle(.glass)
                        }
                    }
                    .controlSize(.large)
                }
                Spacer(minLength: 0)
            }
        }
        .redacted(reason: isPlaceholder ? .placeholder : [])
    }

    // MARK: Parts

    /// Videos or Live, when the channel has both, and the order: Latest, Popular, Oldest.
    @ViewBuilder
    private func tabBar(_ page: ChannelPage) -> some View {
        if page.tabs.count > 1 || !page.sorts.isEmpty {
            HStack(spacing: 12) {
                if page.tabs.count > 1 {
                    Picker("Show", selection: Binding(get: { page.tab }, set: { kind in
                        guard let tab = page.tabs.first(where: { $0.kind == kind }) else { return }
                        Task { await model.open(tab, music: app.music) }
                    })) {
                        ForEach(page.tabs, id: \.kind) { Text($0.kind.title).tag($0.kind) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                } else {
                    Text(page.tab.title).font(.title3.bold())
                }
                Spacer(minLength: 0)
                if !page.sorts.isEmpty {
                    let selected = page.sorts.first { $0.isSelected } ?? page.sorts[0]
                    Menu {
                        Picker("Sort By", selection: Binding(get: { selected.id }, set: { id in
                            guard let sort = page.sorts.first(where: { $0.id == id }) else { return }
                            Task { await model.sort(by: sort, music: app.music) }
                        })) {
                            ForEach(page.sorts) { Text($0.title).tag($0.id) }
                        }
                    } label: {
                        Label(selected.title, systemImage: "arrow.up.arrow.down")
                            .font(.subheadline.weight(.semibold))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.glass)
                    .fixedSize()
                    .accessibilityLabel("Sort By, \(selected.title)")
                }
            }
            .disabled(model.isSwitching)
        }
    }

    @ViewBuilder
    private func more(_ page: ChannelPage) -> some View {
        if page.videos.continuation != nil, page.videos.videos.first?.id.hasPrefix("placeholder") != true {
            ProgressView()
                .frame(maxWidth: .infinity)
                .task { await model.loadMore(music: app.music) }
        } else if page.videos.videos.isEmpty {
            ContentUnavailableView(page.tab == .live ? "No Live Streams" : "No Videos", systemImage: "play.rectangle",
                                   description: Text("Nothing here yet."))
                .frame(maxWidth: .infinity, minHeight: 240)
        }
    }
}

/// What a channel says about itself: its description, links, and when it started and how big it
/// has grown.
private struct ChannelAboutSheet: View {
    let page: ChannelPage
    let model: ChannelModel
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch model.about {
                case .loaded(let about):
                    content(about)
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Couldn't Load About", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try Again") { Task { await model.loadAbout(music: app.music) } }.buttonStyle(.glass)
                    }
                case .loading, nil:
                    content(ChannelAbout(description: page.description ?? "A few lines about the channel.", country: "Country",
                                         subscribers: "1M subscribers", views: "100,000,000 views", joined: "Joined Jan 1, 2010",
                                         videoCount: "100 videos", links: []))
                        .loadingPlaceholder()
                }
            }
            .navigationTitle(page.channel.name)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .presentationDetents(Platform.isMac ? [.large] : [.medium, .large])
        .frame(minWidth: Platform.isMac ? 480 : nil, minHeight: Platform.isMac ? 560 : nil)
        .task { await model.loadAbout(music: app.music) }
    }

    private func content(_ about: ChannelAbout) -> some View {
        List {
            if let description = about.description {
                Section("Description") {
                    Text(description)
                        .font(.subheadline)
                        .textSelection(.enabled)
                }
            }
            if !about.links.isEmpty {
                Section("Links") {
                    ForEach(about.links) { link in
                        Link(destination: link.url) {
                            LabeledContent {
                                Image(systemName: "arrow.up.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            } label: {
                                Text(link.title)
                                Text(link.label)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            Section("Details") {
                if let handle = page.channel.handle { LabeledContent("Handle", value: handle) }
                if let subscribers = about.subscribers { LabeledContent("Subscribers", value: Self.count(subscribers)) }
                if let videos = about.videoCount { LabeledContent("Videos", value: Self.count(videos)) }
                if let views = about.views { LabeledContent("Views", value: Self.count(views)) }
                if let joined = about.joined { LabeledContent("Joined", value: joined.replacingOccurrences(of: "Joined ", with: "")) }
                if let country = about.country { LabeledContent("Country", value: country) }
            }
        }
    }

    /// "21.4M subscribers" → "21.4M": the row already says what it counts.
    private static func count(_ text: String) -> String {
        text.split(separator: " ").first.map(String.init) ?? text
    }
}
