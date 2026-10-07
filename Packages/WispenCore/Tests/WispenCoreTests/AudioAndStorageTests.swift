import XCTest
@testable import WispenCore

final class AudioAndStorageTests: XCTestCase {
    func tone(seconds: Double, amplitude: Float) -> [Float] {
        (0..<Int(seconds * 16_000)).map { amplitude * sin(Float($0) * 2 * .pi * 220 / 16_000) }
    }

    func testSpeechDetection() {
        XCTAssertFalse(AudioMath.containsSpeech(tone(seconds: 2, amplitude: 0.001)))
        XCTAssertTrue(AudioMath.containsSpeech(tone(seconds: 1, amplitude: 0.001) + tone(seconds: 1, amplitude: 0.2)))
    }

    func testChunkerCutsAtPause() {
        var chunker = SpeechChunker(targetSeconds: 25, maxSeconds: 30)
        let speech = tone(seconds: 26, amplitude: 0.2) + tone(seconds: 1, amplitude: 0.0001) + tone(seconds: 10, amplitude: 0.2)
        var chunks: [SpeechChunker.Chunk] = []
        for i in stride(from: 0, to: speech.count, by: 1600) {
            chunks += chunker.append(Array(speech[i..<min(i + 1600, speech.count)]))
        }
        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue((26.0...27.0).contains(chunks[0].end), "cut should land inside the pause")
        let rest = chunker.flush()
        XCTAssertNotNil(rest)
        XCTAssertEqual(rest!.start, chunks[0].end, accuracy: 0.001)
    }

    func testChunkerHardCutsContinuousSpeech() {
        var chunker = SpeechChunker(targetSeconds: 25, maxSeconds: 30)
        let chunks = chunker.append(tone(seconds: 65, amplitude: 0.2))
        XCTAssertEqual(chunks.count, 2)
        XCTAssertLessThanOrEqual(chunks[0].end, 30.01)
    }

    func testStoreRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = WispenStore(root: WispenPaths.ensure(dir))
        var settings = WispenSettings()
        settings.defaultStyleID = "casual"
        try store.settingsFile.save(settings)
        XCTAssertEqual(store.loadSettings().defaultStyleID, "casual")

        let m = Meeting(title: "Sync", segments: [TranscriptSegment(start: 0, end: 1, speaker: "Me", text: "Hello.")])
        try store.save(m)
        XCTAssertEqual(store.loadMeetings().first?.transcriptText, "Me: Hello.")

        try store.importLibrary(LibraryBundle(dictionary: [DictionaryEntry(term: "Wispen")], snippets: [Snippet(trigger: "sig", expansion: "Rex")]))
        try store.importLibrary(LibraryBundle(dictionary: [DictionaryEntry(term: "wispen", soundsLike: ["why spin"])]))
        XCTAssertEqual(store.loadDictionary().count, 1)
        XCTAssertEqual(store.loadSnippets().count, 1)
    }

    func testSettingsDecodeToleratesMissingKeys() throws {
        let s = try JSONDecoder().decode(WispenSettings.self, from: Data(#"{"defaultStyleID":"formal"}"#.utf8))
        XCTAssertEqual(s.defaultStyleID, "formal")
        XCTAssertEqual(s.sessionTimeoutMinutes, 15)
    }

    func testFlowStateHeartbeat() {
        let s = FlowSessionState(phase: .ready, heartbeat: Date(timeIntervalSinceNow: -10))
        XCTAssertFalse(s.isAlive())
        XCTAssertTrue(FlowSessionState(phase: .recording).isAlive())
        XCTAssertFalse(FlowSessionState.inactive.isAlive())
    }

    func testAppStyleRules() {
        var s = WispenSettings()
        XCTAssertEqual(AppStyleRules.styleID(forBundleID: "com.apple.MobileSMS", settings: s), "texting")
        s.appStyleOverrides["com.apple.MobileSMS"] = "formal"
        XCTAssertEqual(AppStyleRules.styleID(forBundleID: "com.apple.MobileSMS", settings: s), "formal")
        XCTAssertEqual(AppStyleRules.styleID(forBundleID: "unknown.app", settings: s), "polished")
    }
}
