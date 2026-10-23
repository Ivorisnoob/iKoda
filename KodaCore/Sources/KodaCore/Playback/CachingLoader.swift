import AVFoundation
import Foundation
import ObjectiveC

/// Feeds AVFoundation a song from YouTube while keeping every byte that arrives, so next
/// time the song plays from the phone.
///
/// The asset gets a `koda-cache:` URL, which AVFoundation can't load by itself, so it asks
/// this loader for each byte range it wants. Bytes already on disk are answered from the
/// file. For the rest one ranged request runs at a time, from the first byte any waiting
/// request needs to the next byte already held; what arrives is written to the file and
/// answered from there. When nobody is waiting it fills the song's remaining gaps, so a
/// song that was skipped through still ends up whole. Everything runs on one serial queue.
final class CachingLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private let stream: ResolvedStream
    private let length: Int64
    private let store: AudioStore
    private let queue = DispatchQueue(label: "koda.cachingloader", qos: .userInitiated)
    private var session: URLSession!
    private var requests: [AVAssetResourceLoadingRequest] = []
    private var task: URLSessionDataTask?
    /// Where the running request's next byte belongs, and where it stops.
    private var taskOffset: Int64 = 0
    private var taskEnd: Int64 = 0
    private var taskAccepted = false
    private var failure: Error?

    /// A waiting request this close ahead of the running one is left to it rather than
    /// starting a request of its own.
    private static let reachAhead: Int64 = 512 * 1024
    /// The most handed to AVFoundation in one go.
    private static let slice: Int64 = 512 * 1024

    /// Nil when the stream's length isn't known: without it the file can't be laid out.
    init?(stream: ResolvedStream, song: Song?, store: AudioStore) {
        guard let length = stream.contentLength, length > 0 else { return nil }
        self.stream = stream
        self.length = length
        self.store = store
        super.init()
        store.prepare(stream, song: song)
        store.beginUse(stream.videoId)
        let operations = OperationQueue()
        operations.underlyingQueue = queue
        operations.maxConcurrentOperationCount = 1
        let configuration = URLSessionConfiguration.default
        // The file is the cache; URLCache keeping a second copy would only take space.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: SessionEvents(loader: self), delegateQueue: operations)
    }

    deinit {
        session.invalidateAndCancel()
        store.endUse(stream.videoId)
    }

    /// An asset reading through this loader; the asset keeps the loader alive, since its
    /// resource loader holds its delegate weakly.
    func makeAsset() -> AVURLAsset {
        let asset = AVURLAsset(url: URL(string: "koda-cache://audio/\(stream.videoId).m4a")!)
        asset.resourceLoader.setDelegate(self, queue: queue)
        objc_setAssociatedObject(asset, &loaderKey, self, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return asset
    }

    // MARK: AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        requests.append(loadingRequest)
        serve()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        // The running request keeps going: what it fetches is kept either way.
        requests.removeAll { $0 === loadingRequest }
    }

    // MARK: Answering

    private func serve() {
        requests.removeAll { answer($0) }
        fetchIfNeeded()
    }

    /// Answer as much of `request` as the file holds; true once it is finished.
    private func answer(_ request: AVAssetResourceLoadingRequest) -> Bool {
        if let info = request.contentInformationRequest {
            info.contentType = AVFileType.m4a.rawValue
            info.contentLength = length
            info.isByteRangeAccessSupported = true
        }
        guard let data = request.dataRequest else {
            request.finishLoading()
            return true
        }
        let end = data.requestsAllDataToEndOfResource ? length : min(length, data.requestedOffset + Int64(data.requestedLength))
        while data.currentOffset < end {
            let count = min(store.contiguousLength(stream.videoId, from: data.currentOffset), end - data.currentOffset, Self.slice)
            guard count > 0, let bytes = store.read(stream.videoId, at: data.currentOffset, count: count) else { break }
            data.respond(with: bytes)
        }
        if data.currentOffset >= end {
            request.finishLoading()
            return true
        }
        if let failure {
            request.finishLoading(with: failure)
            return true
        }
        return false
    }

    // MARK: Fetching

    private func fetchIfNeeded() {
        guard failure == nil else { return }
        guard let needed = requests.compactMap({ $0.dataRequest?.currentOffset }).min() else {
            // Nobody waiting: fill the song's gaps while there is no request running.
            if task == nil, let gap = store.firstGap(stream.videoId) { start(gap) }
            return
        }
        if task != nil, needed >= taskOffset, needed < min(taskEnd, taskOffset + Self.reachAhead) { return }
        guard let gap = store.firstGap(stream.videoId, from: needed) else { return }
        task?.cancel()
        start(gap)
    }

    private func start(_ range: Range<Int64>) {
        var request = URLRequest(url: stream.url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        request.setValue(stream.userAgent, forHTTPHeaderField: "User-Agent")
        taskOffset = range.lowerBound
        taskEnd = range.upperBound
        taskAccepted = false
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
    }

    /// Whether the response is audio for the range asked; checked once, on its first bytes.
    private func accepts(_ response: URLResponse?) -> Bool {
        switch (response as? HTTPURLResponse)?.statusCode {
        case 206:
            return true
        case 200:
            // The range was ignored and the whole file is coming.
            taskOffset = 0
            taskEnd = length
            return true
        default:
            return false
        }
    }

    fileprivate func received(_ data: Data, from task: URLSessionTask) {
        guard task === self.task else { return }
        if !taskAccepted {
            guard accepts(task.response) else {
                // googlevideo refused the URL; AVFoundation fails the item and the player reloads it.
                fail(URLError(.badServerResponse))
                return
            }
            taskAccepted = true
        }
        do {
            try store.write(data, at: taskOffset, for: stream.videoId)
        } catch {
            fail(error)
            return
        }
        taskOffset += Int64(data.count)
        serve()
    }

    fileprivate func completed(_ task: URLSessionTask, error: Error?) {
        guard task === self.task else { return }
        self.task = nil
        if let error, (error as? URLError)?.code != .cancelled {
            fail(error)
            return
        }
        // A refusal can come with no body, and so without any bytes to check it on; retrying
        // it would loop.
        if error == nil, !taskAccepted, !accepts(task.response) {
            fail(URLError(.badServerResponse))
            return
        }
        serve()
    }

    private func fail(_ error: Error) {
        failure = error
        task?.cancel()
        task = nil
        serve()
    }
}

nonisolated(unsafe) private var loaderKey: UInt8 = 0

/// The session's delegate. A session keeps its delegate until invalidated, so this holds the
/// loader weakly, letting it go with its asset.
private final class SessionEvents: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    weak var loader: CachingLoader?

    init(loader: CachingLoader) {
        self.loader = loader
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        loader?.received(data, from: dataTask)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        loader?.completed(task, error: error)
    }
}
