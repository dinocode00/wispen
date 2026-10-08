import Foundation
import SpeakerKit
import WispenCore

/// "Who spoke when" for a recording, on-device with SpeakerKit (pyannote on the Neural Engine).
/// The model (~30 MB) downloads on first use and is reused from disk afterwards.
actor SpeakerDiarizer {
    private var kit: SpeakerKit?

    func diarize(_ samples: [Float], progress: (@Sendable (Double) -> Void)? = nil) async throws -> [SpeakerTurn] {
        if kit == nil {
            kit = try await SpeakerKit(PyannoteConfig(modelRepo: "argmaxinc/speakerkit-coreml", verbose: false, logLevel: .error))
        }
        guard let kit else { return [] }
        let result = try await kit.diarize(audioArray: samples, options: PyannoteDiarizationOptions()) { p in
            progress?(p.fractionCompleted)
        }
        return result.segments.compactMap { segment in
            guard let id = segment.speaker.speakerId else { return nil }
            return SpeakerTurn(speaker: id, start: Double(segment.startTime), end: Double(segment.endTime))
        }
    }

    /// Frees the models (they're only needed right after a meeting).
    func unload() async {
        await kit?.unloadModels()
        kit = nil
    }
}

/// Temporary on-disk copy of a meeting's audio (16-bit, ~115 MB/hour), kept only until speakers have
/// been identified, then deleted. Never leaves the device.
final class AudioSpool: @unchecked Sendable {
    let url: URL
    private let handle: FileHandle?
    private let lock = NSLock()

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("wispen-meeting-\(UUID().uuidString).pcm")
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        handle = try? FileHandle(forWritingTo: url)
    }

    func append(_ samples: [Float]) {
        var pcm = [Int16](repeating: 0, count: samples.count)
        for i in samples.indices { pcm[i] = Int16(max(-1, min(1, samples[i])) * Float(Int16.max)) }
        let data = pcm.withUnsafeBufferPointer { Data(buffer: $0) }
        lock.lock()
        handle?.write(data)
        lock.unlock()
    }

    func readAll() -> [Float] {
        lock.lock()
        try? handle?.synchronize()
        lock.unlock()
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        return data.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float($0) / Float(Int16.max) }
        }
    }

    func delete() {
        lock.lock()
        try? handle?.close()
        lock.unlock()
        try? FileManager.default.removeItem(at: url)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}
