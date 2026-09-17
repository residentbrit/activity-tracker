import Foundation
import SQLite3

/// MCP (Model Context Protocol) server over stdio transport (D7).
///
/// Reads JSON-RPC 2.0 messages from stdin, writes responses to stdout.
/// MCP clients (Claude Desktop, VS Code, etc.) connect via stdio pipe.
///
/// ## Protocol
/// - Newline-delimited JSON (one complete JSON object per line)
/// - `initialize` → server capabilities handshake
/// - `tools/list` → list available tools with their schemas
/// - `tools/call` → invoke a tool, return result
///
/// ## Tools exposed
/// - `search_activities` — full-text search over recent captures
/// - `get_recent_activity` — latest events from local SQLite
/// - `get_sync_status` — sync state
/// - `list_sessions` — session summaries
/// - `get_session` — single session detail
actor MCPServer {
    private let db: Database
    private let eventStore: EventStore

    /// Set after initialize handshake. If the client hasn't initialized,
    /// we reject non-initialize requests per MCP spec.
    private var initialized = false

    init(database: Database) {
        self.db = database
        self.eventStore = EventStore(database: database)
    }

    // MARK: - Run loop

    func run() async {
        // Write to stderr so stdout stays clean for JSON-RPC transport
        fputs("[MCPServer] listening on stdio\n", stderr)

        // Read stdin on a dedicated thread (readLine blocks)
        let stream = AsyncStream<String> { continuation in
            DispatchQueue.global(qos: .default).async {
                while let line = readLine(strippingNewline: true) {
                    continuation.yield(line)
                }
                continuation.finish()
            }
        }

        for await line in stream {
            await processLine(line)
        }

        fputs("[MCPServer] stdin closed, shutting down\n", stderr)
    }

    // MARK: - Message dispatch

    private func processLine(_ line: String) async {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let method = json["method"] as? String
        let id = json["id"]  // Int in JSON, but JSONSerialization gives us NSNumber

        // MCP spec: reject non-initialize before handshake
        if !initialized && method != "initialize" {
            await sendError(id: id, code: -32002, message: "Not initialized")
            return
        }

        switch method {
        case "initialize":
            await handleInitialize(id: id)

        case "notifications/initialized":
            // No response needed — client confirms it's ready
            break

        case "tools/list":
            await handleToolsList(id: id)

        case "tools/call":
            let params = json["params"] as? [String: Any]
            await handleToolCall(id: id, params: params)

        case "shutdown":
            await handleShutdown(id: id)

        default:
            await sendError(id: id, code: -32601, message: "Method not found: \(method ?? "nil")")
        }
    }

    // MARK: - MCP lifecycle

    private func handleInitialize(id: Any?) async {
        initialized = true

        let result: [String: Any] = [
            "protocolVersion": "2024-11-05",
            "capabilities": [
                "tools": [:]  // We support tools
            ],
            "serverInfo": [
                "name": "activity-tracker",
                "version": "0.1.0"
            ]
        ]
        await sendResult(id: id, result: result)
    }

    private func handleShutdown(id: Any?) async {
        await sendResult(id: id, result: [:])
        // MCP spec: server should exit after responding to shutdown
        fputs("[MCPServer] shutdown received\n", stderr)
        exit(0)
    }

    // MARK: - tools/list

    private func handleToolsList(id: Any?) async {
        let tools: [[String: Any]] = [
            [
                "name": "search_activities",
                "description": "Search captured activity by keyword or concept. Hybrid: exact keyword matching plus semantic similarity over on-device embeddings, so paraphrases and concepts match even when the exact words were never on screen. Returns events with timestamps, app context, and extracted text.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Search query — keywords or a description of what you're looking for"],
                        "limit": ["type": "integer", "description": "Max results (default 20, max 100)"],
                        "start": ["type": "string", "description": "Optional start time (ISO 8601, inclusive). e.g. '2026-09-14T08:00:00'"],
                        "end": ["type": "string", "description": "Optional end time (ISO 8601, exclusive). e.g. '2026-09-15T08:00:00'"]
                    ],
                    "required": ["query"]
                ]
            ],
            [
                "name": "get_recent_activity",
                "description": "Get the most recent captures from the last N minutes.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "minutes": ["type": "integer", "description": "Look back N minutes (default 60)"]
                    ]
                ]
            ],
            [
                "name": "get_activity_range",
                "description": "Get activity captured within a specific time range. Use this for 'what did I do between X and Y' queries. Timestamps are ISO 8601; if no timezone is given, local time is assumed.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "start": ["type": "string", "description": "Start time (ISO 8601, inclusive). e.g. '2026-08-12T08:00:00'"],
                        "end": ["type": "string", "description": "End time (ISO 8601, exclusive). e.g. '2026-08-12T16:00:00'"],
                        "limit": ["type": "integer", "description": "Max results (default 50, max 500)"]
                    ]
                ]
            ],
            [
                "name": "get_sync_status",
                "description": "Check sync status — how many events are pending push to homellm, and when the last sync occurred.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:]
                ]
            ],
            [
                "name": "list_sessions",
                "description": "List activity sessions, optionally filtered by date or machine.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "date": ["type": "string", "description": "ISO date (YYYY-MM-DD)"],
                        "machine_id": ["type": "string", "description": "Machine identifier"]
                    ]
                ]
            ],
            [
                "name": "get_session",
                "description": "Get details for a single activity session, including all captures within it.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "session_id": ["type": "string", "description": "Session UUID"]
                    ],
                    "required": ["session_id"]
                ]
            ],
            [
                "name": "list_meetings",
                "description": "List captured meeting transcripts with a preview. Newest first.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "limit": ["type": "integer", "description": "Max results (default 20, max 100)"]
                    ]
                ]
            ],
            [
                "name": "get_meeting_transcript",
                "description": "Get the full transcript for a meeting, by session_id or exact started_at (ISO 8601).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "session_id": ["type": "string", "description": "Session UUID of the meeting"],
                        "started_at": ["type": "string", "description": "Exact meeting start time, e.g. '2026-09-04T16:03:35Z'"]
                    ]
                ]
            ],
            [
                "name": "search_transcripts",
                "description": "Keyword search across meeting transcripts.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Search query text"],
                        "limit": ["type": "integer", "description": "Max results (default 10)"]
                    ],
                    "required": ["query"]
                ]
            ]
        ]

        await sendResult(id: id, result: ["tools": tools])
    }

    // MARK: - tools/call

    private func handleToolCall(id: Any?, params: [String: Any]?) async {
        guard let toolName = params?["name"] as? String else {
            await sendError(id: id, code: -32602, message: "Invalid params: missing name")
            return
        }

        let arguments = params?["arguments"] as? [String: Any] ?? [:]

        do {
            let result = try await callTool(name: toolName, arguments: arguments)
            let content: [[String: Any]] = [[
                "type": "text",
                "text": result
            ]]
            await sendResult(id: id, result: ["content": content])
        } catch {
            await sendError(id: id, code: -32000, message: error.localizedDescription)
        }
    }

    private func callTool(name: String, arguments: [String: Any]) async throws -> String {
        switch name {
        case "search_activities":
            let query = arguments["query"] as? String ?? ""
            let limit = arguments["limit"] as? Int ?? 20
            let start = arguments["start"] as? String
            let end = arguments["end"] as? String
            return try await searchActivities(query: query, limit: limit, start: start, end: end)

        case "get_recent_activity":
            let minutes = arguments["minutes"] as? Int ?? 60
            return try await getRecentActivity(minutes: minutes)

        case "get_activity_range":
            let start = arguments["start"] as? String
            let end = arguments["end"] as? String
            let limit = arguments["limit"] as? Int ?? 50
            return try await getActivityRange(start: start, end: end, limit: limit)

        case "get_sync_status":
            return await getSyncStatus()

        case "list_sessions":
            let date = arguments["date"] as? String
            let machineId = arguments["machine_id"] as? String
            return try await listSessions(date: date, machineId: machineId)

        case "get_session":
            guard let sessionId = arguments["session_id"] as? String else {
                throw ToolError.missingParam("session_id")
            }
            return try await getSession(sessionId)

        case "list_meetings":
            let limit = arguments["limit"] as? Int ?? 20
            return try await listMeetings(limit: limit)

        case "get_meeting_transcript":
            let sessionId = arguments["session_id"] as? String
            let startedAt = arguments["started_at"] as? String
            return try await getMeetingTranscript(sessionId: sessionId, startedAt: startedAt)

        case "search_transcripts":
            let query = arguments["query"] as? String ?? ""
            let limit = arguments["limit"] as? Int ?? 10
            return try await searchTranscripts(query: query, limit: limit)

        default:
            throw ToolError.unknownTool(name)
        }
    }

    // MARK: - Tool implementations

    /// Hybrid search: embedding similarity, with literal matches as a boost.
    ///
    /// Keyword alone misses paraphrase — "change ticket for production
    /// deployment" returns nothing by LIKE even though those conversations are on
    /// record, because those words never appear in that order. Semantic alone is
    /// weak on exact tokens: a ticket id should rank by literal presence, not by
    /// proximity in embedding space (a query for one scored 0.73 against screens
    /// that merely looked similar, while 1,455 rows contained it verbatim).
    ///
    /// Fusion is additive rather than rank-based, because the two lists aren't
    /// comparable: the semantic list is ordered by relevance, while a LIKE result
    /// set is ordered by recency, so its rank position carries no information. A
    /// literal match adds a bounded boost on top of the semantic score instead —
    /// larger for distinctive single-token queries and short curated fields,
    /// smaller for a common word inside a large OCR blob.
    private func searchActivities(
        query: String, limit: Int, start: String? = nil, end: String? = nil
    ) async throws -> String {
        let clampedLimit = min(max(limit, 1), 100)
        let candidates = clampedLimit * 3
        let startUTC = start.flatMap(normalizeToUTC)
        let endUTC = end.flatMap(normalizeToUTC)

        let keyword = try keywordMatches(
            query: query, limit: candidates, start: startUTC, end: endUTC
        )

        // Empty query means "no keyword filter" — skip semantics, keep the
        // recent-capture behaviour the tool has always had.
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var semanticAvailable = true
        var vector: [Float]?
        if !trimmedQuery.isEmpty {
            vector = await queryVector(trimmedQuery)
            semanticAvailable = vector != nil
        }
        let semanticHits = await semanticMatches(
            vector: vector, limit: candidates, start: startUTC, end: endUTC
        )

        let distinctive = isDistinctiveToken(query)

        // Keyword matches outside the semantic top-k still need a real score, or
        // they can only ever contribute their small boost and lose to every
        // semantic hit. Score them directly instead.
        let semanticIDs = Set(semanticHits.compactMap { $0["id"] as? String })
        let unscored = keyword.compactMap { $0["id"] as? String }.filter { !semanticIDs.contains($0) }
        var fillIn: [String: Float] = [:]
        if let vector, !unscored.isEmpty {
            let handle = db.handle
            fillIn = await Task.detached(priority: .userInitiated) {
                SemanticSearch.similarities(handle: handle, query: vector, eventIDs: unscored)
            }.value
        }

        var fused: [String: FusedHit] = [:]

        for hit in keyword {
            guard let id = hit["id"] as? String else { continue }
            var entry = fused[id] ?? FusedHit(payload: hit)
            entry.viaKeyword = true
            entry.keywordBoost = keywordBoost(for: hit, distinctive: distinctive)
            entry.capturedAt = hit["captured_at"] as? String ?? ""
            if entry.similarity == nil, let similarity = fillIn[id] {
                entry.similarity = Double((similarity * 100).rounded()) / 100
            }
            fused[id] = entry
        }

        for hit in semanticHits {
            guard let id = hit["id"] as? String else { continue }
            var entry = fused[id] ?? FusedHit(payload: hit)
            entry.viaSemantic = true
            entry.similarity = hit["similarity"] as? Double
            entry.capturedAt = hit["captured_at"] as? String ?? ""
            fused[id] = entry
        }

        var scored: [FusedHit] = []
        scored.reserveCapacity(fused.count)
        for entry in fused.values {
            var copy: FusedHit = entry
            copy.score = (copy.similarity ?? 0) + copy.keywordBoost
            if copy.score > 0 {
                scored.append(copy)
            }
        }
        // Relevance first, then recency. The tie-break matters: a keyword-only
        // result set shares one boost value, so without it those rows would come
        // back in arbitrary order.
        scored.sort { (first: FusedHit, second: FusedHit) -> Bool in
            if first.score == second.score {
                return first.capturedAt > second.capturedAt
            }
            return first.score > second.score
        }

        var results: [[String: Any]] = []
        var seenIdentities = Set<String>()
        for entry in scored {
            var payload = entry.payload
            // One screen can produce hundreds of matching rows; keep the best and
            // skip the rest so they don't consume the whole result list.
            let identity = resultIdentity(payload)
            guard seenIdentities.insert(identity).inserted else { continue }

            switch (entry.viaKeyword, entry.viaSemantic) {
            case (true, true): payload["match_source"] = "keyword+semantic"
            case (true, false): payload["match_source"] = "keyword"
            default: payload["match_source"] = "semantic"
            }
            if let similarity = entry.similarity {
                payload["similarity"] = similarity
            }

            results.append(payload)
            if results.count == clampedLimit { break }
        }

        guard !results.isEmpty else {
            if semanticAvailable {
                return "No matching activity found for '\(query)'."
            }
            return "No matching activity found for '\(query)' (semantic search "
                + "unavailable — embed server not responding, keyword search only)."
        }

        return prettyJSON(results)
    }

    /// A single distinctive token — a ticket id, hostname or error code. Literal
    /// matches on these are high precision, unlike a common word buried in a large
    /// OCR blob, so they earn the larger boost.
    private func isDistinctiveToken(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return false }
        guard trimmed.count >= 4 else { return false }
        return trimmed.contains(where: \.isNumber)
            || trimmed.contains("-")
            || trimmed.contains("_")
    }

    private func keywordBoost(for hit: [String: Any], distinctive: Bool) -> Double {
        switch hit["match_source"] as? String {
        case "window_title", "app_name":
            // Short curated fields — a match here is meaningful on its own.
            return 0.08
        case "text_content":
            // Large enough that a literal hit on an identifier outranks a screen
            // that is merely similar (measured: a ticket id present in 1,455 rows
            // scored 0.68 against a similar-looking screen's 0.75).
            return distinctive ? 0.10 : 0.02
        default:
            return 0.02
        }
    }

    /// Identity of a result for de-duplication: same app, same opening content.
    private func resultIdentity(_ payload: [String: Any]) -> String {
        let app = payload["app_name"] as? String ?? ""
        let text = payload["text"] as? String ?? ""
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return "\(app)|\(collapsed.prefix(200))"
    }

    private func keywordMatches(
        query: String, limit: Int, start: String?, end: String?
    ) throws -> [[String: Any]] {
        var conditions = [
            "is_duplicate = 0",
            "(text_content LIKE ? OR window_title LIKE ? OR app_name LIKE ?)",
        ]
        if start != nil { conditions.append("captured_at >= ?") }
        if end != nil { conditions.append("captured_at < ?") }

        let sql = """
            SELECT id, captured_at, app_name, window_title, source_type, text_content,
                   CASE
                       WHEN text_content LIKE ? THEN 'text_content'
                       WHEN window_title LIKE ? THEN 'window_title'
                       WHEN app_name LIKE ? THEN 'app_name'
                       ELSE 'unknown'
                   END AS match_source
            FROM events
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY captured_at DESC
            LIMIT ?
            """

        var stmtPointer: OpaquePointer?
        guard sqlite3_prepare_v2(db.handle, sql, -1, &stmtPointer, nil) == SQLITE_OK else {
            throw ToolError.queryFailed
        }
        let stmt = stmtPointer!
        defer { sqlite3_finalize(stmt) }

        let pattern = "%\(query)%"
        var index: Int32 = 1
        for _ in 0..<3 {  // CASE expressions in the SELECT list bind first
            bindText(stmt, index, pattern)
            index += 1
        }
        for _ in 0..<3 {  // then the WHERE predicate
            bindText(stmt, index, pattern)
            index += 1
        }
        if let start {
            bindText(stmt, index, start)
            index += 1
        }
        if let end {
            bindText(stmt, index, end)
            index += 1
        }
        sqlite3_bind_int(stmt, index, Int32(limit))

        var results: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let matchSource = columnText(stmt, 6)
            let text = columnText(stmt, 5)
            let windowTitle = columnTextOrNull(stmt, 3) ?? ""
            let appName = columnTextOrNull(stmt, 2) ?? ""

            let matchedValue: String
            switch matchSource {
            case "text_content": matchedValue = text
            case "window_title": matchedValue = windowTitle
            case "app_name": matchedValue = appName
            default: matchedValue = text
            }

            results.append([
                "id": columnText(stmt, 0),
                "captured_at": columnText(stmt, 1),
                "app_name": appName,
                "window_title": windowTitle,
                "source_type": columnText(stmt, 4),
                "text": text.isEmpty ? (windowTitle.isEmpty ? appName : windowTitle) : text,
                "match_source": matchSource,
                "matched_value": matchedValue,
            ])
        }
        return results
    }

    /// Embed the query, or nil when the embed server is unreachable.
    private func queryVector(_ query: String) async -> [Float]? {
        do {
            return try await SemanticSearch.embedQuery(query)
        } catch {
            fputs("[MCPServer] semantic search unavailable: \(error)\n", stderr)
            return nil
        }
    }

    /// Embedding similarity search, best-first. Empty when `vector` is nil (no
    /// semantic ranking available) so callers degrade to keyword-only.
    private func semanticMatches(
        vector: [Float]?, limit: Int, start: String?, end: String?
    ) async -> [[String: Any]] {
        guard let vector else { return [] }

        do {
            let handle = db.handle
            // Ranking scans every stored vector; run it off the actor so stdio
            // requests stay responsive. The MCP database handle is read-only, so
            // concurrent use is safe.
            let matches = try await Task.detached(priority: .userInitiated) {
                try SemanticSearch.search(
                    handle: handle, query: vector, limit: limit,
                    start: start, end: end
                )
            }.value

            return matches.map { match in
                [
                    "id": match.eventID,
                    "captured_at": match.capturedAt,
                    "app_name": match.appName ?? "",
                    "window_title": match.windowTitle ?? "",
                    "source_type": match.sourceType,
                    "text": match.text,
                    "match_source": "semantic",
                    // Round in the Double domain: rounding a Float leaves
                    // 0.8080000281333923 in the JSON payload.
                    "similarity": Double((match.similarity * 100).rounded()) / 100,
                ]
            }
        } catch {
            fputs("[MCPServer] semantic search failed: \(error)\n", stderr)
            return []
        }
    }

    private func getRecentActivity(minutes: Int) async throws -> String {
        let sql = """
            SELECT captured_at, trigger, app_name, window_title, source_type, text_content
            FROM events
            WHERE is_duplicate = 0
                            AND datetime(captured_at) > datetime('now', '-\(minutes) minutes')
            ORDER BY captured_at DESC
            LIMIT 50
            """

        var stmtPointer: OpaquePointer?
        guard sqlite3_prepare_v2(db.handle, sql, -1, &stmtPointer, nil) == SQLITE_OK else {
            throw ToolError.queryFailed
        }
        let stmt = stmtPointer!
        defer { sqlite3_finalize(stmt) }

        var results: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append([
                "captured_at": columnText(stmt, 0),
                "trigger": columnText(stmt, 1),
                "app_name": columnTextOrNull(stmt, 2) ?? "",
                "window_title": columnTextOrNull(stmt, 3) ?? "",
                "source_type": columnText(stmt, 4),
                "text": columnText(stmt, 5)
            ])
        }

        if results.isEmpty {
            return "No activity recorded in the last \(minutes) minutes."
        }

        return prettyJSON(results)
    }

    /// Query activity within an arbitrary time range. Timestamps normalized to UTC before SQL comparison.
    private func getActivityRange(start: String?, end: String?, limit: Int) async throws -> String {
        let clampedLimit = min(max(limit, 1), 500)

        var conditions: [String] = ["is_duplicate = 0"]
        var params: [String] = []

        if let start = start, let utc = normalizeToUTC(start) {
            conditions.append("captured_at >= ?")
            params.append(utc)
        }
        if let end = end, let utc = normalizeToUTC(end) {
            conditions.append("captured_at < ?")
            params.append(utc)
        }

        let sql = """
            SELECT captured_at, trigger, app_name, window_title, source_type, text_content
            FROM events
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY captured_at ASC
            LIMIT \(clampedLimit)
            """

        var stmtPointer: OpaquePointer?
        guard sqlite3_prepare_v2(db.handle, sql, -1, &stmtPointer, nil) == SQLITE_OK else {
            throw ToolError.queryFailed
        }
        let stmt = stmtPointer!
        defer { sqlite3_finalize(stmt) }

        for (i, p) in params.enumerated() {
            bindText(stmt, Int32(i + 1), p)
        }

        var results: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let capturedUTC = columnText(stmt, 0)
            results.append([
                "captured_at": capturedUTC,
                "captured_at_local": localString(forUTC: capturedUTC),
                "trigger": columnText(stmt, 1),
                "app_name": columnTextOrNull(stmt, 2) ?? "",
                "window_title": columnTextOrNull(stmt, 3) ?? "",
                "source_type": columnText(stmt, 4),
                "text": columnText(stmt, 5)
            ])
        }

        if results.isEmpty {
            return "No activity recorded in that time range."
        }

        return prettyJSON(results)
    }

    private func getSyncStatus() async -> String {
        let count = (try? await eventStore.unsyncedCount()) ?? 0
        let sql = "SELECT started_at, status FROM sync_log ORDER BY id DESC LIMIT 1"
        let row = db.queryOne(sql)

        let status: [String: Any] = [
            "unsynced_events": count,
            "last_sync_at": row?[0] ?? NSNull(),
            "last_sync_status": row?[1] ?? "never"
        ]

        if let data = try? JSONSerialization.data(withJSONObject: status, options: .prettyPrinted),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return "Could not retrieve sync status."
    }

    private func listSessions(date: String?, machineId: String?) async throws -> String {
        var sql = """
            SELECT id, machine_id, started_at, ended_at, timezone
            FROM sessions
            WHERE 1=1
            """
        if date != nil {
            sql += """
                 AND date(datetime(started_at, 'localtime')) <= date(?)
                 AND date(datetime(COALESCE(ended_at, started_at), 'localtime')) >= date(?)
                """
        }
        if machineId != nil {
            sql += " AND machine_id = ?"
        }
        sql += " ORDER BY started_at DESC LIMIT 200"

        var stmtPointer: OpaquePointer?
        guard sqlite3_prepare_v2(db.handle, sql, -1, &stmtPointer, nil) == SQLITE_OK else {
            throw ToolError.queryFailed
        }
        let stmt = stmtPointer!
        defer { sqlite3_finalize(stmt) }

        var idx: Int32 = 1
        if let date = date {
            bindText(stmt, idx, date)
            idx += 1
            bindText(stmt, idx, date)
            idx += 1
        }
        if let machineId = machineId {
            bindText(stmt, idx, machineId)
        }

        var results: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append([
                "id": columnText(stmt, 0),
                "machine_id": columnText(stmt, 1),
                "started_at": columnText(stmt, 2),
                "ended_at": columnTextOrNull(stmt, 3) as Any,
                "timezone": columnText(stmt, 4)
            ])
        }

        if results.isEmpty {
            return "No sessions found."
        }

        return prettyJSON(results)
    }

    private func getSession(_ sessionId: String) async throws -> String {
        let eventSQL = """
            SELECT captured_at, trigger, app_name, window_title, source_type, text_content
            FROM events
            WHERE session_id = ? AND is_duplicate = 0
            ORDER BY captured_at ASC
            LIMIT 200
            """

        var stmtPointer: OpaquePointer?
        guard sqlite3_prepare_v2(db.handle, eventSQL, -1, &stmtPointer, nil) == SQLITE_OK else {
            throw ToolError.queryFailed
        }
        let stmt = stmtPointer!
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, 1, sessionId)

        var events: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            events.append([
                "captured_at": columnText(stmt, 0),
                "trigger": columnText(stmt, 1),
                "app_name": columnTextOrNull(stmt, 2) ?? "",
                "window_title": columnTextOrNull(stmt, 3) ?? "",
                "source_type": columnText(stmt, 4),
                "text": columnText(stmt, 5)
            ])
        }

        let result: [String: Any] = [
            "session_id": sessionId,
            "event_count": events.count,
            "events": events
        ]

        return prettyJSON(result)
    }

    // MARK: - Meeting transcript tools

    private func listMeetings(limit: Int) async throws -> String {
        let clamped = min(max(limit, 1), 100)
        let sql = """
            SELECT id, session_id, started_at, ended_at, meeting_app, transcript
            FROM audio_segments
            ORDER BY started_at DESC
            LIMIT \\(clamped)
            """

        var stmtPointer: OpaquePointer?
        guard sqlite3_prepare_v2(db.handle, sql, -1, &stmtPointer, nil) == SQLITE_OK else {
            throw ToolError.queryFailed
        }
        let stmt = stmtPointer!
        defer { sqlite3_finalize(stmt) }

        var results: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let transcript = columnText(stmt, 5)
            results.append([
                "id": columnText(stmt, 0),
                "session_id": columnText(stmt, 1),
                "started_at": columnText(stmt, 2),
                "ended_at": columnTextOrNull(stmt, 3) as Any,
                "meeting_app": columnTextOrNull(stmt, 4) ?? "",
                "transcript_length": transcript.count,
                "preview": String(transcript.prefix(200))
            ])
        }

        if results.isEmpty {
            return "No meeting transcripts captured yet."
        }

        return prettyJSON(results)
    }

    private func getMeetingTranscript(sessionId: String?, startedAt: String?) async throws -> String {
        var sql = "SELECT id, session_id, started_at, ended_at, meeting_app, transcript FROM audio_segments"
        var param: String?
        if let sessionId, !sessionId.isEmpty {
            sql += " WHERE session_id = ?"
            param = sessionId
        } else if let startedAt, !startedAt.isEmpty {
            sql += " WHERE started_at = ?"
            param = startedAt
        } else {
            throw ToolError.missingParam("session_id or started_at")
        }
        sql += " ORDER BY started_at DESC LIMIT 1"

        var stmtPointer: OpaquePointer?
        guard sqlite3_prepare_v2(db.handle, sql, -1, &stmtPointer, nil) == SQLITE_OK else {
            throw ToolError.queryFailed
        }
        let stmt = stmtPointer!
        defer { sqlite3_finalize(stmt) }

        if let param {
            bindText(stmt, 1, param)
        }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return "No transcript found."
        }

        let result: [String: Any] = [
            "session_id": columnText(stmt, 1),
            "started_at": columnText(stmt, 2),
            "ended_at": columnTextOrNull(stmt, 3) as Any,
            "meeting_app": columnTextOrNull(stmt, 4) ?? "",
            "transcript": columnText(stmt, 5)
        ]
        return prettyJSON(result)
    }

    private func searchTranscripts(query: String, limit: Int) async throws -> String {
        let clamped = min(max(limit, 1), 100)
        let sql = """
            SELECT id, session_id, started_at, ended_at, meeting_app, transcript
            FROM audio_segments
            WHERE transcript LIKE ?
            ORDER BY started_at DESC
            LIMIT \\(clamped)
            """
        let pattern = "%\\(query)%"

        var stmtPointer: OpaquePointer?
        guard sqlite3_prepare_v2(db.handle, sql, -1, &stmtPointer, nil) == SQLITE_OK else {
            throw ToolError.queryFailed
        }
        let stmt = stmtPointer!
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, 1, pattern)

        var results: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append([
                "session_id": columnText(stmt, 1),
                "started_at": columnText(stmt, 2),
                "ended_at": columnTextOrNull(stmt, 3) as Any,
                "meeting_app": columnTextOrNull(stmt, 4) ?? "",
                "transcript": columnText(stmt, 5)
            ])
        }

        if results.isEmpty {
            return "No transcripts matched '\\(query)'."
        }

        return prettyJSON(results)
    }

    // MARK: - JSON-RPC response helpers

    private func sendResult(id: Any?, result: [String: Any]) async {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "result": result
        ]
        writeJSON(response)
    }

    private func sendError(id: Any?, code: Int, message: String) async {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": [
                "code": code,
                "message": message
            ]
        ]
        writeJSON(response)
    }

    /// Write a JSON object to stdout as a single line.
    /// Uses stderr for logging to keep stdout clean for JSON-RPC transport.
    private func writeJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let line = String(data: data, encoding: .utf8) else {
            fputs("[MCPServer] failed to serialize response\n", stderr)
            return
        }
        print(line)
        fflush(stdout)
    }
}

// MARK: - Helpers

/// A result accumulated across the keyword and semantic rankings, carrying the
/// fused score plus which sources surfaced it.
private struct FusedHit {
    var score: Double = 0
    var payload: [String: Any]
    var capturedAt: String = ""
    var viaKeyword = false
    var viaSemantic = false
    var similarity: Double?
    var keywordBoost: Double = 0
}

/// Read a non-null text column from a sqlite3 statement.
private func columnText(_ stmt: OpaquePointer, _ idx: Int32) -> String {
    guard let ptr = sqlite3_column_text(stmt, idx) else { return "" }
    return String(cString: ptr)
}

/// Read a nullable text column — returns nil if NULL, empty string is still a valid value.
private func columnTextOrNull(_ stmt: OpaquePointer, _ idx: Int32) -> String? {
    guard let ptr = sqlite3_column_text(stmt, idx) else { return nil }
    return String(cString: ptr)
}

private func bindText(_ stmt: OpaquePointer, _ idx: Int32, _ value: String) {
    sqlite3_bind_text(
        stmt,
        idx,
        (value as NSString).utf8String,
        -1,
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    )
}

/// Encode anything JSON-encodable to a pretty-printed string.
private func prettyJSON(_ object: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: .prettyPrinted),
          let text = String(data: data, encoding: .utf8) else {
        return ""
    }
    return text
}

// MARK: - Timestamp helpers

/// Convert an ISO-ish timestamp string to a canonical UTC "YYYY-MM-DDTHH:MM:SSZ".
/// Accepts with/without fractional seconds, with/without timezone (assumes local if absent).
private func normalizeToUTC(_ input: String) -> String? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    // ISO 8601 with fractional seconds
    let f1 = ISO8601DateFormatter()
    f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f1.date(from: trimmed) { return utcString(from: d) }

    // ISO 8601 without fractional seconds
    let f2 = ISO8601DateFormatter()
    f2.formatOptions = [.withInternetDateTime]
    if let d = f2.date(from: trimmed) { return utcString(from: d) }

    // "YYYY-MM-DDTHH:mm:ss" — T separator, no timezone → local time
    let fT = DateFormatter()
    fT.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    fT.timeZone = TimeZone.current
    if let d = fT.date(from: trimmed) { return utcString(from: d) }

    // "YYYY-MM-DD HH:mm:ss" (local time)
    let f3 = DateFormatter()
    f3.dateFormat = "yyyy-MM-dd HH:mm:ss"
    f3.timeZone = TimeZone.current
    if let d = f3.date(from: trimmed) { return utcString(from: d) }

    // "YYYY-MM-DD" (local date, midnight)
    let f4 = DateFormatter()
    f4.dateFormat = "yyyy-MM-dd"
    f4.timeZone = TimeZone.current
    if let d = f4.date(from: trimmed) { return utcString(from: d) }

    return nil
}

private func utcString(from date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    f.timeZone = TimeZone(secondsFromGMT: 0)
    return f.string(from: date)
}

/// Convert a stored UTC "YYYY-MM-DDTHH:MM:SSZ" string to local-time "YYYY-MM-DDTHH:MM:SS".
private func localString(forUTC utc: String) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    f.timeZone = TimeZone(secondsFromGMT: 0)
    guard let date = f.date(from: utc) else { return utc }
    let out = DateFormatter()
    out.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    out.timeZone = TimeZone.current
    return out.string(from: date)
}

enum ToolError: Error, LocalizedError {
    case unknownTool(String)
    case missingParam(String)
    case queryFailed

    var errorDescription: String? {
        switch self {
        case .unknownTool(let name): return "Unknown tool: \(name)"
        case .missingParam(let name): return "Missing required parameter: \(name)"
        case .queryFailed: return "Database query failed"
        }
    }
}
