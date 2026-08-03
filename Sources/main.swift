import Foundation
import Darwin

private var retainedSignalSources: [DispatchSourceSignal] = []

/// Entry point. Sets up signal handlers, loads config, starts the capture daemon.
/// Runs as a background agent — no GUI, no dock icon.
@main
struct ActivityTracker {
    static func main() async throws {

        // 1. Load config
        log("loading config…")
        var config: Config
        do {
            config = try Config.load()
        } catch {
            log("config load failed, using defaults: \(error)")
            config = Config()
        }
        log("config loaded")

        // 2. Initialize storage (creates SQLite DB + runs migrations if needed)
        log("opening database…")
        let db: Database
        do {
            db = try Database(config: config)
        } catch {
            let fallbackDir = "\(FileManager.default.currentDirectoryPath)/.activity-tracker/.local/share/activity-tracker"
            try? FileManager.default.createDirectory(atPath: fallbackDir, withIntermediateDirectories: true)
            config.dbPath = "\(fallbackDir)/activity.db"
            log("database open failed at configured path; retrying with fallback path: \(config.dbPath)")
            db = try Database(config: config)
        }
        log("database ready")

        // 3-6: create subsystems (don't start them yet)
        log("initializing subsystems…")
        let captureEngine = CaptureEngine(config: config, database: db)
        let mcpServer = MCPServer(database: db)
        let syncEngine = SyncEngine(config: config, database: db)
        let audioCapture = AudioCapture(config: config, database: db)
        log("subsystems ready")

        signal(SIGHUP, SIG_IGN)
        let reloadQueue = DispatchQueue(label: "activity-tracker.reload")
        let sighupSource = DispatchSource.makeSignalSource(signal: SIGHUP, queue: reloadQueue)
        sighupSource.setEventHandler {
            Task {
                do {
                    let newConfig = try Config.load()
                    await captureEngine.applyConfig(newConfig)
                    await syncEngine.applyConfig(newConfig)
                    await audioCapture.applyConfig(newConfig)
                    log("reloaded config via SIGHUP")
                } catch {
                    log("config reload failed: \(error)")
                }
            }
        }
        sighupSource.resume()
        retainedSignalSources.append(sighupSource)

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
