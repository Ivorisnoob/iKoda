import Foundation
import Testing
@testable import KodaCore

@Suite struct LyricsTests {
    @Test func parsesStampsAndRepeatedLines() {
        let lines = Lyrics.parseLRC("""
        [ar:Someone]
        [00:13.13] Yeah
        [00:27.16] I've been tryna call
        [01:02.50][02:10.00] Chorus
        not a lyric
        """)
        #expect(lines.map(\.text) == ["Yeah", "I've been tryna call", "Chorus", "Chorus"])
        #expect(lines[0].time == 13.13)
        #expect(lines[3].time == 130)
        #expect(lines.map(\.id) == [0, 1, 2, 3])
    }

    @Test func findsTheLineThatHasStarted() {
        let lines = Lyrics.parseLRC("[00:10.00] a\n[00:20.00] b\n[00:30.00] c")
        #expect(Lyrics.index(of: 5, in: lines) == nil)
        #expect(Lyrics.index(of: 10, in: lines) == 0)
        #expect(Lyrics.index(of: 29.9, in: lines) == 1)
        #expect(Lyrics.index(of: 500, in: lines) == 2)
    }
}

@Suite struct WordLyricsTests {
    private func text(_ name: String, _ ext: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Both services return the same Apple-timed lyrics for Blinding Lights, in different shapes.
    private func checkBlindingLights(_ lines: [LyricLine]) throws {
        #expect(lines.count == 35)
        let first = try #require(lines.first)
        #expect(first.text == "I been tryna call")
        #expect(first.words.map(\.text) == ["I", "been", "tryna", "call"])
        #expect(abs(first.words[0].start - 27.395) < 0.001)
        #expect(abs(first.words[0].end - 27.549) < 0.001)
        // "e" and "nough" are two syllables of one word.
        let second = lines[1]
        #expect(second.text == "I've been on my own for long enough")
        #expect(second.words.first { $0.text == "e" }?.spaceAfter == false)
        // Backing vocals stay out of the line and keep their own timing.
        let echoed = try #require(lines.first { !$0.background.isEmpty })
        #expect(echoed.text == "I'm just calling back to let you know")
        #expect(echoed.background.map(\.text) == ["(Back", "to", "let", "you", "know)"])
        #expect(lines.map(\.id) == Array(0..<35))
        #expect(lines.allSatisfy { $0.voice == .lead })
    }

    @Test func readsAppleTTML() throws {
        let lines = try #require(Lyrics.parseTTML(try text("lyrics-ttml", "xml")))
        try checkBlindingLights(lines)
    }

    @Test func readsYouLyPlusJSON() throws {
        let lines = try #require(Lyrics.parseYouLyPlus(try fixture("lyrics-youlyplus")))
        try checkBlindingLights(lines)
    }

    @Test func unwrapsTTMLInsideJSON() throws {
        let ttml = try text("lyrics-ttml", "xml")
        let body = try JSONSerialization.data(withJSONObject: ["ttml": ttml])
        let lyrics = try #require(LyricsClient.decodeWrapped(body))
        #expect(lyrics.quality == 2)
    }

    @Test func readsEnhancedLRC() {
        let lines = Lyrics.parseLRC("[00:10.00]<00:10.00>Hello <00:10.50>world\n[00:20.00]Next")
        #expect(lines[0].text == "Hello world")
        #expect(lines[0].words.map(\.text) == ["Hello", "world"])
        #expect(lines[0].words[0].end == 10.5)
        #expect(lines[0].words[1].end == 20)
        #expect(lines[1].words.isEmpty)
    }

    @Test func alternatesDuetSingers() {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata"><head><metadata>
        <ttm:agent type="person" xml:id="v1"/><ttm:agent type="person" xml:id="v2"/><ttm:agent type="group" xml:id="v1000"/>
        </metadata></head><body>
        <p begin="1.0" end="2.0" ttm:agent="v1">One</p>
        <p begin="3.0" end="4.0" ttm:agent="v2">Two</p>
        <p begin="5.0" end="6.0" ttm:agent="v1000">All</p>
        </body></tt>
        """
        let lines = Lyrics.parseTTML(ttml)
        #expect(lines?.map(\.voice) == [.lead, .duet, .together])
        #expect(lines?.map(\.text) == ["One", "Two", "All"])
        #expect(lines?.allSatisfy { !$0.isWordTimed } == true)
    }

    @Test func readsTTMLTimes() {
        #expect(Lyrics.ttmlTime("27.395") == 27.395)
        #expect(Lyrics.ttmlTime("2:19.5") == 139.5)
        #expect(Lyrics.ttmlTime("1:00:00") == 3600)
        #expect(Lyrics.ttmlTime("500ms") == 0.5)
        #expect(Lyrics.ttmlTime("12s") == 12)
        #expect(Lyrics.ttmlTime("abc") == nil)
    }
}

@Suite struct LyricsRomanizerTests {
    private func isLatin(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        return text.unicodeScalars.allSatisfy { $0.isASCII || (0xC0...0x24F).contains($0.value) }
    }

    @Test func latinLyricsNeedNothing() {
        #expect(LyricsRomanizer.romanize("I been tryna call", language: "en") == nil)
        #expect(LyricsRomanizer.romanize("Corazón, ¿dónde estás?", language: "es") == nil)
        #expect(!LyricsRomanizer.needsRomanization(["I been tryna call", "Café"]))
    }

    @Test func otherScriptsComeOutInLatinLetters() {
        #expect(LyricsRomanizer.romanize("привет", language: "ru") == "privet")
        #expect(isLatin(LyricsRomanizer.romanize("사랑해", language: "ko")))
        #expect(isLatin(LyricsRomanizer.romanize("नमस्ते दुनिया", language: "hi")))
        #expect(isLatin(LyricsRomanizer.romanize("我爱你", language: "zh-Hans")))
        #expect(LyricsRomanizer.needsRomanization(["Hello", "사랑해"]))
    }

    /// Kanji read the Japanese way: 君 is "kimi", not the Chinese "jun".
    @Test func japaneseIsReadAsJapanese() throws {
        let romaji = try #require(LyricsRomanizer.romanize("君の名は", language: "ja"))
        #expect(isLatin(romaji))
        #expect(romaji.lowercased().hasPrefix("kimi"))
    }

    @Test func tellsTheLanguageFromAllTheLines() {
        let lines = ["君の名前を呼んだ", "夜空に星が光る", "ずっと一緒にいたい"]
        #expect(LyricsRomanizer.language(of: lines) == "ja")
    }
}
