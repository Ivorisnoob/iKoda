import Foundation
import Testing
@testable import KodaCore

/// Against real Apple Music answers (November 2026): a catalogue search for
/// "Espresso Sabrina Carpenter", and from it the square ladder of emails i can't send's
/// animated cover and its leanest 960 px rung's media playlist.
@Suite struct MotionArtworkTests {
    private func fixture(_ name: String, _ ext: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func search() throws -> JSON {
        try JSON(data: Data(fixture("motion-search", "json").utf8))
    }

    private func song(_ title: String, artist: String = "Sabrina Carpenter", album: String?,
                      duration: TimeInterval? = 175, isVideo: Bool = false) -> Song {
        Song(id: "x", title: title, artistLine: artist, artists: [ArtistRef(id: "UC1", name: artist)],
             album: album.map { AlbumRef(id: "MPREb_1", title: $0) }, duration: duration, isVideo: isVideo)
    }

    @Test func findsTheAlbumsCoversForTheSongPlaying() throws {
        let covers = try #require(MotionArtworkCatalog.covers(in: search(), for: song("Espresso", album: "Short n' Sweet")))
        #expect(covers.albumID == "1752214909")
        #expect(covers.masters[.square]?.lastPathComponent == "P899578198_default.m3u8")
        #expect(covers.masters[.tall]?.lastPathComponent == "P899565453_default.m3u8")
        let preview = try #require(covers.preview(.tall, pixels: 600))
        #expect(preview.lastPathComponent == "600x800bb.jpg")
    }

    @Test func curlyAndStraightApostrophesAgree() throws {
        let covers = MotionArtworkCatalog.covers(in: try search(), for: song("Tears", album: "Man's Best Friend", duration: 160))
        #expect(covers?.albumID == "1819861154")
    }

    /// Espresso is also a single, and the single's cover doesn't move: the album's cover
    /// must not stand in for it.
    @Test func anotherReleaseOfTheSongDoesNotLendItsCover() throws {
        #expect(MotionArtworkCatalog.covers(in: try search(), for: song("Espresso", album: "Espresso")) == nil)
    }

    @Test func refusesNearMisses() throws {
        let json = try search()
        // Same title and album, another artist.
        #expect(MotionArtworkCatalog.covers(in: json, for: song("Espresso", artist: "Vitamin String Quartet", album: "Short n' Sweet")) == nil)
        // A different length is a different recording.
        #expect(MotionArtworkCatalog.covers(in: json, for: song("Espresso", album: "Short n' Sweet", duration: 240)) == nil)
        // Music videos and songs without an album aren't looked up at all.
        #expect(MotionArtworkCatalog.covers(in: json, for: song("Espresso", album: "Short n' Sweet", isVideo: true)) == nil)
        #expect(MotionArtworkCatalog.covers(in: json, for: song("Espresso", album: nil)) == nil)
    }

    @Test func titlesAndAlbumsAreComparedWithoutTheirDecorations() {
        #expect(MotionArtworkCatalog.title("Song (feat. Someone)") == MotionArtworkCatalog.title("Song"))
        #expect(MotionArtworkCatalog.title("Song [with Someone]") == "song")
        #expect(MotionArtworkCatalog.title("Song (Live)") != "song")
        #expect(MotionArtworkCatalog.album("Espresso - Single") == "espresso")
        #expect(MotionArtworkCatalog.album("Brat - EP") == "brat")
        #expect(MotionArtworkCatalog.normalized("Man’s Best Friend") == "man s best friend")
    }

    @Test func readsTheLadderAndPicksTheLeanestRungThatFills() throws {
        let master = URL(string: "https://mvod.itunes.apple.com/itunes-assets/HLSMusic122/v4/b2/9e/4c/b29e4c99/P476477099_default.m3u8")!
        let variants = MotionArtworkCatalog.variants(master: master, playlist: try fixture("motion-master", "m3u8"))
        // 29 video rungs; the 8 I-frame trick-play rungs are not among them.
        #expect(variants.count == 29)
        #expect(!variants.contains { $0.url.lastPathComponent.contains("iframe") })

        // A phone's full-width cover, about 1026 px: the 960 rung, at its leanest encode (HEVC).
        let phone = try #require(MotionArtworkCatalog.pick(variants, pixels: 1026))
        #expect(phone.width == 960)
        #expect(phone.hevc)
        #expect(phone.bandwidth == variants.filter { $0.width == 960 }.map(\.bandwidth).min())

        // Never past 1080, however large the request.
        #expect(MotionArtworkCatalog.pick(variants, pixels: 2732)?.width == 960)
        #expect(MotionArtworkCatalog.pick(variants, pixels: 1300)?.width ?? 0 <= 1080)
        // Small asks get small files.
        #expect(MotionArtworkCatalog.pick(variants, pixels: 400)?.width == 360)
    }

    @Test func refusesLaddersFromElsewhere() throws {
        let playlist = try fixture("motion-master", "m3u8")
        #expect(MotionArtworkCatalog.variants(master: URL(string: "https://example.com/a.m3u8")!, playlist: playlist).isEmpty)
        #expect(MotionArtworkCatalog.variants(master: URL(string: "http://mvod.itunes.apple.com/a.m3u8")!, playlist: playlist).isEmpty)
    }

    @Test func aRungIsOneFileCutIntoRanges() throws {
        let media = URL(string: "https://mvod.itunes.apple.com/itunes-assets/HLSMusic112/v4/7e/P476477099_Anull_video_gr650_sdr_960x960_-.m3u8")!
        let playlist = try fixture("motion-media", "m3u8")
        let file = try #require(MotionArtworkCatalog.singleFile(media: media, playlist: playlist))
        #expect(file.absoluteString == "https://mvod.itunes.apple.com/itunes-assets/HLSMusic112/v4/7e/P476477099_Anull_video_gr650_sdr_960x960_-.mp4")

        // A gap in the ranges, or segments in files of their own, can't be one download.
        let gapped = playlist.replacingOccurrences(of: "#EXT-X-BYTERANGE:1307732@819244", with: "#EXT-X-BYTERANGE:1307732@819000")
        #expect(MotionArtworkCatalog.singleFile(media: media, playlist: gapped) == nil)
        let segmented = "#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\",BYTERANGE=\"900@0\"\n#EXTINF:2,\n#EXT-X-BYTERANGE:100@900\nseg1.m4s\n#EXT-X-ENDLIST\n"
        #expect(MotionArtworkCatalog.singleFile(media: media, playlist: segmented) == nil)
    }

    private func token(_ payload: String) -> String {
        let body = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return "eyJhbGciOiJFUzI1NiJ9.\(body).c2ln"
    }

    @Test func takesMusicOnTheWebsTokenWhileItHasAnHourLeft() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let good = token(#"{"iss":"AMPWebPlay","exp":1800100000}"#)
        let ending = token(#"{"iss":"AMPWebPlay","exp":1800001000}"#)
        let other = token(#"{"iss":"5IKPP2IECQ","exp":1800100000}"#)
        #expect(MotionArtworkCatalog.isUsableToken(good, now: now))
        #expect(!MotionArtworkCatalog.isUsableToken(ending, now: now))
        #expect(!MotionArtworkCatalog.isUsableToken(other, now: now))
        #expect(!MotionArtworkCatalog.isUsableToken("eyJ.not.json", now: now))
        let script = "var a=\"\(other)\";var b=\"\(good)\";"
        #expect(MotionArtworkCatalog.webToken(inScript: script, now: now) == good)
    }

    @Test func findsTheScriptBundleAndKeepsToApplesHosts() {
        let page = #"<link rel="modulepreload" href="/assets/vendor~1.js"><script type="module" src="/assets/index~cc245af156.js"></script>"#
        #expect(MotionArtworkCatalog.scriptPath(inPage: page) == "/assets/index~cc245af156.js")
        #expect(MotionArtworkCatalog.isWebURL(URL(string: "https://music.apple.com/us/new")!))
        #expect(!MotionArtworkCatalog.isWebURL(URL(string: "https://music.apple.com.evil.example/")!))
        #expect(MotionArtworkCatalog.isMediaURL(URL(string: "https://is1-ssl.mzstatic.com/image/a.jpg")!))
        #expect(!MotionArtworkCatalog.isMediaURL(URL(string: "https://mzstatic.com.evil.example/a.jpg")!))
    }

    /// The shape `MotionArtwork` keeps its answers in, to seed one without the network.
    private struct SeededLookup: Codable {
        var covers: MotionArtwork.Covers?
        var until: Date
    }

    @Test func oneSongsCoverServesItsAlbumAndAnswersSurviveARelaunch() async throws {
        let directory = URL.temporaryDirectory.appending(path: "motion-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let covers = try #require(MotionArtworkCatalog.covers(in: search(), for: song("Espresso", album: "Short n' Sweet")))
        // As a found cover left it: by song, and by the YouTube album it is on.
        let seeded: [String: SeededLookup] = [
            "x": SeededLookup(covers: covers, until: .now + 3600),
            "album:MPREb_1": SeededLookup(covers: covers, until: .now + 3600),
            "nothing": SeededLookup(covers: nil, until: .now + 3600),
        ]
        try JSONEncoder().encode(seeded).write(to: directory.appending(path: "lookups.json"))
        try Data([0xFF, 0xD8]).write(to: directory.appending(path: "\(covers.albumID)-tall-preview.jpg"))

        let motion = MotionArtwork(directory: directory)
        // Another song from the album: no search, the album's cover.
        var other = song("Taste", album: "Short n' Sweet")
        other.id = "y"
        #expect(await motion.covers(for: other, allowsCellular: false) == covers)
        // The same song reaching the player without its album still has its cover.
        #expect(await motion.covers(for: song("Espresso", album: nil), allowsCellular: false) == covers)
        // A song known to have none isn't asked about again.
        var none = song("Please Please Please", album: "Short n' Sweet")
        none.id = "nothing"
        #expect(await motion.covers(for: none, allowsCellular: false) == nil)
        // The Lock Screen's still frame comes from disk.
        #expect(await motion.previewImage(covers, shape: .tall, pixels: 600, allowsCellular: false) == Data([0xFF, 0xD8]))
    }

    @Test func aSongWithoutItsAlbumIsAskedAboutOnceAndAFailureIsntRemembered() async throws {
        let directory = URL.temporaryDirectory.appending(path: "motion-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let covers = try #require(MotionArtworkCatalog.covers(in: search(), for: song("Espresso", album: "Short n' Sweet")))
        // The album YouTube names is one whose cover is already known.
        let seeded = ["album:MPREb_1": SeededLookup(covers: covers, until: .now + 3600)]
        try JSONEncoder().encode(seeded).write(to: directory.appending(path: "lookups.json"))
        let asked = Counter()
        let motion = MotionArtwork(directory: directory) { id in
            await asked.add()
            if id == "offline" { throw URLError(.notConnectedToInternet) }
            return id == "single" ? nil : AlbumRef(id: "MPREb_1", title: "Short n' Sweet")
        }
        var bare = song("Espresso", album: nil)
        bare.id = "bare"
        #expect(await motion.covers(for: bare, allowsCellular: false) == covers)
        var single = song("Lone Upload", album: nil)
        single.id = "single"
        #expect(await motion.covers(for: single, allowsCellular: false) == nil)
        #expect(await motion.covers(for: single, allowsCellular: false) == nil)
        var offline = song("Espresso", album: nil)
        offline.id = "offline"
        #expect(await motion.covers(for: offline, allowsCellular: false) == nil)
        #expect(await motion.covers(for: offline, allowsCellular: false) == nil)
        // Asked once for each song it learned something about; a failure is asked again.
        #expect(await asked.value == 4)
    }

    private actor Counter {
        var value = 0
        func add() { value += 1 }
    }

    /// Real network: Music on the web's token, the catalogue, and the loop download.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KODA_LIVE"] == "1"))
    func liveAnimatedCover() async throws {
        let directory = URL.temporaryDirectory.appending(path: "motion-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let motion = MotionArtwork(directory: directory)
        let covers = try #require(await motion.covers(for: song("Espresso", album: "Short n' Sweet"), allowsCellular: true))
        let file = try #require(await motion.loop(covers, shape: .square, pixels: 1000, allowsCellular: true))
        let size = try #require(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(size > 1 << 20)
        // Asked again, it's the same file, with no download.
        #expect(await motion.loop(covers, shape: .square, pixels: 900, allowsCellular: false) == file)
    }
}
