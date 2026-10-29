import Foundation
struct TrialReport: Codable {
    var inputPages: Int
    var outputPages: Int
    var beforeBytes: Int
    var afterBytes: Int
    var recognizedPages: Int
    var elapsed: Double
    var wordCreated: Bool
    var chapterFiles: Int
    var summary: String { "试做完成：\(inputPages) → \(outputPages) 页，识别 \(recognizedPages) 页，耗时 " + String(format:"%.2f 秒",elapsed) + "；文件 " + ByteCountFormatter.string(fromByteCount:Int64(beforeBytes),countStyle:.file) + " → " + ByteCountFormatter.string(fromByteCount:Int64(afterBytes),countStyle:.file) + (wordCreated ? "；含 Word 样稿" : "") + "；章节文件 \(chapterFiles) 份。原件保持不变。" }
}
