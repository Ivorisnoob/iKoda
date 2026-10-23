import AuthenticationServices
import KodaCore
import SwiftUI

/// What the iPhone's and the Mac's Last.fm screens share: signing in, and the recent plays by day.
enum LastFMUI {
    static let createAccountURL = URL(string: "https://www.last.fm/api/account/create")!

    static func profileURL(_ user: String) -> URL {
        URL(string: "https://www.last.fm/user/\(user.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? user)")!
    }

    /// Opens Last.fm's approval page in a browser sheet. Last.fm's desktop flow has no way to
    /// call back, so closing the sheet is the cue to finish: if the listener approved, they're
    /// connected; if not, the screen says so and offers the page again.
    @MainActor
    static func approve(_ url: URL, lastFM: LastFM, web: WebAuthenticationSession) async {
        _ = try? await web.authenticate(using: url, callbackURLScheme: "koda", preferredBrowserSession: .shared)
        try? await lastFM.finishSignIn()
    }

    /// Recent plays grouped by the day they were played, newest first; what is playing now leads.
    static func days(_ tracks: [LastFMTrack]) -> [(title: String, tracks: [LastFMTrack])] {
        var groups: [(String, [LastFMTrack])] = []
        let calendar = Calendar.current
        for track in tracks {
            let title: String
            if track.isNowPlaying {
                title = "Now"
            } else if let date = track.playedAt {
                title = calendar.isDateInToday(date) ? "Today"
                    : calendar.isDateInYesterday(date) ? "Yesterday"
                    : date.formatted(.dateTime.weekday(.wide).day().month(.wide))
            } else {
                title = "Earlier"
            }
            if groups.last?.0 == title { groups[groups.count - 1].1.append(track) } else { groups.append((title, [track])) }
        }
        return groups.map { (title: $0.0, tracks: $0.1) }
    }

    /// "12,345 scrobbles".
    static func scrobbles(_ count: Int) -> String {
        count == 1 ? "1 scrobble" : "\(count.formatted()) scrobbles"
    }

    /// "Scrobbling since 2014 · United Kingdom".
    static func since(_ profile: LastFMProfile) -> String? {
        let parts = [profile.registered.map { "Scrobbling since \($0.formatted(.dateTime.year()))" },
                     profile.country.isEmpty ? nil : profile.country].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// How the queue stands, in a line: what's waiting, or when the last play went.
    static func status(_ lastFM: LastFM) -> String {
        if lastFM.isPaused { return "Paused while listening history is off" }
        if !lastFM.queued.isEmpty {
            return lastFM.queued.count == 1 ? "1 play waiting to send" : "\(lastFM.queued.count) plays waiting to send"
        }
        if let sent = lastFM.lastSent { return "Up to date · last sent \(sent.formatted(.relative(presentation: .named)))" }
        return "Up to date"
    }
}

/// A Last.fm cover or avatar, with Koda's stand-in while there is none.
struct LastFMImage: View {
    let url: URL?
    var size: CGFloat
    var circle = false

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
                    .overlay {
                        Image(systemName: circle ? "person.fill" : "music.note")
                            .font(.system(size: size * 0.36, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: size * 0.14, style: .continuous)))
        .accessibilityHidden(true)
    }
}

/// One play from Last.fm: cover, title, artist and album, and when, or that it is playing now.
struct LastFMTrackRow: View {
    let track: LastFMTrack
    var coverSize: CGFloat = 44

    var body: some View {
        HStack(spacing: 12) {
            LastFMImage(url: track.artwork, size: coverSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.body).lineLimit(1)
                Text([track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if track.isNowPlaying {
                Label("Now", systemImage: "waveform")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.variableColor.iterative, options: .repeat(.continuous))
            } else if let date = track.playedAt {
                Text(date.formatted(date: .omitted, time: .shortened))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
