import KodaCore
import SwiftUI

/// A new release, on the iPhone: what's new and where to get it. An iPhone app can't install
/// a new copy of itself, so this only tells; the listener downloads Koda.ipa and installs it over
/// this one with AltStore, which keeps the library. Put off for a week, skipped, or swiped away
/// (then it comes back with the next day's check).
struct UpdateNoticeView: View {
    let release: AppRelease
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 16) {
                        Image("KodaIcon")
                            .resizable()
                            .frame(width: 72, height: 72)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(release.title)
                                .font(.scaled(.title2).weight(.bold))
                            Text("You have Koda \(app.updates.current)")
                                .font(.scaled(.subheadline))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Label {
                        Text("Download **Koda.ipa** from the release page, then install it from AltStore over this copy. Your library, settings and sign-in stay.")
                    } icon: {
                        Image(systemName: "arrow.down.app")
                    }
                    .font(.scaled(.footnote))
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.fill.quaternary, in: .rect(cornerRadius: 16, style: .continuous))
                    if !release.notes.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("What's New")
                                .font(.scaled(.title3).weight(.bold))
                            ReleaseNotesView(markdown: release.notes)
                        }
                    }
                }
                .padding(20)
            }
            .safeAreaBar(edge: .bottom) {
                VStack(spacing: 4) {
                    Button {
                        openURL(release.page)
                        app.updates.dismiss()
                        dismiss()
                    } label: {
                        Text("Get \(release.title)")
                            .font(.scaled(.body).weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    Button("Remind Me in a Week") {
                        app.updates.remindLater(release, days: 7)
                        dismiss()
                    }
                    .font(.scaled(.body).weight(.medium))
                    .padding(.vertical, 8)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
            .navigationTitle("Update Available")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") {
                        app.updates.dismiss()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu("More", systemImage: "ellipsis") {
                        Button("Skip This Version", systemImage: "forward.end") {
                            app.updates.skip(release)
                            dismiss()
                        }
                    }
                }
            }
        }
        .presentationDetents([.large])
    }
}
