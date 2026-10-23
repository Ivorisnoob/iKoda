import KodaCore
import SwiftUI

/// One song in a list: cover (or track number), title, byline, and its menu.
struct SongRow: View {
    let song: Song
    var number: Int?
    var showsArtwork = true
    var subtitle: String?
    let action: () -> Void

    @Environment(Player.self) private var player

    private var isCurrent: Bool { player.current?.id == song.id }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                leading
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(.body)
                        .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                        .lineLimit(1)
                    Text(subtitle ?? song.artistLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                DownloadIndicator(song: song)
                if song.isVideo {
                    Image(systemName: "play.rectangle")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("Music video")
                }
            }
            .padding(.vertical, 6)
            .contentShape(.rect)
        }
        .buttonStyle(RowButtonStyle())
        // The row's tap target stops short of the menu button, which sits in the space kept for it.
        .padding(.trailing, 32)
        .overlay(alignment: .trailing) { SongMenuButton(song: song).offset(x: 6) }
        .contextMenu {
            SongMenuItems(song: song)
        } preview: {
            SongPreview(song: song)
        }
    }

    @ViewBuilder
    private var leading: some View {
        if let number, !showsArtwork {
            ZStack {
                if isCurrent {
                    NowPlayingBars(isPlaying: player.wantsToPlay)
                } else {
                    Text("\(number)")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 28)
        } else {
            ArtworkView(artwork: song.artwork, size: 48, cornerRadius: 6)
                .overlay {
                    if isCurrent {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.black.opacity(0.45))
                        NowPlayingBars(isPlaying: player.wantsToPlay).foregroundStyle(.white)
                    }
                }
        }
    }
}

/// The animated bars on the song that is playing.
struct NowPlayingBars: View {
    var isPlaying: Bool

    var body: some View {
        Image(systemName: "waveform")
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .symbolEffect(.variableColor.iterative.reversing, options: .repeat(.continuous), isActive: isPlaying)
            .accessibilityLabel(isPlaying ? "Playing" : "Paused")
    }
}

/// Dims a row while pressed, like a list cell.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.primary.opacity(configuration.isPressed ? 0.08 : 0))
                    .padding(.horizontal, -8)
            }
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// What a long press lifts out of the list.
struct SongPreview: View {
    let song: Song

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ArtworkView(artwork: song.artwork, size: 260, cornerRadius: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).font(.headline).lineLimit(2)
                Text(song.artistLine).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                if let album = song.album?.title {
                    Text(album).font(.subheadline).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
        .padding(16)
        .frame(width: 292)
    }
}
