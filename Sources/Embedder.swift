import Foundation

/// Embedding via llama.cpp's `llama-embedding` example binary (D11).
///
/// Calls the binary as a subprocess — avoids C++ build integration in
/// the Swift package. The binary and model must be available at the
/// paths configured in `config.json`.
///
/// The embedding model (mxbai-embed-large) is loaded by llama.cpp
/// on each call. For a future optimization, we could keep the model
/// resident by wrapping llama.cpp's server mode, but subprocess-per-call
/// is fine for a 60-second heartbeat cadence.
actor Embedder {
    private let config: Config
    private var binaryAvailable: Bool?

    init(config: Config) {
        self.config = config
    }

    /// Embed a text string → 1024-dim float32 vector (mxbai-embed-large).
    /// Returns nil if embedding is unavailable or text is empty.
    func embed(_ text: String) async -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Check binary availability once
        if binaryAvailable == nil {
            binaryAvailable = FileManager.default.isExecutableFile(atPath: config.embeddingBinaryPath)
            if binaryAvailable == false {
                fputs("[Embedder] ⚠️ llama-embedding not found at \(config.embeddingBinaryPath)\n", stderr)
                fputs("[Embedder]    build llama.cpp and set embeddingBinaryPath in config.json\n", stderr)
            }
        }
        guard binaryAvailable == true else { return nil }

        return await runEmbedding(trimmed)
    }

    /// Run llama-embedding as a subprocess.
    /// Writes text to a temp file (stdin can be unreliable for binary subprocesses),
    /// parses the float vector from stdout.
    private func runEmbedding(_ text: String) async -> Data? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let result = self.runEmbeddingSync(text)
                continuation.resume(returning: result)
            }
        }
    }

    private nonisolated func runEmbeddingSync(_ text: String) -> Data? {
        // Write text to temp file (llama-embedding reads from file, not stdin)
        let tempDir = FileManager.default.temporaryDirectory
        let inputFile = tempDir.appendingPathComponent("embed-input-\(UUID().uuidString).txt")
        guard let _ = try? text.write(to: inputFile, atomically: true, encoding: .utf8) else {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: inputFile) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.embeddingBinaryPath)
        process.arguments = [
            "-m", config.embeddingModelPath + "/mxbai-embed-large.gguf",
            "--pooling", "mean",
            "--embd-normalize", "2",   // L2 normalization
            "-f", inputFile.path,
            "--no-escape",
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            fputs("[Embedder] failed to launch: \(error.localizedDescription)\n", stderr)
            return nil
        }

        guard process.terminationStatus == 0 else {
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            fputs("[Embedder] llama-embedding failed: \(errStr)\n", stderr)
            return nil
        }

        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        guard let outputStr = String(data: outputData, encoding: .utf8) else {
            return nil
        }

        return parseEmbeddingOutput(outputStr)
    }

    /// Parse llama-embedding output: space-separated floats, one per line segment.
    /// mxbai-embed-large outputs 1024 dimensions.
    private nonisolated func parseEmbeddingOutput(_ output: String) -> Data? {
        let components = output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .compactMap { Float($0) }

        guard components.count == 1024 else {
            fputs("[Embedder] unexpected embedding dimension: \(components.count) (expected 1024)\n", stderr)
            return nil
        }

        return components.withUnsafeBytes { Data($0) }
    }
}
