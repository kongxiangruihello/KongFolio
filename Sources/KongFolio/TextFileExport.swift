import AppKit
import CoreText
import PDFKit
import UniformTypeIdentifiers

/// Exports the editor's current text, including edits that have not yet been saved.
enum TextFileExport {
    static func writeWord(_ text: String, format: TextDocumentFormat, to destination: URL, baseURL: URL? = nil, options: TextLayoutOptions = TextLayoutOptions()) throws {
        try RichTextWord.write(RichTextDocument(text, format: format, baseURL: baseURL, options: options), to: destination)
    }

}

extension MarkdownNote {
    func writePDF(to url: URL) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FolioError(message: "文件内容为空，请先输入内容") }
        let document = try renderDocument()
        try document.dataRepresentation().unwrap("PDF 生成失败").write(to: url, options: .atomic)
    }
    func exportWord() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: "docx") ?? .data]
        panel.nameFieldStringValue = title + ".docx"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try TextFileExport.writeWord(try SourceLink.rebasedText(text, baseURL: fileURL?.deletingLastPathComponent()), format: format, to: url, baseURL: fileURL?.deletingLastPathComponent(), options: layoutOptions); status = "已导出可编辑的 Word 文档" }
        catch { self.error = "Word 导出失败：" + error.localizedDescription }
    }
}
