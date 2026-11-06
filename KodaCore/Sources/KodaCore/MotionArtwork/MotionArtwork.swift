import Foundation
import os

private let log = Logger(subsystem: "Koda", category: "MotionArtwork")

/// Animated album covers, as Music shows them: found in Apple Music's public catalogue with
/// the anonymous token Music on the web uses, and kept as local video files, because the
/// Lock Screen will only take a file and a file loops without going back to the network.
///
/// No account and no listening history leave the device beyond the catalogue search itself;
/// on disk are the token, every lookup's answer (with a cover or without), the loops and
/// their still frames (oldest dropped past `budget`). Each song is asked about once in a long
/// while, and an album's cover once found serves every song on it. Every failure is the
/// still cover, never a playback problem.
public actor MotionArtwork {
    public typealias Shape = MotionArtworkCatalog.Shape
    public typealias Covers = MotionArtworkCatalog.Covers

    private let directory: URL
    /// Wi-Fi and Ethernet only, and never in Low Data Mode.
    private let unmetered: URLSession
    /// Cellular too, still never in Low Data Mode.
    private let anyNetwork: URLSession
    /// Loops kept on disk; past it the least recently shown go.
    private let budget: Int
    /// The album of a song that came without one, from YouTube: covers are matched by album.
    /// Throws when it can't be asked now, so a network failure isn't remembered as no album.
    public typealias AlbumFinder = @Sendable (_ videoId: String) async throws -> AlbumRef?
    private let findAlbum: AlbumFinder?

    private var token: String?
    private var lookups: [String: Lookup] = [:]
    private var lookupsLoaded = false
    private var inFlight: [String: Task<Covers?, Never>] = [:]
    private var downloads: [String: Task<URL?, Never>] = [:]
    /// After a failure, no new lookups for a minute, so every skip doesn't become another request.
    private var quietUntil = Date.distantPast

    private struct Lookup: Codable {
        var covers: Covers?
        var until: Date
    }

    /// A found cover is trusted for half a year (Apple doesn't take them down); an album
    /// without one is asked again after two weeks, in case one was added.
    static let foundFor: TimeInterval = 180 * 86400
    static let missingFor: TimeInterval = 14 * 86400

    public init(directory: URL, budget: Int = 500 << 20, findAlbum: AlbumFinder? = nil) {
        self.directory = directory
        self.budget = budget
        self.findAlbum = findAlbum
        func session(allowsCellular: Bool) -> URLSession {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.allowsConstrainedNetworkAccess = false
            configuration.allowsExpensiveNetworkAccess = allowsCellular
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 60
            configuration.httpCookieAcceptPolicy = .never
            return URLSession(configuration: configuration)
        }
        unmetered = session(allowsCellular: false)
        anyNetwork = session(allowsCellular: true)
    }

    // MARK: Finding the cover

    /// The animated covers of the album `song` is on, or nil when it has none (most don't).
    public func covers(for song: Song, allowsCellular: Bool) async -> Covers? {
        loadLookups()
        // Known by its id first: the same song can reach the player without its album (some
        // lists leave it out), and the answer found when it had one still holds.
        if let known = lookups[song.id], known.until > .now { return known.covers }
        var song = song
        if song.album == nil, !song.isVideo, let findAlbum {
            let found: AlbumRef?
            do { found = try await findAlbum(song.id) } catch { return nil }
            guard let album = found else {
                // YouTube has it on no album (a lone upload): there is no album cover to find.
                remember(song.id, Lookup(covers: nil, until: .now + Self.missingFor))
                return nil
            }
            song.album = album
        }
        guard MotionArtworkCatalog.isLookable(song) else { return nil }
        // Another song from the same album already found its cover: the cover is the album's.
        if let album = song.album?.id, let known = lookups[Self.albumKey(album)], known.until > .now, let covers = known.covers {
            remember(song.id, known)
            return covers
        }
        if let running = inFlight[song.id] { return await running.value }
        guard Date.now >= quietUntil else { return nil }
        let task = Task { await lookUp(song, session: allowsCellular ? anyNetwork : unmetered) }
        inFlight[song.id] = task
        let found = await task.value
        inFlight[song.id] = nil
        return found
    }

    private enum Outcome {
        case found(Covers?)
        /// No network allowed right now (cellular with Wi-Fi only, Low Data Mode): ask again later.
        case notNow
        case failed
    }

    private func lookUp(_ song: Song, session: URLSession) async -> Covers? {
        let outcome = await search(song, session: session)
        switch outcome {
        case .found(let covers):
            let lookup = Lookup(covers: covers, until: .now + (covers == nil ? Self.missingFor : Self.foundFor))
            remember(song.id, lookup)
            if covers != nil, let album = song.album?.id { remember(Self.albumKey(album), lookup) }
            log.info("\(covers == nil ? "No animated cover" : "Animated cover found") for \(song.title, privacy: .public)")
            return covers
        case .notNow:
            return nil
        case .failed:
            quietUntil = .now + 60
            return nil
        }
    }

    private func search(_ song: Song, session: URLSession) async -> Outcome {
        guard let url = MotionArtworkCatalog.searchURL(for: song) else { return .found(nil) }
        for attempt in 0..<2 {
            let bearer: String
            switch await webToken(session: session) {
            case .success(let found): bearer = found
            case .failure(let error): return outcome(of: error, while: "reading Music on the web's token")
            }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            request.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")
            request.setValue("https://music.apple.com/", forHTTPHeaderField: "Referer")
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 401 || status == 403 {
                    // The token was withdrawn early: forget it and read the current one, once.
                    forgetToken()
                    if attempt == 0 { continue }
                }
                guard (200..<300).contains(status) else {
                    log.error("Catalogue search answered HTTP \(status)")
                    return .failed
                }
                guard let json = try? JSON(data: data) else {
                    log.error("Catalogue search answer was not JSON")
                    return .failed
                }
                return .found(MotionArtworkCatalog.covers(in: json, for: song))
            } catch {
                return outcome(of: error, while: "searching the catalogue")
            }
        }
        return .failed
    }

    private func outcome(of error: Error, while doing: String) -> Outcome {
        if let urlError = error as? URLError, urlError.networkUnavailableReason != nil { return .notNow }
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return .notNow }
        log.error("Animated covers failed \(doing, privacy: .public): \(error.localizedDescription, privacy: .public)")
        return .failed
    }

    // MARK: The loop file

    /// A local file of the album's `shape` loop, at least about `pixels` across, downloading it
    /// if no file that size is kept yet. Nil when it can't be had now.
    public func loop(_ covers: Covers, shape: Shape, pixels: Int, allowsCellular: Bool) async -> URL? {
        if let kept = keptLoop(covers.albumID, shape: shape, pixels: pixels) {
            touch(kept)
            return kept
        }
        guard let master = covers.masters[shape] else { return nil }
        let key = "\(covers.albumID)-\(shape.rawValue)"
        if let running = downloads[key] { return await running.value }
        let session = allowsCellular ? anyNetwork : unmetered
        let task = Task { await download(master, albumID: covers.albumID, shape: shape, pixels: pixels, session: session) }
        downloads[key] = task
        let file = await task.value
        downloads[key] = nil
        return file
    }

    /// A loop already kept for the album and shape, if one is about as large as asked or larger.
    private func keptLoop(_ albumID: String, shape: Shape, pixels: Int) -> URL? {
        let wanted = Int(Double(min(pixels, MotionArtworkCatalog.largestWidth)) * 0.85)
        let prefix = "\(albumID)-\(shape.rawValue)-"
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .compactMap { file -> (URL, Int)? in
                let name = file.deletingPathExtension().lastPathComponent
                guard file.pathExtension == "mp4", name.hasPrefix(prefix), let width = Int(name.dropFirst(prefix.count)) else { return nil }
                return (file, width)
            }
            .filter { $0.1 >= wanted }
            .min { $0.1 < $1.1 }
            .map { directory.appending(path: $0.0.lastPathComponent) }
    }

    private func download(_ master: URL, albumID: String, shape: Shape, pixels: Int, session: URLSession) async -> URL? {
        do {
            let (ladder, _) = try await session.data(from: master)
            let variants = MotionArtworkCatalog.variants(master: master, playlist: String(decoding: ladder, as: UTF8.self))
            guard let variant = MotionArtworkCatalog.pick(variants, pixels: pixels) else {
                log.error("Animated cover's ladder had no usable rung")
                return nil
            }
            let (media, _) = try await session.data(from: variant.url)
            guard let file = MotionArtworkCatalog.singleFile(media: variant.url, playlist: String(decoding: media, as: UTF8.self)) else {
                log.error("Animated cover isn't one file; keeping the still cover")
                return nil
            }
            let (temporary, response) = try await session.download(from: file)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let size = (try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            // The largest rung taken is about 25 MB; anything far past that isn't a cover.
            guard (200..<300).contains(status), size > 0, size < 48 << 20 else {
                log.error("Animated cover download answered HTTP \(status), \(size) bytes")
                return nil
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appending(path: "\(albumID)-\(shape.rawValue)-\(variant.width).mp4")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            log.info("Kept a \(variant.width)px \(shape.rawValue, privacy: .public) loop, \(size) bytes")
            trim()
            return destination
        } catch {
            _ = outcome(of: error, while: "downloading a loop")
            return nil
        }
    }

    // MARK: The still frame

    /// The loop's first frame as an image, for the Lock Screen to show while the loop loads:
    /// kept beside the loops, so it is fetched once per album and shape.
    public func previewImage(_ covers: Covers, shape: Shape, pixels: Int, allowsCellular: Bool) async -> Data? {
        let file = directory.appending(path: "\(covers.albumID)-\(shape.rawValue)-preview.jpg")
        if let kept = try? Data(contentsOf: file), !kept.isEmpty {
            touch(file)
            return kept
        }
        guard let url = covers.preview(shape, pixels: min(max(pixels, 1), MotionArtworkCatalog.largestWidth)) else { return nil }
        let session = allowsCellular ? anyNetwork : unmetered
        guard let (data, response) = try? await session.data(from: url),
              (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0), !data.isEmpty else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return data
    }

    private func touch(_ file: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: file.path)
    }

    /// Past the budget, the loops shown longest ago go first.
    private func trim() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        var loops = files.filter { ["mp4", "jpg"].contains($0.pathExtension) }.map { file -> (URL, Int, Date) in
            let values = try? file.resourceValues(forKeys: Set(keys))
            return (file, values?.fileSize ?? 0, values?.contentModificationDate ?? .distantPast)
        }
        loops.sort { $0.2 < $1.2 }
        var total = loops.reduce(0) { $0 + $1.1 }
        for (file, size, _) in loops where total > budget {
            try? FileManager.default.removeItem(at: file)
            total -= size
        }
    }

    // MARK: Remembered lookups

    private var lookupsFile: URL { directory.appending(path: "lookups.json") }

    /// Every answer survives a relaunch: a kept loop plays offline and on cellular without
    /// asking the catalogue again, and songs without one aren't asked about on every launch.
    private func loadLookups() {
        guard !lookupsLoaded else { return }
        lookupsLoaded = true
        guard let data = try? Data(contentsOf: lookupsFile),
              let saved = try? JSONDecoder().decode([String: Lookup].self, from: data) else { return }
        lookups = saved.filter { $0.value.until > .now }
    }

    private func remember(_ songID: String, _ lookup: Lookup) {
        lookups[songID] = lookup
        if lookups.count > 8000 {
            let oldest = lookups.sorted { $0.value.until < $1.value.until }.prefix(lookups.count - 6000)
            for (id, _) in oldest { lookups[id] = nil }
        }
        let found = lookups
        let file = lookupsFile
        let directory = directory
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(found) else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }

    private static func albumKey(_ youTubeAlbum: String) -> String { "album:\(youTubeAlbum)" }

    // MARK: The token

    private var tokenFile: URL { directory.appending(path: "token") }

    private func forgetToken() {
        token = nil
        try? FileManager.default.removeItem(at: tokenFile)
    }

    private func webToken(session: URLSession) async -> Result<String, Error> {
        if let token, MotionArtworkCatalog.isUsableToken(token, now: .now) { return .success(token) }
        if let saved = try? String(contentsOf: tokenFile, encoding: .utf8), MotionArtworkCatalog.isUsableToken(saved, now: .now) {
            token = saved
            return .success(saved)
        }
        do {
            let page = try await webPage(URL(string: "https://music.apple.com")!, session: session)
            guard let path = MotionArtworkCatalog.scriptPath(inPage: page),
                  let scriptURL = URL(string: "https://music.apple.com" + path) else {
                log.error("Music on the web named no script bundle; no animated covers")
                return .failure(URLError(.cannotParseResponse))
            }
            let script = try await webPage(scriptURL, session: session)
            guard let found = MotionArtworkCatalog.webToken(inScript: script, now: .now) else {
                log.error("Music on the web's script held no usable token; no animated covers")
                return .failure(URLError(.cannotParseResponse))
            }
            token = found
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? found.write(to: tokenFile, atomically: true, encoding: .utf8)
            return .success(found)
        } catch {
            return .failure(error)
        }
    }

    /// A page of Music on the web. It redirects its root to a storefront path; a redirect
    /// anywhere other than music.apple.com is refused rather than followed.
    private func webPage(_ url: URL, session: URLSession) async throws -> String {
        let (data, response) = try await session.data(from: url, delegate: StayOnMusicWeb.shared)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let final = http.url, MotionArtworkCatalog.isWebURL(final) else {
            throw URLError(.badServerResponse)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

private final class StayOnMusicWeb: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = StayOnMusicWeb()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url, MotionArtworkCatalog.isWebURL(url) else { return nil }
        return request
    }
}
