import Foundation

/// Timestamped log lines to stdout and, once `openFile` was called, to a file (the `.app` has no terminal).
public enum Log {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var file: FileHandle?
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Starts a fresh log at `url`; the previous run's log is kept as `<name>.1`.
    public static func openFile(_ url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = url.appendingPathExtension("1")
        try? fm.removeItem(at: old)
        try? fm.moveItem(at: url, to: old)
        fm.createFile(atPath: url.path, contents: nil)
        lock.withLock { file = try? FileHandle(forWritingTo: url) }
    }

    public static func line(_ s: String) {
        lock.withLock {
            let text = "\(formatter.string(from: Date())) \(s)\n"
            FileHandle.standardOutput.write(Data(text.utf8))
            file?.write(Data(text.utf8))
        }
    }
}

public func mb(_ b: UInt64) -> String { String(format: "%.0f MB", Double(b) / 1_048_576) }
