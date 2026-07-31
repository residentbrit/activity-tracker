import Foundation

/// Loaded from ~/.config/activity-tracker/config.json at startup.
/// Reloadable on SIGHUP without restart.
struct Config: Codable {
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
        "io.gitlab.librewolf-community",    // LibreWolf
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
    var dbPath: String = "\(NSHomeDirectory())/.local/share/activity-tracker/activity.db"

    // MARK: Sync (D13)
    var syncIntervalMin: Int = 30
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
    var embeddingModelPath: String = "\(NSHomeDirectory())/.local/share/activity-tracker/models/"

    /// Path to llama.cpp's llama-embedding binary.
    /// Build from: https://github.com/ggerganov/llama.cpp
    var embeddingBinaryPath: String = "\(NSHomeDirectory())/.local/bin/llama-embedding"

    /// Path to whisper.cpp's whisper-cli binary.
    /// Build from: https://github.com/ggerganov/whisper.cpp
    var whisperBinaryPath: String = "\(NSHomeDirectory())/.local/bin/whisper-cli"

    // MARK: Loading

    static let configPath = "\(NSHomeDirectory())/.config/activity-tracker/config.json"

    static func load() throws -> Config {
        let url = URL(fileURLWithPath: configPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            // Return defaults, write template
            let defaults = Config()
            try defaults.write()
            return defaults
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Config.self, from: data)
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
}
