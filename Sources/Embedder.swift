import Foundation

/// Embedding via llama.cpp's server mode (D11).
///
/// Uses `llama-server` (built alongside llama-embedding) which keeps the
/// model resident in memory. Each embedding is a lightweight HTTP POST
/// to `localhost:8080` — no subprocess-per-text overhead.
///
/// Falls back to llama-embedding subprocess if server isn't running.
actor Embedder {
    private let config: Config
    private var useServer: Bool?
    private let serverURL = "http://127.0.0.1:8080"
    private let maxEmbeddingChars = 1500
    private let maxEmbeddingWords = 200

    // Batch accumulator: texts waiting for the next drain cycle
    private var pending: [(text: String, continuation: CheckedContinuation<Data?, Never>)] = []
    private var drainTask: Task<Void, Never>?

    private final class DataSink: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        func snapshot() -> Data {
            lock.lock()
            let copy = data
            lock.unlock()
            return copy
        }
    }

    init(config: Config) {
        self.config = config
    }

    /// Embed a text string → 1024-dim float32 vector (mxbai-embed-large).
    func embed(_ text: String) async -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let prepared = prepareEmbeddingInput(trimmed)
        if prepared.count < trimmed.count {
            log("[Embedder] truncated input from \(trimmed.count) to \(prepared.count) chars\n")
        }

        return await withCheckedContinuation { cont in
            pending.append((prepared, cont))
            scheduleDrain()
        }
    }

    private func prepareEmbeddingInput(_ text: String) -> String {
        let charLimited = String(text.prefix(maxEmbeddingChars))
        let words = charLimited.split(whereSeparator: \.isWhitespace)
        if words.count <= maxEmbeddingWords { return charLimited }
        return words.prefix(maxEmbeddingWords).joined(separator: " ")
    }

    // MARK: - Batching

    private func scheduleDrain() {
        guard drainTask == nil else { return }
        drainTask = Task {
            // Wait up to 3 seconds for more texts to accumulate
            try? await Task.sleep(for: .seconds(3))
            await drainQueue()
        }
    }

    private func drainQueue() async {
        let batch = pending
        pending.removeAll()
        drainTask = nil
        guard !batch.isEmpty else { return }

        // Determine mode: try server first, fall back to subprocess
        if useServer == nil {
            useServer = await checkServer()
        }

        if useServer == true {
            await drainViaServer(batch)
        } else {
            await drainViaSubprocess(batch)
        }
    }

    // MARK: - Server mode (model resident)

    private func checkServer() async -> Bool {
        let url = URL(string: "\(serverURL)/health")!
        var req = URLRequest(url: url, timeoutInterval: 2)
        req.httpMethod = "GET"
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            log("[Embedder] server not running, using subprocess mode\n")
            return false
        }
    }

    private func drainViaServer(_ batch: [(String, CheckedContinuation<Data?, Never>)]) async {
        log("[Embedder] batching \(batch.count) texts via server\n")
        for (text, cont) in batch {
            let result = await embedViaServer(text)
            cont.resume(returning: result)
        }
    }

    private func embedViaServer(_ text: String) async -> Data? {
        let url = URL(string: "\(serverURL)/v1/embeddings")!
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "input": text,
            "model": "mxbai-embed-large"
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataArr = json["data"] as? [[String: Any]],
                  let first = dataArr.first,
                  let embedding = first["embedding"] as? [Double] else {
                return nil
            }
            let floats = embedding.map { Float($0) }
            return floats.withUnsafeBytes { Data($0) }
        } catch {
            log("[Embedder] server request failed: \(error)\n")
            return nil
        }
    }

    // MARK: - Subprocess fallback

    private func drainViaSubprocess(_ batch: [(String, CheckedContinuation<Data?, Never>)]) async {
        log("[Embedder] batching \(batch.count) texts via subprocess\n")
        for (text, cont) in batch {
            let result = await runSubprocess(text)
            cont.resume(returning: result)
        }
    }

    private func runSubprocess(_ text: String) async -> Data? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let result = Embedder.runEmbeddingSync(text, config: self.config)
                continuation.resume(returning: result)
            }
        }
    }

    private static nonisolated func runEmbeddingSync(_ text: String, config: Config) -> Data? {
        guard FileManager.default.isExecutableFile(atPath: config.embeddingBinaryPath) else {
            fputs("[Embedder] embedding binary not executable at \(config.embeddingBinaryPath)\n", stderr)
            return nil
        }

        let modelFile: String = {
            if config.embeddingModelPath.hasSuffix(".gguf") {
                return config.embeddingModelPath
            }
            if config.embeddingModel.hasSuffix(".gguf") {
                return (config.embeddingModelPath as NSString).appendingPathComponent(config.embeddingModel)
            }
            return (config.embeddingModelPath as NSString).appendingPathComponent("\(config.embeddingModel).gguf")
        }()
        guard FileManager.default.fileExists(atPath: modelFile) else {
            fputs("[Embedder] embedding model not found at \(modelFile)\n", stderr)
            return nil
        }

        let tempDir = FileManager.default.temporaryDirectory
        let inputFile = tempDir.appendingPathComponent("embed-\(UUID().uuidString).txt")
        guard let _ = try? text.write(to: inputFile, atomically: true, encoding: .utf8) else { return nil }
        defer { try? FileManager.default.removeItem(at: inputFile) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.embeddingBinaryPath)
        process.arguments = [
            "-m", modelFile,
            "--pooling", "mean", "--embd-normalize", "2",
            "-f", inputFile.path, "--no-escape",
        ]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            fputs("[Embedder] failed to launch subprocess: \(error)\n", stderr)
            return nil
        }
        let stdoutSink = DataSink()
        let stderrSink = DataSink()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            stdoutSink.append(data)
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            stderrSink.append(data)
        }

        process.waitUntilExit()

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        stdoutSink.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        stderrSink.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
        let stdoutData = stdoutSink.snapshot()
        let stderrData = stderrSink.snapshot()

        let stdoutStr = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let errPreview = stderrStr.prefix(300)
            fputs("[Embedder] subprocess exited \(process.terminationStatus). stderr: \(errPreview)\n", stderr)
            return nil
        }

        if let parsed = parseOutput(stdoutStr) {
            return parsed
        }
        if let parsed = parseOutput(stderrStr) {
            return parsed
        }

        let errPreview = stderrStr.prefix(200)
        let outPreview = stdoutStr.prefix(200)
        fputs("[Embedder] failed to parse embedding output. stdout: \(outPreview) stderr: \(errPreview)\n", stderr)
        return nil
    }

    private static nonisolated func parseOutput(_ output: String) -> Data? {
        let lines = output.split(whereSeparator: \.isNewline)
        for lineSub in lines {
            let line = String(lineSub)
            guard line.contains("embedding") else { continue }
            let payload: String
            if let colonIdx = line.firstIndex(of: ":") {
                payload = String(line[line.index(after: colonIdx)...])
            } else {
                payload = line
            }

            let floats = payload
                .split(whereSeparator: \.isWhitespace)
                .compactMap { Float($0) }
            if floats.count == 1024 {
                return floats.withUnsafeBytes { Data($0) }
            }
            if floats.count > 1024 {
                let tail = Array(floats.suffix(1024))
                return tail.withUnsafeBytes { Data($0) }
            }
        }

        return nil
    }
}
