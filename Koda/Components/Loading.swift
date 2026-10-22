import KodaCore
import SwiftUI

/// A page's data as it loads.
enum LoadState<Value> {
    case loading
    case loaded(Value)
    case failed(String)

    var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }
}

extension Error {
    /// What a listener is told when something did not load.
    var friendlyMessage: String {
        switch self as? MusicError {
        case .network: "Check your connection and try again."
        case .botCheck: "YouTube is refusing requests right now. Try again in a little while."
        case .unplayable(let reason): reason ?? "This isn't available."
        case .badResponse: "YouTube sent something unexpected. Try again."
        case .signedOut: "YouTube signed this account out. Sign in again to continue."
        case .rateLimited: "YouTube is asking Koda to slow down. Try again in a few minutes."
        case nil: "Something went wrong. Try again."
        }
    }
}

/// Loading, failed or loaded, with a retry that re-runs `load`.
///
/// Given a `placeholder`, loading draws the page's own layout from it, redacted: the
/// loading screen then has the loaded page's geometry, and nothing shifts when the
/// real content arrives.
struct AsyncContent<Value, Content: View>: View {
    let state: LoadState<Value>
    var retry: () async -> Void
    var placeholder: Value?
    @ViewBuilder var content: (Value) -> Content

    var body: some View {
        switch state {
        case .loading:
            if let placeholder {
                content(placeholder).loadingPlaceholder()
            } else {
                SongListSkeleton()
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Load", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await retry() } }
                    .buttonStyle(.borderedProminent)
            }
            .frame(minHeight: 300)
        case .loaded(let value):
            content(value)
        }
    }
}

/// Play and Shuffle side by side, in clear glass so the page's colours show through without tinting them.
struct PlayShuffleButtons: View {
    var shuffleTitle = "Shuffle"
    let play: () -> Void
    let shuffle: () -> Void
    @State private var taps = 0

    var body: some View {
        HStack(spacing: 12) {
            Button {
                taps += 1
                play()
            } label: {
                Label("Play", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            Button {
                taps += 1
                shuffle()
            } label: {
                Label(shuffleTitle, systemImage: shuffleTitle == "Shuffle" ? "shuffle" : "dot.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity)
            }
        }
        .font(.body.weight(.semibold))
        .controlSize(.large)
        .buttonStyle(.glass)
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
    }
}

/// Song rows drawn by the real row, redacted, for lists whose shape isn't known yet.
struct SongListSkeleton: View {
    var rows = 8

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Song.placeholders(rows)) { song in
                SongRow(song: song) {}
            }
        }
        .padding(.horizontal, 20)
        .loadingPlaceholder()
    }
}

extension View {
    /// Content standing in while the real content loads: redacted to shapes, shimmering,
    /// not interactive, and read to VoiceOver as loading.
    func loadingPlaceholder() -> some View {
        redacted(reason: .placeholder)
            .shimmer()
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading")
    }
}

/// A page's title appears in the bar once its own header has scrolled away, as Music does.
struct RevealedTitle: ViewModifier {
    let title: String
    let after: CGFloat
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > after
            } action: { _, past in
                withAnimation(.easeInOut(duration: 0.2)) { shown = past }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                        .opacity(shown ? 1 : 0)
                        .accessibilityHidden(!shown)
                }
            }
    }
}

extension View {
    /// Show `title` in the navigation bar after scrolling `after` points.
    func revealsTitle(_ title: String, after: CGFloat) -> some View {
        modifier(RevealedTitle(title: title, after: after))
    }
}
