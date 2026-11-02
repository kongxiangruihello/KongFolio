import AppKit
import PDFKit

struct ReadingExportSnapshot: Codable, Equatable {
    var title: String
    var records: [ReadingRecord] = []
    var essay: ReadingEssay?
    var essays:[ReadingEssay]? = nil
    var order:[String]? = nil
    var options:ReadingExportOptions? = nil
    var allRecords:[ReadingRecord] { records + ([essay].compactMap{$0}+(essays ?? [])).flatMap{$0.blocks.compactMap(\.record)} }
    var digest:String { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return OCRPageCache.digest((try? encoder.encode(self)) ?? Data()) }
}
enum ReadingRecordExport {
    enum Format:String,CaseIterable,Codable { case word = "Word", markdown = "Markdown", pdf = "PDF"; var ext:String { self == .word ? "docx" : (self == .markdown ? "md" : "pdf") } }
    static func rich(_ snapshot:ReadingExportSnapshot, assets:URL,wordFootnotes:Bool = false) throws -> RichTextDocument {
        let preferences = snapshot.options ?? ReadingExportOptions()
        guard preferences.valid else { throw FolioError(message:"导出设置无效，请检查字体、字号和内容选项") }
        let options = preferences.layout
        var document = try RichTextDocument("",format:.plain,options:options)
        var blocks:[RichBlock] = [.paragraph(RichTextDocument.styled(snapshot.title,options:options,heading:1,markdown:false),heading:1)]
        func paragraph(_ text:String,heading:Int = 0) {
            for line in text.components(separatedBy:"\n") where !line.isEmpty { blocks.append(.paragraph(RichTextDocument.styled(line,options:options,heading:heading,markdown:false),heading:heading)) }
        }
        func writingParagraph(_ text:String) throws { guard !text.isEmpty else { return };let rich = try RichTextDocument(text,format:.markdown,options:options);blocks += rich.blocks }
        func record(_ record:ReadingRecord, heading:Bool) throws {
            if heading,preferences.showRecordTitles != false { paragraph(preferences.heading(record),heading:2) }
            for part in preferences.structuralOrder {
                switch part {
                case "quote":
            if preferences.includeQuote && !record.quote.isEmpty { paragraph((preferences.quoteHeading ?? "原文")+"：\n"+record.quote) }
            if preferences.includeQuote, let name = record.imageAsset { blocks.append(.image(try Data(contentsOf:assets.appendingPathComponent(name),options:.mappedIfSafe),alt:preferences.imageHeading ?? "图片摘录")) }
                case "note":
            if preferences.includeNote && !record.note.isEmpty { if record.kind != .note { paragraph((preferences.noteHeading ?? "我的笔记")+"：") };try writingParagraph(record.note) }
                case "sources":
                    if let label = preferences.sourcesHeading,!label.isEmpty,preferences.includeSources { paragraph(label) }
            for citation in preferences.includeSources ? record.citations : [] {
                if preferences.footnotes == true, wordFootnotes {
                    let key = ReadingExportOrdering.citationKey(citation)
                    let marker = NSMutableAttributedString(attributedString:RichTextDocument.styled("[注]",options:options,markdown:false))
                    marker.addAttribute(NSAttributedString.Key("KongFolioFootnote"),value:key,range:NSRange(location:0,length:marker.length));blocks.append(.paragraph(marker,heading:0));continue
                }
                let value = NSMutableAttributedString(attributedString:RichTextDocument.styled(ReadingExportOrdering.citation(citation),options:options,markdown:false))
                if let link = SourceLink.url(citation.source) {
                    let suffix = RichTextDocument.styled("　返回原文",options:options,markdown:false)
                    let start = value.length; value.append(suffix); value.addAttribute(.link,value:link,range:NSRange(location:start,length:suffix.length))
                }
                blocks.append(.paragraph(value,heading:0))
            }
                default:break
                }
            }
            if !record.tags.isEmpty { paragraph("标签："+record.tags.joined(separator:"、")) }
        }
        for item in snapshot.orderedItems {
            switch item {
            case .record(let ref):try record(ref,heading:true)
            case .essay(let essay):
                if snapshot.orderedItems.count != 1 || snapshot.title != essay.title { paragraph(essay.title,heading:2) }
                for block in essay.blocks { try Task.checkCancellation();if let ref = block.record { try record(ref,heading:false) };if preferences.includeNote { try writingParagraph(block.text) } }
            }
        }
        document.blocks = blocks; return document
    }
    private static func literal(_ text:String) -> String {
        var value = text.replacingOccurrences(of:"\\",with:"\\\\")
        for token in ["*","_","[","]","`","#","<",">","|"] { value = value.replacingOccurrences(of:token,with:"\\"+token) }
        return value
    }
    static func markdown(_ snapshot:ReadingExportSnapshot,imageFolder:String) -> String {
        let preferences = snapshot.options ?? ReadingExportOptions()
        var lines = ["# "+literal(snapshot.title),""]
        func record(_ ref:ReadingRecord,heading:Bool) {
            if heading { lines += ["## "+literal(preferences.heading(ref)),""] }
            if preferences.includeQuote && !ref.quote.isEmpty { lines += ref.quote.components(separatedBy:"\n").map { "> "+literal($0) }; lines.append("") }
            if preferences.includeQuote, let image = ref.imageAsset { lines += ["![图片摘录](<"+imageFolder+"/"+image+">)",""] }
            if preferences.includeNote && !ref.note.isEmpty { lines += [(ref.kind == .note ? "" : "我的笔记：\n\n")+ref.note,""] }
            for citation in preferences.includeSources ? ref.citations : [] {
                lines.append(literal(ReadingExportOrdering.citation(citation)))
                if let relative = preferences.sourceLinks?[citation.source.path] { lines.append("[返回原文](<"+relative+"#page="+String(citation.source.page+1)+">)") } else if let url = SourceLink.url(citation.source) { lines.append("[返回原文]("+url.absoluteString+")") }
            }
            if !ref.tags.isEmpty { lines += ["标签："+literal(ref.tags.joined(separator:"、"))] }
            lines.append("")
        }
        for item in snapshot.orderedItems {
            switch item {
            case .record(let ref):record(ref,heading:true)
            case .essay(let essay):if snapshot.orderedItems.count != 1 || snapshot.title != essay.title { lines += ["## "+literal(essay.title),""] };for block in essay.blocks { if let ref = block.record { record(ref,heading:false) };if preferences.includeNote { lines += [block.text,""] } }
            }
        }
        return lines.joined(separator:"\n")
    }
    static func write(_ snapshot:ReadingExportSnapshot,format:Format,assets:URL,to destination:URL,expected:FileBaseline) throws {
        guard (snapshot.options ?? ReadingExportOptions()).valid else { throw FolioError(message:"导出设置无效") }
        let fm = FileManager.default
        let sources = Set(snapshot.allRecords.flatMap { $0.citations.map(\.source.path) }.filter { !$0.isEmpty })
        for source in sources where DocumentTaskOutput.sameFile(URL(fileURLWithPath:source),destination) { throw FolioError(message:"请选择新的导出位置，避免覆盖原书") }
        try DocumentTaskOutput.write(to:destination,expected:expected) { temporary in
            switch format {
            case .word: try word(snapshot,assets:assets,to:temporary)
            case .pdf: guard try rich(snapshot,assets:assets).pdf().write(to:temporary) else { throw FolioError(message:"无法写入 PDF") }
            case .markdown:
                let name = destination.deletingPathExtension().lastPathComponent+"-images"
                let parent = destination.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
                let folder = parent.appendingPathComponent(name).standardizedFileURL.resolvingSymlinksInPath()
                guard folder.path.hasPrefix(parent.path+"/") else { throw FolioError(message:"图片目录指向其他位置，请更换导出位置") }
                for image in (snapshot.options?.includeQuote == false ? Set<String>() : Set(snapshot.allRecords.compactMap(\.imageAsset))) {
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
        let format:ReadingRecordExport.Format = file.pathExtension == "pdf" ? .pdf : (file.pathExtension == "md" ? .markdown : .word)
        try Task.checkCancellation();try ReadingRecordExport.write(snapshot,format:format,assets:assets,to:file,expected:FileBaseline(path:file.standardizedFileURL.path,digest:nil))
    }
    func export(_ snapshot:ReadingExportSnapshot,format:ReadingRecordExport.Format,assets:URL,to file:URL,expected:FileBaseline) throws {
        try Task.checkCancellation(); try ReadingRecordExport.write(snapshot,format:format,assets:assets,to:file,expected:expected)
    }
}
@MainActor final class ReadingExportController: ObservableObject {
    @Published var previewURL:URL?
    @Published var previewDigest = ""
    @Published var previewFormat:ReadingRecordExport.Format?
    private var previewFolder:URL?
    @Published var busy = false
    @Published var message = ""
    private var generation = UUID()
    private var job:Task<Void,Never>?
    func preview(_ snapshot:ReadingExportSnapshot,assets:URL,format:ReadingRecordExport.Format = .word) {
        cancel(); let token = UUID(); generation = token; busy = true; previewURL = nil; previewDigest = ""
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("KongFolio-阅读预览-"+UUID().uuidString)
        job = Task { [weak self] in
            let file = folder.appendingPathComponent("实际预览."+format.ext)
            var adopted = false;defer { if !adopted { try? FileManager.default.removeItem(at:folder) } }
            do {
                try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                try await ReadingExportWorker.shared.preview(snapshot,assets:assets,to:file)
                guard !Task.isCancelled, let self, self.generation == token else { return }
                if let old = self.previewFolder { try? FileManager.default.removeItem(at:old) };self.previewFolder = folder;adopted = true;self.previewURL = file;self.previewFormat = format;self.previewDigest = snapshot.digest;self.busy = false;self.message = "已生成实际 "+format.rawValue+" 文件预览"
            } catch { guard let self, self.generation == token else { return }; self.busy = false; self.message = FolioCancellation.matches(error) ? "已停止旧预览" : error.localizedDescription }
        }
    }
    func export(_ snapshot:ReadingExportSnapshot,format:ReadingRecordExport.Format,assets:URL,to url:URL,expected:FileBaseline) {
        cancel(); let token = UUID(); generation = token; busy = true
        job = Task { [weak self] in
            do {
                try await ReadingExportWorker.shared.export(snapshot,format:format,assets:assets,to:url,expected:expected)
                guard let self, self.generation == token else { return }; self.busy = false; self.message = "已导出 "+url.lastPathComponent+(format == .markdown ? "；请将 Markdown 与配套图片目录一起保存。" : "")
            } catch { guard let self, self.generation == token else { return }; self.busy = false; self.message = FolioCancellation.matches(error) ? "已取消，已有记录保留" : "导出失败："+error.localizedDescription }
        }
    }
    func cancel() { generation = UUID(); job?.cancel(); job = nil; busy = false }
    func close() { cancel();previewURL = nil;previewDigest = "";previewFormat = nil;if let folder = previewFolder { try? FileManager.default.removeItem(at:folder) };previewFolder = nil }
}
