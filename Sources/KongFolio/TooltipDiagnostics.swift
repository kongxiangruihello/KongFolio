import AppKit
import Foundation

/// Finds out why a hover tooltip does not appear. macOS gives no event for "the tooltip was shown", so this records what
/// has to be true for one to show: the app is active, the window under the pointer is the key window, the view under the
/// pointer (or one above it) has a tooltip, the pointer rests there, and mouse-moved events arrive at all. Each rest of
/// the pointer (about a second) adds one line to ~/Library/Logs/KongFolio-hover.log.
@MainActor final class TooltipDiagnostics {
    static let shared = TooltipDiagnostics()
    static let key = "KongFolio.tooltipDiagnostics"

    private var timer: Timer?
    private var monitor: Any?
    private var movedEvents = 0
    private var lastPoint = NSPoint(x: -1, y: -1)
    private var restTicks = 0
    private var reported = false

    var isOn: Bool { timer != nil }

    static var logURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!.appendingPathComponent("Logs/KongFolio-hover.log")
    }

    func start() {
        guard timer == nil else { return }
        UserDefaults.standard.set(true, forKey: Self.key)
        movedEvents = 0
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            MainActor.assumeIsolated { self?.movedEvents += 1 }
            return event
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        append("—— 诊断开始 ——\n" + environment())
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        UserDefaults.standard.set(false, forKey: Self.key)
        append("—— 诊断结束 ——")
    }

    func toggle() { isOn ? stop() : start() }

    func revealLog() {
        if FileManager.default.fileExists(atPath: Self.logURL.path) { NSWorkspace.shared.activateFileViewerSelecting([Self.logURL]) }
    }

    // MARK: Sampling

    private func tick() {
        let point = NSEvent.mouseLocation
        if abs(point.x - lastPoint.x) < 1, abs(point.y - lastPoint.y) < 1 { restTicks += 1 } else { restTicks = 0; reported = false }
        lastPoint = point
        guard restTicks >= 3, !reported else { return }
        reported = true
        append(report(at: point))
    }

    private func report(at screenPoint: NSPoint) -> String {
        var lines = [Self.stamp() + " 指针静止 \(Int(screenPoint.x)),\(Int(screenPoint.y))；累计收到鼠标移动事件 \(movedEvents) 次"]
        lines.append("  应用处于前台：\(NSApp.isActive ? "是" : "否")")
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.contains(screenPoint) }) else {
            lines.append("  指针下没有本应用的窗口（提示只会出现在本应用窗口内）")
            return lines.joined(separator: "\n")
        }
        lines.append("  窗口：\(window.title.isEmpty ? String(describing: type(of: window)) : window.title)；主窗口 \(window.isMainWindow ? "是" : "否")，键盘焦点窗口 \(window.isKeyWindow ? "是" : "否")，接收移动事件 \(window.acceptsMouseMovedEvents ? "是" : "否")")
        let hit = window.contentView?.superview?.hitTest(window.convertPoint(fromScreen: screenPoint))
        lines.append("  " + Self.describe(chainFrom: hit))
        return lines.joined(separator: "\n")
    }

    /// The view under the pointer and its ancestors, with the first tooltip found on the way up.
    nonisolated static func describe(chainFrom view: NSView?) -> String {
        guard let view else { return "指针下没有视图" }
        var names: [String] = []
        var found: String?
        var cursor: NSView? = view
        while let current = cursor {
            names.append(String(describing: type(of: current)))
            if found == nil, let tip = current.toolTip, !tip.isEmpty { found = "“\(tip)”（在 \(type(of: current))）" }
            cursor = current.superview
        }
        let path = names.prefix(6).joined(separator: " ‹ ")
        return "视图链：\(path)；视图自带提示：\(found ?? "无（也可能由系统按区域登记，无法在此读出）")"
    }

    private func environment() -> String {
        let defaults = UserDefaults.standard
        let delay = defaults.object(forKey: "NSInitialToolTipDelay").map { "\($0)" } ?? "未设置"
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        return "  系统 \(system)；NSInitialToolTipDelay = \(delay) 毫秒；减少动态效果 \(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? "开" : "关")"
    }

    nonisolated private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }

    private func append(_ text: String) {
        let url = Self.logURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = (text.hasPrefix("——") ? Self.stamp() + " " : "") + text + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
