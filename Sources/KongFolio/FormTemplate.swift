import AppKit
import PDFKit

struct FormTemplateField: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable { case text = "输入框", check = "勾选框" }
    var id = UUID()
    var name: String
    var kind: Kind
    var rect: CGRect
}
struct FormTemplate: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var pageSize: CGSize
    var fields: [FormTemplateField] = []
    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80, fields.count <= 200,
              pageSize.width.isFinite, pageSize.height.isFinite, pageSize.width > 0, pageSize.height > 0,
              Set(fields.map(\.id)).count == fields.count,
              Set(fields.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }).count == fields.count,
              fields.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 80 && TableGrid.validRect($0.rect) }) else { throw FolioError(message: "请填写模板名称，字段名称应非空且各不相同；最多 200 个字段") }
    }
    func validate(for page: PDFPage) throws {
        try validate(); let size = Self.displaySize(page)
        guard abs(size.width / size.height - pageSize.width / pageSize.height) < 0.02 else { throw FolioError(message: "当前页宽高比例与模板不同，请重新调整字段位置后保存新模板") }
    }
    static func displaySize(_ page: PDFPage) -> CGSize {
        let size = page.bounds(for: .cropBox).size
        return abs(page.rotation % 180) == 90 ? CGSize(width: size.height, height: size.width) : size
    }
}
enum FormTemplateStore {
    static func folder(_ storage: URL) -> URL { storage.appendingPathComponent("FormTemplates", isDirectory: true) }
    static func save(_ template: FormTemplate, storage: URL) throws {
        try template.validate(); try FileManager.default.createDirectory(at: folder(storage), withIntermediateDirectories: true)
        try JSONEncoder().encode(template).write(to: folder(storage).appendingPathComponent(template.id.uuidString + ".json"), options: .atomic)
    }
    static func list(storage: URL) throws -> [FormTemplate] {
        guard FileManager.default.fileExists(atPath: folder(storage).path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder(storage), includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.map {
            let value = try JSONDecoder().decode(FormTemplate.self, from: Data(contentsOf: $0)); try value.validate(); return value
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
extension Workspace {
    func applyFormTemplate(_ template: FormTemplate, page index: Int, from expectedRevision: UUID) throws {
        try applyTemplate(template, pages: [index], revision: expectedRevision, pageNames: false)
    }
}
