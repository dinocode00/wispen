import AVFoundation
import CoreMedia
import ScreenCaptureKit
import WispenCore

/// Captures what your Mac is playing (the other people on a Zoom/Meet/Teams call) with
/// ScreenCaptureKit, so meeting transcripts can label "Me" vs "Others".
/// Needs Screen & System Audio Recording permission (macOS asks the first time).
final class SystemAudioSource: NSObject, MeetingAudioSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let label: String? = "Others"
    var onSamples: (([Float]) -> Void)?
    var onLevel: ((Float) -> Void)?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "app.wispen.system-audio")
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioMath.sampleRate,
                                             channels: 1, interleaved: false)!

    enum SourceError: LocalizedError {
        case noDisplay
        var errorDescription: String? { "No display available for system audio capture." }
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw SourceError.noDisplay }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        // We only want audio; keep the (mandatory) video stream tiny and slow.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        stream?.stopCapture { _ in }
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        if converterInputFormat != pcm.format {
            converter = AVAudioConverter(from: pcm.format, to: targetFormat)
            converterInputFormat = pcm.format
        }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(pcm.frameLength) * targetFormat.sampleRate / pcm.format.sampleRate) + 64
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
            return pcm
        }
        guard error == nil, let channel = output.floatChannelData, output.frameLength > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
        onLevel?(AudioMath.meterLevel(rms: AudioMath.rms(samples)))
        onSamples?(samples)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}
