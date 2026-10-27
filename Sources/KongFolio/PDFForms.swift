import SwiftUI
import PDFKit

struct PDFFormField: Identifiable {
    var page: Int
    var index: Int
    var name: String
    var kind: String
    var value: String
    var choices: [String]
    var exports: [String]
    var readOnly: Bool
    var maximumLength: Int
    var password: Bool
    var id: String { "\(page):\(index)" }
}

enum PDFForms {
    static func fields(_ document: PDFDocument) -> [PDFFormField] {
        (0..<document.pageCount).flatMap { p -> [PDFFormField] in
            (document.page(at: p)?.annotations ?? []).enumerated().compactMap { i, a in
                guard a.type == "Widget" else { return nil }
                let kind: String
                if a.widgetFieldType == .text { kind = "文字" }
                else if a.widgetFieldType == .choice {
                    let flags = (a.value(forAnnotationKey: .widgetFieldFlags) as? NSNumber)?.intValue ?? 0
                    kind = flags & (1 << 21) == 0 ? "选项" : "不支持"
                }
                else if a.widgetFieldType == .button, a.widgetControlType == .checkBoxControl { kind = "勾选" }
                else if a.widgetFieldType == .button, a.widgetControlType == .radioButtonControl { kind = "单选" }
                else { kind = "不支持" }
                var value = ["勾选", "单选"].contains(kind) ? (a.buttonWidgetState == .onState ? "1" : "0") : (a.widgetStringValue ?? "")
                if kind == "选项", let index = a.choices?.firstIndex(of: value), let exports = a.values, exports.indices.contains(index) { value = exports[index] }
                return PDFFormField(page: p, index: i, name: a.fieldName ?? "未命名字段 \(i + 1)", kind: kind, value: value, choices: a.choices ?? [], exports: a.values ?? a.choices ?? [], readOnly: a.isReadOnly || kind == "不支持", maximumLength: a.maximumLength, password: a.isPasswordField)
            }
        }
    }
    static func validate(_ fields: [PDFFormField], values: [String: String]) throws {
        for f in fields {
            guard let value = values[f.id], value != f.value else { continue }
            guard !f.readOnly else { throw FolioError(message: "字段“\(f.name)”不可修改") }
            if f.maximumLength > 0, value.utf16.count > f.maximumLength { throw FolioError(message: "字段“\(f.name)”最多填写 \(f.maximumLength) 个字符") }
            if f.kind == "选项", !value.isEmpty, !f.exports.contains(value), !f.choices.contains(value) { throw FolioError(message: "字段“\(f.name)”请选择已有选项") }
            if ["勾选", "单选"].contains(f.kind), !["0", "1"].contains(value) { throw FolioError(message: "勾选值无效") }
        }
        let changedGroups = Set(fields.filter { $0.kind == "单选" && values[$0.id] != nil && values[$0.id] != $0.value }.map(\.name))
        let radio = fields.filter { changedGroups.contains($0.name) && $0.kind == "单选" && (values[$0.id] ?? $0.value) == "1" }
        guard Dictionary(grouping: radio, by: \.name).values.allSatisfy({ $0.count <= 1 }) else { throw FolioError(message: "同组单选框只能选择一个选项") }
    }
    /// A rendered copy contains no interactive widgets. Never writes back to the source.
    static func flattened(_ document: PDFDocument) throws -> PDFDocument {
        let output = PDFDocument()
        for i in 0..<document.pageCount {
            try Task.checkCancellation()
            let page = try document.page(at: i).unwrap("页面不存在")
            let image = try DocumentServices.render(page, maxDimension: 2400)
            let box = page.bounds(for: .cropBox), rotated = abs(page.rotation % 180) == 90
            let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
            var bounds = CGRect(origin: .zero, size: size)
            let bytes = NSMutableData()
            let consumer = try CGDataConsumer(data: bytes).unwrap("无法创建固定副本")
            let context = try CGContext(consumer: consumer, mediaBox: &bounds, nil).unwrap("无法绘制固定副本")
            context.beginPDFPage(nil); context.draw(image, in: bounds); context.endPDFPage(); context.closePDF()
            let rendered = try PDFDocument(data: bytes as Data).unwrap("固定表单失败")
            let copy = try (rendered.page(at: 0)?.copy() as? PDFPage).unwrap("固定表单失败")
            output.insert(copy, at: output.pageCount)
        }
        return output
    }
}

extension Workspace {
    func applyFormValues(_ values: [String: String], from sourceRevision: UUID) throws {
        guard !busy, revision == sourceRevision else { throw FolioError(message: "文档已变化，请关闭并重新打开表单面板") }
        let fields = PDFForms.fields(document)
        try PDFForms.validate(fields, values: values)
        let changes = fields.filter { values[$0.id] != nil && values[$0.id] != $0.value }
        guard !changes.isEmpty else { return }
        checkpoint()
        for f in changes.sorted(by: { (values[$0.id] ?? "") < (values[$1.id] ?? "") }) {
            guard let annotation = document.page(at: f.page)?.annotations[f.index], let value = values[f.id] else { continue }
            if ["勾选", "单选"].contains(f.kind) { annotation.buttonWidgetState = value == "1" ? .onState : .offState }
            else {
                annotation.widgetStringValue = value
                if annotation.font == nil { annotation.font = .systemFont(ofSize: 12) }
                if annotation.fontColor == nil { annotation.fontColor = .black }
            }
        }
        edited(pages: Set(changes.map(\.page))); pdfView?.needsDisplay = true
        status = "已填写 \(changes.count) 个表单字段"
    }
    func exportFlattenedForm(to destination: URL) throws {
        guard destination.standardizedFileURL != historySource?.standardizedFileURL else { throw FolioError(message: "固定表单副本请另存到其他位置") }
        guard let data = try PDFForms.flattened(document).dataRepresentation() else { throw FolioError(message: "无法生成固定表单副本") }
        try data.write(to: destination, options: .atomic)
    }
}

