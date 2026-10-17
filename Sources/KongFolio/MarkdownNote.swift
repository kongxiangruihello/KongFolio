import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// One text edit expressed as "replace `range` with `replacement`, then select `selection`".
struct TextEdit: Equatable {
    var range: NSRange
    var replacement: String
    var selection: NSRange
}

/// A Markdown file being written in KongFolio. The text lives in memory; unsaved text is also copied to
/// `Notes/<id>.json` in the app's storage folder, so a crash or a forced quit does not lose it.
@MainActor final class MarkdownNote: ObservableObject, Identifiable {
    struct Backup: Codable {
        var id: UUID
        var text: String
        var path: String?
    }

    let id: UUID
    let storage: URL
    @Published var text: String { didSet { if text != oldValue { textChanged() } } }
    @Published var fileURL: URL?
    @Published var dirty = false
    @Published var showPreview = true
    @Published var preview: PDFDocument?
    @Published var error: String?
    @Published var status = ""
    var lastActive = Date()
    weak var textView: NSTextView?
    private var previewTask: Task<Void, Never>?
    private var backupTask: Task<Void, Never>?

    init(id: UUID = UUID(), text: String = "", fileURL: URL? = nil, dirty: Bool = false, storage: URL? = nil) {
        self.id = id
        self.text = text
        self.fileURL = fileURL
        self.dirty = dirty
        self.storage = storage ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("KongFolio", isDirectory: true)
        if !text.isEmpty { refreshPreview() }
    }

    var title: String { fileURL?.deletingPathExtension().lastPathComponent ?? "未命名笔记" }

    /// Characters without whitespace, which is how Chinese text is usually counted.
    var characterCount: Int { text.reduce(0) { $0 + ($1.isWhitespace ? 0 : 1) } }

    static func open(_ url: URL, storage: URL? = nil) throws -> MarkdownNote {
        MarkdownNote(text: TextImport.normalized(try TextImport.decode(Data(contentsOf: url))), fileURL: url, storage: storage)
    }

    // MARK: Saving

    func write(to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        fileURL = url
        dirty = false
        removeBackup()
    }

    @discardableResult func save(asNew: Bool = false) -> Bool {
        var target = fileURL
        if asNew || target == nil {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            panel.nameFieldStringValue = title + ".md"
            guard panel.runModal() == .OK, let chosen = panel.url else { return false }
            target = chosen
        }
        guard let url = target else { return false }
        do {
            try write(to: url)
            status = "已保存"
            return true
        } catch {
            self.error = "保存失败：\(error.localizedDescription)"
            return false
        }
    }

    /// Asks what to do with unsaved text. Returns false when the user cancels or saving fails.
    func confirmClose() -> Bool {
        guard dirty else { removeBackup(); return true }
        let alert = NSAlert()
        alert.messageText = "保存对“\(title)”的修改？"
        alert.informativeText = "不保存会丢弃这些修改。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "不保存")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: removeBackup(); return true
        default: return false
        }
    }

    func exportPDF() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = title + ".pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try TextImport.render(text, markdown: true).dataRepresentation().unwrap("PDF 生成失败")
            try data.write(to: url, options: .atomic)
            status = "已导出 PDF"
        } catch {
            self.error = "导出失败：\(error.localizedDescription)"
        }
    }

    // MARK: Backup of unsaved text

    var backupURL: URL { storage.appendingPathComponent("Notes", isDirectory: true).appendingPathComponent("\(id.uuidString).json") }

    func writeBackup() throws {
        try FileManager.default.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Backup(id: id, text: text, path: fileURL?.path)).write(to: backupURL, options: .atomic)
    }

    func removeBackup() {
        backupTask?.cancel()
        try? FileManager.default.removeItem(at: backupURL)
    }

    private func scheduleBackup() {
        backupTask?.cancel()
        backupTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self, self.dirty else { return }
            do { try self.writeBackup() } catch { self.status = "自动备份失败：\(error.localizedDescription)" }
        }
    }

    /// Notes that were never saved when the app last ended.
    static func restoreBackups(storage: URL) -> [MarkdownNote] {
        let folder = storage.appendingPathComponent("Notes", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { file -> MarkdownNote? in
            guard let backup = try? JSONDecoder().decode(Backup.self, from: Data(contentsOf: file)) else { return nil }
            let note = MarkdownNote(id: backup.id, text: backup.text, fileURL: backup.path.map { URL(fileURLWithPath: $0) }, dirty: true, storage: storage)
            note.status = "已恢复上次未保存的内容"
            return note
        }
    }

    // MARK: Preview

    private func textChanged() {
        dirty = true
        scheduleBackup()
        refreshPreview()
    }

    func refreshPreview() {
        previewTask?.cancel()
        let source = text
        previewTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            let data = await Task.detached(priority: .userInitiated) { () -> Data? in
                guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return try? TextImport.render(source, markdown: true).dataRepresentation()
            }.value
            guard !Task.isCancelled, let self else { return }
            self.preview = data.flatMap { PDFDocument(data: $0) }
        }
    }

    // MARK: Formatting commands

    /// `NSIntersectionRange` leaves the location undefined for empty results, so clamp by hand.
    nonisolated static func clamp(_ range: NSRange, to length: Int) -> NSRange {
        let location = min(max(range.location, 0), length)
        return NSRange(location: location, length: min(max(range.length, 0), length - location))
    }

    /// Wraps the selection (or a placeholder) in `prefix` and `suffix`; the wrapped text stays selected.
    nonisolated static func wrapEdit(in text: String, selection: NSRange, prefix: String, suffix: String, placeholder: String) -> TextEdit {
        let source = text as NSString
        let range = clamp(selection, to: source.length)
        let chosen = range.length == 0 ? placeholder : source.substring(with: range)
        return TextEdit(range: range, replacement: prefix + chosen + suffix,
                        selection: NSRange(location: range.location + (prefix as NSString).length, length: (chosen as NSString).length))
    }

    /// Adds `prefix` to every non-empty line touched by the selection, or removes it when all of them already have it.
    nonisolated static func lineEdit(in text: String, selection: NSRange, prefix: String) -> TextEdit {
        let source = text as NSString
        let range = source.lineRange(for: clamp(selection, to: source.length))
        let block = source.substring(with: range)
        var lines = block.components(separatedBy: "\n")
        var endsWithNewline = false
        if lines.count > 1, lines.last == "" { lines.removeLast(); endsWithNewline = true }
        let content = lines.filter { !$0.isEmpty }
        let remove = !content.isEmpty && content.allSatisfy { $0.hasPrefix(prefix) }
        // Empty lines are skipped unless every touched line is empty (a fresh line should get the prefix).
        let changed = lines.map { line -> String in
            guard content.isEmpty || !line.isEmpty else { return line }
            return remove ? String(line.dropFirst(prefix.count)) : prefix + line
        }
        let replacement = changed.joined(separator: "\n") + (endsWithNewline ? "\n" : "")
        let length = (replacement as NSString).length - (endsWithNewline ? 1 : 0)
        return TextEdit(range: range, replacement: replacement, selection: NSRange(location: range.location, length: max(0, length)))
    }

    func apply(_ edit: TextEdit) {
        guard let view = textView, view.shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        view.textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
        view.didChangeText()
        view.setSelectedRange(edit.selection)
        view.window?.makeFirstResponder(view)
    }

    func wrap(_ prefix: String, _ suffix: String, placeholder: String) {
        guard let view = textView else { return }
        apply(MarkdownNote.wrapEdit(in: view.string, selection: view.selectedRange(), prefix: prefix, suffix: suffix, placeholder: placeholder))
    }

    func prefixLines(_ prefix: String) {
        guard let view = textView else { return }
        apply(MarkdownNote.lineEdit(in: view.string, selection: view.selectedRange(), prefix: prefix))
    }
}
