import XCTest
@testable import WispenCore

final class KeyboardThemeTests: XCTestCase {
    func testDefaultsAreBlackWithArcane() {
        let t = KeyboardTheme()
        XCTAssertEqual(t.look, .black)
        XCTAssertEqual(t.effect, .arcane)
        XCTAssertTrue(t.combo)
        XCTAssertTrue(t.popups)
    }

    func testRoundTripInsideSettings() throws {
        var s = WispenSettings()
        s.keyboardTheme = KeyboardTheme(look: .neon, effect: .fire)
        s.keyboardTheme.neon = "#B6FF3B"
        s.keyboardTheme.custom.roundness = 4
        let back = try JSONDecoder().decode(WispenSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.keyboardTheme, s.keyboardTheme)
    }

    func testOldSettingsFileWithoutThemeStillLoads() throws {
        let json = #"{"keyboardHaptics": false, "keyboardSounds": true}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(WispenSettings.self, from: json)
        XCTAssertTrue(s.keyboardSounds)
        XCTAssertEqual(s.keyboardTheme, KeyboardTheme())
    }

    func testUnknownValuesFallBackInsteadOfWipingSettings() throws {
        let json = #"""
        {"keyboardAutoCorrect": false,
         "keyboardTheme": {"look": "hologram", "effect": "fire", "neon": "nope",
                           "custom": {"roundness": 99, "glowStrength": -1, "font": "comic", "keys": "#abc"}}}
        """#.data(using: .utf8)!
        let s = try JSONDecoder().decode(WispenSettings.self, from: json)
        XCTAssertFalse(s.keyboardAutoCorrect)
        XCTAssertEqual(s.keyboardTheme.look, .black)
        XCTAssertEqual(s.keyboardTheme.effect, .fire)
        XCTAssertEqual(s.keyboardTheme.neon, KeyboardTheme.neonColors[0])
        XCTAssertEqual(s.keyboardTheme.custom.roundness, 22)
        XCTAssertEqual(s.keyboardTheme.custom.glowStrength, 0)
        XCTAssertEqual(s.keyboardTheme.custom.font, .rounded)
        XCTAssertEqual(s.keyboardTheme.custom.keys, "#AABBCC")
    }

    func testPixelEffectsOnlyForPixelLooks() {
        XCTAssertTrue(KeyboardTheme(look: .retro).isPixel)
        var t = KeyboardTheme(look: .custom)
        XCTAssertFalse(t.isPixel)
        t.custom.font = .pixel
        XCTAssertTrue(t.isPixel)
        t.look = .neon
        XCTAssertFalse(t.isPixel)
    }

    func testComboIntensityGrowsAndCaps() {
        XCTAssertEqual(KeyboardTheme.intensity(streak: 1, combo: false), 1)
        XCTAssertEqual(KeyboardTheme.intensity(streak: 50, combo: false), 1)
        XCTAssertEqual(KeyboardTheme.intensity(streak: 0, combo: true), 1)
        XCTAssertEqual(KeyboardTheme.intensity(streak: 15, combo: true), 2)
        XCTAssertEqual(KeyboardTheme.intensity(streak: 400, combo: true), 3)
    }

    func testHexHelpers() {
        XCTAssertEqual(HexColor.normalized("#fff"), "#FFFFFF")
        XCTAssertEqual(HexColor.normalized("39f3ff"), "#39F3FF")
        XCTAssertNil(HexColor.normalized("#12345"))
        XCTAssertNil(HexColor.normalized("purple"))
        XCTAssertEqual(HexColor.mix("#000000", "#FFFFFF", 0.5), "#808080")
        XCTAssertEqual(HexColor.luminance("#FFFFFF"), 1, accuracy: 0.001)
        XCTAssertEqual(HexColor.luminance("#000000"), 0, accuracy: 0.001)
    }
}
