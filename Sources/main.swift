import Foundation

/// Entry point. Sets up signal handlers, loads config, starts the capture daemon.
/// Runs as a background agent — no GUI, no dock icon.
@main
struct ActivityTracker {
    static func main() async throws {
        fputs("[ActivityTracker] starting up…\n", stderr)

        // 1. Load config
        fputs("[ActivityTracker] loading config…\n", stderr)
        let config = try Config.load()
        fputs("[ActivityTracker] config loaded\n", stderr)

        // 2. Initialize storage (creates SQLite DB + runs migrations if needed)
        fputs("[ActivityTracker] opening database…\n", stderr)
        let db = try Database(config: config)
        fputs("[ActivityTracker] database ready\n", stderr)

        // 3-6: create subsystems (don't start them yet)
        fputs("[ActivityTracker] initializing subsystems…\n", stderr)
        let captureEngine = CaptureEngine(config: config, database: db)
        let mcpServer = MCPServer(database: db)
        let syncEngine = SyncEngine(config: config, database: db)
        let audioCapture = AudioCapture(config: config, database: db)
        fputs("[ActivityTracker] subsystems ready\n", stderr)

        // Run until SIGTERM/SIGINT
        fputs("[ActivityTracker] entering run loop…\n", stderr)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await captureEngine.run() }
            group.addTask { await mcpServer.run() }
            group.addTask { await syncEngine.run() }
            group.addTask { await audioCapture.startPolling() }
        }
    }
}
