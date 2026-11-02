import SwiftUI

struct ReadingContextView: View {
    let store:WorkspaceStore;let source:SourceRef
    @Environment(\.dismiss) private var dismiss
    @State private var result:ReadingContextImage?
    @State private var message = ""
    @State private var full = false
    @State private var zoom = 1.0
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text(result?.title ?? "原文上下文").font(.headline)
            HStack { Toggle("整页",isOn:$full);Text("放大");Slider(value:$zoom,in:1...3) }
            ScrollView([.horizontal,.vertical]) { if let result,let image = NSImage(data:result.png) { Image(nsImage:image).resizable().scaledToFit().frame(width:580*zoom) } else { Text(message.isEmpty ? "正在载入原文…" : message).padding(40) } }
            HStack { Button("关闭") { dismiss() };Spacer();Button("返回原文") { dismiss();_ = store.reveal(source,beside:false) } }
        }.padding(18).adaptiveSheet(width:760,height:650,minimumWidth:380)
        .task(id:full) { result = nil;message = "";let source = source,full = full;do { let r = try await Task.detached(priority:.utility) { try ReadingContextLoader.load(source,wholePage:full) }.value;if !Task.isCancelled { result = r } } catch { if !Task.isCancelled { message = error.localizedDescription } } }
    }
}
struct ReadingCitationUpdatesView: View {
    @ObservedObject var journal:ReadingJournal
    let essay:UUID
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("核对引用更新").font(.headline)
            Text("逐条采用最新摘录；你写在札记段落中的论述保留。更新后可在资料库撤销这次操作。").font(.caption)
            ScrollView { LazyVStack(alignment:.leading,spacing:14) { ForEach(journal.citationUpdates(essay)) { change in VStack(alignment:.leading,spacing:6) {
                Text(change.current.displayTitle).bold();Text("插入时："+change.previous.quote+"\n"+change.previous.note).foregroundStyle(.secondary)
                Text("最新："+change.current.quote+"\n"+change.current.note).textSelection(.enabled)
                Button("仅更新这处引用") { do { try journal.synchronizeCitation(change) } catch { message = error.localizedDescription } }
            }.padding(10).background(.quaternary.opacity(0.3)) } } }
            if journal.citationUpdates(essay).isEmpty { Text("当前引用与原摘录一致") }
            Text(message).font(.caption).foregroundStyle(.orange);Button("关闭") { dismiss() }
        }.padding(18).adaptiveSheet(width:760,height:580,minimumWidth:400)
    }
}
struct ReadingSearchMatches: View {
    let store:WorkspaceStore;let item:ReadingLibraryItem;let query:String;var selectBlock:((String)->Void)? = nil
    @State private var page = 0
    var body:some View {
        let hits = ReadingTextSearch.fields(item,query:query)
        if !query.isEmpty,!hits.isEmpty { DisclosureGroup("命中正文 \(hits.count) 处 · 点击定位") {
            ForEach(Array(hits.dropFirst(page*10).prefix(10))) { hit in
                Button { store.writingSearchHit = hit;store.writingSearchRequest = UUID() } label:{Text(hit.context).font(.caption).lineLimit(2).foregroundStyle(.blue)}.buttonStyle(.plain)
            }
            HStack { Button("上一页") { page-=1 }.disabled(page == 0);Text("\(page+1)");Button("下一页") { page+=1 }.disabled((page+1)*10>=hits.count) }.font(.caption)
        }.onChange(of:query) { _,_ in page = 0 } }
    }
}
struct ReadingBulkConfirmation: View {
    @ObservedObject var journal:ReadingJournal;let ids:Set<ReadingLibraryID>;let removed:Bool;let done:()->Void
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text(removed ? "确认恢复所选资料" : "确认移到最近删除").font(.headline)
            Text("影响 \(ids.count) 条，正文与出处保留；操作后可一键撤销，已有新编辑时停止撤销。").font(.caption)
            List { ForEach(ReadingLibraryItem.results(journal.state,removed:removed).filter{ids.contains($0.id)}) { item in Text(item.title).lineLimit(2) } }
            HStack { Button("取消") { dismiss() };Spacer();Button("确认") { journal.setRemoved(ids,removed:!removed);done();dismiss() } }
        }.padding(18).adaptiveSheet(width:600,height:420,minimumWidth:380)
    }
}
