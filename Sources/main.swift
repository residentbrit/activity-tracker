import Foundation

/// Entry point. Sets up signal handlers, loads config, starts the capture daemon.
/// Runs as a background agent — no GUI, no dock icon.
@main
struct ActivityTracker {
    static func main() async throws {

        // 1. Load config
        log("loading config…")
        let config = try Config.load()
        log("config loaded")

        // 2. Initialize storage (creates SQLite DB + runs migrations if needed)
        log("opening database…")
        let db = try Database(config: config)
        log("database ready")

        // 3-6: create subsystems (don't start them yet)
        log("initializing subsystems…")
        let captureEngine = CaptureEngine(config: config, database: db)
        let mcpServer = MCPServer(database: db)
        let syncEngine = SyncEngine(config: config, database: db)
        let audioCapture = AudioCapture(config: config, database: db)
        log("subsystems ready")

        // Run until SIGTERM/SIGINT
        log("entering run loop…")
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                log("capture engine starting…")
                await captureEngine.run()
            }
            group.addTask {
                log("mcp server starting…")
                await mcpServer.run()
            }
            group.addTask {
                log("sync engine starting…")
                await syncEngine.run()
            }
            group.addTask {
                log("audio capture starting…")
                await audioCapture.startPolling()
            }
        }
    }
}
