import AppKit
import PDFKit
import UniformTypeIdentifiers

/// A small local document, handled directly by KongFolio when opened from Finder or the Dock.
struct ReadingShortcut: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable { case resume, fixed
        var title: String { self == .resume ? "继续上次阅读" : "固定到当前页" }
    }
    static let fileExtension = "kongfoliolink"
    static let fileType = UTType(exportedAs: "com.kongfolio.reading-shortcut", conformingTo: .data)
    var version = 1
    var path: String
    var title: String
    var mode = Mode.resume
    var position: ViewPosition
    var layout: ReadingLayout? = nil
    var bookmark: Data? = nil

    func validate() throws {
        guard version == 1, path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 32768,
              title.utf8.count <= 32768, position.selection >= 0,
              (position.x == nil) == (position.y == nil),
              position.x.map({ $0.isFinite }) ?? true, position.y.map({ $0.isFinite }) ?? true,
              position.scale.map({ $0.isFinite && $0 > 0 && $0 <= 64 }) ?? true,
              (bookmark?.count ?? 0) <= 1_000_000,
              URL(fileURLWithPath: path).pathExtension.lowercased() != Self.fileExtension else {
            throw FolioError(message: "阅读快捷方式无效或版本不受支持")
        }
    }
    static func handles(_ url: URL) -> Bool {
        (url.isFileURL && url.pathExtension.lowercased() == fileExtension) || (url.scheme == "kongfolio" && url.host == "reading")
    }
    func link() throws -> URL {
        try validate()
        var portable = self; portable.bookmark = nil
        var value = URLComponents(); value.scheme = "kongfolio"; value.host = "reading"
        value.queryItems = [URLQueryItem(name: "ref", value: try JSONEncoder().encode(portable).base64EncodedString())]
        return try value.url.unwrap("无法创建阅读链接")
    }
    static func read(_ url: URL) throws -> ReadingShortcut {
        let data: Data
        if url.isFileURL {
            guard url.pathExtension.lowercased() == fileExtension,
                  let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2_000_000 else {
                throw FolioError(message: "阅读快捷方式文件过大或类型不正确")
            }
            data = try Data(contentsOf: url)
        } else {
            guard handles(url), let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let encoded = components.queryItems?.first(where: { $0.name == "ref" })?.value,
                  encoded.count <= 200000, let bytes = Data(base64Encoded: encoded) else {
                throw FolioError(message: "阅读链接无法读取")
            }
            data = bytes
        }
        let shortcut = try JSONDecoder().decode(Self.self, from: data); try shortcut.validate(); return shortcut
    }
    func resolvedURL() throws -> URL {
        try validate()
        if let bookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale),
               resolved.isFileURL, FileManager.default.fileExists(atPath: resolved.path) { return resolved }
        }
        let original = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { throw FolioError(message: "找不到这本书：\(path)。请确认原文件仍在本机，或重新打开书籍后保存快捷方式。") }
        return original
    }
    func write(to url: URL) throws {
        try validate()
        guard url.isFileURL, url.pathExtension.lowercased() == Self.fileExtension,
              !DocumentTaskOutput.sameFile(url, URL(fileURLWithPath: path)) else { throw FolioError(message: "请保存为独立的阅读快捷方式文件") }
        let data = try JSONEncoder().encode(self), expected = try FileBaseline.capture(url)
        try DocumentTaskOutput.write(to: url, expected: expected) { try data.write(to: $0) }
    }
    func destination(progress: ReadingProgress, pageCount: Int) -> ViewPosition {
        let chosen = mode == .resume ? progress.resumePosition(pageCount: pageCount) ?? position : position
        return ViewPosition(selection: min(max(0, chosen.selection), max(0, pageCount - 1)), x: chosen.x, y: chosen.y, scale: chosen.scale)
    }
}

extension Workspace {
    var canCreateReadingShortcut: Bool { count > 0 && !busy && progressPath != nil }
    func makeReadingShortcut(mode: ReadingShortcut.Mode) throws -> ReadingShortcut {
        guard canCreateReadingShortcut, let path = progressPath else { throw FolioError(message: "请先保存或打开这本书，再创建阅读快捷方式") }
        saveReadingRecord()
        let file = URL(fileURLWithPath: path)
        let bookmark = readingProgress.bookmark ?? (try? file.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil))
        let result = ReadingShortcut(path: path, title: displayName, mode: mode, position: currentViewPosition(), layout: readingLayout, bookmark: bookmark)
        try result.validate(); return result
    }
    func copyReadingLink(mode: ReadingShortcut.Mode) throws {
        let url = try makeReadingShortcut(mode: mode).link()
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string)
        NSPasteboard.general.setString(url.absoluteString, forType: .URL)
        status = "已拷贝阅读链接：" + mode.title
    }
    @discardableResult func saveReadingShortcut(mode: ReadingShortcut.Mode) throws -> URL? {
        let shortcut = try makeReadingShortcut(mode: mode), panel = NSSavePanel()
        panel.allowedContentTypes = [ReadingShortcut.fileType]; panel.canCreateDirectories = true
        let title = URL(fileURLWithPath: shortcut.title).deletingPathExtension().lastPathComponent.replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = title + (mode == .resume ? "-继续阅读" : "-第\(shortcut.position.selection + 1)页") + "." + ReadingShortcut.fileExtension
        panel.message = "保存后将快捷方式拖到 Dock 右侧分隔线后，点击即可用 KongFolio 打开。"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try shortcut.write(to: url)
        status = "阅读快捷方式已保存，可拖到 Dock 右侧：" + url.lastPathComponent
        return url
    }
}

extension WorkspaceStore {
    @discardableResult func openReadingShortcut(_ shortcut: ReadingShortcut) throws -> Workspace {
        if tabs.isEmpty { bootstrap() }
        let url = try shortcut.resolvedURL(), path = url.path
        let existing = tabs.compactMap(\.workspace).first { $0.matches(path: path) }
        guard existing?.busy != true else { throw FolioError(message: "这本书正在处理任务，请完成后再打开快捷方式") }
        existing?.saveReadingRecord()
        var progress = ReadingProgress.load(path: path, defaults: readingDefaults)
        if progress.date == nil, path != shortcut.path {
            progress = ReadingProgress.load(path: shortcut.path, defaults: readingDefaults)
            if progress.date != nil || !progress.visited.isEmpty { progress.save(path: path, defaults: readingDefaults) }
        }
        let target: Workspace
        if let existing { target = existing }
        else if let empty = activeWorkspace, empty.count == 0, !empty.needsLoad, !empty.busy { target = empty }
        else { target = addWorkspace() }
        let position = shortcut.destination(progress: progress, pageCount: target.count > 0 ? target.count : max(progress.pages, shortcut.position.selection + 1))
        let layout = shortcut.mode == .resume ? progress.layout ?? shortcut.layout : shortcut.layout
        if target.count > 0 {
            select(target.id)
            if let layout { target.readingLayout = layout }
            target.readingScale = position.scale
            target.go(to: position)
            target.saveReadingRecord(capture: false)
        } else {
            if url.pathExtension.lowercased() == "kongfolio" { target.projectURL = url } else { target.sourceURL = url }
            target.pendingView = position; target.pendingReadingLayout = layout
            select(target.id)
            if !target.busy, target.count == 0 { target.needsLoad = false; target.load([url]) }
        }
        return target
    }
    func openReadingShortcut(_ url: URL) throws { try openReadingShortcut(ReadingShortcut.read(url)) }
}
