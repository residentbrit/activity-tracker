import Foundation
import AVFoundation

/// Meetings-only audio capture (D5).
///
/// Periodically checks meeting state via MeetingDetector. When a meeting starts:
/// taps the mic via AVAudioEngine and accumulates **all** PCM for the duration.
/// When it ends: transcribes the whole recording via whisper.cpp, stores the
/// transcript + embedding, and discards the raw audio.
///
/// The energy VAD is deliberately NOT used to gate retention any more. Speech is
/// amplitude-modulated internally — inter-word gaps and unvoiced consonants fall
/// below any fixed threshold — so gating each ~85ms buffer independently kept only
/// the loud fragments, concatenated into a mosaic. Measured 2026-09-18: a
/// 21-minute Teams meeting retained 2.5 minutes of audio, and whisper then
/// produced 903 chars/min on what it received, i.e. normal density. All of the
/// loss was the gate. The VAD survives as a diagnostic only — see
/// `vadPassedBuffers` and `peakRMS`.
///
/// Audio capture is disabled if `audioMode` is `.off` in config.
actor AudioCapture {
    private var config: Config
    private let db: Database
    private let eventStore: EventStore
    private var meetingDetector: MeetingDetector
    private var embedder: Embedder

    private var isInMeeting = false
    private var currentMeetingApp: String?
    private var meetingStartTime: Date?
    private var currentMeetingSession: Session?
    private var audioEngine: AVAudioEngine?
    private var meetingAudio: [Data] = []    // Raw PCM for the whole meeting
    private var retainedFrames = 0           // Frames retained, for the duration
    private var totalBuffers = 0             // Buffers seen (diagnostic)
    private var vadPassedBuffers = 0         // Buffers above the VAD threshold (diagnostic)
    private var audioCapReached = false
    private var peakRMS: Double = 0          // Diagnostic: loudest mic level this meeting
    private var audioSampleRate: Double = 16000  // Mic native sample rate, set at engine start

    /// What the machine is *playing* — the far end of the call.
    ///
    /// The mic alone records the room, so a meeting heard through headphones is
    /// invisible to it: measured 2026-09-18, two Teams meetings yielded ~10-12%
    /// of their speech because only the local voice reached the mic.
    private var systemAudio: [Data] = []
    private var systemFrames = 0
    private var systemPeakRMS: Double = 0
    private var systemCapReached = false
    private var systemCapture: SystemAudioCapture?

    /// Cap on retained meeting audio, purely a guard against a forgotten call
    /// holding the mic open indefinitely. Each source is 48 kHz mono Int16 at
    /// ~96 KB/s, so the two together are ~192 KB/s; 90 minutes is ~1.0 GB.
    private let maxMeetingAudioSeconds: Double = 90 * 60

    /// Window snapshot taken when the meeting started; we end the meeting only
    /// once this window disappears (not when focus is lost).
    private var meetingWindowRef: MeetingDetector.MeetingWindowRef?
    private var meetingWindowMisses = 0

    /// End the meeting only after its window has been absent this many
    /// consecutive polls (12 × 5s = 60s grace).
    private let meetingEndGracePolls = 12

    /// Poll meeting state every 5 seconds.
    private var pollTask: Task<Void, Never>?

    init(config: Config, database: Database) {
        self.config = config
        self.db = database
        self.eventStore = EventStore(database: database)
        self.meetingDetector = MeetingDetector(config: config)
        self.embedder = Embedder(config: config)
    }

    func applyConfig(_ newConfig: Config) {
        config = newConfig
        meetingDetector = MeetingDetector(config: newConfig)
        embedder = Embedder(config: newConfig)

        if newConfig.audioMode == .off {
            stop()
        } else if pollTask == nil {
            startPolling()
        }
    }

    // MARK: - Public

    /// Start the meeting detection loop. Safe to call even if audio is disabled.
    func startPolling() {
        guard config.audioMode != .off else { return }

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkMeetingState()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        if isInMeeting {
            Task { await endMeeting() }
        }
    }

    // MARK: - Meeting state machine

    private func checkMeetingState() async {
        if !isInMeeting {
            // Start trigger: a meeting app is frontmost or using the mic.
            if meetingDetector.isMeetingActive() {
                await startMeeting()
            }
        } else if meetingStillActive() {
            meetingWindowMisses = 0
        } else {
            // Stop trigger: the meeting window has been gone (and no meeting
            // app is holding the mic) for a grace period. Focus is ignored.
            meetingWindowMisses += 1
            if meetingWindowMisses >= meetingEndGracePolls {
                await endMeeting()
            }
        }
    }

    /// True while the meeting is still going, regardless of which app is
    /// frontmost: the tracked meeting window is still in the window list, or a
    /// meeting app is still holding the microphone.
    private func meetingStillActive() -> Bool {
        // (Re)snapshot the call window if we don't have one yet — it may appear
        // a few seconds after the meeting starts, so retry each poll.
        if meetingWindowRef == nil, let app = currentMeetingApp {
            meetingWindowRef = meetingDetector.frontmostMeetingWindow(for: app)
        }
        if let ref = meetingWindowRef,
           let app = currentMeetingApp,
           meetingDetector.windowStillPresent(ref, for: app) {
            return true
        }
        return meetingDetector.isMeetingAppUsingMicrophone()
    }

    private func startMeeting() async {
        isInMeeting = true
        currentMeetingApp = meetingDetector.currentMeetingApp()
        meetingWindowRef = currentMeetingApp.flatMap { meetingDetector.frontmostMeetingWindow(for: $0) }
        meetingWindowMisses = 0
        meetingStartTime = Date()
        resetAudioBuffers()

        let session = Session(
            id: UUID().uuidString,
            machineId: Host.current().localizedName ?? "unknown",
            startedAt: ISO8601DateFormatter().string(from: meetingStartTime ?? Date()),
            endedAt: nil,
            timezone: TimeZone.current.identifier
        )
        try? await eventStore.insertSession(session)
        currentMeetingSession = session

        fputs("[AudioCapture] meeting started (\(currentMeetingApp ?? "unknown"))\n", stderr)

        do {
            try setupAudioEngine()
            try audioEngine?.start()
        } catch {
            log("[AudioCapture] failed to start audio: \(error.localizedDescription)\n")
            isInMeeting = false
        }

        // The mic tap above hears the room. Add what the machine is playing so a
        // call heard through headphones is recorded at all.
        let system = SystemAudioCapture()
        system.onSamples = { [weak self] data in
            Task { await self?.appendSystemAudio(data) }
        }
        if await system.start() {
            systemCapture = system
            log("[AudioCapture] system audio capture started\n")
        } else {
            log("[AudioCapture] ⚠️ system audio unavailable — this meeting records the mic only\n")
        }
    }

    private func endMeeting() async {
        guard let startTime = meetingStartTime else { return }

        isInMeeting = false
        audioEngine?.stop()
        audioEngine = nil
        if let systemCapture { await systemCapture.stop() }
        systemCapture = nil

        let endedAt = ISO8601DateFormatter().string(from: Date())
        let retainedSeconds = Double(retainedFrames) / max(audioSampleRate, 1)
        let vadPercent = totalBuffers > 0
            ? Double(vadPassedBuffers) / Double(totalBuffers) * 100
            : 0
        let systemSeconds = Double(systemFrames) / max(audioSampleRate, 1)
        log("[AudioCapture] meeting ended, \(String(format: "%.1f", retainedSeconds / 60)) min mic + "
            + "\(String(format: "%.1f", systemSeconds / 60)) min system retained "
            + "(VAD passed \(String(format: "%.0f", vadPercent))% of buffers), "
            + "peak RMS mic \(String(format: "%.0f", peakRMS)) system \(String(format: "%.0f", systemPeakRMS))\n")

        // Snapshot meeting state into locals and clear actor state BEFORE any
        // await. Meetings flap (frontmost app changes every few seconds), so a
        // new meeting can start while this one is still transcribing; using
        // locals prevents the delayed resume from clobbering the new meeting.
        let session = currentMeetingSession
        let meetingApp = currentMeetingApp
        // Pre-size the concatenation: a full meeting is ~96 KB/s per source, so
        // growing this by repeated reallocation would copy hundreds of MB more
        // than needed. Mix before resetAudioBuffers() clears the buffers.
        let micAudio = meetingAudio.reduce(into: Data(capacity: retainedFrames * 2)) { $0.append($1) }
        let capturedSystemAudio = systemAudio.reduce(into: Data(capacity: systemFrames * 2)) { $0.append($1) }
        let fullAudio = Self.mixSources(mic: micAudio, system: capturedSystemAudio)

        currentMeetingApp = nil
        meetingStartTime = nil
        currentMeetingSession = nil
        meetingWindowRef = nil
        meetingWindowMisses = 0
        resetAudioBuffers()

        if var session {
            session.endedAt = endedAt
            try? await eventStore.updateSession(session)
        }

        guard !fullAudio.isEmpty else { return }

        // Transcribe via whisper.cpp, then store transcript + embedding.
        let transcript = await transcribeAudio(fullAudio)
        guard let transcript, !transcript.isEmpty, let sessionId = session?.id else { return }

        let embedding = await embedder.embed(transcript)
        try? await eventStore.insertAudioSegment(
            id: UUID().uuidString,
            sessionId: sessionId,
            startedAt: ISO8601DateFormatter().string(from: startTime),
            endedAt: endedAt,
            meetingApp: meetingApp,
            transcript: transcript,
            embedding: embedding
        )
    }

    // MARK: - AVAudioEngine setup

    private func setupAudioEngine() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Tap the mic input in its native format. Record the real sample rate
        // so the WAV header written for whisper.cpp matches the actual PCM data.
        let inputFormat = inputNode.outputFormat(forBus: 0)
        self.audioSampleRate = inputFormat.sampleRate
        log("[AudioCapture] mic format: \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) ch\n")

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let frameLength = buffer.frameLength
            let sampleCount = Int(frameLength)

            let copy: Data?
            if let int16 = buffer.int16ChannelData {
                copy = Data(bytes: int16.pointee, count: sampleCount * 2)
            } else if let floatData = buffer.floatChannelData {
                var pcm16 = [Int16](repeating: 0, count: sampleCount)
                let src = floatData.pointee
                for i in 0..<sampleCount {
                    let sample = max(-1.0, min(1.0, src[i]))
                    pcm16[i] = Int16(sample * Float(Int16.max))
                }
                copy = pcm16.withUnsafeBytes { Data($0) }
            } else {
                copy = nil
            }

            guard let copy else { return }
            Task { await self.processAudioTap(copy, frameCount: Int(frameLength)) }
        }

        engine.prepare()
        self.audioEngine = engine
    }

    // MARK: - Audio processing (actor-isolated — called via Task from tap)

    private func processAudioTap(_ pcmData: Data, frameCount: Int) {
        let samples = pcmData.withUnsafeBytes { ptr in
            Array(ptr.bindMemory(to: Int16.self).prefix(frameCount))
        }

        // Retain every buffer. The transcript is only as complete as the audio
        // handed to whisper, and dropping the quiet parts of speech is exactly
        // what made earlier transcripts cover ~12% of a meeting.
        totalBuffers += 1
        if Double(retainedFrames) / max(audioSampleRate, 1) >= maxMeetingAudioSeconds {
            if !audioCapReached {
                audioCapReached = true
                log("[AudioCapture] ⚠️ \(Int(maxMeetingAudioSeconds / 60))-minute audio cap reached — dropping further audio\n")
            }
        } else {
            meetingAudio.append(pcmData)
            retainedFrames += frameCount
        }

        // VAD retained as a diagnostic only: the pass rate says whether the mic
        // is delivering level at all, and peakRMS separates "mic silent" from
        // "threshold too high".
        if vadDetect(samples) { vadPassedBuffers += 1 }
        if let rms = rmsLevel(samples), rms > peakRMS {
            peakRMS = rms
        }
    }

    /// Append a chunk of system audio (48 kHz mono Int16, same as the mic).
    private func appendSystemAudio(_ pcmData: Data) {
        let frameCount = pcmData.count / 2
        guard frameCount > 0 else { return }

        totalBuffers += 1
        let samples = pcmData.withUnsafeBytes { Array($0.bindMemory(to: Int16.self).prefix(frameCount)) }
        if vadDetect(samples) { vadPassedBuffers += 1 }
        if let rms = rmsLevel(samples), rms > systemPeakRMS { systemPeakRMS = rms }

        if Double(systemFrames) / max(audioSampleRate, 1) >= maxMeetingAudioSeconds {
            if !systemCapReached {
                systemCapReached = true
                log("[AudioCapture] ⚠️ system audio cap reached — dropping further system audio\n")
            }
            return
        }
        systemAudio.append(pcmData)
        systemFrames += frameCount
    }

    /// Sum the mic and system streams.
    ///
    /// With headphones these are **disjoint speakers** — the mic carries only the
    /// local voice and the system stream only the remote one — so summing produces
    /// a conversation rather than an echo of it. The mic gets slightly less gain
    /// because it carries room acoustics while the other side arrives as a clean
    /// digital stream.
    private static func mixSources(mic: Data, system: Data) -> Data {
        let micCount = mic.count / 2
        let systemCount = system.count / 2
        guard systemCount > 0 else { return mic }
        let count = max(micCount, systemCount)

        var mixed = [Int16](repeating: 0, count: count)
        mic.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<micCount { mixed[i] = samples[i] }
        }
        system.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<systemCount {
                mixed[i] = Int16(clamping: Int(mixed[i]) + Int(Double(samples[i]) * 0.85))
            }
        }
        return mixed.withUnsafeBytes { Data($0) }
    }

    private func resetAudioBuffers() {
        meetingAudio = []
        retainedFrames = 0
        totalBuffers = 0
        vadPassedBuffers = 0
        audioCapReached = false
        peakRMS = 0
        systemAudio = []
        systemFrames = 0
        systemPeakRMS = 0
        systemCapReached = false
    }

    /// Simple energy-based VAD. Returns true if RMS exceeds threshold.
    private func vadDetect(_ samples: [Int16]) -> Bool {
        guard samples.count > 0 else { return false }
        let threshold: Double = 500.0
        return (rmsLevel(samples) ?? 0) > threshold
    }

    private func rmsLevel(_ samples: [Int16]) -> Double? {
        guard samples.count > 0 else { return nil }
        let sumSq = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return sqrt(sumSq / Double(samples.count))
    }

    // MARK: - Transcription (whisper.cpp subprocess)

    /// Transcribe audio via whisper.cpp's `whisper-cli` binary.
    /// Writes PCM data to a temp WAV file, runs whisper-cli, returns transcript.
    private nonisolated func transcribeAudio(_ audioData: Data) async -> String? {
        let config = await self.config
        let sampleRate = await self.audioSampleRate
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let result = Self.runWhisper(audioData, config: config, sampleRate: sampleRate)
                continuation.resume(returning: result)
            }
        }
    }

    private static func runWhisper(_ audioData: Data, config: Config, sampleRate: Double) -> String? {
        // Check binary availability
        guard FileManager.default.isExecutableFile(atPath: config.whisperBinaryPath) else {
            log("[AudioCapture] ⚠️ whisper-cli not found at \(config.whisperBinaryPath)\n")
            return nil
        }

        // Write audio to temp WAV file
        let tempDir = FileManager.default.temporaryDirectory
        let wavFile = tempDir.appendingPathComponent("whisper-input-\(UUID().uuidString).wav")
        guard writeWAV(audioData, to: wavFile, sampleRate: sampleRate) else {
            log("[AudioCapture] failed to write WAV\n")
            return nil
        }
        defer { try? FileManager.default.removeItem(at: wavFile) }

        let modelPath = config.embeddingModelPath + "ggml-\(config.whisperModel.rawValue).bin"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.whisperBinaryPath)
        process.arguments = [
            "-m", modelPath,
            "-f", wavFile.path,
            "--no-timestamps",
            "-otxt",           // Output to text file alongside input
            "--output-txt",     // Force text output
        ]

        // whisper-cli writes output to <input>.txt by default with -otxt
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            log("[AudioCapture] whisper failed: \(error.localizedDescription)\n")
            return nil
        }

        guard process.terminationStatus == 0 else {
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            fputs("[AudioCapture] whisper error: \(String(data: errData, encoding: .utf8) ?? "")\n", stderr)
            return nil
        }

        // whisper-cli -otxt writes to <input>.txt — it appends ".txt" to the
        // FULL input path (e.g. whisper-input-ABC.wav.txt), not replacing the
        // .wav extension. Reading the wrong path here silently produced nil
        // transcripts (whisper exited 0, but no .txt was found at <stem>.txt).
        let outputPath = wavFile.appendingPathExtension("txt")
        defer { try? FileManager.default.removeItem(at: outputPath) }

        guard let transcript = (try? String(contentsOf: outputPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !transcript.isEmpty else {
            log("[AudioCapture] no transcript output at \(outputPath.path)\n")
            return nil
        }

        return transcript
    }

    /// Write raw Int16 PCM data as a minimal WAV file at the given sample rate.
    private static func writeWAV(_ pcmData: Data, to url: URL, sampleRate: Double) -> Bool {
        let sampleRate: UInt32 = UInt32(sampleRate.rounded())
        let bitsPerSample: UInt16 = 16
        let numChannels: UInt16 = 1
        let byteRate = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = UInt32(pcmData.count)

        var header = Data()
        // RIFF header
        header.append("RIFF".data(using: .ascii)!)
        header.append(withUnsafeBytes(of: UInt32(36 + dataSize).littleEndian) { Data($0) })
        header.append("WAVE".data(using: .ascii)!)
        // fmt chunk
        header.append("fmt ".data(using: .ascii)!)
        header.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })   // chunk size
        header.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })    // PCM
        header.append(withUnsafeBytes(of: numChannels.littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })
        // data chunk
        header.append("data".data(using: .ascii)!)
        header.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })

        let wavData = header + pcmData
        do {
            try wavData.write(to: url)
            return true
        } catch {
            return false
        }
    }
}