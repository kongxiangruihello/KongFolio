import Foundation
import PDFKit
import UniformTypeIdentifiers

enum ExportReviewKind: String { case pdf = "PDF", word = "Word" }
struct ExportReviewIssue: Identifiable, Equatable {
    enum Severity: String { case blocking = "需要处理", warning = "请留意" }
    enum Target: String { case page, table, word, text }
    var severity: Severity
    var message: String
    var target: Target = .page
    var page: Int? = nil
    var range: NSRange? = nil
    var tableID: UUID? = nil
    var id: String {
        let pageKey = String(page ?? -1)
        let rangeKey = String(range?.location ?? -1)
        let tableKey = tableID?.uuidString ?? ""
        return [severity.rawValue, target.rawValue, pageKey, rangeKey, tableKey, message].joined(separator: "|")
    }
}
enum ExportPreflight {
    static func fingerprint<T: Encodable>(_ value: T) throws -> String { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return OCRPageCache.digest(try encoder.encode(value)) }
    static func pdf(_ data: Data, pages: [Int], kind: ExportReviewKind, options: WordExportOptions? = nil, regions: [Int: [RecognizedLine]] = [:], baseline: FileBaseline? = nil) -> [ExportReviewIssue] {
        guard let document = PDFDocument(data: data), !pages.isEmpty, Set(pages).count == pages.count, pages.allSatisfy({ (0..<document.pageCount).contains($0) }) else { return [ExportReviewIssue(severity: .blocking, message: "导出页码为空、重复或超出文档范围")] }
        var issues: [ExportReviewIssue] = []
        if let baseline { do { try baseline.verify(URL(fileURLWithPath: baseline.path)) } catch { issues.append(ExportReviewIssue(severity: .blocking, message: "原文件已变化或移走，请先另存当前修改，或核对原件后重新打开")) } }
        guard kind == .word, let options else { return issues }
        let digest = OCRPageCache.digest(data), tables = options.content == .imagesOnly || options.includeTables == false ? [] : (options.tables ?? [])
        for table in tables where table.regions.contains(where: { pages.contains($0.page) }) {
            if table.sourceDigest != digest { issues.append(ExportReviewIssue(severity: .blocking, message: "表格草稿对应的原文已变化", target: .table, page: table.page, tableID: table.id)) }
            if !table.regions.allSatisfy({ pages.contains($0.page) }) { issues.append(ExportReviewIssue(severity: .blocking, message: "页码范围仅包含跨页表格的一部分", target: .table, page: table.page, tableID: table.id)) }
            for region in table.regions where options.editedText?[region.page] != nil { issues.append(ExportReviewIssue(severity: .blocking, message: "已有整页文字草稿与插表范围冲突，请保留文字后重新核对", target: .word, page: region.page)) }
        }
        if options.content != .imagesOnly {
            for index in pages {
                if document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
                   !tables.contains(where: { $0.regions.contains(where: { $0.page == index }) && !$0.rows.isEmpty }) {
                    issues.append(ExportReviewIssue(severity: options.content == .textOnly ? .blocking : .warning, message: "第 \(index+1) 页没有文字层，可先 OCR；图片模式仍可保留页面外观", page: index))
                }
            }
            if !issues.contains(where: { $0.severity == .blocking }) {
                do { _ = try WordCleanup.inspect(document, pages: pages, options: options, regions: regions, sourceDigest: digest) }
                catch {
                    let message = error.localizedDescription
                    let regex = try? NSRegularExpression(pattern: "第\\s*(\\d+)\\s*页")
                    let match = regex?.firstMatch(in: message, range: NSRange(location:0,length:(message as NSString).length))
                    let page = match.flatMap { Int((message as NSString).substring(with:$0.range(at:1))) }.map { $0-1 }
                    issues.append(ExportReviewIssue(severity: .blocking, message: message, target: .word, page: page ?? pages.first))
                }
            }
        }
        return issues
    }
    static func text(_ text: String, format: TextDocumentFormat, baseURL: URL?, options: TextLayoutOptions) -> [ExportReviewIssue] {
        var issues: [ExportReviewIssue] = []
        if text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { issues.append(ExportReviewIssue(severity:.blocking,message:"文件内容为空",target:.text,range:NSRange(location:0,length:0))) }
        for image in TextAssets.references(text,format:format) {
            // Code examples are not rendered as images by the Markdown renderer.
            if format == .markdown {
                let prefix = (text as NSString).substring(to:image.range.location)
                let fences = prefix.components(separatedBy:"\n").filter { $0.trimmingCharacters(in:.whitespaces).hasPrefix("```") }.count
                if fences % 2 == 1 { continue }
            }
            do { _ = try TextMedia.read(image.reference,baseURL:baseURL) }
            catch { issues.append(ExportReviewIssue(severity:.blocking,message:"图片无法载入：" + image.reference + "（" + error.localizedDescription + "）",target:.text,range:image.range)) }
        }
        if !options.valid { issues.append(ExportReviewIssue(severity:.blocking,message:"页面尺寸、边距或字体设置无效",target:.text)) }
        if issues.isEmpty { do { _ = try RichTextDocument(text,format:format,baseURL:baseURL,options:options) } catch { issues.append(ExportReviewIssue(severity:.blocking,message:error.localizedDescription,target:.text)) } }
        return issues
    }
}
@MainActor struct ExportReviewRequest: Identifiable {
    var id = UUID()
    var title: String
    var summary: String
    var inspect: @Sendable () throws -> [ExportReviewIssue]
    var isCurrent: () -> Bool
    var proceed: () -> Void
    var locate: (ExportReviewIssue) -> Void
}
extension WorkspaceStore {
    func presentExportReview(_ request: ExportReviewRequest) {
        activeWorkspace?.showWordExport = false; activeWorkspace?.showExport = false; activeWorkspace?.showTableExtraction = false
        DispatchQueue.main.asyncAfter(deadline:.now()+0.25) { self.exportReview = request }
    }
    func locateExportIssue(_ issue: ExportReviewIssue, workspace: Workspace) {
        select(workspace.id)
        workspace.showTableExtraction=false; workspace.showWordExport=false
        if let page = issue.page, (0..<workspace.count).contains(page) { workspace.selectPage(page) }
        if issue.target == .table { if let id=issue.tableID { workspace.pendingTableDraftID=id }; workspace.showTableExtraction=true }
        if issue.target == .word { workspace.pendingWordPreviewPage=issue.page;workspace.showWordExport=true }
    }
}
extension Workspace {
    func reviewExport(_ kind: ExportReviewKind, proceed: @escaping () -> Void) throws {
        let data = try pdfData(), pages = kind == .word ? (wordScope == .all ? Array(0..<count) : effectivePages) : exportPages
        var options = kind == .word ? try wordOptionsWithTables(allowUnregenerated: true) : wordOptions; options.replacements = applyReplacements ? ReplacementRules.parse(replacementText) : []
        let optionsCopy = options, baseline = fileBaseline
        var initialIssues: [ExportReviewIssue] = []
        if kind == .word, options.content != .imagesOnly {
            if options.hasDraft, options.editedFromRevision != revision { initialIssues.append(ExportReviewIssue(severity:.blocking,message:"原文已变化，Word 修改草稿保留，请拷贝核对后清除旧稿",target:.word,page:options.draftPages.sorted().first)) }
            if options.includeTables != false { for draft in tableDrafts where draft.includeInWord && draft.needsRegeneration { initialIssues.append(ExportReviewIssue(severity:.blocking,message:"表格分隔线已变化，请重新生成并核对",target:.table,page:draft.page,tableID:draft.id)) } }
        }
        let initial = initialIssues
        let regions = Dictionary(uniqueKeysWithValues: pages.compactMap { i in meta(i).ocrRegions.map { (i,$0) } })
        let signature = try exportReviewSignature(kind), version = revision
        guard let store else { throw FolioError(message:"导出检查不可用") }
        let summary = kind == .word ? "\(pages.count) 页 · \(options.content.rawValue) · \(options.tables?.count ?? 0) 份表格" : "\(pages.count) 页 · \(exportOptions.format.rawValue)"
        store.presentExportReview(ExportReviewRequest(title:"导出检查 · " + kind.rawValue,summary:summary,inspect:{ initial + ExportPreflight.pdf(data,pages:pages,kind:kind,options:optionsCopy,regions:regions,baseline:baseline) },isCurrent:{ [weak self] in self?.revision == version && (try? self?.exportReviewSignature(kind)) == signature },proceed:proceed,locate:{ [weak store,weak self] issue in if let self { store?.locateExportIssue(issue,workspace:self) } }))
    }
    func exportReviewSignature(_ kind: ExportReviewKind) throws -> String {
        var options = kind == .word ? try wordOptionsWithTables(allowUnregenerated: true) : wordOptions; options.replacements = applyReplacements ? ReplacementRules.parse(replacementText) : []
        return revision.uuidString + (kind == .word ? try ExportPreflight.fingerprint(options) + String(describing:wordScope) + String(describing:effectivePages) : try ExportPreflight.fingerprint(exportOptions) + String(describing:exportPages))
    }
}
extension MarkdownNote {
    func reviewExport(_ kind: ExportReviewKind, proceed: @escaping () -> Void) throws {
        guard let store else { throw FolioError(message:"导出检查不可用") }
        let content=text,kindOfText=format,base=fileURL?.deletingLastPathComponent() ?? recoveryBaseURL,options=layoutOptions,signature=try exportReviewSignature()
        store.presentExportReview(ExportReviewRequest(title:"导出检查 · " + kind.rawValue,summary:"\(characterCount) 字 · \(TextAssets.references(content,format:kindOfText).count) 张图片引用",inspect:{ ExportPreflight.text(content,format:kindOfText,baseURL:base,options:options) },isCurrent:{ [weak self] in (try? self?.exportReviewSignature()) == signature },proceed:proceed,locate:{ [weak self, weak store] issue in guard let self else { return };store?.select(self.id);if let range=issue.range { self.revealSearch(range) } }))
    }
    func exportReviewSignature() throws -> String { OCRPageCache.digest(Data((text+format.rawValue+(fileURL?.absoluteString ?? recoveryBaseURL?.absoluteString ?? "")).utf8)) + (try ExportPreflight.fingerprint(layoutOptions)) }
}

extension ExportPreflight {
    static func table(_ draft: TableDraftRecord, currentDigest: String) -> [ExportReviewIssue] {
        do { try draft.validate() } catch { return [ExportReviewIssue(severity:.blocking,message:error.localizedDescription,target:.table,page:draft.page)] }
        if draft.needsRegeneration { return [ExportReviewIssue(severity:.blocking,message:"分隔线已变化，请先重新生成并核对单元格",target:.table,page:draft.page)] }
        if draft.sourceDigest != currentDigest { return [ExportReviewIssue(severity:.warning,message:"原文已变化，本次仅导出保留的表格草稿，请核对内容",target:.table,page:draft.page)] }
        return []
    }
}
extension Workspace {
    func reviewTableExport(_ draft: TableDraftRecord, suffix: String) throws {
        guard let store else { throw FolioError(message:"后台任务不可用") }
        let source=try pdfData(), file=TableDraftStore.url(draft.id,storage:storage)
        let summary="\(draft.rows.count) 行 × \(draft.columns) 列 · \(draft.spans?.count ?? 0) 个合并单元格 · " + suffix.uppercased()
        store.presentExportReview(ExportReviewRequest(title:"导出检查 · 表格",summary:summary,inspect:{
            var issues=ExportPreflight.table(draft,currentDigest:OCRPageCache.digest(source))
            if ["md","csv"].contains(suffix), !(draft.spans ?? []).isEmpty { issues.append(ExportReviewIssue(severity:.warning,message:"Markdown / CSV 不保留合并结构，文字保留在各合并区域的首格；需要结构请导出 Word 或 Excel",target:.table,page:draft.page)) }
            if suffix == "xlsx" { for r in draft.rows.indices { for c in draft.rows[r].indices where draft.rows[r][c].utf16.count > 32767 { issues.append(ExportReviewIssue(severity:.blocking,message:"Excel 单元格 \(TableStructure.reference(r,c)) 超过 32767 字符，请拆分内容",target:.table,page:draft.page,tableID:draft.id)) } } }
            return issues
        },isCurrent:{ (try? TableDraftStore.read(file)) == draft },proceed:{ [weak self] in self?.performTableExport(draft,suffix:suffix,source:source) },locate:{ [weak self,weak store] issue in if let self { self.pendingTableDraftID=draft.id;store?.locateExportIssue(issue,workspace:self) } }))
    }
    private func performTableExport(_ draft: TableDraftRecord, suffix: String, source: Data) {
        guard let destination=saveURL(type:UTType(filenameExtension:suffix) ?? .data,suffix:suffix,name:title+"-表格"),let queue=store?.documentTasks else { return }
        do {
            var spec=PersistentDocumentTask(kind:.table,destination:destination,expected:try FileBaseline.capture(destination));spec.draft=draft;spec.suffix=suffix;spec.protectedSource=historySource
            try queue.startPersistent("导出表格 · \(displayName)",source:source,spec:spec)
        } catch { self.error=error.localizedDescription }
    }
}
