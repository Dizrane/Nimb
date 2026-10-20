import Foundation

/// A short diary of what Nimb did and what went wrong: the last lines are kept in memory and in a small file, so that a report
/// also has what happened before the program was started again. It holds no secrets: only what the person saw on the screen
/// and the names of the steps. Addresses are removed again when a report is made (`ReportRedactor`).
final class AppLog: @unchecked Sendable {
    static let shared = AppLog()

    private let lock = NSLock()
    private var lines: [String] = []
    private let fileURL: URL
    private static let keepInMemory = 400
    private static let fileLimit = 200_000

    private init() {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
        let dir = base.appendingPathComponent("Logs/Nimb", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("nimb.log")
        trimFile()
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    func add(_ tag: String, _ message: String) {
        let line = "\(Self.stamp.string(from: Date())) [\(tag)] \(message.replacingOccurrences(of: "\n", with: " ⏎ "))"
        lock.lock()
        lines.append(line)
        if lines.count > Self.keepInMemory { lines.removeFirst(lines.count - Self.keepInMemory) }
        append(line + "\n")
        lock.unlock()
    }

    /// The last `count` lines of this run, and before them the end of the file of the runs before.
    func recent(_ count: Int) -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL), let text = String(data: data, encoding: .utf8) else { return Array(lines.suffix(count)) }
        return Array(text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init).suffix(count))
    }

    private func append(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }

    /// Keeps the file small: when it is large, only the last half stays.
    private func trimFile() {
        guard let data = try? Data(contentsOf: fileURL), data.count > Self.fileLimit else { return }
        let tail = data.suffix(Self.fileLimit / 2)
        if let newline = tail.firstIndex(of: 0x0A) { try? Data(tail[tail.index(after: newline)...]).write(to: fileURL) }
    }
}
