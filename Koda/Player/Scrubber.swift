import AVKit
import KodaCore
import MediaPlayer
import SwiftUI

/// The progress bar: it thickens under the finger, and a drag from anywhere on it moves the
/// position by the distance dragged, as Music's does; a touch alone never jumps the song.
///
/// Position is read from the player's time anchor inside a TimelineView, so
/// only this bar redraws as the song plays, never the screen around it.
struct Scrubber: View {
    @Environment(Player.self) private var player
    @State private var dragFraction: Double?
    /// Where the bar was when the finger came down.
    @State private var dragStart: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let duration = max(player.duration, 1)
            let fraction = dragFraction ?? min(1, player.position(at: context.date) / duration)
            VStack(spacing: 6) {
                GeometryReader { geometry in
                    let width = geometry.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.25))
                        Capsule().fill(.white.opacity(dragFraction == nil ? 0.85 : 1))
                            .frame(width: max(0, width * fraction))
                    }
                    // Light runs along the bar while the song loads or the network catches up.
                    .shimmer(player.isBuffering)
                    .clipShape(.capsule)
                    .frame(height: dragFraction == nil ? 6 : 12)
                    .frame(maxHeight: .infinity)
                    .contentShape(.rect)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let start = dragStart ?? (Platform.isMac
                                    ? min(1, max(0, value.startLocation.x / width))
                                    : min(1, player.position() / duration))
                                dragStart = start
                                dragFraction = min(1, max(0, start + value.translation.width / width))
                            }
                            .onEnded { _ in
                                if let dragFraction, let dragStart, Platform.isMac || abs(dragFraction - dragStart) * width >= 1 {
                                    player.seek(to: dragFraction * duration)
                                }
                                dragFraction = nil
                                dragStart = nil
                            })
                }
                .frame(height: 24)
                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: dragFraction == nil)

                HStack {
                    Text(format(fraction * duration))
                    Spacer()
                    Text("-" + format(max(0, duration - fraction * duration)))
                }
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.white.opacity(0.6))
            }
            .accessibilityElement()
            .accessibilityLabel("Position")
            .accessibilityValue("\(format(fraction * duration)) of \(format(duration))")
            .accessibilityAdjustableAction { direction in
                let step: TimeInterval = direction == .increment ? 10 : -10
                player.seek(to: player.position() + step)
            }
        }
        .sensoryFeedback(.selection, trigger: dragFraction == nil)
        .disabled(player.phase != .ready)
    }

    private func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0:00" }
        return Duration.seconds(seconds.rounded(.down)).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}

/// The phone's media volume as a bar drawn like the progress bar, speaker symbols either
/// side and centred on it. It follows the hardware buttons, and while it is on screen
/// the system's volume overlay stays away, as in Music. Like the progress bar it moves by
/// the distance dragged, so brushing its loud end never jumps to full volume.
struct VolumeSlider: View {
    @Environment(Player.self) private var player
    @State private var volume = SystemVolume()
    @State private var dragging = false
    /// The level when the finger came down.
    @State private var dragStart: Float?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
                .font(.caption)
                .accessibilityHidden(true)
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(.white.opacity(dragging ? 1 : 0.85))
                        .frame(width: max(0, width * CGFloat(level)))
                        // Changes from the volume buttons ease in with the system's smooth spring;
                        // under the finger the bar follows directly, with no lag.
                        .animation(dragging ? nil : .smooth, value: level)
                }
                .frame(height: dragging ? 12 : 6)
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            dragging = true
                            let start = dragStart ?? (Platform.isMac ? Float(value.startLocation.x / width) : level)
                            dragStart = start
                            setLevel(start + Float(value.translation.width / width))
                        }
                        .onEnded { _ in
                            dragging = false
                            dragStart = nil
                        })
            }
            .frame(height: 24)
            .animation(.smooth, value: dragging)
            Image(systemName: "speaker.wave.3.fill")
                .font(.caption)
                .accessibilityHidden(true)
        }
        .foregroundStyle(.white.opacity(0.6))
        .background {
            if !Platform.isMac { HiddenSystemVolumeView(volume: volume).frame(width: 1, height: 1) }
        }
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue(Text(Double(level), format: .percent.precision(.fractionLength(0))))
        .accessibilityAdjustableAction { direction in
            setLevel(level + (direction == .increment ? 0.0625 : -0.0625))
        }
    }

    /// The phone's media volume; on the Mac, where no app can set the system's, Koda's own.
    private var level: Float { Platform.isMac ? player.volume : volume.level }

    private func setLevel(_ value: Float) {
        let clamped = min(1, max(0, value))
        if Platform.isMac { player.volume = clamped } else { volume.set(clamped) }
    }
}

/// The phone's media volume: read from the audio session, set through the slider inside
/// an MPVolumeView, which is the one way an app can change it.
@MainActor
@Observable
final class SystemVolume {
    private(set) var level: Float
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored weak var slider: UISlider?

    init() {
        level = AVAudioSession.sharedInstance().outputVolume
        observation = Self.observe { [weak self] value in
            Task { @MainActor in self?.level = value }
        }
    }

    func set(_ value: Float) {
        level = value
        guard let slider else { return }
        slider.value = value
        slider.sendActions(for: .valueChanged)
    }

    /// The observer runs on whatever thread the audio session reports from, so it is built
    /// outside the main actor.
    nonisolated private static func observe(_ change: @escaping @Sendable (Float) -> Void) -> NSKeyValueObservation {
        AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { session, _ in
            change(session.outputVolume)
        }
    }
}

/// An MPVolumeView kept on screen but invisible: its slider sets the volume, and its
/// presence keeps the system's volume overlay from covering the player.
private struct HiddenSystemVolumeView: UIViewRepresentable {
    let volume: SystemVolume

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        // Not isHidden: a hidden volume view no longer keeps the overlay away.
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {
        if volume.slider == nil {
            // The slider exists once the view has laid out.
            Task { @MainActor in
                volume.slider = view.subviews.compactMap { $0 as? UISlider }.first
            }
        }
    }
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = UIColor(Color.accentColor)
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
