import Foundation
import SQLite3

/// Thin wrapper around SQLite. Creates DB, runs migrations, provides
/// type-safe access to events, sessions, screenshots, audio_segments, sync_log.
final class Database {
    private var db: OpaquePointer?
    let path: String

    init(config: Config) throws {
        self.path = config.dbPath

        // Ensure directory exists
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )

        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw DatabaseError.openFailed(String(cString: sqlite3_errmsg(db)))
        }

        // WAL mode for concurrent reads during writes
        _ = try? execute("PRAGMA journal_mode=WAL")
        _ = try? execute("PRAGMA foreign_keys=ON")

        try migrate()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Migrations

    private var schemaVersion: Int {
        guard let row = queryOne("SELECT MAX(version) FROM schema_version"),
              let v = row[0] else { return 0 }
        return Int(v) ?? 0
    }

    func migrate() throws {
        // Create schema_version table if it doesn't exist
        try execute("""
            CREATE TABLE IF NOT EXISTS schema_version (
                version INTEGER PRIMARY KEY,
                applied_at TEXT NOT NULL DEFAULT (datetime('now'))
            )
        """)

        let current = schemaVersion

        if current < 1 {
            try execute("""
                CREATE TABLE sessions (
                    id TEXT PRIMARY KEY,
                    machine_id TEXT NOT NULL,
                    started_at TEXT NOT NULL,
                    ended_at TEXT,
                    timezone TEXT NOT NULL
                )
            """)
            try execute("""
                CREATE TABLE events (
                    id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL REFERENCES sessions(id),
                    captured_at TEXT NOT NULL,
                    trigger TEXT NOT NULL,
                    app_bundle_id TEXT,
                    app_name TEXT,
                    window_title TEXT,
                    active_file_path TEXT,
                    source_type TEXT NOT NULL,
                    text_content TEXT NOT NULL,
                    embedding BLOB,
                    dedup_key TEXT,
                    is_duplicate INTEGER DEFAULT 0,
                    synced INTEGER DEFAULT 0
                )
            """)
            try execute("""
                CREATE TABLE screenshots (
                    event_id TEXT PRIMARY KEY REFERENCES events(id) ON DELETE CASCADE,
                    path TEXT NOT NULL,
                    created_at TEXT NOT NULL
                )
            """)
            try execute("""
                CREATE TABLE audio_segments (
                    id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL REFERENCES sessions(id),
                    started_at TEXT NOT NULL,
                    ended_at TEXT NOT NULL,
                    meeting_app TEXT,
                    transcript TEXT NOT NULL,
                    embedding BLOB,
                    synced INTEGER DEFAULT 0
                )
            """)
            try execute("""
                CREATE TABLE sync_log (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    started_at TEXT NOT NULL,
                    ended_at TEXT,
                    events_synced INTEGER DEFAULT 0,
                    status TEXT
                )
            """)
            try execute("CREATE INDEX idx_events_session ON events(session_id)")
            try execute("CREATE INDEX idx_events_captured ON events(captured_at)")
            try execute("CREATE INDEX idx_events_synced ON events(synced)")
            try execute("CREATE INDEX idx_events_dedup ON events(dedup_key)")

            try execute("INSERT INTO schema_version(version) VALUES (1)")
        }

        if current < 2 {
            // v2: Switch screenshots from BLOB to disk-based storage
            try execute("DROP TABLE IF EXISTS screenshots")
            try execute("""
                CREATE TABLE screenshots (
                    event_id TEXT PRIMARY KEY REFERENCES events(id) ON DELETE CASCADE,
                    path TEXT NOT NULL,
                    created_at TEXT NOT NULL
                )
            """)
            try execute("INSERT INTO schema_version(version) VALUES (2)")
        }
    }

    // MARK: - Raw execution

    @discardableResult
    func execute(_ sql: String) throws -> Int32 {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK, let msg = errMsg {
            let error = String(cString: msg)
            sqlite3_free(errMsg)
            throw DatabaseError.executeFailed(error)
        }
        return rc
    }

    func queryOne(_ sql: String) -> [String?]? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let count = sqlite3_column_count(stmt)
        var row: [String?] = []
        for i in 0..<count {
            if let cstr = sqlite3_column_text(stmt, i) {
                row.append(String(cString: cstr))
            } else {
                row.append(nil)
            }
        }
        return row
    }

    /// Returns the underlying sqlite3 pointer for prepared statement usage.
    var handle: OpaquePointer? { db }
}

enum DatabaseError: Error {
    case openFailed(String)
    case executeFailed(String)
}
