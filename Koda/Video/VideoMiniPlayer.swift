import AVFoundation
import KodaCore
import SwiftUI

/// The video carrying on after its page was left: the iPhone's tab bar accessory. The picture
/// keeps moving in a small frame beside the title; a tap goes back to the page, the buttons play,
/// pause and close. It takes over picture in picture while the page is away, so leaving the app
/// from here floats the video as it would from the page.
struct VideoMiniPlayer: View {
    let playback: VideoPlayback
    let open: () -> Void
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    private var isInline: Bool { placement == .inline }

    var body: some View {
        if let video = playback.current {
            HStack(spacing: 12) {
                HStack(spacing: 12) {
                    picture(video)
                        .frame(width: isInline ? 46 : 64, height: isInline ? 26 : 36)
                        .clipShape(.rect(cornerRadius: isInline ? 5 : 7, style: .continuous))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(video.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if !isInline {
                            Text(subtitle(video))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .contentTransition(.numericText(countsDown: true))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(.rect)
                .onTapGesture(perform: open)

                if playback.isLoading {
                    ProgressView().frame(width: 36, height: 36)
                } else {
                    Button {
                        if playback.autoplayCountdown != nil { playback.playNext() } else { playback.togglePlay() }
                    } label: {
                        Image(systemName: playback.hasEnded && playback.autoplayCountdown == nil ? "arrow.counterclockwise"
                              : playback.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 20))
                            .contentTransition(.symbolEffect(.replace.downUp))
                            .frame(width: 36, height: 36)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
                }
                if !isInline {
                    Button {
                        withAnimation(.smooth) { playback.stop() }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 36, height: 36)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close Video")
                }
            }
            .padding(.leading, 6)
            .padding(.trailing, 8)
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: "Open Video", open)
        }
    }

    @ViewBuilder
    private func picture(_ video: Video) -> some View {
        if playback.player.currentItem != nil {
            VideoSurface(player: playback.player, role: .mini, register: playback.register)
        } else {
            VideoThumbnail(video: video, cornerRadius: 0, width: 120, showsProgress: false)
        }
    }

    private func subtitle(_ video: Video) -> String {
        if let seconds = playback.autoplayCountdown, let next = playback.upNext {
            return "Up next in \(seconds): \(next.title)"
        }
        return video.channel?.name ?? ""
    }
}

/// The Mac's bar for a video playing while its page is away, where the songs' player bar sits:
/// the picture, what it is, skip, play/pause and how far it's got, and close. A click on the
/// picture or title goes back to the page.
struct MacVideoBar: View {
    let playback: VideoPlayback
    let open: () -> Void

    var body: some View {
        if let video = playback.current {
            HStack(spacing: 14) {
                Button(action: open) {
                    HStack(spacing: 12) {
                        Group {
                            if playback.player.currentItem != nil {
                                VideoSurface(player: playback.player, role: .mini, register: playback.register)
                            } else {
                                VideoThumbnail(video: video, cornerRadius: 0, width: 160, showsProgress: false)
                            }
                        }
                        .frame(width: 80, height: 45)
                        .clipShape(.rect(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(video.title).font(.headline).lineLimit(1)
                            Text(playback.autoplayCountdown.map { "Up next in \($0)" } ?? video.channel?.name ?? "")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(minWidth: 0, maxWidth: 360, alignment: .leading)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Back to the Video")

                Spacer(minLength: 8)

                HStack(spacing: 18) {
                    if !playback.isLive {
                        Button("Back 10 Seconds", systemImage: "gobackward.10") { playback.skip(by: -10) }
                    }
                    Button(playback.isPlaying ? "Pause" : "Play", systemImage: playback.isPlaying ? "pause.fill" : "play.fill") {
                        if playback.autoplayCountdown != nil { playback.playNext() } else { playback.togglePlay() }
                    }
                    .font(.system(size: 22))
                    .contentTransition(.symbolEffect(.replace))
                    if !playback.isLive {
                        Button("Forward 10 Seconds", systemImage: "goforward.10") { playback.skip(by: 10) }
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(.system(size: 17, weight: .medium))

                if !playback.isLive, playback.duration > 0 {
                    ProgressView(value: min(playback.time, playback.duration), total: playback.duration)
                        .progressViewStyle(.linear)
                        .frame(width: 140)
                        .tint(.primary)
                        .accessibilityLabel("Playback position")
                }

                Button("Close Video", systemImage: "xmark") { withAnimation(.smooth) { playback.stop() } }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .help("Close Video")
            }
            .padding(.horizontal, 12)
            .frame(height: 68)
            .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }
}
