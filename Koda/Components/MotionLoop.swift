import KodaCore
import SwiftUI

extension AppModel {
    /// Apple Music's artist for a YouTube one (moving portrait, biography, colours, newest
    /// release), remembered by `MotionArtwork`. Their own song and album titles tell their Apple
    /// artist from others with the same name: `titles` when the caller has some (a search's top
    /// songs), else their YouTube page, `page` or fetched, only when Apple has to be asked.
    func appleArtist(_ artist: ArtistSummary, page: ArtistPage? = nil, titles: [String] = []) async -> AppleArtist? {
        let id = artist.id
        guard id.hasPrefix("UC"), !artist.name.isEmpty else { return nil }
        let music = music
        return await motionArtwork.artist(id, name: artist.name, allowsCellular: true) {
            if titles.count >= 2 { return titles }
            let known: ArtistPage?
            if let page { known = page } else { known = try? await music.artist(id) }
            guard let known else { return titles }
            return known.topSongs.map(\.title) + known.albums.map(\.title) + known.singles.map(\.title)
        }
    }
}

/// A loop from Apple's catalogue (an artist's moving portrait, an album's cover) laid over
/// whatever is under it, as Music shows them: it fades in on its first frame and moves while
/// `isPlaying`. With Animated Art off, animated images off in Accessibility, or no loop to be
/// had on this network (Wi‑Fi Only), nothing is drawn and the still underneath stays.
struct MotionLoop: View {
    let covers: MotionArtwork.Covers?
    let shape: MotionArtwork.Shape
    var isPlaying = true
    /// Told whether the loop is showing, for a page that dims or moves things around it.
    var onShow: ((Bool) -> Void)? = nil
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityPlayAnimatedImages) private var playsAnimatedImages
    @Environment(\.scenePhase) private var scenePhase
    @State private var file: URL?
    @State private var isReady = false

    private struct Request: Equatable {
        var covers: MotionArtwork.Covers?
        var shape: MotionArtwork.Shape
        var art: AppSettings.AnimatedArt
        var allowed: Bool
    }

    var body: some View {
        ZStack {
            if let file {
                LoopingVideo(file: file, isPlaying: isPlaying && scenePhase == .active) { isReady = true }
                    .id(file)
                    .opacity(isReady ? 1 : 0)
            }
        }
        .animation(.smooth(duration: 0.6), value: isReady)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: Request(covers: covers, shape: shape, art: app.settings.animatedArt, allowed: playsAnimatedImages)) {
            await find()
        }
        .onChange(of: file != nil && isReady, initial: true) { _, showing in onShow?(showing) }
    }

    private func find() async {
        let setting = app.settings.animatedArt
        guard let covers, covers.masters[shape] != nil, setting != .off, playsAnimatedImages else {
            show(nil)
            return
        }
        let found = await app.motionArtwork.loop(covers, shape: shape, pixels: AnimatedCover.pixels,
                                                 allowsCellular: setting.allowsCellular)
        guard !Task.isCancelled else { return }
        show(found)
    }

    private func show(_ next: URL?) {
        guard next != file else { return }
        isReady = false
        file = next
    }
}

extension Color {
    /// Apple's `RRGGBB` colours; nil for anything else.
    init?(hex: String?) {
        guard let hex, hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(.sRGB,
                  red: Double((value >> 16) & 0xff) / 255,
                  green: Double((value >> 8) & 0xff) / 255,
                  blue: Double(value & 0xff) / 255)
    }
}

extension AppleArtist {
    /// Their portrait's colour, when it has one worth tinting a page with: Apple gives many
    /// artists a plain black, grey or white, which would only muddy it.
    var tint: Color? {
        guard let color = Color(hex: background), let hsb = color.hsb, hsb.saturation >= 0.18,
              hsb.brightness >= 0.15 else { return nil }
        return color
    }

    /// The still frame of the moving portrait, for a card that waits for the loop on top of it.
    func still(_ shape: MotionArtwork.Shape, pixels: Int) -> Artwork? {
        motion?.preview(shape, pixels: pixels).map { Artwork(url: $0) }
    }

    /// "Born December 18, 2001", "Formed June 13, 2013".
    var bornOrFormedLine: String? {
        bornOrFormed.map { (isGroup ? "Formed " : "Born ") + $0 }
    }
}
