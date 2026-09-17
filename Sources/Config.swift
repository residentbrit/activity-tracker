import Foundation

/// Failures that should stop configuration loading outright, as opposed to a
/// missing key (which keeps its default).
enum ConfigError: LocalizedError {
    case malformedJSON(String)
    case notAnObject

    var errorDescription: String? {
        switch self {
        case .malformedJSON(let detail):
            return "config.json is not valid JSON: \(detail)"
        case .notAnObject:
            return "config.json must contain a JSON object at the top level"
        }
    }
}

/// Loaded from ~/.config/activity-tracker/config.json at startup.
/// Reloadable on SIGHUP without restart.
struct Config: Codable {
    private static let runtimeHome = resolveRuntimeHome()
    // MARK: Capture
    var heartbeatIntervalSec: Int = 30
    var typingPauseSec: Int = 3
    var idleTimeoutMin: Int = 5

    // MARK: Tier 1 per-window polling
    /// Apps whose windows get per-window change detection at a faster cadence.
    /// AX-capable apps use text-hash diffs; AX-opaque apps use pixel-diff thumbnails.
    var tier1BundleIDs: [String] = [
        "com.tinyspeck.slackmacgap",        // Slack
        "com.microsoft.VSCode",             // VS Code
        "com.apple.Terminal",               // Terminal
        "com.google.Chrome",                // Chrome
        "net.librewolf.librewolf",          // LibreWolf (NOT io.gitlab.librewolf-community)
        "com.microsoft.Outlook",            // Outlook
    ]
    var tier1PollIntervalSec: Int = 5

    // MARK: Audio
    var audioMode: AudioMode = .meetingsOnly

    enum AudioMode: String, Codable {
        case meetingsOnly = "meetings_only"
        case off
    }

    // MARK: Meeting detection (D15)
    var meetingBundleIDs: [String] = [
        "com.microsoft.teams",
        "com.tinyspeck.slackmacgap",
        "us.zoom.xos"
    ]
    var meetingWindowTitlePatterns: [String] = [
        "huddle"  // Slack huddle detection
    ]

    // MARK: Storage
    var screenshotRetentionHours: Int = 24
    var dbPath: String = "\(Config.runtimeHome)/.local/share/activity-tracker/activity.db"

    // MARK: Sync (D13)
    var syncIntervalMin: Int = 30
    /// Prune sync-outbox export files older than this many days.
    /// 0 (the default) keeps everything — see `SyncEngine.pruneOutbox`.
    var syncOutboxRetentionDays: Int = 0
    /// Write JSON export files to `sync-outbox/` for a homellm-side collector.
    ///
    /// Off by default: that collector was never built, so the files accumulated
    /// with nothing reading them (~1GB). The direct SQLite→pgvector sync
    /// (`scripts/sync_to_pgvector.py`) replaces this path. Kept as a switch
    /// rather than deleted so the old mechanism remains available if needed.
    var syncOutboxEnabled: Bool = false
    var syncTarget: SyncTarget = SyncTarget()

    struct SyncTarget: Codable {
        var host: String = "192.168.1.33"
        var port: Int = 5433
        var database: String = "phillip_ai"
        var user: String = "activity_tracker"
        var password: String = "" // loaded from Keychain at runtime
    }

    // MARK: Models
    var whisperModel: WhisperModel = .small

    enum WhisperModel: String, Codable {
        case tiny, base, small, medium, largeV3 = "large-v3", largeV3Turbo = "large-v3-turbo"
    }

    var embeddingModel: String = "mxbai-embed-large"
    var embeddingModelPath: String = "\(Config.runtimeHome)/.local/share/activity-tracker/models/"

    /// Path to llama.cpp's llama-embedding binary.
    /// Build from: https://github.com/ggerganov/llama.cpp
    var embeddingBinaryPath: String = "\(Config.runtimeHome)/.local/bin/llama-embedding"

    /// Path to whisper.cpp's whisper-cli binary.
    /// Build from: https://github.com/ggerganov/whisper.cpp
    var whisperBinaryPath: String = "\(Config.runtimeHome)/.local/bin/whisper-cli"

    // MARK: Loading

    static let configPath = "\(runtimeHome)/.config/activity-tracker/config.json"

    static func load() throws -> Config {
        let url = URL(fileURLWithPath: configPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            // Return defaults, write template
            let defaults = Config()
            do {
                try defaults.write()
            } catch {
                fputs("[Config] warning: could not write default config at \(url.path): \(error)\n", stderr)
            }
            return defaults
        }
        let data = try Data(contentsOf: url)
        return try decode(data)
    }

    /// Decode the config file *on top of* the built-in defaults.
    ///
    /// Swift's synthesised `Codable` throws `keyNotFound` for an absent key — it
    /// does **not** fall back to the property's default value. So adding any new
    /// setting silently invalidated every existing config file, and the daemon
    /// started with all-default settings instead: it ignored the corrected
    /// LibreWolf id and the teams2 meeting bundle id, among other things.
    ///
    /// Overlaying the file onto the encoded defaults means a key the file doesn't
    /// mention keeps its default, while everything present still wins.
    private static func decode(_ data: Data) throws -> Config {
        // Parse the file first. A malformed file must fail loudly — `main` logs
        // "config load failed" — rather than quietly reverting to defaults, which
        // would look identical to "no config file" in the logs.
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ConfigError.malformedJSON(error.localizedDescription)
        }
        guard let fileObject = parsed as? [String: Any] else {
            throw ConfigError.notAnObject
        }

        // An explicit null means "unset": `merge` skips nulls at every depth.
        // Otherwise a null reaches the decoder, which rejects it for a
        // non-optional property — so one `"password": null` would revert the
        // entire config. Nested nulls count too: the top level alone is not enough.
        let nulledKeys = nullPaths(in: fileObject)
        if !nulledKeys.isEmpty {
            fputs("[Config] null keys treated as absent: \(nulledKeys.joined(separator: ", "))\n", stderr)
        }

        let defaultData = try JSONEncoder().encode(Config())
        guard let defaultObject = try JSONSerialization.jsonObject(with: defaultData) as? [String: Any] else {
            return try JSONDecoder().decode(Config.self, from: data)
        }

        let absent = Set(defaultObject.keys).subtracting(fileObject.keys).sorted()
        if !absent.isEmpty {
            fputs("[Config] absent keys keep their defaults: \(absent.joined(separator: ", "))\n", stderr)
        }

        // Surface keys we don't recognise. There is no migration for a *renamed*
        // setting: the old key stays in the file, the new property keeps its
        // default, and the configured value is silently lost — so at least say so.
        let unknown = Set(fileObject.keys).subtracting(defaultObject.keys).sorted()
        if !unknown.isEmpty {
            fputs("[Config] unrecognised keys ignored (renamed or typo?): \(unknown.joined(separator: ", "))\n", stderr)
        }

        let merged = try JSONSerialization.data(withJSONObject: merge(defaultObject, fileObject))
        return try JSONDecoder().decode(Config.self, from: merged)
    }

    /// Dotted paths of every null value in a config object, at any depth.
    private static func nullPaths(in object: [String: Any], prefix: String = "") -> [String] {
        var paths: [String] = []
        for (key, value) in object {
            let path = prefix.isEmpty ? key : "\(prefix).\(key)"
            if value is NSNull {
                paths.append(path)
            } else if let child = value as? [String: Any] {
                paths.append(contentsOf: nullPaths(in: child, prefix: path))
            }
        }
        return paths.sorted()
    }

    /// Recursively overlay `override` onto `base`, so partially-specified nested
    /// objects (e.g. `syncTarget`) don't lose their defaults either.
    ///
    /// Nulls are skipped at every depth: the decoder rejects null for a
    /// non-optional property, so dropping the key keeps the default instead of
    /// failing the whole decode.
    private static func merge(_ base: [String: Any], _ override: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in override {
            if value is NSNull { continue }
            if let baseChild = result[key] as? [String: Any],
               let overrideChild = value as? [String: Any] {
                result[key] = merge(baseChild, overrideChild)
            } else {
                result[key] = value
            }
        }
        return result
    }

    func write() throws {
        let url = URL(fileURLWithPath: Self.configPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url)
    }

    private static func resolveRuntimeHome() -> String {
        if let override = ProcessInfo.processInfo.environment["ACTIVITY_TRACKER_HOME"], !override.isEmpty {
            return (override as NSString).expandingTildeInPath
        }

        let home = NSHomeDirectory()
        let testDir = "\(home)/.local/share/activity-tracker"
        if canCreate(directory: testDir) {
            return home
        }

        let cwdFallback = "\(FileManager.default.currentDirectoryPath)/.activity-tracker"
        _ = canCreate(directory: "\(cwdFallback)/.local/share/activity-tracker")
        _ = canCreate(directory: "\(cwdFallback)/.config/activity-tracker")
        return cwdFallback
    }

    private static func canCreate(directory path: String) -> Bool {
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }
}
