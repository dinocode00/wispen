import AVFoundation
import Foundation
import WispenCore

/// Keeps a meeting's audio + word timings until you've said who's who, so Wispen can play you each
/// voice and re-detect speakers. Deleted when you finish (or skip) the review, or after 24 hours.
enum SpeakerReviewStore {
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Wispen/SpeakerReview", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func folder(_ meetingID: String) -> URL {
        root.appendingPathComponent(meetingID, isDirectory: true)
    }

    /// Moves a finished spool and its words into the meeting's review folder.
    static func keep(meetingID: String, key: String, spool: AudioSpool, words: [TimedText]) {
        let dir = folder(meetingID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        spool.close()
        let audio = dir.appendingPathComponent("\(key).pcm")
        try? FileManager.default.removeItem(at: audio)
        try? FileManager.default.moveItem(at: spool.url, to: audio)
        try? JSONEncoder().encode(words).write(to: dir.appendingPathComponent("\(key).words.json"))
    }

    /// Source keys with saved audio ("mic", or "Others" on Mac).
    static func keys(_ meetingID: String) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder(meetingID).path)) ?? []
        return files.filter { $0.hasSuffix(".pcm") }.map { String($0.dropLast(4)) }.sorted()
    }

    static func hasAudio(_ meetingID: String) -> Bool { !keys(meetingID).isEmpty }

    static func samples(_ meetingID: String, key: String) -> [Float] {
        guard let data = try? Data(contentsOf: folder(meetingID).appendingPathComponent("\(key).pcm"), options: .mappedIfSafe) else {
            return []
        }
        return data.withUnsafeBytes { raw in raw.bindMemory(to: Int16.self).map { Float($0) / Float(Int16.max) } }
    }

    static func words(_ meetingID: String, key: String) -> [TimedText] {
        guard let data = try? Data(contentsOf: folder(meetingID).appendingPathComponent("\(key).words.json")) else { return [] }
        return (try? JSONDecoder().decode([TimedText].self, from: data)) ?? []
    }

    static func delete(_ meetingID: String) {
        try? FileManager.default.removeItem(at: folder(meetingID))
    }

    /// Deletes review audio older than a day (you never finished the review).
    static func purgeExpired(maxAge: TimeInterval = 24 * 3600) {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for dir in dirs {
            let created = (try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if Date().timeIntervalSince(created) > maxAge { try? FileManager.default.removeItem(at: dir) }
        }
    }

    /// A playable WAV clip of the meeting between two times.
    static func clip(_ meetingID: String, start: Double, end: Double) -> Data? {
        guard let key = keys(meetingID).first,
              let handle = try? FileHandle(forReadingFrom: folder(meetingID).appendingPathComponent("\(key).pcm")) else { return nil }
        defer { try? handle.close() }
        let rate = AudioMath.sampleRate
        let from = UInt64(max(0, start - 0.2) * rate) * 2
        let length = Int(max(0.5, min(end - start + 0.4, 15)) * rate) * 2
        try? handle.seek(toOffset: from)
        guard let pcm = try? handle.read(upToCount: length), !pcm.isEmpty else { return nil }
        return wav(pcm: pcm, sampleRate: Int(rate))
    }

    private static func wav(pcm: Data, sampleRate: Int) -> Data {
        func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        var d = Data("RIFF".utf8)
        d += le32(36 + pcm.count)
        d += Data("WAVEfmt ".utf8)
        d += le32(16) + le16(1) + le16(1) + le32(sampleRate) + le32(sampleRate * 2) + le16(2) + le16(16)
        d += Data("data".utf8) + le32(pcm.count)
        d += pcm
        return d
    }
}

/// Plays short clips so you can recognize each voice.
@MainActor
final class SnippetPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playingID: String?
    private var player: AVAudioPlayer?

    func toggle(_ segment: TranscriptSegment, meetingID: String) {
        if playingID == segment.id {
            stop()
            return
        }
        guard let data = SpeakerReviewStore.clip(meetingID, start: segment.start, end: segment.end) else { return }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // Don't disturb a running dictation session (it already allows playback).
        if session.category != .playAndRecord {
            try? session.setCategory(.playback, options: [.mixWithOthers])
            try? session.setActive(true)
        }
        #endif
        player = try? AVAudioPlayer(data: data)
        player?.delegate = self
        player?.play()
        playingID = segment.id
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.playingID = nil }
    }
}
