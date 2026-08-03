import Foundation
import SQLite3

/// CRUD operations for events, sessions, screenshots, audio_segments.
/// Uses prepared statements with parameter binding (SQL injection safe).
actor EventStore {
    private let db: Database

    private let screenshotDir: String

    init(database: Database) {
        self.db = database
        let baseDir = (database.path as NSString).deletingLastPathComponent
        self.screenshotDir = "\(baseDir)/screenshots"
        try? FileManager.default.createDirectory(atPath: screenshotDir, withIntermediateDirectories: true)
    }

    // MARK: - Sessions

    func insertSession(_ session: Session) throws {
        let sql = """
            INSERT INTO sessions (id, machine_id, started_at, ended_at, timezone)
            VALUES (?, ?, ?, ?, ?)
        """
        try execute(sql, params: [
            session.id, session.machineId, session.startedAt,
            session.endedAt as Any, session.timezone
        ])
    }

    func updateSession(_ session: Session) throws {
        let sql = "UPDATE sessions SET ended_at = ? WHERE id = ?"
        try execute(sql, params: [session.endedAt as Any, session.id])
    }

    // MARK: - Events

    func insertEvent(
        id: String, sessionId: String, capturedAt: String,
        trigger: String, appBundleID: String?, appName: String?,
        windowTitle: String?, activeFilePath: String?,
        sourceType: String, textContent: String,
        embedding: Data?, dedupKey: String?, isDuplicate: Bool
    ) throws {
        let sql = """
            INSERT INTO events (id, session_id, captured_at, trigger,
                app_bundle_id, app_name, window_title, active_file_path,
                source_type, text_content, embedding, dedup_key, is_duplicate, synced)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
        """
        try execute(sql, params: [
            id, sessionId, capturedAt, trigger,
            appBundleID as Any, appName as Any, windowTitle as Any,
            activeFilePath as Any, sourceType, textContent,
            embedding as Any, dedupKey as Any, isDuplicate ? 1 : 0
        ])
    }

    /// Returns unsynced events (synced = 0), ordered by captured_at.
    func unsyncedEvents(limit: Int = 500) throws -> [EventRow] {
        let sql = """
            SELECT id, session_id, captured_at, trigger, app_bundle_id,
                   app_name, window_title, active_file_path, source_type,
                   text_content, embedding, dedup_key
            FROM events WHERE synced = 0 AND is_duplicate = 0
            ORDER BY captured_at ASC LIMIT ?
        """
        return try query(sql, params: [limit])
    }

    func markSynced(eventIDs: [String]) throws {
        let placeholders = eventIDs.map { _ in "?" }.joined(separator: ",")
        let sql = "UPDATE events SET synced = 1 WHERE id IN (\(placeholders))"
        try execute(sql, params: eventIDs)
    }

    /// Update embedding for an event after async embedding completes.
    func updateEmbedding(eventId: String, embedding: Data) throws {
        let sql = "UPDATE events SET embedding = ? WHERE id = ?"
        try execute(sql, params: [embedding, eventId])
    }

    // MARK: - Screenshots

    func saveScreenshot(eventId: String, imageData: Data) throws {
        let path = "\(screenshotDir)/\(eventId).png"
        try imageData.write(to: URL(fileURLWithPath: path))
        let sql = """
            INSERT OR REPLACE INTO screenshots (event_id, path, created_at)
            VALUES (?, ?, datetime('now'))
        """
        try execute(sql, params: [eventId, path])
    }

    /// Purge screenshots older than configured retention hours (D8).
    func purgeOldScreenshots(retentionHours: Int) throws {
        let sql = """
            SELECT s.event_id, s.path
            FROM screenshots s
            JOIN events e ON e.id = s.event_id
            WHERE s.created_at < datetime('now', '-\(retentionHours) hours')
              AND (e.embedding IS NOT NULL OR e.is_duplicate = 1 OR e.synced = 1)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db.handle, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        var toDelete: [(id: String, path: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let path = String(cString: sqlite3_column_text(stmt, 1))
            toDelete.append((id, path))
        }

        for item in toDelete {
            try? FileManager.default.removeItem(atPath: item.path)
        }

        let deleteSQL = """
            DELETE FROM screenshots
            WHERE event_id IN (
                SELECT s.event_id
                FROM screenshots s
                JOIN events e ON e.id = s.event_id
                WHERE s.created_at < datetime('now', '-\(retentionHours) hours')
                  AND (e.embedding IS NOT NULL OR e.is_duplicate = 1 OR e.synced = 1)
            )
            """
        try execute(deleteSQL, params: [])
    }

    // MARK: - Audio segments

    func insertAudioSegment(
        id: String, sessionId: String, startedAt: String, endedAt: String,
        meetingApp: String?, transcript: String, embedding: Data?
    ) throws {
        let sql = """
            INSERT INTO audio_segments (id, session_id, started_at, ended_at,
                meeting_app, transcript, embedding, synced)
            VALUES (?, ?, ?, ?, ?, ?, ?, 0)
        """
        try execute(sql, params: [
            id, sessionId, startedAt, endedAt,
            meetingApp as Any, transcript, embedding as Any
        ])
    }

    // MARK: - Sync log

    func insertSyncLog(startedAt: String) throws -> Int64 {
        let sql = "INSERT INTO sync_log (started_at, status) VALUES (?, 'in_progress')"
        try execute(sql, params: [startedAt])
        return sqlite3_last_insert_rowid(db.handle)
    }

    func updateSyncLog(id: Int64, endedAt: String, eventsSynced: Int, status: String) throws {
        let sql = """
            UPDATE sync_log SET ended_at = ?, events_synced = ?, status = ? WHERE id = ?
        """
        try execute(sql, params: [endedAt, eventsSynced, status, id])
    }

    /// Get count of unsynced events for MCP status check.
    func unsyncedCount() throws -> Int {
        let sql = "SELECT COUNT(*) FROM events WHERE synced = 0"
        guard let row = db.queryOne(sql), let countStr = row[0] else { return 0 }
        return Int(countStr) ?? 0
    }

    // MARK: - Internal

    private func execute(_ sql: String, params: [Any]) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db.handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executeFailed(String(cString: sqlite3_errmsg(db.handle)))
        }
        defer { sqlite3_finalize(stmt) }

        for (i, param) in params.enumerated() {
            let idx = Int32(i + 1)
            switch param {
            case let text as String:
                sqlite3_bind_text(
                    stmt,
                    idx,
                    (text as NSString).utf8String,
                    -1,
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                )
            case let data as Data:
                _ = data.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(stmt, idx, ptr.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            case let num as Int:
                sqlite3_bind_int64(stmt, idx, Int64(num))
            case let num as Int64:
                sqlite3_bind_int64(stmt, idx, num)
            case is NSNull:
                sqlite3_bind_null(stmt, idx)
            default:
                sqlite3_bind_null(stmt, idx)
            }
        }

        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_OK else {
            throw DatabaseError.executeFailed(String(cString: sqlite3_errmsg(db.handle)))
        }
    }

    private func query(_ sql: String, params: [Any]) throws -> [EventRow] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db.handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executeFailed(String(cString: sqlite3_errmsg(db.handle)))
        }
        defer { sqlite3_finalize(stmt) }

        for (i, param) in params.enumerated() {
            let idx = Int32(i + 1)
            switch param {
            case let num as Int:
                sqlite3_bind_int64(stmt, idx, Int64(num))
            default:
                break
            }
        }

        var rows: [EventRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(EventRow(stmt: stmt!))
        }
        return rows
    }
}

/// Lightweight row representation for sync payload construction.
struct EventRow {
    let id: String
    let sessionId: String
    let capturedAt: String
    let trigger: String
    let appBundleId: String?
    let appName: String?
    let windowTitle: String?
    let activeFilePath: String?
    let sourceType: String
    let textContent: String
    let embedding: Data?
    let dedupKey: String?

    init(stmt: OpaquePointer) {
        id = String(cString: sqlite3_column_text(stmt, 0))
        sessionId = String(cString: sqlite3_column_text(stmt, 1))
        capturedAt = String(cString: sqlite3_column_text(stmt, 2))
        trigger = String(cString: sqlite3_column_text(stmt, 3))
        appBundleId = columnText(stmt, 4)
        appName = columnText(stmt, 5)
        windowTitle = columnText(stmt, 6)
        activeFilePath = columnText(stmt, 7)
        sourceType = String(cString: sqlite3_column_text(stmt, 8))
        textContent = String(cString: sqlite3_column_text(stmt, 9))
        embedding = columnBlob(stmt, 10)
        dedupKey = columnText(stmt, 11)
    }
}

private func columnText(_ stmt: OpaquePointer, _ idx: Int32) -> String? {
    guard let cstr = sqlite3_column_text(stmt, idx) else { return nil }
    return String(cString: cstr)
}

private func columnBlob(_ stmt: OpaquePointer, _ idx: Int32) -> Data? {
    guard let blob = sqlite3_column_blob(stmt, idx) else { return nil }
    let count = sqlite3_column_bytes(stmt, idx)
    return Data(bytes: blob, count: Int(count))
}
