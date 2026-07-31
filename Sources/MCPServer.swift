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
                "description": "Search captured activity by keyword. Returns matching events with timestamps, app context, and extracted text.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Search query text"],
                        "limit": ["type": "integer", "description": "Max results (default 20)"]
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
            ]
        ]

        await sendResult(id: id, result: ["tools": tools])
    }

    // MARK: - tools/call

    private func handleToolCall(id: Any?, params: [String: Any]?) async {
        guard let toolName = params?["name"] as? String,
              let arguments = params?["arguments"] as? [String: Any] else {
            await sendError(id: id, code: -32602, message: "Invalid params: missing name or arguments")
            return
        }

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
            return try await searchActivities(query: query, limit: limit)

        case "get_recent_activity":
            let minutes = arguments["minutes"] as? Int ?? 60
            return try await getRecentActivity(minutes: minutes)

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

        default:
            throw ToolError.unknownTool(name)
        }
    }

    // MARK: - Tool implementations

    private func searchActivities(query: String, limit: Int) async throws -> String {
        // Full-text search over text_content + structured fields.
        // When llama.cpp is integrated, this becomes semantic search via embeddings.
        let sql = """
            SELECT captured_at, app_name, window_title, source_type, text_content
            FROM events
            WHERE is_duplicate = 0
              AND (text_content LIKE ? OR window_title LIKE ? OR app_name LIKE ?)
            ORDER BY captured_at DESC
            LIMIT ?
            """
        let pattern = "%\(query)%"

        var stmtPointer: OpaquePointer?
        guard sqlite3_prepare_v2(db.handle, sql, -1, &stmtPointer, nil) == SQLITE_OK else {
            throw ToolError.queryFailed
        }
        let stmt = stmtPointer!
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, pattern, -1, nil)
        sqlite3_bind_text(stmt, 2, pattern, -1, nil)
        sqlite3_bind_text(stmt, 3, pattern, -1, nil)
        sqlite3_bind_int(stmt, 4, Int32(limit))

        var results: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append([
                "captured_at": columnText(stmt, 0),
                "app_name": columnTextOrNull(stmt, 1) ?? "",
                "window_title": columnTextOrNull(stmt, 2) ?? "",
                "source_type": columnText(stmt, 3),
                "text": columnText(stmt, 4)
            ])
        }

        if results.isEmpty {
            return "No matching activity found for '\(query)'."
        }

        return prettyJSON(results)
    }

    private func getRecentActivity(minutes: Int) async throws -> String {
        let sql = """
            SELECT captured_at, trigger, app_name, window_title, source_type, text_content
            FROM events
            WHERE is_duplicate = 0
              AND captured_at > datetime('now', '-\(minutes) minutes')
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
            sql += " AND date(started_at) = ?"
        }
        if machineId != nil {
            sql += " AND machine_id = ?"
        }
        sql += " ORDER BY started_at DESC LIMIT 50"

        var stmtPointer: OpaquePointer?
        guard sqlite3_prepare_v2(db.handle, sql, -1, &stmtPointer, nil) == SQLITE_OK else {
            throw ToolError.queryFailed
        }
        let stmt = stmtPointer!
        defer { sqlite3_finalize(stmt) }

        var idx: Int32 = 1
        if let date = date {
            sqlite3_bind_text(stmt, idx, date, -1, nil)
            idx += 1
        }
        if let machineId = machineId {
            sqlite3_bind_text(stmt, idx, machineId, -1, nil)
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

        sqlite3_bind_text(stmt, 1, sessionId, -1, nil)

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

/// Encode anything JSON-encodable to a pretty-printed string.
private func prettyJSON(_ object: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: .prettyPrinted),
          let text = String(data: data, encoding: .utf8) else {
        return ""
    }
    return text
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
