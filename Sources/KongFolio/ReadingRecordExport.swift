import AppKit
import PDFKit

struct ReadingExportSnapshot: Codable, Equatable {
    var title: String
    var records: [ReadingRecord] = []
    var essay: ReadingEssay?
    var allRecords:[ReadingRecord] { records + (essay?.blocks.compactMap(\.record) ?? []) }
    var digest:String { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return OCRPageCache.digest((try? encoder.encode(self)) ?? Data()) }
}
enum ReadingRecordExport {
    enum Format:String,CaseIterable { case word = "Word", markdown = "Markdown", pdf = "PDF"; var ext:String { self == .word ? "docx" : (self == .markdown ? "md" : "pdf") } }
    static func rich(_ snapshot:ReadingExportSnapshot, assets:URL) throws -> RichTextDocument {
        var document = try RichTextDocument("",format:.plain)
        let options = document.options
        var blocks:[RichBlock] = [.paragraph(RichTextDocument.styled(snapshot.title,options:options,heading:1,markdown:false),heading:1)]
        func paragraph(_ text:String,heading:Int = 0) {
            for line in text.components(separatedBy:"\n") where !line.isEmpty { blocks.append(.paragraph(RichTextDocument.styled(line,options:options,heading:heading,markdown:false),heading:heading)) }
        }
        func record(_ record:ReadingRecord, heading:Bool) throws {
            if heading { paragraph(record.displayTitle,heading:2) }
            if !record.quote.isEmpty { paragraph("原文：\n"+record.quote) }
            if let name = record.imageAsset { blocks.append(.image(try Data(contentsOf:assets.appendingPathComponent(name),options:.mappedIfSafe),alt:"图片摘录")) }
            if !record.note.isEmpty { paragraph((record.kind == .note ? "" : "我的笔记：\n")+record.note) }
            for citation in record.citations {
                let value = NSMutableAttributedString(attributedString:RichTextDocument.styled(citation.display,options:options,markdown:false))
                if let link = SourceLink.url(citation.source) {
                    let suffix = RichTextDocument.styled("　返回原文",options:options,markdown:false)
                    let start = value.length; value.append(suffix); value.addAttribute(.link,value:link,range:NSRange(location:start,length:suffix.length))
                }
                blocks.append(.paragraph(value,heading:0))
            }
            if !record.tags.isEmpty { paragraph("标签："+record.tags.joined(separator:"、")) }
        }
        if let essay = snapshot.essay {
            for block in essay.blocks { try Task.checkCancellation(); if let ref = block.record { try record(ref,heading:false) }; paragraph(block.text) }
        } else { for ref in snapshot.records { try Task.checkCancellation(); try record(ref,heading:true) } }
        document.blocks = blocks; return document
    }
    private static func literal(_ text:String) -> String {
        var value = text.replacingOccurrences(of:"\\",with:"\\\\")
        for token in ["*","_","[","]","`","#","<",">","|"] { value = value.replacingOccurrences(of:token,with:"\\"+token) }
        return value
    }
    static func markdown(_ snapshot:ReadingExportSnapshot,imageFolder:String) -> String {
        var lines = ["# "+literal(snapshot.title),""]
        func record(_ ref:ReadingRecord,heading:Bool) {
            if heading { lines += ["## "+literal(ref.displayTitle),""] }
            if !ref.quote.isEmpty { lines += ref.quote.components(separatedBy:"\n").map { "> "+literal($0) }; lines.append("") }
            if let image = ref.imageAsset { lines += ["![图片摘录](<"+imageFolder+"/"+image+">)",""] }
            if !ref.note.isEmpty { lines += [(ref.kind == .note ? "" : "我的笔记：\n\n")+literal(ref.note),""] }
            for citation in ref.citations {
                lines.append(literal(citation.display))
                if let url = SourceLink.url(citation.source) { lines.append("[返回原文]("+url.absoluteString+")") }
            }
            if !ref.tags.isEmpty { lines += ["标签："+literal(ref.tags.joined(separator:"、"))] }
            lines.append("")
        }
        if let essay = snapshot.essay { for block in essay.blocks { if let ref = block.record { record(ref,heading:false) }; lines += [literal(block.text),""] } }
        else { for ref in snapshot.records { record(ref,heading:true) } }
        return lines.joined(separator:"\n")
    }
    static func write(_ snapshot:ReadingExportSnapshot,format:Format,assets:URL,to destination:URL,expected:FileBaseline) throws {
        let fm = FileManager.default
        let sources = Set(snapshot.allRecords.flatMap { $0.citations.map(\.source.path) }.filter { !$0.isEmpty })
        for source in sources where DocumentTaskOutput.sameFile(URL(fileURLWithPath:source),destination) { throw FolioError(message:"请选择新的导出位置，避免覆盖原书") }
        try DocumentTaskOutput.write(to:destination,expected:expected) { temporary in
            switch format {
            case .word: try RichTextWord.write(rich(snapshot,assets:assets),to:temporary)
            case .pdf: guard try rich(snapshot,assets:assets).pdf().write(to:temporary) else { throw FolioError(message:"无法写入 PDF") }
            case .markdown:
                let name = destination.deletingPathExtension().lastPathComponent+"-images"
                let parent = destination.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
                let folder = parent.appendingPathComponent(name).standardizedFileURL.resolvingSymlinksInPath()
                guard folder.path.hasPrefix(parent.path+"/") else { throw FolioError(message:"图片目录指向其他位置，请更换导出位置") }
                for image in Set(snapshot.allRecords.compactMap(\.imageAsset)) {
                    try Task.checkCancellation()
                    let bytes = try Data(contentsOf:assets.appendingPathComponent(image)); try fm.createDirectory(at:folder,withIntermediateDirectories:true)
                    let out = folder.appendingPathComponent(image)
                    if fm.fileExists(atPath:out.path) { guard try Data(contentsOf:out) == bytes else { throw FolioError(message:"同名图片内容不同，请更换导出位置") } }
                    else { try bytes.write(to:out,options:.atomic) }
                }
                try markdown(snapshot,imageFolder:name).write(to:temporary,atomically:true,encoding:.utf8)
            }
        }
    }
}
actor ReadingExportWorker {
    static let shared = ReadingExportWorker()
    func preview(_ snapshot:ReadingExportSnapshot,assets:URL,to file:URL) throws {
        try Task.checkCancellation(); try RichTextWord.write(ReadingRecordExport.rich(snapshot,assets:assets),to:file)
    }
    func export(_ snapshot:ReadingExportSnapshot,format:ReadingRecordExport.Format,assets:URL,to file:URL,expected:FileBaseline) throws {
        try Task.checkCancellation(); try ReadingRecordExport.write(snapshot,format:format,assets:assets,to:file,expected:expected)
    }
}
@MainActor final class ReadingExportController: ObservableObject {
    @Published var previewURL:URL?
    @Published var previewDigest = ""
    @Published var busy = false
    @Published var message = ""
    private var generation = UUID()
    private var job:Task<Void,Never>?
    func preview(_ snapshot:ReadingExportSnapshot,assets:URL) {
        cancel(); let token = UUID(); generation = token; busy = true; previewURL = nil; previewDigest = ""
        job = Task { [weak self] in
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("KongFolio-阅读预览-"+UUID().uuidString+".docx")
            do {
                try await ReadingExportWorker.shared.preview(snapshot,assets:assets,to:file)
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.previewURL = file; self.previewDigest = snapshot.digest; self.busy = false; self.message = "已生成实际 Word 文件预览"
            } catch { guard let self, self.generation == token else { return }; self.busy = false; self.message = FolioCancellation.matches(error) ? "已停止旧预览" : error.localizedDescription }
        }
    }
    func export(_ snapshot:ReadingExportSnapshot,format:ReadingRecordExport.Format,assets:URL,to url:URL,expected:FileBaseline) {
        cancel(); let token = UUID(); generation = token; busy = true
        job = Task { [weak self] in
            do {
                try await ReadingExportWorker.shared.export(snapshot,format:format,assets:assets,to:url,expected:expected)
                guard let self, self.generation == token else { return }; self.busy = false; self.message = "已导出 "+url.lastPathComponent+"；请将 Markdown 与配套图片目录一起保存。"
            } catch { guard let self, self.generation == token else { return }; self.busy = false; self.message = FolioCancellation.matches(error) ? "已取消，已有记录保留" : "导出失败："+error.localizedDescription }
        }
    }
    func cancel() { generation = UUID(); job?.cancel(); job = nil; busy = false }
}
