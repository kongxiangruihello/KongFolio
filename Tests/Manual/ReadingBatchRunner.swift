import Foundation
import PDFKit
import Darwin
import AppKit

/// Exercises production close/save paths without XCTest, window activation, or user storage.
@MainActor final class WeakReadingWorkspace { weak var value:Workspace?;init(_ value:Workspace) { self.value = value } }
@main struct ReadingBatchRunner {
    @MainActor static func waitFor(_ test:()->Bool,_ label:String) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime+25
        while !test(),ProcessInfo.processInfo.systemUptime<deadline { try await Task.sleep(nanoseconds:20_000_000) }
        guard test() else { throw FolioError(message:"连续阅读验证未完成："+label) }
    }
    static func memoryMB() -> Double {
        var info = mach_task_basic_info();var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size/MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to:&info) { p in p.withMemoryRebound(to:integer_t.self,capacity:Int(count)) { task_info(mach_task_self_,task_flavor_t(MACH_TASK_BASIC_INFO),$0,&count) } }
        return status == KERN_SUCCESS ? Double(info.resident_size)/1048576 : 0
    }
    @MainActor static func main() async throws {
        guard !AppEnvironment.isTestRun else { throw FolioError(message:"必须使用正常运行模式") }
        let fm = FileManager.default,root = fm.temporaryDirectory.appendingPathComponent("KongFolio-ReadingBatch-"+UUID().uuidString)
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        let source:[URL]
        if let path = ProcessInfo.processInfo.environment["KONGFOLIO_STRESS_INPUT"] { source = Array(try fm.contentsOfDirectory(at:URL(fileURLWithPath:path),includingPropertiesForKeys:nil).filter{$0.pathExtension.lowercased()=="pdf"}.sorted{$0.path<$1.path}.prefix(20)) }
        else { let doc = PDFDocument()
            let context = CGContext(data:nil,width:500,height:700,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(gray:1,alpha:1));context.fill(CGRect(x:0,y:0,width:500,height:700));context.setStrokeColor(CGColor(gray:0,alpha:1))
            for y in stride(from:50,through:650,by:20) { context.stroke(CGRect(x:35,y:y,width:430,height:4)) }
            let image = NSImage(cgImage:context.makeImage()!,size:NSSize(width:500,height:700))
            for _ in 0..<4 { doc.insert(PDFPage(image:image)!,at:doc.pageCount) }
            let data = doc.dataRepresentation()!;source = try (0..<20).map { i in let f = root.appendingPathComponent("input-\(i).pdf");try data.write(to:f);return f } }
        guard source.count == 20 else { throw FolioError(message:"需要 20 份验证文献") }
        let checksums = try source.map{OCRPageCache.digest(try Data(contentsOf:$0))}
        let files = try source.enumerated().map { i,url in let f = root.appendingPathComponent("reading-\(i).pdf");try fm.copyItem(at:url,to:f);return f }
        let store = WorkspaceStore(storage:root.appendingPathComponent("storage"),readingDefaults:UserDefaults(suiteName:"KongFolio.NormalBatch."+UUID().uuidString)!)
        store.readingMode = true;store.bootstrap();store.maxLoadedTabs = 3
        let rounds = max(3,min(20,Int(ProcessInfo.processInfo.environment["KONGFOLIO_STRESS_ROUNDS"] ?? "10") ?? 10))
        var closedReferences:[WeakReadingWorkspace] = [],liveAfterRounds:[Int] = []
        var ticks = 0,gap = 0.0,previous = ProcessInfo.processInfo.systemUptime,longest = 0.0,memory:[Double] = []
        let pulse = Task { @MainActor in while !Task.isCancelled { let now = ProcessInfo.processInfo.systemUptime;gap = max(gap,now-previous);previous = now;ticks += 1;try? await Task.sleep(nanoseconds:20_000_000) } };defer { pulse.cancel() }
        for round in 1...rounds {
            store.openEach(files);guard store.tabs.count == 20 else { throw FolioError(message:"标签页数量不符") }
            let ids = store.tabs.map(\.id)
            for id in ids {
                let start = ProcessInfo.processInfo.systemUptime
                store.select(id);let w = store.activeWorkspace!
                try await waitFor({!w.busy && w.count>0},"打开文献")
                w.selectPage(max(0,w.count-1));w.bookmarkName = "第\(round)轮验证书签";w.addBookmark()
                closedReferences.append(WeakReadingWorkspace(w))
                store.close(id)
                try await waitFor({w.count == 0 && !w.saving && !w.busy},"关闭并保存")
                longest = max(longest,ProcessInfo.processInfo.systemUptime-start)
            }
            guard store.tabs.count == 1,store.activeWorkspace?.count == 0 else { throw FolioError(message:"本轮未清空阅读文档") }
            try await Task.sleep(nanoseconds:250_000_000)
            let live = closedReferences.filter{$0.value != nil}.count;liveAfterRounds.append(live)
            guard live<=2 else { throw FolioError(message:"关闭后的文献仍被持有：\(live) 份") }
            memory.append(memoryMB());print("NORMAL_READING round=\(round) opened=20 closed=20 memoryMB=\(memory.last!) longestStepSeconds=\(longest)")
        }
        let check = Workspace(storage:store.storage,slot:"verify",readingDefaults:store.readingDefaults);check.bootstrap(restoreRecovery:false);check.load([files[0]])
        try await waitFor({!check.busy && check.count>0},"核对重开书签")
        guard check.bookmarks.contains(where:{$0.label == "第\(rounds)轮验证书签"}),ticks>20,longest<25 else { throw FolioError(message:"阅读记录或响应验证未通过") }
        guard try source.map({OCRPageCache.digest(try Data(contentsOf:$0))}) == checksums else { throw FolioError(message:"输入文献发生变化") }
        let growth = (memory.last ?? 0)-(memory.dropFirst(2).min() ?? memory.first ?? 0)
        guard gap < 5,growth < 256 else { throw FolioError(message:"响应或内存趋势超出阅读验证预算") }
        let report:[String:Any] = ["closedWorkspaceReferencesStillLive":liveAfterRounds,"testMode":false,"rounds":rounds,"opened":rounds*20,"closed":rounds*20,"bookmarksRestored":true,"sourceFixturesUnchanged":true,"mainActorHeartbeats":ticks,"maxHeartbeatGapSeconds":gap,"longestStepSeconds":longest,"residentMB":memory,"postWarmupGrowthMB":growth,"heartbeatBudgetSeconds":5,"memoryGrowthBudgetMB":256]
        let data = try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]);if let path = ProcessInfo.processInfo.environment["KONGFOLIO_READING_BATCH_REPORT"] { try data.write(to:URL(fileURLWithPath:path),options:.atomic) }
        print(String(data:data,encoding:.utf8)!);print("PASS: normal-mode repeated batch reading and close/save")
        _ = await check.finishPendingSave();_ = check.closeDocument()
    }
}
