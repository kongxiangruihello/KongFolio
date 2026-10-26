import AppKit
import Foundation

@MainActor final class FolderSearchModel: ObservableObject {
    struct Settings: Codable { var folder:URL?;var recursive=true;var query="" }
    @Published var folder:URL?
    @Published var recursive=true
    @Published var query=""
    @Published private(set) var searchedQuery=""
    @Published private(set) var searchedFolder:URL?
    @Published private(set) var running=false
    @Published private(set) var stopping=false
    @Published private(set) var openingID:UUID?
    @Published private(set) var results:[FolderSearchHit]=[]
    @Published private(set) var files:[FolderSearchFile]=[]
    @Published private(set) var scanned=0
    @Published private(set) var total=0
    @Published private(set) var progressText=""
    @Published var message=""
    @Published private(set) var discoveryErrors:[String]=[]
    let storage:URL
    private var generation=UUID()
    private var delivered=Set<Int>()
    private var worker:Task<FolderSearchSummary,Error>?
    private var task:Task<Void,Never>?
    private var openWorker:Task<FolderSearchService.Verified,Error>?
    var indexURL:URL { storage.appendingPathComponent("FolderSearch/index.sqlite") }
    private var settingsURL:URL { storage.appendingPathComponent("FolderSearch/Settings.json") }
    init(storage:URL) {
        self.storage=storage
        if let data=try? Data(contentsOf:settingsURL),let saved=try? JSONDecoder().decode(Settings.self,from:data) {
            folder=saved.folder;recursive=saved.recursive;query=saved.query
        }
    }
    var noTextFiles:[URL] { files.filter(\.needsOCR).map(\.url) }
    var problems:[String] {
        discoveryErrors + files.compactMap { file in
            (file.error ?? file.warning).map { file.url.path+"："+$0 }
        }
    }
    func remember() {
        do {
            try FileManager.default.createDirectory(at:settingsURL.deletingLastPathComponent(),withIntermediateDirectories:true)
            try JSONEncoder().encode(Settings(folder:folder,recursive:recursive,query:query)).write(to:settingsURL,options:.atomic)
        } catch { message="搜索设置未保存："+error.localizedDescription }
    }
    func start() {
        guard !running,openingID==nil else { return }
        guard let folder else { message="请先选择文件夹";return }
        let query=query.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !query.isEmpty else { message="请输入要搜索的文字";return }
        remember()
        generation=UUID();let token=generation,indexURL=indexURL,recursive=recursive
        delivered=[];results=[];files=[];discoveryErrors=[];scanned=0;total=0;message="";progressText="正在查找 PDF…"
        searchedQuery=query;searchedFolder=folder;running=true;stopping=false
        let job=Task.detached(priority:.userInitiated) { [weak self] in
            try FolderSearchService.run(folder:folder,query:query,recursive:recursive,indexURL:indexURL) { event in
                Task { @MainActor [weak self] in self?.receive(event,token:token) }
            }
        }
        worker=job
        task=Task { [weak self] in
            do {
                let result=try await job.value
                guard let self,self.generation==token else { return }
                self.files=result.files;self.results=result.hits;self.scanned=result.files.count;self.total=result.totalFiles;self.discoveryErrors=result.discoveryErrors
                self.message=(result.truncated ? "已达到 1,000 处结果上限，请缩小范围或搜索更长词句。" : "搜索完成，找到 \(result.hits.count) 处匹配。")
                    + " 复用 \(result.files.filter(\.cached).count) 份文字索引。" + (result.indexWarning.map { " "+$0 } ?? "")
            } catch is CancellationError {
                guard let self,self.generation==token else { return };self.message="搜索已停止，已完成文件的结果和索引保留。"
            } catch {
                guard let self,self.generation==token else { return };self.message=error.localizedDescription
            }
            guard let self,self.generation==token else { return }
            self.running=false;self.stopping=false;self.progressText="";self.worker=nil;self.task=nil
        }
    }
    private func receive(_ event:FolderSearchService.Event,token:UUID) {
        guard generation==token,running,!stopping else { return }
        switch event {
        case .discovered(let count):total=count
        case .reading(let name):progressText="正在读取："+name
        case .page(let name,let page,let count):progressText="\(name) · 第 \(page)"+(count>0 ? " / \(count)" : "")+" 页"
        case .file(let offset,let count,let file):
            guard delivered.insert(offset).inserted else { return }
            total=count;scanned=max(scanned,offset+1);files.append(file);results += file.hits
        }
    }
    func cancel() {
        if running { stopping=true;worker?.cancel() }
        openWorker?.cancel()
    }
    func clearIndex() {
        guard !running,openingID==nil else { return }
        do {
            for suffix in ["","-wal","-shm"] {
                let url=URL(fileURLWithPath:indexURL.path+suffix)
                if FileManager.default.fileExists(atPath:url.path) { try FileManager.default.removeItem(at:url) }
            }
            message="本地搜索索引已清除，下次搜索重新提取文字。已有 PDF 和搜索结果保留。"
        } catch { message="无法清除索引："+error.localizedDescription }
    }
    func open(_ result:FolderSearchHit,in store:WorkspaceStore) async -> Bool {
        guard !running,openingID==nil else { return false }
        openingID=result.id;message="正在核对并打开："+result.url.lastPathComponent
        let job=Task.detached(priority:.userInitiated) { try FolderSearchService.verify(result) };openWorker=job
        defer { openingID=nil;openWorker=nil }
        do {
            let verified=try await withTaskCancellationHandler(operation:{ try await job.value },onCancel:{ job.cancel() })
            guard !job.isCancelled else { throw CancellationError() }
            try Task.checkCancellation()
            try store.openFolderSearchResult(result,verified:verified)
            message="已定位到第 \(result.hit.page+1) 页";return true
        } catch is CancellationError { message="已取消打开" }
        catch { message=error.localizedDescription }
        return false
    }
    func report() -> String {
        var lines=["KongFolio 跨文件搜索","文件夹：\(searchedFolder?.path ?? "")","搜索：\(searchedQuery)","已检查 \(scanned) / \(total) 份 PDF，\(results.count) 处匹配",message,""]
        for result in results {
            lines.append(result.url.path+" · 第 \(result.hit.page+1) 页"+(result.hit.label.map { "（印刷页码 \($0)）" } ?? ""))
            lines.append(result.hit.snippet);lines.append("")
        }
        if !noTextFiles.isEmpty { lines += ["未提取到文字："]+noTextFiles.map(\.path)+[""] }
        if !problems.isEmpty { lines += ["跳过 / 提示："]+problems }
        return lines.joined(separator:"\n")
    }
}

extension WorkspaceStore {
    func openFolderSearchResult(_ result:FolderSearchHit,verified:FolderSearchService.Verified) throws {
        let path=result.url.standardizedFileURL.resolvingSymlinksInPath()
        let existing=tabs.compactMap(\.workspace).first { $0.projectURL==nil && $0.sourceURL?.standardizedFileURL.resolvingSymlinksInPath()==path }
        let target:Workspace
        if let existing {
            guard !existing.busy else { throw FolioError(message:"这个文件正在处理，请完成或取消当前任务后再打开结果") }
            guard !existing.dirty else { throw FolioError(message:"这个文件有未保存编辑，请保存并重新搜索后定位；当前编辑已保留") }
            if existing.count>0 {
                guard try existing.pdfData()==verified.data else { throw FolioError(message:"已打开的文档与搜索版本不同，请关闭该标签页后重新打开结果；未替换当前内容") }
                select(existing.id);existing.go(to:verified.source.position,highlighting:verified.source.rects);return
            }
            target=existing
        } else if let empty=activeWorkspace,empty.count==0,!empty.needsLoad,!empty.busy,empty.sourceURL==nil,empty.projectURL==nil { target=empty }
        else { target=addWorkspace() }
        target.needsLoad=false;target.pendingView=verified.source.position;target.pendingReveal=verified.source
        target.load([result.url],prepared:.documents([verified.data]))
        guard target.count>0 else { throw FolioError(message:target.error ?? "无法打开搜索结果") }
        select(target.id)
    }
}
