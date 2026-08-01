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

    // Batch accumulator: texts waiting for the next drain cycle
    private var pending: [(text: String, continuation: CheckedContinuation<Data?, Never>)] = []
    private var drainTask: Task<Void, Never>?

    init(config: Config) {
        self.config = config
    }

    /// Embed a text string → 1024-dim float32 vector (mxbai-embed-large).
    func embed(_ text: String) async -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        return await withCheckedContinuation { cont in
            pending.append((trimmed, cont))
            scheduleDrain()
        }
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
            fputs("[Embedder] server not running, using subprocess mode\n", stderr)
            return false
        }
    }

    private func drainViaServer(_ batch: [(String, CheckedContinuation<Data?, Never>)]) async {
        fputs("[Embedder] batching \(batch.count) texts via server\n", stderr)
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
            fputs("[Embedder] server request failed: \(error)\n", stderr)
            return nil
        }
    }

    // MARK: - Subprocess fallback

    private func drainViaSubprocess(_ batch: [(String, CheckedContinuation<Data?, Never>)]) async {
        fputs("[Embedder] batching \(batch.count) texts via subprocess\n", stderr)
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
        guard FileManager.default.isExecutableFile(atPath: config.embeddingBinaryPath) else { return nil }

        let tempDir = FileManager.default.temporaryDirectory
        let inputFile = tempDir.appendingPathComponent("embed-\(UUID().uuidString).txt")
        guard let _ = try? text.write(to: inputFile, atomically: true, encoding: .utf8) else { return nil }
        defer { try? FileManager.default.removeItem(at: inputFile) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.embeddingBinaryPath)
        process.arguments = [
            "-m", config.embeddingModelPath + "/mxbai-embed-large.gguf",
            "--pooling", "mean", "--embd-normalize", "2",
            "-f", inputFile.path, "--no-escape",
        ]
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()

        try? process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let outputStr = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else {
            return nil
        }
        return parseOutput(outputStr)
    }

    private static nonisolated func parseOutput(_ output: String) -> Data? {
        let components = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").compactMap { Float($0) }
        guard components.count == 1024 else { return nil }
        return components.withUnsafeBytes { Data($0) }
    }
}
