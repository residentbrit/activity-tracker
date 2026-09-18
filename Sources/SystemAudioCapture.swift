import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Captures what the Mac is *playing* — the far end of a call.
///
/// The microphone tap alone records the room, so a meeting heard through
/// headphones is invisible to it. Measured 2026-09-18: two Teams meetings
/// yielded ~10–12% of the meeting's speech, because the only voice reaching the
/// mic was the local one. The transcripts read like one side of a conversation
/// because they were one side.
///
/// ScreenCaptureKit closes that gap with **no virtual audio driver and no extra
/// permission** — it rides the Screen Recording grant the app already holds.
/// Verified before building: `capturesAudio` delivers 48 kHz stereo float32, and
/// a paired `afplay` test showed clean RMS spikes at exactly the seconds sound
/// was produced and silence elsewhere.
///
/// Output is deliberately the **same format as the mic tap** — 48 kHz mono
/// Int16 — so the two streams share a byte rate and their segment offsets are
/// directly comparable when merging. Resampling to 16 kHz would save disk, but
/// whisper resamples internally anyway and matching formats removes an entire
/// class of alignment bug.
final class SystemAudioCapture: NSObject, SCStreamOutput {

    /// Receives 48 kHz mono Int16 PCM. Called on a private serial queue.
    var onSamples: ((Data) -> Void)?

    private var stream: SCStream?
    private var isRunning = false
    private let queue = DispatchQueue(label: "activity-tracker.system-audio")

    /// Start capturing system output.
    ///
    /// Returns false rather than throwing when the capture is unavailable, so a
    /// meeting degrades to mic-only instead of failing to record at all.
    func start() async -> Bool {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            guard let display = content.displays.first else {
                log("[SystemAudioCapture] no display available\n")
                return false
            }

            let config = SCStreamConfiguration()
            // Video is not wanted; keep it minimal so the stream costs nothing.
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.capturesAudio = true
            // Never record our own output, which would feed back.
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48000
            config.channelCount = 2

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try await stream.startCapture()

            self.stream = stream
            isRunning = true
            return true
        } catch {
            log("[SystemAudioCapture] unavailable: \(error.localizedDescription)\n")
            return false
        }
    }

    func stop() async {
        guard let stream, isRunning else { return }
        isRunning = false
        self.stream = nil
        try? await stream.stopCapture()
    }

    // MARK: - SCStreamOutput

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                    totalLengthOut: &length, dataPointerOut: &pointer)
        guard let base = pointer, length > 0 else { return }

        let asbd = asbdPointer.pointee
        let channels = max(1, Int(asbd.mChannelsPerFrame))
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        var mono: [Int16] = []

        if isFloat {
            let frames = length / (MemoryLayout<Float>.size * channels)
            guard frames > 0 else { return }
            mono.reserveCapacity(frames)
            base.withMemoryRebound(to: Float.self, capacity: frames * channels) { samples in
                for frame in 0..<frames {
                    var sum: Float = 0
                    for channel in 0..<channels { sum += samples[frame * channels + channel] }
                    let clamped = Swift.max(-1, Swift.min(1, sum / Float(channels)))
                    mono.append(Int16(clamped * Float(Int16.max)))
                }
            }
        } else {
            let frames = length / (MemoryLayout<Int16>.size * channels)
            guard frames > 0 else { return }
            mono.reserveCapacity(frames)
            base.withMemoryRebound(to: Int16.self, capacity: frames * channels) { samples in
                for frame in 0..<frames {
                    var sum = 0
                    for channel in 0..<channels { sum += Int(samples[frame * channels + channel]) }
                    mono.append(Int16(clamping: sum / channels))
                }
            }
        }

        onSamples?(mono.withUnsafeBytes { Data($0) })
    }
}
