import Foundation
import Testing
@testable import KodaCore

/// AutoMix over a whole set of real songs: each one measured, then every ordered pair planned,
/// the results written as JSON for study. Run with
/// `KODA_STUDY=/path/to/folder swift test --filter AutoMixStudy`; the folder holds `manifest.json`
/// (entries with `id`, `title`, `artist`, `duration`, `file`, or just a `query` to search for)
/// and receives `analyses.json` and `pairs.json`. Measurements are kept in `cache/` between runs.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["KODA_STUDY"] != nil))
struct AutoMixStudy {
    struct Entry: Codable {
        var id: String?
        var title: String?
        var artist: String?
        var duration: Double?
        var file: String?
        var query: String?
        var source: String?
    }

    struct Track: Codable {
        var id: String
        var title: String
        var artist: String
        var source: String
        var duration: Double
        var analysis: TrackAnalysis
    }

    struct Pair: Codable {
        var from: String
        var to: String
        var style: String?
        var cue: Double?
        var beforeEnd: Double?
        var overlap: Double?
        var rate: Double?
        var tempoMatch: Double?
        var reason: String?
    }

    @Test func studiesTheSet() async throws {
        let folder = URL(filePath: try #require(ProcessInfo.processInfo.environment["KODA_STUDY"]))
        let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: folder.appending(path: "manifest.json")))
        let music = YouTubeMusic(defaultsSuite: "koda.study")
        let analyzer = AutoMixAnalyzer(store: nil, directory: folder.appending(path: "cache"))
        var tracks: [Track] = []
        for entry in entries {
            do {
                var id = entry.id, title = entry.title ?? "", artist = entry.artist ?? "", duration = entry.duration
                var stream: ResolvedStream
                if let file = entry.file, let known = id {
                    stream = ResolvedStream(videoId: known, url: URL(filePath: file), userAgent: "", itag: 0,
                                            contentLength: nil, duration: duration, loudnessDb: nil, expiresAt: nil)
                } else {
                    if id == nil, let query = entry.query {
                        let song = try #require(try await music.search(query, filter: .songs).songs.first)
                        id = song.id
                        title = song.title
                        artist = song.artistLine
                    }
                    stream = try await music.stream(for: try #require(id))
                    duration = stream.duration ?? duration
                }
                guard let analysis = await analyzer.analysis(for: stream, title: title) else {
                    print("STUDY failed to measure \(title)")
                    continue
                }
                tracks.append(Track(id: stream.videoId, title: title, artist: artist, source: entry.source ?? "",
                                    duration: duration ?? analysis.duration, analysis: analysis))
                print("STUDY \(title) - \(artist): \(analysis.summary)")
            } catch {
                print("STUDY skipped \(entry.title ?? entry.query ?? "?"): \(error)")
            }
        }
        var pairs: [Pair] = []
        for a in tracks {
            for b in tracks {
                let plan = TransitionPlanner.plan(from: a.analysis, to: b.analysis,
                                                  context: .init(outgoingEnd: a.duration, albumNeighbours: false))
                let match = TransitionPlanner.tempoMatch(a.analysis, b.analysis)
                pairs.append(Pair(from: a.id, to: b.id, style: plan?.style.rawValue, cue: plan?.cue,
                                  beforeEnd: plan.map { a.duration - $0.cue }, overlap: plan?.overlap,
                                  rate: plan?.rate, tempoMatch: match?.rate, reason: plan?.reason))
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(tracks).write(to: folder.appending(path: "analyses.json"))
        try encoder.encode(pairs).write(to: folder.appending(path: "pairs.json"))
        print("STUDY \(tracks.count) songs, \(pairs.count) pairs")
    }
}
