import Foundation

/// Preview pagination uses an immutable text snapshot. Cancellation reaches the rendering loop when typing resumes.
enum TextPreviewRenderer {
    static func render(_ text: String, format: TextDocumentFormat, base: URL?, options: TextLayoutOptions) async throws -> Data? {
        let worker = Task.detached(priority: .utility) { () throws -> Data? in
            try Task.checkCancellation()
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            let rendered = format == .markdown && !EditorFootnotes.list(text).isEmpty ? try EditorFootnotes.rendered(EditorCorrections.export(text,include:true)) : EditorCorrections.export(text,include:true,html:format == .html)
            let document = try RichTextDocument(try SourceLink.rebasedText(rendered, baseURL: base), format: format, baseURL: base, options: options)
            try Task.checkCancellation()
            let pdf = try document.pdf()
            try Task.checkCancellation()
            return try pdf.dataRepresentation().unwrap("PDF 预览生成失败")
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
}
