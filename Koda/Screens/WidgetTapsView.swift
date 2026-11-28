#if os(iOS)
import SwiftUI
import UIKit

/// Settings → Widget Taps: what each side of a widget or Control Center tap saw, newest first,
/// to find out where taps go on the iOS versions where the buttons do nothing (issue #10).
struct WidgetTapsView: View {
    @State private var entries: [WidgetTaps.Entry] = []
    private let hasFolder = SharedContainer.directory != nil

    var body: some View {
        Form {
            if !hasFolder {
                Section {
                    Text("This copy of Koda shares no folder with its widgets, so taps can't be traced or handed over.")
                }
            } else if entries.isEmpty {
                Section {
                    Text("No taps yet. Tap a widget button, then come back here.")
                }
            } else {
                Section {
                    ForEach(entries.reversed()) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.action.title)
                            Text(detail(entry)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Seen by the widget means iOS ran the widget's copy of the button. Run by the app means the tap reached Koda, as it should. A tap only the widget saw is handed to Koda while it's running.")
                }
                Section {
                    ShareLink(item: report) {
                        Label("Share Taps", systemImage: "square.and.arrow.up")
                    }
                    Button("Clear", role: .destructive) {
                        WidgetTaps.clearTrace()
                        entries = []
                    }
                }
            }
        }
        .navigationTitle("Widget Taps")
        // Both the app and the widget write the trace, so read it again while it's open.
        .task {
            while !Task.isCancelled {
                entries = WidgetTaps.trace()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func detail(_ entry: WidgetTaps.Entry) -> String {
        let side = switch entry.side {
        case .widget: "Seen by the widget"
        case .app: "Run by the app"
        case .handedOver: "Handed over to the app"
        }
        return [entry.at.formatted(date: .omitted, time: .standard), side, entry.note].compactMap(\.self).joined(separator: " · ")
    }

    /// Plain text for an issue report: the iOS version, then one line a tap, oldest first.
    private var report: String {
        let lines = entries.map { "\($0.at.formatted(.iso8601)) \($0.side.rawValue) \($0.action.rawValue)\($0.note.map { " (\($0))" } ?? "")" }
        return (["iOS \(UIDevice.current.systemVersion)"] + lines).joined(separator: "\n")
    }
}
#endif
