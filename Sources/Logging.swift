import Foundation

/// Global logger — writes to stderr + a debug file.
let logFile: FileHandle? = {
    let dir = "\(NSHomeDirectory())/.local/share/activity-tracker"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = "\(dir)/debug.log"
    FileManager.default.createFile(atPath: path, contents: nil)
    return try? FileHandle(forWritingTo: URL(fileURLWithPath: path))
}()

func log(_ msg: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
    fputs(line, stderr)
    fflush(stderr)
    if let data = line.data(using: .utf8) {
        try? logFile?.seekToEnd()
        try? logFile?.write(contentsOf: data)
    }
}
