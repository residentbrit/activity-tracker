import Foundation

/// Background sync to homellm pgvector (D10, D13).
///
/// Every N minutes: exports unsynced events to a JSON file, then
/// marks them as synced. A companion script (Python, part of homellm)
/// reads the file and pushes to pgvector. This keeps the Swift agent
/// free of Postgres dependency wrangling.
///
/// TODO: replace file-based export with direct pgvector push once
///       a suitable Swift Postgres client is available or libpq headers
///       are accessible.
actor SyncEngine {
    private var config: Config
    private let db: Database
    private let eventStore: EventStore

    /// Directory where sync export files are written.
    /// Companion script watches this directory.
    private let exportDir: String

    init(config: Config, database: Database) {
        self.config = config
        self.db = database
        self.eventStore = EventStore(database: database)
        let baseDir = (config.dbPath as NSString).deletingLastPathComponent
        self.exportDir = "\(baseDir)/sync-outbox"
    }

    func applyConfig(_ newConfig: Config) {
        config = newConfig
    }

    func run() async {
        log("[SyncEngine] run loop starting\n")
        while !Task.isCancelled {
            do { try await performSync() }
            catch { log("[SyncEngine] sync failed: \(error.localizedDescription)\n") }
            try? await Task.sleep(for: .seconds(config.syncIntervalMin * 60))
        }
    }

    /// Delete outbox exports older than `syncOutboxRetentionDays`.
    ///
    /// Nothing consumes these files automatically and `markSynced` records that a
    /// row was *written* to the outbox, not that it was delivered — so without a
    /// retention window the directory grows forever (~100MB/day at current rates).
    /// Retention is opt-in: the default of 0 keeps every file, so this can't
    /// delete data for a consumer that might still be pulling it.
    private func pruneOutbox() {
        let retentionDays = config.syncOutboxRetentionDays
        guard retentionDays > 0 else { return }

        let cutoff: Date = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        let directory = URL(fileURLWithPath: exportDir)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: []
            )
        } catch {
            return
        }

        var removed = 0
        var bytes = 0
        for file in files {
            if file.pathExtension != "json" { continue }

            let values = try? file.resourceValues(forKeys: keys)
            guard let modified: Date = values?.contentModificationDate else { continue }
            if modified >= cutoff { continue }

            let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
            let size: Int = (attributes?[FileAttributeKey.size] as? Int) ?? 0

            do {
                try FileManager.default.removeItem(at: file)
                removed += 1
                bytes += size
            } catch {
                continue
            }
        }

        if removed > 0 {
            log("[SyncEngine] pruned \(removed) outbox file(s), \(bytes / 1_048_576)MB, "
                + "older than \(retentionDays)d\n")
        }
    }

    private func performSync() async throws {
        let startedAt = nowISO()
        let logId = try await eventStore.insertSyncLog(startedAt: startedAt)

        let events = try await eventStore.unsyncedEvents(limit: 500)
        guard !events.isEmpty else {
            try await eventStore.updateSyncLog(id: logId, endedAt: nowISO(), eventsSynced: 0, status: "nothing_to_sync")
            pruneOutbox()
            return
        }

        // Export to JSON file
        let exportData = events.map { event in
            [
                "id": event.id,
                "session_id": event.sessionId,
                "captured_at": event.capturedAt,
                "trigger": event.trigger,
                "app_bundle_id": event.appBundleId as Any,
                "app_name": event.appName as Any,
                "window_title": event.windowTitle as Any,
                "active_file_path": event.activeFilePath as Any,
                "source_type": event.sourceType,
                "text_content": event.textContent,
                "embedding": event.embedding?.base64EncodedString() as Any,
            ]
        }

        let payload: [String: Any] = [
            "exported_at": startedAt,
            "machine_id": Host.current().localizedName ?? "unknown",
            "events": exportData
        ]

        let json = try JSONSerialization.data(withJSONObject: payload, options: [])
        let filename = "sync-\(startedAt.replacingOccurrences(of: ":", with: "-")).json"
        let dir = URL(fileURLWithPath: exportDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json.write(to: dir.appendingPathComponent(filename))

        // Mark as synced locally
        let syncedIDs = events.map { $0.id }
        try await eventStore.markSynced(eventIDs: syncedIDs)

        try await eventStore.updateSyncLog(id: logId, endedAt: nowISO(), eventsSynced: syncedIDs.count, status: "exported")
        log("[SyncEngine] exported \(syncedIDs.count) events → \(filename)\n")
        pruneOutbox()
    }

    func status() async -> SyncStatus {
        let count = (try? await eventStore.unsyncedCount()) ?? 0
        let row = db.queryOne("SELECT started_at, status FROM sync_log ORDER BY id DESC LIMIT 1")
        return SyncStatus(unsyncedEvents: count, lastSyncAt: row?[0] ?? nil, lastSyncStatus: row?[1] ?? "never")
    }

    private func nowISO() -> String { ISO8601DateFormatter().string(from: Date()) }
}

struct SyncStatus: Codable {
    let unsyncedEvents: Int
    let lastSyncAt: String?
    let lastSyncStatus: String
}
