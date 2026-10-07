import Foundation

/// Audio helpers that don't depend on AVFoundation, so they're unit-testable.
public enum AudioMath {
    public static let sampleRate = 16_000.0

    public static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    public static func rms(_ samples: [Float]) -> Float { rms(samples[...]) }

    /// 0…1 meter value from RMS (roughly −50 dB … 0 dB).
    public static func meterLevel(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return max(0, min(1, (db + 50) / 50))
    }

    /// True when at least `minimumSpeechSeconds` of 30 ms frames rise above an adaptive noise floor.
    public static func containsSpeech(_ samples: [Float], minimumSpeechSeconds: Double = 0.25) -> Bool {
        let frame = Int(sampleRate * 0.03)
        guard samples.count >= frame else { return false }
        var energies: [Float] = []
        var i = 0
        while i + frame <= samples.count {
            energies.append(rms(samples[i..<(i + frame)]))
            i += frame
        }
        let sorted = energies.sorted()
        let floor = sorted[sorted.count / 10]
        let threshold = max(0.008, floor * 3)
        let voiced = energies.filter { $0 > threshold }.count
        return Double(voiced) * 0.03 >= minimumSpeechSeconds
    }
}

/// Cuts a continuous 16 kHz stream into ~30 s chunks at natural pauses, so a long meeting can be
/// transcribed while it's still being recorded and the audio thrown away immediately afterwards.
public struct SpeechChunker: Sendable {
    public struct Chunk: Sendable {
        public var samples: [Float]
        /// Seconds from the start of the stream.
        public var start: Double
        public var end: Double { start + Double(samples.count) / AudioMath.sampleRate }
        public var hasSpeech: Bool { AudioMath.containsSpeech(samples) }
    }

    public var targetSeconds: Double
    public var maxSeconds: Double
    private var buffer: [Float] = []
    private var bufferStart: Double = 0

    public init(targetSeconds: Double = 25, maxSeconds: Double = 30) {
        self.targetSeconds = targetSeconds
        self.maxSeconds = maxSeconds
    }

    public var bufferedSeconds: Double { Double(buffer.count) / AudioMath.sampleRate }

    /// Feed audio; returns any chunks that are ready.
    public mutating func append(_ samples: [Float]) -> [Chunk] {
        buffer.append(contentsOf: samples)
        var out: [Chunk] = []
        while bufferedSeconds >= targetSeconds {
            guard let cut = cutPoint() else { break }
            out.append(take(cut))
        }
        return out
    }

    /// Returns whatever is left (call when recording stops).
    public mutating func flush() -> Chunk? {
        guard !buffer.isEmpty else { return nil }
        return take(buffer.count)
    }

    private mutating func take(_ count: Int) -> Chunk {
        let chunk = Chunk(samples: Array(buffer[..<count]), start: bufferStart)
        buffer.removeFirst(count)
        bufferStart += Double(count) / AudioMath.sampleRate
        return chunk
    }

    /// Quietest 300 ms window between target and max length, or a hard cut at max.
    private func cutPoint() -> Int? {
        let sr = Int(AudioMath.sampleRate)
        let from = Int(targetSeconds * Double(sr))
        let to = min(buffer.count, Int(maxSeconds * Double(sr)))
        if buffer.count < Int(maxSeconds * Double(sr)) {
            // Not at max yet: only cut if we find a clear pause.
            guard let (idx, level) = quietestWindow(from: from, to: to), level < 0.01 else { return nil }
            return idx
        }
        return quietestWindow(from: from, to: to)?.0 ?? to
    }

    private func quietestWindow(from: Int, to: Int) -> (Int, Float)? {
        let window = Int(AudioMath.sampleRate * 0.3)
        let step = Int(AudioMath.sampleRate * 0.1)
        guard to - from >= window else { return nil }
        var best: (Int, Float)?
        var i = from
        while i + window <= to {
            let level = AudioMath.rms(buffer[i..<(i + window)])
            if best == nil || level < best!.1 { best = (i + window / 2, level) }
            i += step
        }
        return best
    }
}
