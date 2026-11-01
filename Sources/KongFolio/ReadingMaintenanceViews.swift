import SwiftUI

struct ReadingOrganizationSheet: View {
    @ObservedObject var journal:ReadingJournal
    let ids:Set<ReadingLibraryID>
    @Environment(\.dismiss) private var dismiss
    @State private var tags = ""
    @State private var topic = ""
    @State private var remove = false
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            Text("批量整理 · \(ids.count) 条记录").font(.headline)
            TextField("标签，以逗号分隔",text:$tags)
            TextField("专题名称（可留空）",text:$topic)
            Toggle("从所选记录移除这些标签／专题",isOn:$remove)
            Text("其他标签、正文与引用保持不变。专题保存为“专题：名称”，也可直接搜索。").font(.caption).foregroundStyle(.secondary)
            HStack { Button("取消") { dismiss() }; Spacer(); Button(remove ? "移除" : "应用") { journal.organize(ids,tags:tags,topic:topic,remove:remove); dismiss() }.disabled(tags.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && topic.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty) }
        }.padding(20).frame(minWidth:420,idealWidth:520)
    }
}

struct ReadingReferencesView: View {
    @ObservedObject var journal:ReadingJournal
    let id:ReadingLibraryID
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        let links = journal.references(to:id)
        VStack(alignment:.leading,spacing:12) {
            HStack { Text("引用关系").font(.headline); Spacer(); Button("关闭") { dismiss() } }
            ScrollView {
                LazyVStack(alignment:.leading,spacing:14) {
                    Text("引用了 · \(links.outgoing.count) 条").font(.headline)
                    if links.outgoing.isEmpty { Text("暂无关联引用").foregroundStyle(.secondary) }
                    ForEach(links.outgoing) { entry in reference(entry) }
                    Divider(); Text("被引用 · \(links.incoming.count) 条").font(.headline)
                    if links.incoming.isEmpty { Text("暂无其他笔记或札记引用").foregroundStyle(.secondary) }
                    ForEach(links.incoming) { entry in reference(entry) }
                }
            }
            Text("札记中的引用保留插入时的内容；原条目后来修改或删除，不会重写已有札记。").font(.caption).foregroundStyle(.secondary)
        }.padding(20).adaptiveSheet(width:660,height:580,minimumWidth:420)
    }
    private func reference(_ entry:ReadingReference) -> some View {
        VStack(alignment:.leading,spacing:6) {
            Text(entry.kind+" · "+entry.title).font(.headline)
            if entry.removed { Text("当前已删除或原条目不在资料库，引用内容仍保留").font(.caption).foregroundStyle(.secondary) }
            if !entry.text.isEmpty { Text(entry.text).textSelection(.enabled) }
        }.frame(maxWidth:.infinity,alignment:.leading).padding(10).background(.quaternary,in:RoundedRectangle(cornerRadius:8))
    }
}

struct ReadingBackupView: View {
    @ObservedObject var journal:ReadingJournal
    @Environment(\.dismiss) private var dismiss
    @State private var backups:[ReadingBackup] = []
    @State private var selected:String?
    @State private var query = ""
    @State private var records:Set<ReadingLibraryID> = []
    @State private var busy = false
    @State private var message = ""
    @State private var page = 0
    @State private var size = 10
    private var backup:ReadingBackup? { backups.first{$0.id == selected} }
    private var entries:[ReadingLibraryItem] {
        guard let backup else { return [] }
        return (backup.state.records.filter{$0.hasContent && $0.matches(query)}.map(ReadingLibraryItem.record)+backup.state.essays.filter{$0.hasContent && $0.matches(query)}.map(ReadingLibraryItem.essay)).sorted{$0.key < $1.key}
    }
    private var pagination:ReadingPagination { ReadingPagination(total:entries.count,page:page,size:size) }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { Text("资料库备份与恢复").font(.headline); Spacer(); Button("关闭") { dismiss() }.disabled(busy) }
            Text("每天自动备份一次，保留最近 30 份每日备份；手动备份和恢复前备份保留。可复制整个备份目录另存。").font(.caption)
            HStack {
                Button("立即备份") { run { _ = try await journal.makeBackup(); message = "已保存手动备份"; await refresh() } }.disabled(busy || journal.unreadable)
                Button("刷新") { Task { await refresh() } }.disabled(busy)
                Button("显示备份目录") { let folder = ReadingBackupStorage.root(journal.folder); NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                if busy { ProgressView().controlSize(.small) }
            }
            Picker("按日期选择备份",selection:$selected) {
                Text("请选择备份").tag(nil as String?)
                ForEach(backups) { value in Text(value.date.formatted(date:.numeric,time:.standard)+" · "+value.kind.rawValue).tag(Optional(value.id)) }
            }
            if let backup {
                Text("备份含 \(backup.state.records.count) 条记录、\(backup.state.essays.count) 篇札记。选择后先核对下方内容，再恢复。").font(.caption)
                TextField("在备份中搜索标题、正文或出处",text:$query).textFieldStyle(.roundedBorder)
                List(selection:$records) { ForEach(Array(entries.dropFirst(pagination.range.lowerBound).prefix(pagination.size))) { entry in
                    VStack(alignment:.leading) { Text(entry.kind+" · "+entry.title).lineLimit(2); Text(status(entry,backup:backup)).font(.caption).foregroundStyle(.secondary) }.tag(entry.id)
                } }.frame(minHeight:110,maxHeight:180)
                ReadingPageControls(pagination:pagination,page:$page,size:$size)
                if records.count == 1, let id = records.first {
                    ScrollView {
                        VStack(alignment:.leading,spacing:8) {
                            Text(preview(id,backup:backup)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                            ForEach(imageHashes(id,backup:backup),id:\.self) { hash in ReadingBackupImage(folder:journal.folder,hash:hash).frame(maxHeight:140) }
                        }
                    }.frame(minHeight:80,maxHeight:170).padding(8).background(.quaternary)
                }
                Button("恢复所选 \(records.count) 条记录") { let id = backup.id, selection = records; run { try await journal.restoreBackup(id,ids:selection); message = "所选记录已恢复，其他记录保持不变；恢复前备份已保留"; await refresh() } }.disabled(records.isEmpty || busy || journal.unreadable)
            } else { Text(backups.isEmpty ? "暂无备份，记录保存后会自动建立每日备份。" : "请选择日期，预览后恢复单条或多条记录。").foregroundStyle(.secondary).frame(maxHeight:.infinity) }
            if !message.isEmpty { Text(message).font(.caption).textSelection(.enabled) }
        }.padding(20).adaptiveSheet(width:720,height:720,minimumWidth:460)
        .task { await refresh() }.onChange(of:selected) { _,_ in records = []; page = 0; query = "" }.onChange(of:query) { _,_ in records = []; page = 0 }.onChange(of:size) { _,_ in page = 0 }
    }
    private func status(_ entry:ReadingLibraryItem,backup:ReadingBackup) -> String {
        switch entry {
        case .record(let old): guard let current = journal.state.records.first(where:{$0.id == old.id}) else { return "当前未找到，可恢复" }; return current == old ? "与当前一致" : "内容或信息有变化，可预览核对"
        case .essay(let old): guard let current = journal.state.essays.first(where:{$0.id == old.id}) else { return "当前未找到，可恢复" }; return current == old ? "与当前一致" : "内容或信息有变化，可预览核对"
        }
    }
    private func preview(_ id:ReadingLibraryID,backup:ReadingBackup) -> String {
        switch id {
        case .record(let id): guard let r = backup.state.records.first(where:{$0.id == id}) else { return "" }; return [r.displayTitle,r.quote,r.note,r.citations.map(\.display).joined(separator:"\n"),r.tags.joined(separator:" · ")].filter{!$0.isEmpty}.joined(separator:"\n\n")
        case .essay(let id): guard let e = backup.state.essays.first(where:{$0.id == id}) else { return "" }; return ([e.title]+e.blocks.map { [$0.record?.quote ?? "",$0.record?.note ?? "",$0.record?.citations.map(\.display).joined(separator:"\n") ?? "",$0.text].filter{!$0.isEmpty}.joined(separator:"\n\n") }).joined(separator:"\n\n")
        }
    }
    private func imageHashes(_ id:ReadingLibraryID,backup:ReadingBackup) -> [String] {
        let names:[String]
        switch id {
        case .record(let id): names = backup.state.records.first{$0.id == id}?.imageAsset.map{[$0]} ?? []
        case .essay(let id): names = backup.state.essays.first{$0.id == id}?.blocks.compactMap{$0.record?.imageAsset} ?? []
        }
        return Array(Set(names.compactMap{backup.assets[$0]})).sorted()
    }
    private func refresh() async {
        let folder = journal.folder
        do { backups = try await Task.detached(priority:.utility) { try ReadingBackupStorage.list(folder) }.value } catch { message = error.localizedDescription }
    }
    private func run(_ operation:@escaping @MainActor () async throws -> Void) { busy = true; Task { do { try await operation() } catch { message = error.localizedDescription }; busy = false } }
}

struct ReadingBackupImage: View {
    let folder:URL
    let hash:String
    @State private var image:NSImage?
    @State private var message = "正在读取备份图片…"
    var body:some View {
        Group { if let image { Image(nsImage:image).resizable().scaledToFit() } else { Text(message).font(.caption) } }
        .task(id:hash) {
            let url = ReadingBackupStorage.root(folder).appendingPathComponent("Assets").appendingPathComponent(hash)
            let data = await Task.detached(priority:.utility) { () -> Data? in
                guard (try? ReadingBackupStorage.checked(url)) != nil, let data = try? Data(contentsOf:url), OCRPageCache.digest(data) == hash else { return nil }; return data
            }.value
            guard !Task.isCancelled else { return }; image = data.flatMap(NSImage.init(data:)); if image == nil { message = "备份图片暂不可用，恢复前会再次校验" }
        }
    }
}
