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
    var assetNames053:Set<String> { Set(allRecords.flatMap(\.assetNames053)+([essay].compactMap{$0}+(essays ?? [])).flatMap{$0.extras?.assets ?? []}) }
    var citations053:[ReadingCitation] { orderedItems.flatMap { item in switch item {case .record(let r):return ReadingLibraryItem.record(r).citations053;case .essay(let e):return ReadingLibraryItem.essay(e).citations053} } }
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
        let sourceIndex = ReadingSourceIndex(snapshot)
        var citationFormat053=ReadingCitationFormat053()
        func extraContent053(_ extras:ReadingRecordExtras053?) throws {
            guard let extras else { return }
            if preferences.includeQuote {
                for q in extras.quotations ?? [] { paragraph("引用副本："+q.title,heading:3);paragraph(q.text);for asset in Set(q.assets ?? []).sorted() { blocks.append(.image(try Data(contentsOf:assets.appendingPathComponent(asset)),alt:"引用图片副本")) };if let created=q.originalCreated { paragraph("原记录创建："+ReadingRecordMetadata.date(created)) };paragraph("引用时间："+ReadingRecordMetadata.date(q.captured)) }
                for region in extras.regions ?? [] { blocks.append(.image(try Data(contentsOf:assets.appendingPathComponent(region.asset)),alt:"来源区域")) }
            }
            if preferences.includeQuote,preferences.includeRegionImages==true,let name=extras.visualAsset { blocks.append(.image(try Data(contentsOf:assets.appendingPathComponent(name)),alt:"标注快照")) }
        }
        func indexLabel(_ citation:ReadingCitation) -> String {
            sourceIndex.label(citation).map{"["+$0+"] "} ?? ""
        }
        func linkedParagraph(_ text:String,citation:ReadingCitation) {
            let value = NSMutableAttributedString(attributedString:RichTextDocument.styled(text,options:options,markdown:false))
            if let address = ReadingSourceIndex.link(citation,options:preferences), let link = URL(string:address) {
                let suffix = RichTextDocument.styled("　返回原文",options:options,markdown:false)
                let start = value.length
                value.append(suffix)
                value.addAttribute(.link,value:link,range:NSRange(location:start,length:suffix.length))
            }
            blocks.append(.paragraph(value,heading:0))
        }
        func sourceParagraphs(_ citations: [ReadingCitation]) {
            for (index,citation) in citations.enumerated() {
                if preferences.footnotes == true, wordFootnotes {
                    let key = ReadingExportOrdering.citationKey(citation)
                    let marker = NSMutableAttributedString(attributedString:RichTextDocument.styled("\(index+1). [注]",options:options,markdown:false))
                    marker.addAttribute(NSAttributedString.Key("KongFolioFootnote"),value:key,range:NSRange(location:0,length:marker.length))
                    let label = indexLabel(citation)
                    if !label.isEmpty { marker.append(RichTextDocument.styled(" "+label,options:options,markdown:false)) }
                    blocks.append(.paragraph(marker,heading:0))
                    continue
                }
                let formatted = citationFormat053.render(citation,shorten:preferences.shortenedCitations053==true)
                let text = indexLabel(citation)+ReadingExportOrdering.sourceLine(citation,index:index,rendered:formatted)
                linkedParagraph(text,citation:citation)
            }
        }

        func record(_ record:ReadingRecord, heading:Bool) throws {
            if heading,preferences.showRecordTitles != false { paragraph(preferences.heading(record),heading:2) }
            let segmented = record.excerptSegments != nil && preferences.includeQuote
            let displayedSources = Set(segmented ? record.textExcerptSegments.flatMap { $0.citationIndices } : [])
            for part in preferences.structuralOrder {
                switch part {
                case "quote":
                    guard preferences.includeQuote else { break }
                    if let origin = record.pdfOrigin,!origin.contents.isEmpty {
                        if wordFootnotes,preferences.nativeWordComments != false {
                            let anchor = NSMutableAttributedString(attributedString:RichTextDocument.styled("[PDF 评论]",options:options,markdown:false))
                            let comment = ReadingWordComment053(text:origin.contents,author:origin.author ?? "未记录作者",date:origin.originalModified ?? origin.originalCreated)
                            anchor.addAttribute(NSAttributedString.Key("KongFolioComment053"),value:try JSONEncoder().encode(comment),range:NSRange(location:0,length:anchor.length))
                            blocks.append(.paragraph(anchor,heading:0))
                        } else { paragraph("PDF 原评论："+origin.contents) }
                    }
                    if segmented {
                        for (index,segment) in record.textExcerptSegments.enumerated() {
                            paragraph("第 \(index+1) 段 · "+ReadingRecordMetadata.date(segment.captured),heading:3)
                            paragraph(segment.text)
                            if preferences.includeSources { sourceParagraphs(segment.sources(in:record)) }
                        }
                    } else if !record.quote.isEmpty { paragraph((preferences.quoteHeading ?? "原文")+"：\n"+record.quote) }
                    if let name = record.imageAsset {
                        blocks.append(.image(try Data(contentsOf:assets.appendingPathComponent(name),options:.mappedIfSafe),alt:preferences.imageHeading ?? "图片摘录"))
                    }
                case "note":
                    guard preferences.includeNote else { break }
                    if let remark = record.excerptRemark,!remark.isEmpty { paragraph("备注："+remark) }
                    if !record.note.isEmpty {
                        if let heading = preferences.noteHeading { paragraph(heading,heading:3) }
                        else if record.kind != .note { paragraph("我的笔记：") }
                        try writingParagraph(record.note)
                    }
                case "sources":
                    guard preferences.includeSources else { break }
                    let shown = displayedSources.compactMap { record.citations.indices.contains($0) ? record.citations[$0] : nil }
                    let citations = record.citations053.filter { !shown.contains($0) }
                    if citations.isEmpty {
                        if !segmented { paragraph("出处：独立笔记（未关联文献）") }
                        break
                    }
                    paragraph(preferences.sourcesHeading ?? "出处",heading:3)
                    sourceParagraphs(citations)
                default: break
                }
            }
            try extraContent053(record.extras)
            for line in ReadingRecordMetadata.lines(record,includeSources:false) { paragraph(line) }
            if !record.tags.isEmpty { paragraph("标签："+record.tags.joined(separator:"、")) }
        }
        for item in snapshot.orderedItems {
            switch item {
            case .record(let ref):try record(ref,heading:true)
            case .essay(let essay):
                if snapshot.orderedItems.count != 1 || snapshot.title != essay.title { paragraph(essay.title,heading:2) }
                try extraContent053(essay.extras)
                if preferences.includeSources, let extras = essay.extras {
                    let sources = (extras.regions ?? []).map(\.citation)+(extras.quotations ?? []).flatMap(\.citations)
                    if !sources.isEmpty { paragraph(preferences.sourcesHeading ?? "出处",heading:3) }
                    for (index,citation) in sources.enumerated() {
                        linkedParagraph(indexLabel(citation)+ReadingExportOrdering.sourceLine(citation,index:index,rendered:ReadingExportOrdering.citation(citation)),citation:citation)
                    }
                }
                for line in ReadingRecordMetadata.essayLines(essay) { paragraph(line) }
                for block in essay.blocks { try Task.checkCancellation();if let ref = block.record { try record(ref,heading:false) };if preferences.includeNote { try writingParagraph(block.text) } }
            }
        }
        if preferences.bibliography053==true { paragraph("参考文献",heading:1);for line in ReadingWorkflow053.bibliography(snapshot.orderedItems.map { value in switch value {case .record(let r):return ReadingLibraryItem.record(r);case .essay(let e):return ReadingLibraryItem.essay(e)} }) { paragraph(line) } }
        if !sourceIndex.entries.isEmpty {
            paragraph("出处索引",heading:1)
            for entry in sourceIndex.entries { linkedParagraph(entry.label+"　"+entry.detail,citation:entry.citation) }
        }
        document.blocks = blocks; return document
    }
    static func literal(_ text:String) -> String {
        var value = text.replacingOccurrences(of:"\\",with:"\\\\")
        for token in ["*","_","[","]","`","#","<",">","|"] { value = value.replacingOccurrences(of:token,with:"\\"+token) }
        return value
    }
    static func markdown(_ snapshot:ReadingExportSnapshot,imageFolder:String) -> String {
        let preferences = snapshot.options ?? ReadingExportOptions()
        var lines = ["# "+literal(snapshot.title),""]
        let sourceIndex = ReadingSourceIndex(snapshot)
        var citationFormat053=ReadingCitationFormat053()
        func extras053(_ extras:ReadingRecordExtras053?) {
            guard let extras,preferences.includeQuote else { return }
            for q in extras.quotations ?? [] { for asset in Set(q.assets ?? []).sorted() { lines += ["![引用图片副本](<"+imageFolder+"/"+asset+">)",""] };lines += ["### 引用副本："+literal(q.title),"",q.text,""]+["引用时间："+ReadingRecordMetadata.date(q.captured),""] }
            for region in extras.regions ?? [] { lines += ["![来源区域](<"+imageFolder+"/"+region.asset+">)",""] }
            if preferences.includeQuote,preferences.includeRegionImages==true,let name=extras.visualAsset { lines += ["![标注快照](<"+imageFolder+"/"+name+">)",""] }
        }
        func sourceLines(_ citations: [ReadingCitation]) {
            for (index,citation) in citations.enumerated() {
                let rendered = citationFormat053.render(citation,shorten:preferences.shortenedCitations053==true)
                let label = sourceIndex.label(citation).map{"["+$0+"] "} ?? ""
                lines.append(literal(label+ReadingExportOrdering.sourceLine(citation,index:index,rendered:rendered)))
                if citation.source.invalidPage053 != true {
                    if let relative = preferences.sourceLinks?[citation.source.path] {
                        lines.append("[返回原文](<"+relative+"#page="+String(citation.source.page+1)+">)")
                    } else if let url = SourceLink.url(citation.source) { lines.append("[返回原文]("+url.absoluteString+")") }
                }
                lines.append("")
            }
        }

        func record(_ ref:ReadingRecord,heading:Bool) {
            if heading,preferences.showRecordTitles != false { lines += ["## "+literal(preferences.heading(ref)),""] }
            let segmented = ref.excerptSegments != nil && preferences.includeQuote
            for part in preferences.structuralOrder {
                switch part {
                case "quote":
                    guard preferences.includeQuote else { break }
                    if let origin = ref.pdfOrigin,!origin.contents.isEmpty {
                        lines += ["PDF 原评论："+literal(origin.contents),""]
                    }
                    if segmented {
                        for (index,segment) in ref.textExcerptSegments.enumerated() {
                            lines += ["### 第 \(index+1) 段 · "+ReadingRecordMetadata.date(segment.captured),""]
                            lines += segment.text.components(separatedBy:"\n").map { "> "+literal($0) }+[""]
                            if preferences.includeSources { sourceLines(segment.sources(in:ref)) }
                        }
                    } else if !ref.quote.isEmpty {
                        if let heading = preferences.quoteHeading { lines += ["### "+literal(heading),""] }
                        lines += ref.quote.components(separatedBy:"\n").map { "> "+literal($0) }
                        lines.append("")
                    }
                    if let image = ref.imageAsset {
                        lines += ["!["+literal(preferences.imageHeading ?? "图片摘录")+"](<"+imageFolder+"/"+image+">)",""]
                    }
                case "note":
                    guard preferences.includeNote else { break }
                    if let remark = ref.excerptRemark,!remark.isEmpty { lines += ["备注："+literal(remark),""] }
                    if !ref.note.isEmpty {
                        if let heading = preferences.noteHeading { lines += ["### "+literal(heading),""] }
                        else if ref.kind != .note { lines += ["我的笔记：",""] }
                        lines += [ref.note,""]
                    }
                case "sources":
                    guard preferences.includeSources else { break }
                    let shown = segmented ? ref.textExcerptSegments.flatMap { $0.sources(in:ref) } : []
                    let sources = ref.citations053.filter { !shown.contains($0) }
                    if sources.isEmpty {
                        if !segmented { lines += ["出处：独立笔记（未关联文献）",""] }
                        break
                    }
                    lines += ["### "+literal(preferences.sourcesHeading ?? "出处"),""]
                    sourceLines(sources)
                default: break
                }
            }
            extras053(ref.extras)
            lines += ReadingRecordMetadata.lines(ref,includeSources:false).map(literal)
            if !ref.tags.isEmpty { lines += ["标签："+literal(ref.tags.joined(separator:"、"))] }
            lines.append("")
        }
        for item in snapshot.orderedItems {
            switch item {
            case .record(let ref):record(ref,heading:true)
            case .essay(let essay):
                if snapshot.orderedItems.count != 1 || snapshot.title != essay.title { lines += ["## "+literal(essay.title),""] }
                extras053(essay.extras)
                if preferences.includeSources, let extras = essay.extras {
                    let sources = (extras.regions ?? []).map(\.citation)+(extras.quotations ?? []).flatMap(\.citations)
                    if !sources.isEmpty { lines += ["### "+literal(preferences.sourcesHeading ?? "出处"),""] }
                    sourceLines(sources)
                }
                lines += ReadingRecordMetadata.essayLines(essay).map(literal)
                for block in essay.blocks {
                    if let ref = block.record { record(ref,heading:false) }
                    if preferences.includeNote { lines += [block.text,""] }
                }
            }
        }
        if preferences.bibliography053==true { lines += ["## 参考文献",""]+ReadingWorkflow053.bibliography(snapshot.orderedItems.map { value in switch value {case .record(let r):return ReadingLibraryItem.record(r);case .essay(let e):return ReadingLibraryItem.essay(e)} }) }
        if !sourceIndex.entries.isEmpty {
            lines += ["","## 出处索引",""]
            for entry in sourceIndex.entries {
                lines += [literal(entry.label+"　"+entry.detail)]
                if let link = ReadingSourceIndex.link(entry.citation,options:preferences) { lines.append("[返回原文](<"+link+">)") }
                lines.append("")
            }
        }
        return lines.joined(separator:"\n")
    }
    static func write(_ snapshot:ReadingExportSnapshot,format:Format,assets:URL,to destination:URL,expected:FileBaseline) throws {
        guard (snapshot.options ?? ReadingExportOptions()).valid else { throw FolioError(message:"导出设置无效") }
        let prepared=try ReadingSourceImages053.prepare(snapshot,assets:assets)
        defer { if let temp=prepared.temporary { try? FileManager.default.removeItem(at:temp) } }
        let snapshot=prepared.snapshot,assets=prepared.assets
        let fm = FileManager.default
        let sources = Set(snapshot.citations053.map(\.source.path).filter { !$0.isEmpty })
        for source in sources where DocumentTaskOutput.sameFile(URL(fileURLWithPath:source),destination) { throw FolioError(message:"请选择新的导出位置，避免覆盖原书") }
        try DocumentTaskOutput.write(to:destination,expected:expected) { temporary in
            switch format {
            case .word: try word(snapshot,assets:assets,to:temporary,warnings:prepared.warnings)
            case .pdf:
                var document=try rich(snapshot,assets:assets)
                for warning in prepared.warnings { document.blocks.append(.paragraph(RichTextDocument.styled("附图提示："+warning,options:document.options,markdown:false),heading:0)) }
                guard try document.pdf().write(to:temporary) else { throw FolioError(message:"无法写入 PDF") }
            case .markdown:
                let name = destination.deletingPathExtension().lastPathComponent+"-images"
                let parent = destination.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
                let folder = parent.appendingPathComponent(name).standardizedFileURL.resolvingSymlinksInPath()
                guard folder.path.hasPrefix(parent.path+"/") else { throw FolioError(message:"图片目录指向其他位置，请更换导出位置") }
                for image in (snapshot.options?.includeQuote == false ? Set<String>() : snapshot.assetNames053) {
                    try Task.checkCancellation()
                    let bytes = try Data(contentsOf:assets.appendingPathComponent(image)); try fm.createDirectory(at:folder,withIntermediateDirectories:true)
                    let out = folder.appendingPathComponent(image)
                    if fm.fileExists(atPath:out.path) { guard try Data(contentsOf:out) == bytes else { throw FolioError(message:"同名图片内容不同，请更换导出位置") } }
                    else { try bytes.write(to:out,options:.atomic) }
                }
                try (markdown(snapshot,imageFolder:name)+(prepared.warnings.isEmpty ? "":"\n\n附图提示：\n"+prepared.warnings.joined(separator:"\n"))).write(to:temporary,atomically:true,encoding:.utf8)
            }
            try ReadingExportAudit.validate(temporary,format:format,snapshot:snapshot)
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
    @Published var lastExportURL:URL?
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
    func export(_ snapshot:ReadingExportSnapshot,format:ReadingRecordExport.Format,assets:URL,to url:URL,expected:FileBaseline,onSuccess: @escaping () -> Void = {}) {
        cancel(); let token = UUID(); generation = token; busy = true
        job = Task { [weak self] in
            do {
                try await ReadingExportWorker.shared.export(snapshot,format:format,assets:assets,to:url,expected:expected)
                guard let self, self.generation == token else { return }; self.busy = false; self.lastExportURL = url; onSuccess(); self.message = "已导出并核验 "+url.lastPathComponent+" · "+String(snapshot.orderedItems.count)+" 项"+(format == .markdown ? "；请将 Markdown 与配套图片目录一起保存。" : "")
            } catch { guard let self, self.generation == token else { return }; self.busy = false; self.message = FolioCancellation.matches(error) ? "已取消，已有记录保留" : "导出失败："+error.localizedDescription }
        }
    }
    func cancel() { generation = UUID(); job?.cancel(); job = nil; busy = false }
    func close() { cancel();previewURL = nil;previewDigest = "";previewFormat = nil;if let folder = previewFolder { try? FileManager.default.removeItem(at:folder) };previewFolder = nil }
}
