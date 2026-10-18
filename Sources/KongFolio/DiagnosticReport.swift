import AppKit
import Foundation

/// A short text for reporting a problem: what version and system, what was open, and the latest lines of the logs.
enum DiagnosticReport {
    static func tail(of url: URL, lines: Int) -> [String] {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n", omittingEmptySubsequences: true).suffix(lines)).map(String.init)
    }

    static func text(version: String, build: String, system: String, facts: [String], perf: [String], hover: [String]) -> String {
        var out = "KongFolio \(version)（build \(build)）\n系统：\(system)\n"
        for fact in facts { out += fact + "\n" }
        out += "\n— 性能日志（最近）—\n" + (perf.isEmpty ? "（没有）" : perf.joined(separator: "\n"))
        out += "\n\n— 悬停诊断（最近）—\n" + (hover.isEmpty ? "（没有）" : hover.joined(separator: "\n")) + "\n"
        return out
    }
}

extension Workspace {
    /// Puts the report on the pasteboard.
    func copyDiagnostics() {
        let info = Bundle.main.infoDictionary ?? [:]
        let facts = [
            "文档：\(count) 页；\(displayName)",
            "已识别记录的页：\(ocrRegions.count)；目录条目：\(outlineEntries.count)",
            "未保存的修改：\(dirty ? "有" : "无")；隐藏的标注类型：\(hiddenKinds.isEmpty ? "无" : hiddenKinds.sorted().joined(separator: "、"))",
        ]
        let text = DiagnosticReport.text(
            version: info["CFBundleShortVersionString"] as? String ?? "?", build: info["CFBundleVersion"] as? String ?? "?",
            system: ProcessInfo.processInfo.operatingSystemVersionString, facts: facts,
            perf: DiagnosticReport.tail(of: PerfLog.url, lines: 12), hover: DiagnosticReport.tail(of: TooltipDiagnostics.logURL, lines: 12))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        status = "已复制诊断信息，可直接粘贴给我"
    }
}
