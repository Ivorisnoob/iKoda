import Foundation
import Testing
@testable import KodaCore

struct KodaAvatarTests {
    // Golden values: a profile's default avatar must not change between
    // launches, builds or platforms, so these are fixed, not recomputed.
    @Test func seededAvatarsAreFixed() {
        #expect(KodaAvatar.seeded("koda") == KodaAvatar(shape: 6, color: 9, eyes: 0, mouth: 1, extra: 5, blush: false))
        #expect(KodaAvatar.seeded("8d1f2c4e-0b7a-4c55-9e36-5f0a2b1c9d77")
            == KodaAvatar(shape: 1, color: 9, eyes: 0, mouth: 0, extra: 2, blush: true))
        #expect(KodaAvatar.seeded("Ivor") == KodaAvatar(shape: 5, color: 4, eyes: 3, mouth: 1, extra: 5, blush: true))
        #expect(KodaAvatar.seeded("") == KodaAvatar(shape: 0, color: 10, eyes: 5, mouth: 4, extra: 5, blush: true))
    }

    @Test func sameSeedSameAvatar() {
        #expect(KodaAvatar.seeded("profile-1") == KodaAvatar.seeded("profile-1"))
    }

    @Test func differentSeedsDiffer() {
        let avatars = Set((0..<50).map { KodaAvatar.seeded("profile-\($0)") })
        // Fifty ids land on (nearly) fifty different faces, not one.
        #expect(avatars.count > 40)
        #expect(KodaAvatar.seeded("a") != KodaAvatar.seeded("b"))
    }

    @Test func randomStaysInRange() {
        var generator = SplitMix64(state: 42)
        for _ in 0..<500 {
            let avatar = KodaAvatar.random(using: &generator)
            #expect((0..<KodaAvatar.shapes).contains(avatar.shape))
            #expect((0..<KodaAvatar.colors).contains(avatar.color))
            #expect((0..<KodaAvatar.eyeStyles).contains(avatar.eyes))
            #expect((0..<KodaAvatar.mouths).contains(avatar.mouth))
            #expect((0..<KodaAvatar.extras).contains(avatar.extra))
        }
    }

    @Test func indicesPastTheEndWrap() {
        let avatar = KodaAvatar(shape: 10, color: 13, eyes: -1, mouth: 6, extra: 7, blush: false)
        #expect(avatar.shapeIndex == 1)
        #expect(avatar.colorIndex == 1)
        #expect(avatar.eyesIndex == 5)
        #expect(avatar.mouthIndex == 0)
        #expect(avatar.extraIndex == 1)
        #expect(avatar.colorway == KodaAvatar.colorways[1])
    }

    @Test func colorwaysMatchAndroid() {
        #expect(KodaAvatar.colors == 12)
        let peach = KodaAvatar.colorways[0]
        #expect(peach.fill == KodaAvatar.RGB(0xFFD8C2))
        #expect(abs(peach.fill.red - 1) < 0.0001)
        #expect(abs(peach.fill.blue - 194.0 / 255) < 0.0001)
        #expect(KodaAvatar.colorways[11].name == "Night")
    }

    @Test func roundTrips() throws {
        let avatar = KodaAvatar(shape: 3, color: 7, eyes: 2, mouth: 5, extra: 4, blush: true)
        let data = try JSONEncoder().encode(avatar)
        #expect(try JSONDecoder().decode(KodaAvatar.self, from: data) == avatar)
    }

    @Test func decodesPartialJSON() throws {
        let old = Data(#"{"shape": 2, "color": 5}"#.utf8)
        let avatar = try JSONDecoder().decode(KodaAvatar.self, from: old)
        #expect(avatar == KodaAvatar(shape: 2, color: 5, eyes: 0, mouth: 0, extra: 0, blush: false))
        #expect(try JSONDecoder().decode(KodaAvatar.self, from: Data("{}".utf8)) == KodaAvatar())
    }

    @Test func decodesUnknownKeysAndFutureIndices() throws {
        let newer = Data(#"{"shape": 14, "color": 30, "eyes": 1, "mouth": 2, "extra": 9, "blush": true, "hat": 3}"#.utf8)
        let avatar = try JSONDecoder().decode(KodaAvatar.self, from: newer)
        #expect(avatar.shape == 14)
        #expect(avatar.shapeIndex == 5)
        #expect(avatar.colorIndex == 6)
    }
}
