import AVFoundation
import WispenCore

enum AudioCaptureError: LocalizedError {
    case permissionDenied
    case noInputDevice

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Microphone access is off. Turn it on in Settings › Privacy › Microphone."
        case .noInputDevice: return "No microphone is available."
        }
    }
}

/// Microphone → 16 kHz mono Float samples (what Whisper wants), plus a level meter.
final class AudioCapture: @unchecked Sendable {
    /// Called on the audio thread with 16 kHz mono samples.
    var onSamples: (([Float]) -> Void)?
    /// Called on the audio thread with a 0…1 level.
    var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioMath.sampleRate,
                                             channels: 1, interleaved: false)!
    private(set) var isRunning = false
    private var observers: [NSObjectProtocol] = []
    /// Called (on the main queue) when another app or a call takes the microphone away.
    var onInterrupted: (() -> Void)?
    /// How many captures (flow session, meeting) are using the shared audio session.
    private static var activeCaptures = 0

    /// Running, and the audio engine hasn't been stopped behind our back (calls, Siri, camera, other apps).
    var isLive: Bool { isRunning && engine.isRunning }

    static func requestPermission() async -> Bool {
        #if os(iOS)
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        }
        return await withCheckedContinuation { cont in
            AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
        }
        #else
        return await AVCaptureDevice.requestAccess(for: .audio)
        #endif
    }

    func start() throws {
        guard !isRunning else { return }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // mixWithOthers: your music/podcast keeps playing while Wispen listens in the background.
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker])
        try session.setActive(true)
        #endif

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw AudioCaptureError.noInputDevice }
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
        isRunning = true
        Self.activeCaptures += 1
        observeInterruptions()
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        Self.activeCaptures = max(0, Self.activeCaptures - 1)
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        #if os(iOS)
        // Only release the shared audio session when nobody else is using it — deactivating it under a
        // running flow session would silently stop that session's microphone.
        if Self.activeCaptures == 0 {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        #endif
    }

    /// If the engine was stopped behind our back, start it again. Throws if iOS won't allow it right now.
    func ensureLive() throws {
        guard isRunning, !engine.isRunning else { return }
        let samples = onSamples, level = onLevel
        stop()
        onSamples = samples
        onLevel = level
        try start()
    }

    /// Restart after a phone call, Siri, or headphones being plugged in/out.
    private func observeInterruptions() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.restart()
        })
        #if os(iOS)
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began { self?.onInterrupted?() } else { self?.restart() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            self?.restart()
        })
        #endif
    }

    private func restart() {
        guard isRunning else { return }
        let samples = onSamples, level = onLevel
        stop()
        onSamples = samples
        onLevel = level
        try? start()
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.floatChannelData, output.frameLength > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
        onLevel?(AudioMath.meterLevel(rms: AudioMath.rms(samples)))
        onSamples?(samples)
    }
}

/// Thread-safe sample accumulator with a short pre-roll, so the first syllable isn't clipped when
/// recording starts on a warm microphone.
final class SampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var preroll: [Float] = []
    private var collecting = false
    private let prerollCount = Int(AudioMath.sampleRate * 0.35)

    func append(_ chunk: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        if collecting {
            samples.append(contentsOf: chunk)
        } else {
            preroll.append(contentsOf: chunk)
            if preroll.count > prerollCount { preroll.removeFirst(preroll.count - prerollCount) }
        }
    }

    func begin() {
        lock.lock()
        samples = preroll
        preroll.removeAll()
        collecting = true
        lock.unlock()
    }

    /// Stops collecting and returns everything recorded.
    func end() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        collecting = false
        let out = samples
        samples.removeAll()
        return out
    }

    var duration: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(samples.count) / AudioMath.sampleRate
    }
}
