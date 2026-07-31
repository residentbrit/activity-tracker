import Foundation

/// Entry point. Sets up signal handlers, loads config, starts the capture daemon.
/// Runs as a background agent — no GUI, no dock icon.
@main
struct ActivityTracker {
    static func main() async throws {
        print("[ActivityTracker] starting up…")

        // 1. Load config
        let config = try Config.load()

        // 2. Initialize storage (creates SQLite DB + runs migrations if needed)
        let db = try Database(config: config)

        // 3. Start capture engine
        let captureEngine = CaptureEngine(config: config, database: db)

        // 4. Start MCP server (stdio transport — clients like Claude Desktop connect via pipe)
        let mcpServer = MCPServer(database: db)

        // 5. Start sync engine (30-min background sync to homellm)
        let syncEngine = SyncEngine(config: config, database: db)

        // 6. Start audio capture (meetings-only, polls meeting state)
        let audioCapture = AudioCapture(config: config, database: db)

        // Run until SIGTERM/SIGINT
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await captureEngine.run() }
            group.addTask { await mcpServer.run() }
            group.addTask { await syncEngine.run() }
            group.addTask { await audioCapture.startPolling() }
        }
    }
}
