import Foundation

/// Global logger — writes to stderr immediately, queues file writes async.
let logFile: FileHandle? = {
    let dir = "\(NSHomeDirectory())/.local/share/activity-tracker"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = "\(dir)/debug.log"
    FileManager.default.createFile(atPath: path, contents: nil)
    return try? FileHandle(forWritingTo: URL(fileURLWithPath: path))
}()

private let logQueue = DispatchQueue(label: "activity-tracker.log", qos: .utility)

func log(_ msg: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
    fputs(line, stderr)
    fflush(stderr)
    // Write to file async — never block the calling thread
    let data = line.data(using: .utf8)
    logQueue.async {
        guard let data else { return }
        _ = try? logFile?.seekToEnd()
        try? logFile?.write(contentsOf: data)
    }
}
