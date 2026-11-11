import KodaCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The top of an album or playlist page.
struct CollectionHeader: View {
    let artwork: Artwork?
    let title: String
    var byline: String?
    /// The artists behind the byline, to open from it.
    var bylineArtists: [ArtistRef] = []
    var openArtist: (ArtistSummary) -> Void = { _ in }
    var detail: String?
    var description: String?
    var accent: Color
    var shuffleTitle = "Shuffle"
    let play: () -> Void
    let shuffle: () -> Void

    @State private var expanded = false
    @Environment(\.colorScheme) private var colorScheme

    /// The cover's colour, made readable on this background: a colourless cover's would be
    /// white or grey, so Koda's accent stands in; light mode darkens a bright one, dark mode
    /// lightens a deep one.
    private var readableAccent: Color {
        guard case let (h, s, b)? = accent.hsb, s >= 0.2 else { return .accentColor }
        return colorScheme == .dark
            ? Color(hue: h, saturation: min(s, 0.7), brightness: max(b, 0.85))
            : Color(hue: h, saturation: max(s, 0.6), brightness: min(b, 0.5))
    }

    var body: some View {
        VStack(spacing: 14) {
            ArtworkView(artwork: artwork, size: 248, cornerRadius: 14)
                .shadow(color: .black.opacity(0.25), radius: 24, y: 12)
                .padding(.bottom, 4)
            VStack(spacing: 4) {
                Text(title)
                    .font(.scaled(.title2).bold())
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                if let byline, !byline.isEmpty {
                    let opens = !ArtistRef.linked(bylineArtists).isEmpty
                    ArtistLinks(line: byline, artists: bylineArtists, open: openArtist) {
                        Text(byline).font(.scaled(.title3)).foregroundStyle(opens ? readableAccent : .secondary).lineLimit(1)
                    }
                }
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.scaled(.footnote).weight(.medium))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }
            }
            .padding(.horizontal, 24)
            PlayShuffleButtons(shuffleTitle: shuffleTitle, play: play, shuffle: shuffle)
                .padding(.horizontal, 20)
                .padding(.top, 4)
            if let description, !description.isEmpty {
                Text(description)
                    .font(.scaled(.footnote))
                    .foregroundStyle(.secondary)
                    .lineLimit(expanded ? nil : 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .contentShape(.rect)
                    .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
                    .accessibilityHint(expanded ? "Collapses the description" : "Shows the whole description")
            }
        }
        .padding(.top, 8)
    }
}

/// A wash of the cover's colour behind the top of a page, fading into the background.
struct ArtworkGlow: View {
    let palette: Palette

    var body: some View {
        LinearGradient(
            colors: [palette.mesh[1].opacity(0.55), palette.mesh[4].opacity(0.25), .clear],
            startPoint: .top, endPoint: .bottom)
            .frame(height: 520)
            .frame(maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
