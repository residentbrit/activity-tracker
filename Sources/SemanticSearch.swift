import Foundation
import SQLite3
import Accelerate

/// SQLite wants an explicit destructor constant, and `SQLITE_TRANSIENT` is a C
/// macro that doesn't survive the Swift import. -1 is its documented value.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Semantic (embedding) search over captured events.
///
/// Embeddings are stored as raw little-endian Float32 blobs in `events.embedding`
/// (mxbai-embed-large, 1024 dims). The daemon embeds with `--embd-normalize 2`,
/// so stored vectors are unit-length and cosine similarity reduces to a dot
/// product — verified against the live DB (norms 1.0000 across 40k rows).
///
/// There is no vector index, so ranking is a brute-force scan. Two details keep
/// that cheap at current volumes (~72k embedded rows):
///   * pass 1 streams only `(id, embedding)` and keeps a bounded top-k, so text
///     is never copied for a row that won't be returned;
///   * the dot product runs on a reused scratch buffer via vDSP — one 4KB memcpy
///     per row rather than a fresh allocation per row.
///
/// Timestamps in SQL comparisons are ISO-8601 UTC strings; callers normalise
/// local input via `normalizeToUTC` (same convention as `get_activity_range`).
enum SemanticSearch {

    /// llama-server endpoint — the same server the daemon embeds through, so
    /// query vectors come from the identical model, pooling and normalisation.
    static let serverURL = "http://127.0.0.1:8080"

    static let dimensions = 1024
    static let byteCount = dimensions * MemoryLayout<Float>.size

    /// Cosine floor for a hit to count as a match.
    ///
    /// Calibrated against this corpus: genuine matches score 0.72-0.78 while
    /// unrelated content tops out around 0.60 (a query with no real answer in
    /// the data peaked at 0.597). 0.62 therefore keeps real hits and returns
    /// nothing rather than "least unrelated" noise for a miss.
    static let minSimilarity: Float = 0.62

    /// Max chars of text used to recognise results that are the same capture.
    private static let identityPrefixLength = 200

    struct Result {
        let eventID: String
        let capturedAt: String
        let appName: String?
        let windowTitle: String?
        let sourceType: String
        let text: String
        let similarity: Float
    }

    enum Failure: Error {
        case embeddingFailed
    }

    // MARK: - Query embedding

    /// Embed a query string via the resident llama-server.
    ///
    /// Mirrors the daemon's input caps and retries with progressively shorter
    /// input, because llama-server rejects inputs over its 512-token batch with
    /// HTTP 500 — the same failure mode the backfill script handles.
    static func embedQuery(_ text: String) async throws -> [Float] {
        for variant in inputVariants(text) {
            if let vector = try? await postEmbedding(variant) {
                return vector
            }
        }
        throw Failure.embeddingFailed
    }

    private static func inputVariants(_ text: String) -> [String] {
        var variants: [String] = []
        for words in [200, 100, 60, 30, 15] {
            variants.append(prepare(text, maxWords: words))
        }
        for chars in [800, 400, 200] {
            variants.append(prepare(text, maxChars: chars))
        }
        var seen = Set<String>()
        return variants.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func prepare(_ text: String, maxChars: Int = 1500, maxWords: Int = 200) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if trimmed.count > maxChars { trimmed = String(trimmed.prefix(maxChars)) }
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        if words.count > maxWords {
            trimmed = words.prefix(maxWords).joined(separator: " ")
        }
        return trimmed
    }

    private static func postEmbedding(_ input: String) async throws -> [Float] {
        guard let url = URL(string: "\(serverURL)/v1/embeddings") else {
            throw Failure.embeddingFailed
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "input": input,
            "model": "mxbai-embed-large",
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Failure.embeddingFailed
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]],
              let first = items.first,
              let embedding = first["embedding"] as? [Double] else {
            throw Failure.embeddingFailed
        }

        let floats = embedding.map { Float($0) }
        guard floats.count == dimensions else { throw Failure.embeddingFailed }
        return floats
    }

    // MARK: - Ranking

    /// Brute-force cosine ranking with a bounded top-k.
    ///
    /// - Parameters:
    ///   - start: inclusive ISO-8601 UTC lower bound.
    ///   - end: exclusive ISO-8601 UTC upper bound.
    /// - Returns: results best-first, with consecutive captures of the same
    ///   content collapsed so one identical screen can't fill the whole list.
    static func search(
        handle: OpaquePointer?,
        query: [Float],
        limit: Int,
        start: String? = nil,
        end: String? = nil
    ) throws -> [Result] {
        guard let handle else { return [] }
        let ranked = try rank(
            handle: handle,
            query: query,
            limit: limit,
            start: start,
            end: end
        )
        guard !ranked.isEmpty else { return [] }

        var results: [Result] = []
        var seenIdentity = Set<String>()
        for hit in ranked {
            guard let result = try fetch(handle: handle, eventID: hit.eventID, similarity: hit.similarity) else {
                continue
            }
            // Collapse repeated captures of the same content. Two rows with an
            // identical 200-char prefix are the same screen; keeping both would
            // crowd out other matches (observed: 5 identical Slack rows).
            let identity = "\(result.appName ?? "")|\(normalizedPrefix(result.text))"
            if !seenIdentity.insert(identity).inserted { continue }
            results.append(result)
            if results.count == limit { break }
        }
        return results
    }

    private struct Ranked {
        let eventID: String
        let similarity: Float
    }

    private static func rank(
        handle: OpaquePointer,
        query: [Float],
        limit: Int,
        start: String?,
        end: String?
    ) throws -> [Ranked] {
        var sql = """
            SELECT id, embedding FROM events
            WHERE is_duplicate = 0 AND embedding IS NOT NULL
            """
        if start != nil { sql += " AND captured_at >= ?" }
        if end != nil { sql += " AND captured_at < ?" }
        // Newest-first so ties prefer the most recent capture.
        sql += " ORDER BY captured_at DESC"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executeFailed(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(stmt) }

        var bindIndex: Int32 = 1
        if let start {
            sqlite3_bind_text(stmt, bindIndex, start, -1, sqliteTransient)
            bindIndex += 1
        }
        if let end {
            sqlite3_bind_text(stmt, bindIndex, end, -1, sqliteTransient)
            bindIndex += 1
        }

        var queryVector = query
        normalize(&queryVector)

        var scratch = [Float](repeating: 0, count: dimensions)
        // Ascending by similarity: kept[0] is the weakest hit retained.
        var kept: [Ranked] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idPtr = sqlite3_column_text(stmt, 0),
                  let blob = sqlite3_column_blob(stmt, 1),
                  Int(sqlite3_column_bytes(stmt, 1)) == byteCount else { continue }

            scratch.withUnsafeMutableBytes { destination in
                memcpy(destination.baseAddress, blob, byteCount)
            }

            var similarity: Float = 0
            vDSP_dotpr(queryVector, 1, scratch, 1, &similarity, vDSP_Length(dimensions))

            guard similarity >= minSimilarity else { continue }
            if kept.count == limit && similarity <= kept[0].similarity { continue }

            insert(Ranked(eventID: String(cString: idPtr), similarity: similarity), into: &kept, limit: limit)
        }

        return kept.reversed()
    }

    private static func insert(_ hit: Ranked, into kept: inout [Ranked], limit: Int) {
        var index = kept.count
        while index > 0 && kept[index - 1].similarity > hit.similarity { index -= 1 }
        kept.insert(hit, at: index)
        if kept.count > limit { kept.removeFirst() }
    }

    // MARK: - Meeting transcripts

    /// Cosine floor for meeting transcripts.
    ///
    /// Calibrated separately from `minSimilarity`, and it has to be: transcripts
    /// are conversational, so their mean-pooled embeddings are more diffuse and
    /// absolute scores sit well below screen text. Measured against the 19 stored
    /// transcripts on 2026-09-18: genuinely matching queries scored 0.576–0.621,
    /// while unrelated ones topped out at 0.472 and a plausible-but-absent topic
    /// reached 0.510. **The events floor of 0.62 would have returned nothing for
    /// three of the four answerable queries.**
    ///
    /// Chunking was tried as a way to improve coverage and localisation, and
    /// measurably hurt. At ~150-word chunks the two paraphrase queries moved to
    /// the wrong meeting and the no-answer floor *rose* to 0.509; averaging the
    /// chunk vectors into one per-meeting vector was worse again (no-answer floor
    /// 0.512, correct meeting lost on two of four). A short chunk of
    /// conversational filler has too little topical anchoring, and averaging
    /// dilutes it. Ranking therefore stays on the whole transcript's embedding.
    static let minTranscriptSimilarity: Float = 0.55

    struct TranscriptResult {
        let id: String
        let sessionID: String
        let startedAt: String
        let endedAt: String?
        let meetingApp: String?
        let transcript: String
        let similarity: Float
    }

    /// Brute-force cosine ranking over stored meeting transcripts.
    ///
    /// Simpler than `search` in one respect — the corpus is tens of rows, so every
    /// hit above the threshold is collected rather than a bounded top-k — but the
    /// scoring itself is identical: normalised query, `vDSP_dotpr` against a
    /// re-used scratch buffer, and the same unit-norm assumption (verified:
    /// norms are 1.0000 across all 19 rows).
    static func searchTranscripts(
        handle: OpaquePointer?,
        query: [Float],
        limit: Int
    ) throws -> [TranscriptResult] {
        guard let handle, limit > 0 else { return [] }

        let sql = """
            SELECT id, embedding FROM audio_segments
            WHERE embedding IS NOT NULL AND LENGTH(TRIM(transcript)) > 0
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executeFailed(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(stmt) }

        var queryVector = query
        normalize(&queryVector)

        var scratch = [Float](repeating: 0, count: dimensions)
        var hits: [(id: String, similarity: Float)] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idPtr = sqlite3_column_text(stmt, 0),
                  let blob = sqlite3_column_blob(stmt, 1),
                  Int(sqlite3_column_bytes(stmt, 1)) == byteCount else { continue }

            scratch.withUnsafeMutableBytes { destination in
                memcpy(destination.baseAddress, blob, byteCount)
            }

            var similarity: Float = 0
            vDSP_dotpr(queryVector, 1, scratch, 1, &similarity, vDSP_Length(dimensions))
            guard similarity >= minTranscriptSimilarity else { continue }
            hits.append((String(cString: idPtr), similarity))
        }

        hits.sort { $0.similarity > $1.similarity }

        var results: [TranscriptResult] = []
        for hit in hits where results.count < limit {
            if let result = try fetchTranscript(handle: handle, id: hit.id, similarity: hit.similarity) {
                results.append(result)
            }
        }
        return results
    }

    private static func fetchTranscript(
        handle: OpaquePointer, id: String, similarity: Float
    ) throws -> TranscriptResult? {
        let sql = """
            SELECT session_id, started_at, ended_at, meeting_app, transcript
            FROM audio_segments WHERE id = ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executeFailed(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, sqliteTransient)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        func text(_ index: Int32) -> String? {
            guard let ptr = sqlite3_column_text(stmt, index) else { return nil }
            return String(cString: ptr)
        }

        return TranscriptResult(
            id: id,
            sessionID: text(0) ?? "",
            startedAt: text(1) ?? "",
            endedAt: text(2),
            meetingApp: text(3),
            transcript: text(4) ?? "",
            similarity: similarity
        )
    }

    /// Cosine similarity for a specific set of events.
    ///
    /// Literal matches that don't reach the semantic top-k still need a real
    /// similarity score. Without one they can only ever score their small
    /// literal-match boost and therefore lose to every semantic hit — which is how
    /// a query for an id present verbatim in 1,455 rows returned none of them.
    ///
    /// Costs one dot product per requested id, so callers should keep the list to
    /// their candidate set rather than the full match count.
    static func similarities(
        handle: OpaquePointer?,
        query: [Float],
        eventIDs: [String]
    ) -> [String: Float] {
        guard let handle, !eventIDs.isEmpty else { return [:] }

        let placeholders = eventIDs.map { _ in "?" }.joined(separator: ",")
        let sql = """
            SELECT id, embedding FROM events
            WHERE embedding IS NOT NULL AND id IN (\(placeholders))
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }

        for (offset, eventID) in eventIDs.enumerated() {
            sqlite3_bind_text(stmt, Int32(offset + 1), eventID, -1, sqliteTransient)
        }

        var queryVector = query
        normalize(&queryVector)

        var scratch = [Float](repeating: 0, count: dimensions)
        var scores: [String: Float] = [:]

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idPtr = sqlite3_column_text(stmt, 0),
                  let blob = sqlite3_column_blob(stmt, 1),
                  Int(sqlite3_column_bytes(stmt, 1)) == byteCount else { continue }

            scratch.withUnsafeMutableBytes { destination in
                memcpy(destination.baseAddress, blob, byteCount)
            }

            var similarity: Float = 0
            vDSP_dotpr(queryVector, 1, scratch, 1, &similarity, vDSP_Length(dimensions))
            scores[String(cString: idPtr)] = similarity
        }

        return scores
    }

    private static func fetch(handle: OpaquePointer, eventID: String, similarity: Float) throws -> Result? {
        let sql = """
            SELECT captured_at, app_name, window_title, source_type, text_content
            FROM events WHERE id = ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executeFailed(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, eventID, -1, sqliteTransient)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        func text(_ index: Int32) -> String? {
            guard let ptr = sqlite3_column_text(stmt, index) else { return nil }
            return String(cString: ptr)
        }

        return Result(
            eventID: eventID,
            capturedAt: text(0) ?? "",
            appName: text(1),
            windowTitle: text(2),
            sourceType: text(3) ?? "",
            text: text(4) ?? "",
            similarity: similarity
        )
    }

    private static func normalizedPrefix(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.prefix(identityPrefixLength))
    }

    private static func normalize(_ vector: inout [Float]) {
        var sumOfSquares: Float = 0
        vDSP_svesq(vector, 1, &sumOfSquares, vDSP_Length(vector.count))
        let norm = sqrt(sumOfSquares)
        guard norm > 0 else { return }
        var divisor = norm
        var output = [Float](repeating: 0, count: vector.count)
        vDSP_vsdiv(vector, 1, &divisor, &output, 1, vDSP_Length(vector.count))
        vector = output
    }
}
