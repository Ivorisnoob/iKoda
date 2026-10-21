import AVKit
import KodaCore
import SwiftUI

struct VideoWatchView: View {
    let video: VideoItem

    @Environment(AppModel.self) private var app
    @Environment(VideoPlayback.self) private var playback
    @Environment(VideoModel.self) private var model
    @State private var showFullDescription = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VideoPlayer(player: playback.player)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 20)

                AsyncContent(state: model.watch, retry: { await model.loadWatch(video.id) }, placeholder: .placeholder) { page in
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(page.video.title)
                                .font(.title3.bold())
                                .lineLimit(3)
                            HStack(spacing: 8) {
                                Text(page.channel.name)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.secondary)
                                if let views = page.viewCountText {
                                    Text("•").foregroundStyle(.secondary)
                                    Text(views).font(.subheadline).foregroundStyle(.secondary)
                                }
                                if let date = page.publishedText {
                                    Text("•").foregroundStyle(.secondary)
                                    Text(date).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            .lineLimit(1)

                            if let description = page.description, !description.isEmpty {
                                Text(description)
                                    .font(.body)
                                    .lineLimit(showFullDescription ? nil : 3)
                                    .foregroundStyle(.primary)
                                Button(showFullDescription ? "Show less" : "Show more") {
                                    withAnimation(.smooth) { showFullDescription.toggle() }
                                }
                                .font(.subheadline.weight(.medium))
                                .buttonStyle(.plain)
                                .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.horizontal, 20)

                        if !page.upNext.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Up next")
                                    .font(.title3.bold())
                                    .padding(.horizontal, 20)
                                LazyVStack(spacing: 0) {
                                    ForEach(page.upNext) { item in
                                        VideoRow(video: item) {
                                            if let idx = page.upNext.firstIndex(where: { $0.id == item.id }) {
                                                playback.play(item, queue: Array(page.upNext[(idx + 1)...]))
                                            } else {
                                                playback.play(item)
                                            }
                                        }
                                        .padding(.horizontal, 20)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .navigationTitle(model.watch.value?.video.title ?? (video.title.isEmpty ? "Video" : video.title))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(VideoQuality.allCases, id: \.self) { q in
                        Button {
                            playback.setQuality(q)
                        } label: {
                            Label(q.title, systemImage: playback.quality == q ? "checkmark" : "")
                        }
                    }
                } label: {
                    Label("Quality", systemImage: "slider.horizontal.3")
                }
                .accessibilityLabel("Quality")
            }
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: URL(string: "https://www.youtube.com/watch?v=\(video.id)")!) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .task {
            if playback.current?.id != video.id {
                playback.play(video)
            }
            await model.loadWatch(video.id)
            if let page = model.watch.value, playback.current?.id == video.id, playback.upNext.isEmpty {
                playback.upNext = page.upNext
            }
        }
    }
}