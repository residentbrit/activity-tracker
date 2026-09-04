import Foundation
import Darwin

private var retainedSignalSources: [DispatchSourceSignal] = []

/// Entry point. Sets up signal handlers, loads config, starts the capture daemon.
/// Runs as a background agent — no GUI, no dock icon.
@main
struct ActivityTracker {
    static func main() async throws {
        let options = RuntimeOptions(arguments: CommandLine.arguments)

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
        //    MCP-only mode opens read-only — it must never write or create the DB.
        log("opening database…")
        let db: Database
        do {
            db = try Database(config: config, readOnly: !options.collectorOnly)
        } catch {
            let fallbackDir = "\(FileManager.default.currentDirectoryPath)/.activity-tracker/.local/share/activity-tracker"
            try? FileManager.default.createDirectory(atPath: fallbackDir, withIntermediateDirectories: true)
            config.dbPath = "\(fallbackDir)/activity.db"
            log("database open failed at configured path; retrying with fallback path: \(config.dbPath)")
            db = try Database(config: config, readOnly: !options.collectorOnly)
        }
        log("database ready")

        // Separate SQLite connections per subsystem. A single shared connection
        // accessed concurrently from multiple actors corrupts macOS SQLite's
        // purgeable page cache (SIGABRT in purgeableCacheUnpin). WAL mode +
        // busy_timeout make multiple connections safe.
        let captureDB = options.collectorOnly ? ((try? Database(config: config)) ?? db) : db
        let syncDB    = options.collectorOnly ? ((try? Database(config: config)) ?? db) : db
        let audioDB   = options.collectorOnly ? ((try? Database(config: config)) ?? db) : db

        // Close sessions left dangling by a previous run (crashed/killed daemon).
        if options.collectorOnly {
            do {
                try await EventStore(database: captureDB).closeDanglingSessions()
            } catch {
                log("closeDanglingSessions failed: \(error)")
            }
        }

        // 3-6: create subsystems (don't start them yet)
        log("initializing subsystems…")
        let captureEngine = CaptureEngine(config: config, database: captureDB)
        let mcpServer = MCPServer(database: db)
        let syncEngine = SyncEngine(config: config, database: syncDB)
        let audioCapture = AudioCapture(config: config, database: audioDB)
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
            if options.collectorOnly {
                // Collector daemon: capture + sync + audio, read-write DB
                group.addTask {
                    log("capture engine starting…")
                    await captureEngine.run()
                }
                group.addTask {
                    log("sync engine starting…")
                    await syncEngine.run()
                }
                group.addTask {
                    log("audio capture starting…")
                    await audioCapture.startPolling()
                }
            } else {
                // MCP mode: query server only, read-only DB — never captures or writes
                log("mcp-only mode: capture/sync/audio disabled")
                group.addTask {
                    log("mcp server starting…")
                    await mcpServer.run()
                }
            }
        }
    }
}

private struct RuntimeOptions {
    let collectorOnly: Bool

    init(arguments: [String]) {
        collectorOnly = arguments.contains("--collector-only")
    }
}
