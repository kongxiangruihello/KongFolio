import Foundation
import Combine

struct ReadingExportJob:Identifiable {
    enum State:String { case pending = "等待",running = "正在导出",complete = "完成",failed = "失败",cancelled = "已取消" }
    var id = UUID()
    var snapshot:ReadingExportSnapshot
    var format:ReadingRecordExport.Format
    var destination:URL
    var state = State.pending
    var message = ""
}
enum ReadingExportJobs {
    static func filename(_ value:String) -> String {
        let clean = value.components(separatedBy:CharacterSet.controlCharacters.union(CharacterSet(charactersIn:"/:\\"))).joined(separator:"-").trimmingCharacters(in:CharacterSet(charactersIn:" ."))
        return clean.isEmpty ? "阅读记录" : String(clean.prefix(70))
    }
    static func groups(_ snapshot:ReadingExportSnapshot) -> [ReadingExportSnapshot] {
        var result:[ReadingExportSnapshot] = [],indices:[String:Int] = [:]
        for item in snapshot.orderedItems {
            switch item {
            case .essay(let e):result.append(ReadingExportSnapshot(title:e.title,essay:e,options:snapshot.options))
            case .record(let r):
                let citation = r.citations.first,key = citation?.source.path.isEmpty == false ? citation!.source.path : "__notes"
                if let index = indices[key] { result[index].records.append(r) }
                else { indices[key] = result.count;result.append(ReadingExportSnapshot(title:citation?.title.isEmpty == false ? citation!.title : "独立笔记",records:[r],options:snapshot.options)) }
            }
        }
        return result
    }
    static func plan(_ snapshot:ReadingExportSnapshot,formats:[ReadingRecordExport.Format],folder:URL) throws -> [ReadingExportJob] {
        guard !formats.isEmpty else { throw FolioError(message:"至少选择一种导出格式") }
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        var jobs:[ReadingExportJob] = []
        for (i,group) in groups(snapshot).enumerated() {
            for format in formats { let name = String(format:"%03d",i+1)+"-"+filename(group.title)+"."+format.ext
                let url = folder.appendingPathComponent(name)
                guard !FileManager.default.fileExists(atPath:url.path) else { throw FolioError(message:"导出目录已有同名文件，请选择新目录") }
                jobs.append(ReadingExportJob(snapshot:group,format:format,destination:url))
            }
        };return jobs
    }
}
@MainActor final class ReadingExportBatch:ObservableObject {
    @Published private(set) var jobs:[ReadingExportJob] = []
    @Published private(set) var busy = false
    @Published private(set) var message = ""
    @Published private(set) var folder:URL?
    private var task:Task<Void,Never>?
    private var assets:URL?
    var completed:Int { jobs.filter{$0.state == .complete}.count }
    func start(_ snapshot:ReadingExportSnapshot,formats:[ReadingRecordExport.Format],assets:URL,folder:URL) {
        guard !busy else { return }
        do { jobs = try ReadingExportJobs.plan(snapshot,formats:formats,folder:folder);self.assets = assets;self.folder = folder;run() }
        catch { message = error.localizedDescription }
    }
    func retry() { guard !busy else { return };for i in jobs.indices where jobs[i].state == .failed || jobs[i].state == .cancelled { jobs[i].state = .pending };run() }
    private func run() {
        guard let assets else { return };busy = true;message = "正在导出…"
        task = Task { [weak self] in
            guard let self else { return }
            for i in self.jobs.indices where self.jobs[i].state == .pending {
                if Task.isCancelled { break }
                self.jobs[i].state = .running
                let job = self.jobs[i]
                do {
                    try await ReadingExportWorker.shared.export(job.snapshot,format:job.format,assets:assets,to:job.destination,expected:FileBaseline(path:job.destination.standardizedFileURL.path,digest:nil))
                    self.jobs[i].state = .complete;self.jobs[i].message = "已保存"
                } catch {
                    self.jobs[i].state = FolioCancellation.matches(error) ? .cancelled : .failed;self.jobs[i].message = FolioCancellation.matches(error) ? "可重试" : error.localizedDescription
                }
            }
            for i in self.jobs.indices where self.jobs[i].state == .pending { self.jobs[i].state = .cancelled }
            self.busy = false;self.message = "已完成 \(self.completed)/\(self.jobs.count) 项；完成文件已保留。";self.task = nil
        }
    }
    func stopAndWait() async { task?.cancel();await task?.value }
    func cancel() { task?.cancel();message = "正在停止，已完成文件会保留…" }
}
actor ReadingPackageWorker {
    static let shared = ReadingPackageWorker()
    func write(_ snapshot:ReadingExportSnapshot,formats:[ReadingRecordExport.Format],assets:URL,originals:Bool,to destination:URL,expected:FileBaseline,progress:@escaping @Sendable (String)->Void) throws {
        guard !formats.isEmpty else { throw FolioError(message:"至少选择一种导出格式") }
        for path in Set(snapshot.allRecords.flatMap(\.citations).map(\.source.path).filter{!$0.isEmpty}) where DocumentTaskOutput.sameFile(URL(fileURLWithPath:path),destination) { throw FolioError(message:"资料包不能覆盖原始文献，请选择新位置") }
        let fm = FileManager.default,root = fm.temporaryDirectory.appendingPathComponent("KongFolio-package-"+UUID().uuidString)
        try fm.createDirectory(at:root,withIntermediateDirectories:true);defer { try? fm.removeItem(at:root) }
        var value = snapshot,links:[String:String] = [:]
        if originals {
            for path in Set(snapshot.allRecords.flatMap(\.citations).map(\.source.path).filter{!$0.isEmpty}).sorted() {
                try Task.checkCancellation();progress("正在复制所引用的原始文献…")
                let source = URL(fileURLWithPath:path).resolvingSymlinksInPath()
                guard try source.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true else { throw FolioError(message:"原始文献暂不可用："+source.lastPathComponent) }
                let relative = "Sources/"+String(OCRPageCache.digest(Data(path.utf8)).prefix(10))+"-"+ReadingExportJobs.filename(source.lastPathComponent)
                let target = root.appendingPathComponent(relative);try fm.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true);try fm.copyItem(at:source,to:target);links[path] = relative
            }
        }
        var options = value.options ?? ReadingExportOptions();options.sourceLinks = links.isEmpty ? nil : links;value.options = options
        for format in formats {
            try Task.checkCancellation();progress("正在生成 "+format.rawValue+"…")
            let file = root.appendingPathComponent("阅读资料."+format.ext)
            try ReadingRecordExport.write(value,format:format,assets:assets,to:file,expected:FileBaseline(path:file.path,digest:nil))
        }
        // Keep images even when the selected output formats embed them, so the package remains editable.
        if options.includeQuote {
            for name in value.assetNames053 {
                try Task.checkCancellation();let folder = root.appendingPathComponent("Images");try fm.createDirectory(at:folder,withIntermediateDirectories:true)
                try fm.copyItem(at:assets.appendingPathComponent(name),to:folder.appendingPathComponent(name))
            }
        }
        let citations = value.allRecords.flatMap(\.citations)
        let bibliography = Array(Set(citations.map(ReadingExportOrdering.citation))).sorted().joined(separator:"\n")
        try bibliography.write(to:root.appendingPathComponent("出处清单.txt"),atomically:true,encoding:.utf8)
        var html = "<!doctype html><meta charset=utf-8><title>阅读资料与出处</title><h1>"+WordExport.escape(snapshot.title)+"</h1><ul>"
        for format in formats { html += "<li><a href=\"阅读资料."+format.ext+"\">"+format.rawValue+"</a></li>" };html += "</ul><h2>引用的文献</h2><ol>"
        for citation in citations {
            let text = WordExport.escape(ReadingExportOrdering.citation(citation))
            if let relative = links[citation.source.path] { html += "<li><a href=\""+RichTextWord.attribute(relative+"#page="+String(citation.source.page+1))+"\">"+text+"</a></li>" } else { html += "<li>"+text+"</li>" }
        }
        html += "</ol>";try html.write(to:root.appendingPathComponent("打开资料包.html"),atomically:true,encoding:.utf8)
        try "解压整个资料包后打开“打开资料包.html”。Markdown 与配套图片目录一起保留。只有勾选“包含原始文献”才复制所引用文件；未包含的原书需在本机继续访问。Word 中的返回原文链接由 KongFolio 打开；资料包目录页和 Markdown 在包含原书时使用相对链接。".write(to:root.appendingPathComponent("使用说明.txt"),atomically:true,encoding:.utf8)
        var manifest:[String:String] = [:]
        for file in try fm.subpathsOfDirectory(atPath:root.path).sorted() {
            let url = root.appendingPathComponent(file);if try url.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true { manifest[file] = OCRPageCache.digest(try Data(contentsOf:url,options:.mappedIfSafe)) }
        }
        try JSONEncoder().encode(manifest).write(to:root.appendingPathComponent("文件校验.json"),options:.atomic)
        try DocumentTaskOutput.write(to:destination,expected:expected) { temporary in
            let zip = try ZipWriter(url:temporary)
            do { for name in try fm.subpathsOfDirectory(atPath:root.path).sorted() {
                try Task.checkCancellation();let file = root.appendingPathComponent(name)
                if try file.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true { try zip.add(name,Data(contentsOf:file,options:.mappedIfSafe)) }
            };try zip.finish() } catch { zip.abandon();throw error }
        }
    }
}
@MainActor final class ReadingPackageController:ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var message = ""
    private var task:Task<Void,Never>?
    func start(_ snapshot:ReadingExportSnapshot,formats:[ReadingRecordExport.Format],assets:URL,originals:Bool,to url:URL,expected:FileBaseline) {
        guard !busy else { return };busy = true
        task = Task { [weak self] in
            do { try await ReadingPackageWorker.shared.write(snapshot,formats:formats,assets:assets,originals:originals,to:url,expected:expected) { phase in Task { @MainActor [weak self] in self?.message = phase } };self?.message = "资料包已导出："+url.lastPathComponent }
            catch { self?.message = FolioCancellation.matches(error) ? "已取消，正式文件未写入" : error.localizedDescription }
            self?.busy = false;self?.task = nil
        }
    }
    func stopAndWait() async { task?.cancel();await task?.value }
    func cancel() { task?.cancel() }
}
