import Foundation
import AVFoundation

/// Meetings-only audio capture (D5).
///
/// Periodically checks meeting state via MeetingDetector. When a meeting
/// starts: captures mic + system audio via AVAudioEngine, applies energy-based
/// VAD to filter silence, accumulates speech segments. When meeting ends:
/// transcribes via whisper.cpp (TODO), stores transcript + embedding,
/// discards raw audio.
///
/// Audio capture is disabled if `audioMode` is `.off` in config.
actor AudioCapture {
    private let config: Config
    private let db: Database
    private let eventStore: EventStore
    private let meetingDetector: MeetingDetector
    private let embedder: Embedder

    private var isInMeeting = false
    private var currentMeetingApp: String?
    private var meetingStartTime: Date?
    private var audioEngine: AVAudioEngine?
    private var speechSegments: [Data] = []  // Raw PCM chunks that passed VAD

    /// Poll meeting state every 5 seconds.
    private var pollTask: Task<Void, Never>?

    init(config: Config, database: Database) {
        self.config = config
        self.db = database
        self.eventStore = EventStore(database: database)
        self.meetingDetector = MeetingDetector(config: config)
        self.embedder = Embedder(config: config)
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
        let meetingActive = meetingDetector.isMeetingActive()

        if meetingActive && !isInMeeting {
            await startMeeting()
        } else if !meetingActive && isInMeeting {
            await endMeeting()
        }
    }

    private func startMeeting() async {
        isInMeeting = true
        currentMeetingApp = meetingDetector.currentMeetingApp()
        meetingStartTime = Date()
        speechSegments = []

        fputs("[AudioCapture] meeting started (\(currentMeetingApp ?? "unknown"))\n", stderr)

        do {
            try setupAudioEngine()
            try audioEngine?.start()
        } catch {
            fputs("[AudioCapture] failed to start audio: \(error.localizedDescription)\n", stderr)
            isInMeeting = false
        }
    }

    private func endMeeting() async {
        guard let startTime = meetingStartTime else { return }

        isInMeeting = false
        audioEngine?.stop()
        audioEngine = nil

        let endedAt = ISO8601DateFormatter().string(from: Date())
        fputs("[AudioCapture] meeting ended, \(speechSegments.count) speech segments\n", stderr)

        guard !speechSegments.isEmpty else {
            currentMeetingApp = nil
            meetingStartTime = nil
            return
        }

        // Concatenate all speech segments for transcription
        let fullAudio = speechSegments.reduce(into: Data()) { $0.append($1) }

        // Transcribe (TODO: whisper.cpp — placeholder for now)
        let transcript = await transcribeAudio(fullAudio)

        // Store in DB, discard raw audio
        if let transcript, !transcript.isEmpty {
            let embedding = await embedder.embed(transcript)
            try? await eventStore.insertAudioSegment(
                id: UUID().uuidString,
                sessionId: "",  // TODO: get current session ID
                startedAt: ISO8601DateFormatter().string(from: startTime),
                endedAt: endedAt,
                meetingApp: currentMeetingApp,
                transcript: transcript,
                embedding: embedding
            )
        }

        currentMeetingApp = nil
        meetingStartTime = nil
        speechSegments = []
    }

    // MARK: - AVAudioEngine setup

    private func setupAudioEngine() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Tap the mic input in its native format.
        // Conversion to 16kHz mono happens before whisper.cpp, not here.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputNode.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            guard let self else { return }
            let frameLength = buffer.frameLength
            guard let channelData = buffer.int16ChannelData else { return }
            let sampleCount = Int(frameLength) * Int(buffer.format.channelCount)
            let copy = Data(bytes: channelData.pointee, count: sampleCount * 2)
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
        if vadDetect(samples) {
            speechSegments.append(pcmData)
        }
    }

    /// Simple energy-based VAD. Returns true if RMS exceeds threshold.
    private func vadDetect(_ samples: [Int16]) -> Bool {
        guard samples.count > 0 else { return false }
        let threshold: Double = 500.0
        let sumSq = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return sqrt(sumSq / Double(samples.count)) > threshold
    }

    // MARK: - Transcription (whisper.cpp subprocess)

    /// Transcribe audio via whisper.cpp's `whisper-cli` binary.
    /// Writes PCM data to a temp WAV file, runs whisper-cli, returns transcript.
    private nonisolated func transcribeAudio(_ audioData: Data) async -> String? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let result = Self.runWhisper(audioData, config: self.config)
                continuation.resume(returning: result)
            }
        }
    }

    private static func runWhisper(_ audioData: Data, config: Config) -> String? {
        // Check binary availability
        guard FileManager.default.isExecutableFile(atPath: config.whisperBinaryPath) else {
            fputs("[AudioCapture] ⚠️ whisper-cli not found at \(config.whisperBinaryPath)\n", stderr)
            return nil
        }

        // Write audio to temp WAV file
        let tempDir = FileManager.default.temporaryDirectory
        let wavFile = tempDir.appendingPathComponent("whisper-input-\(UUID().uuidString).wav")
        guard writeWAV(audioData, to: wavFile) else {
            fputs("[AudioCapture] failed to write WAV\n", stderr)
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
            fputs("[AudioCapture] whisper failed: \(error.localizedDescription)\n", stderr)
            return nil
        }

        guard process.terminationStatus == 0 else {
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            fputs("[AudioCapture] whisper error: \(String(data: errData, encoding: .utf8) ?? "")\n", stderr)
            return nil
        }

        // Read output file: <wavFile>.txt
        let outputPath = wavFile.deletingPathExtension().appendingPathExtension("txt")
        defer { try? FileManager.default.removeItem(at: outputPath) }

        guard let transcript = (try? String(contentsOf: outputPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !transcript.isEmpty else {
            return nil
        }

        return transcript
    }

    /// Write raw Int16 PCM data as a minimal WAV file.
    private static func writeWAV(_ pcmData: Data, to url: URL) -> Bool {
        let sampleRate: UInt32 = 16000
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