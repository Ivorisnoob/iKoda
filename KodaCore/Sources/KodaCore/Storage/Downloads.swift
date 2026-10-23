import Foundation
import Observation

/// Songs the listener downloaded, and the work of fetching them: two at a time, in the order
/// asked, picked up again at the next launch when the app closed first. A song already held
/// whole from listening is downloaded at once, with nothing fetched.
@MainActor
@Observable
public final class Downloads {
    public enum State: Equatable, Sendable {
        case none
        /// Asked for: waiting its turn, or for a connection it may use.
        case waiting
        /// How much of it is here, 0 to 1.
        case downloading(Double)
        case downloaded
    }

    /// Downloaded songs and those on their way, most recently added first.
    public private(set) var songs: [Song] = []
    /// Space downloads take, updated as each finishes.
    public private(set) var bytes: Int64 = 0
    private var states: [String: State] = [:]

    /// Off, downloads wait for Wi-Fi.
    public var allowsCellular: Bool {
        didSet {
            UserDefaults.standard.set(allowsCellular, forKey: Keys.cellular)
            session = Self.makeSession(allowsCellular: allowsCellular)
        }
    }

    @ObservationIgnored public let store: AudioStore
    @ObservationIgnored private let music: YouTubeMusic
    @ObservationIgnored private var session: URLSession
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var running: [String: Task<Void, Never>] = [:]

    private static let parallel = 2
    /// Bytes per request; a song takes a few.
    nonisolated private static let chunk: Int64 = 1 << 20
    private enum Keys {
        static let cellular = "koda.downloads.cellular"
    }

    public init(store: AudioStore, music: YouTubeMusic) {
        self.store = store
        self.music = music
        let cellular = UserDefaults.standard.object(forKey: Keys.cellular) as? Bool ?? true
        allowsCellular = cellular
        session = Self.makeSession(allowsCellular: cellular)
        for entry in store.downloads {
            guard let song = entry.song else { continue }
            songs.append(song)
            states[song.id] = entry.isComplete ? .downloaded : .waiting
            if !entry.isComplete { queue.append(song.id) }
        }
        bytes = store.downloadBytes
        pump()
    }

    // MARK: Reading

    public func state(of song: Song) -> State { states[song.id] ?? .none }

    /// An album's or playlist's: downloaded when every song is, downloading while any is
    /// on its way, with the share of the whole that is here.
    public func state(of songs: [Song]) -> State {
        guard !songs.isEmpty else { return .none }
        var here = 0.0
        var onTheWay = false
        for song in songs {
            switch state(of: song) {
            case .none: break
            case .waiting: onTheWay = true
            case .downloading(let progress):
                onTheWay = true
                here += progress
            case .downloaded: here += 1
            }
        }
        if here >= Double(songs.count) { return .downloaded }
        return onTheWay ? .downloading(here / Double(songs.count)) : .none
    }

    // MARK: Changing

    public func download(_ songs: [Song]) {
        var seen = Set<String>()
        let fresh = songs.filter { state(of: $0) == .none && seen.insert($0.id).inserted }
        guard !fresh.isEmpty else { return }
        store.markDownloaded(fresh)
        for song in fresh { states[song.id] = .waiting }
        self.songs.insert(contentsOf: fresh, at: 0)
        queue += fresh.map(\.id)
        pump()
    }

    public func remove(_ songs: [Song]) {
        let ids = Set(songs.map(\.id))
        for id in ids {
            running[id]?.cancel()
            running[id] = nil
            states[id] = nil
        }
        queue.removeAll { ids.contains($0) }
        self.songs.removeAll { ids.contains($0.id) }
        store.removeDownloads(Array(ids))
        bytes = store.downloadBytes
        pump()
    }

    public func removeAll() {
        remove(songs)
    }

    // MARK: Fetching

    private func pump() {
        while running.count < Self.parallel, !queue.isEmpty {
            let id = queue.removeFirst()
            guard let song = songs.first(where: { $0.id == id }) else { continue }
            running[id] = Task { [weak self] in
                await self?.fetch(song)
                self?.running[id] = nil
                self?.pump()
            }
        }
    }

    private func fetch(_ song: Song) async {
        let id = song.id
        store.beginUse(id)
        defer { store.endUse(id) }
        var refreshedURL = false
        var delay: Duration = .seconds(10)
        while !Task.isCancelled {
            if store.entry(id)?.isComplete == true { break }
            do {
                let stream = try await music.stream(for: id)
                store.prepare(stream, song: song)
                // Without its length the file can't be laid out; a later answer may have it.
                guard stream.contentLength != nil else { throw MusicError.network }
                states[id] = .downloading(progress(id))
                try await Self.fill(id, from: stream, session: session, store: store) { [weak self] in
                    guard let self, self.states[id] != nil else { return }
                    self.states[id] = .downloading(self.progress(id))
                }
            } catch is CancellationError {
                return
            } catch MusicError.unplayable(_) {
                // A verdict on the video: it can never be downloaded.
                remove([song])
                return
            } catch {
                if Task.isCancelled { return }
                if !refreshedURL, (error as? URLError)?.code == .badServerResponse {
                    // googlevideo refused the URL: one fresh one, at once.
                    refreshedURL = true
                    await music.streamFailed(id)
                    continue
                }
                // Offline or refused: wait its turn again a little later, longer each time.
                states[id] = .waiting
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, .seconds(300))
            }
        }
        guard !Task.isCancelled, states[id] != nil else { return }
        states[id] = .downloaded
        bytes = store.downloadBytes
    }

    private func progress(_ id: String) -> Double {
        guard let entry = store.entry(id), let length = entry.contentLength, length > 0 else { return 0 }
        return min(1, Double(entry.bytes) / Double(length))
    }

    /// Fetch the song's missing bytes a chunk at a time and write each to its file, off the
    /// main thread; `progressed` runs after each chunk.
    nonisolated private static func fill(_ id: String, from stream: ResolvedStream, session: URLSession, store: AudioStore,
                                         progressed: @MainActor @Sendable () -> Void) async throws {
        while let gap = store.firstGap(id) {
            try Task.checkCancellation()
            let end = min(gap.upperBound, gap.lowerBound + chunk)
            var request = URLRequest(url: stream.url)
            request.setValue("bytes=\(gap.lowerBound)-\(end - 1)", forHTTPHeaderField: "Range")
            request.setValue(stream.userAgent, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            // 200: the range was ignored and this is the whole file.
            guard status == 206 || status == 200, !data.isEmpty else { throw URLError(.badServerResponse) }
            try store.write(data, at: status == 200 ? 0 : gap.lowerBound, for: id)
            await progressed()
        }
    }

    private static func makeSession(allowsCellular: Bool) -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.allowsCellularAccess = allowsCellular
        // Wait for a connection it may use rather than failing at once.
        configuration.waitsForConnectivity = true
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }
}
