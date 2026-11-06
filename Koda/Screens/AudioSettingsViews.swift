import KodaCore
import SwiftUI

extension StreamQuality {
    var title: String {
        switch self {
        case .high: "High Quality"
        case .dataSaver: "Data Saver"
        }
    }

    var detail: String {
        switch self {
        case .high: "AAC 128 kbps"
        case .dataSaver: "HE-AAC 48 kbps, about a third of the data"
        }
    }
}

/// Settings → Equalizer: the presets as one list with a checkmark, as Music's EQ page is.
struct EqualizerSettingsView: View {
    @Environment(Player.self) private var player

    var body: some View {
        List {
            Section {
                ForEach(EqualizerPreset.allCases) { preset in
                    Button {
                        player.equalizer = preset
                    } label: {
                        HStack {
                            Text(preset.title).foregroundStyle(.primary)
                            Spacer()
                            if player.equalizer == preset {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .accessibilityAddTraits(player.equalizer == preset ? .isSelected : [])
                }
            } footer: {
                Text("The equalizer shapes every song you play, from the next moment of the one playing. Songs that are boosted are played a little quieter, so loud ones never distort.")
            }
        }
        .sensoryFeedback(.selection, trigger: player.equalizer)
        .navigationTitle("Equalizer")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Settings → Audio Quality: what to stream on Wi‑Fi and on mobile data, as Music splits it.
struct AudioQualitySettingsView: View {
    @Environment(Player.self) private var player

    var body: some View {
        @Bindable var player = player
        Form {
            Section {
                picker("Wi‑Fi Streaming", selection: $player.unmeteredQuality)
                picker("Mobile Data Streaming", selection: $player.meteredQuality)
            } footer: {
                Text("Data Saver streams use about a third of the data. In Low Data Mode, Koda always uses Data Saver. Downloads and songs kept as you play them are always High Quality, so a Data Saver stream isn't kept.")
            }
        }
        .navigationTitle("Audio Quality")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func picker(_ title: String, selection: Binding<StreamQuality>) -> some View {
        Picker(title, selection: selection) {
            ForEach(StreamQuality.allCases, id: \.self) { quality in
                VStack(alignment: .leading) {
                    Text(quality.title)
                    Text(quality.detail).font(.caption).foregroundStyle(.secondary)
                }
                .tag(quality)
            }
        }
        .pickerStyle(.navigationLink)
    }
}
