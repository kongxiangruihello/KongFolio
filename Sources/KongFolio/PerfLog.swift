import Foundation

/// A line per heavy step (an OCR chunk, a batch file) with its pages and seconds, kept in
/// ~/Library/Logs/KongFolio-perf.log, so real books give real numbers: seconds per page, and where the time goes.
enum PerfLog {
    private static let lock = NSLock()

    static var url: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!.appendingPathComponent("Logs/KongFolio-perf.log")
    }

    /// One log line: "2026-10-18 10:00:00 | 识别文本 | 书.pdf | 20 页 | 41.3 秒 | 2.07 秒/页 | 备注".
    static func line(_ step: String, name: String, pages: Int, seconds: Double, note: String = "", date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var parts = [formatter.string(from: date), step, name, "\(pages) 页", String(format: "%.1f 秒", seconds)]
        if pages > 0 { parts.append(String(format: "%.2f 秒/页", seconds / Double(pages))) }
        if !note.isEmpty { parts.append(note) }
        return parts.joined(separator: " | ")
    }

    static func record(_ step: String, name: String, pages: Int, seconds: Double, note: String = "", to target: URL? = nil) {
        let text = line(step, name: name, pages: pages, seconds: seconds, note: note) + "\n"
        let file = target ?? url
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile(); handle.write(Data(text.utf8)); try? handle.close()
        } else {
            try? text.write(to: file, atomically: true, encoding: .utf8)
        }
    }
}
