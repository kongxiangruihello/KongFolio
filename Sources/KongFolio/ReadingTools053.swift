import SwiftUI
import UniformTypeIdentifiers

struct ReadingTools053:View {
    @ObservedObject var store:WorkspaceStore
    @ObservedObject var journal:ReadingJournal
    var ids:Set<ReadingLibraryID>
    @Environment(\.dismiss) private var dismiss
    enum Page:String,CaseIterable { case organize="整理",history="修改历史",sources="书目信息",compare="并排核对",duplicates="重复资料",quotations="笔记引用",output="目录与备份" }
    @State private var page=Page.organize
    @State private var review=ReadingRecordExtras053.Review.unreviewed
    @State private var meaning=""
    @State private var chapter=""
    @State private var template=ReadingNoteTemplate053.blank
    @State private var message=""
    @State private var busy=false
    @State private var revisions:[ReadingRecordHistory.Revision]=[]
    @State private var revisionID:UUID?
    @State private var author=""
    @State private var title=""
    @State private var publication=ReadingPublication053()
    @State private var metadataPreview:ReadingJournalState?
    @State private var destination:ReadingLibraryID?
    @State private var columns=Set(ReadingCatalog053.Column.allCases)
    @State private var duplicateGroups053:[[ReadingRecord]]=[]
    private var selected:[ReadingLibraryItem] { ReadingWorkflow053.items(journal.state,ids:ids) }
    private var single:ReadingLibraryItem? { ids.count==1 ? selected.first:nil }
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            HStack { Text("阅读整理与输出").font(.title2.bold());Spacer();Button("完成") { dismiss() } }
            Text(ids.isEmpty ? "未选记录；目录导出与备份包含全部资料。" : "已选 \(selected.count) 条；正文、出处和收录时间会保留。").font(.callout).foregroundStyle(.secondary)
            Picker("功能",selection:$page) { ForEach(Page.allCases,id:\.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu)
            Divider()
            ScrollView { content.frame(maxWidth:.infinity,alignment:.leading).padding(2) }
            if !message.isEmpty { Text(message).font(.callout).textSelection(.enabled) }
            if busy { ProgressView().controlSize(.small) }
        }.padding(22).adaptiveSheet(width:1040,height:720,minimumWidth:600)
        .disabled(journal.unreadable)
        .onAppear { if let item=single { review=item.extras053.review ?? .unreviewed;meaning=item.extras053.colorMeaning ?? "";chapter=item.extras053.chapter ?? "";if let c=item.citations053.first { author=c.author;title=c.title;publication=c.publication ?? ReadingPublication053() } } }
        .task(id:page) { if page == .history,let item=single { let key=(item.id.isEssay053 ? "e-":"r-")+item.id.uuid053.uuidString,historyFolder=journal.folder;do { revisions=try await Task.detached{try ReadingRecordHistory.read(key,folder:historyFolder)}.value;revisionID=revisions.first?.id } catch { message=error.localizedDescription } } }
        .task(id:page.rawValue+String(journal.revisionID)) { if page == .duplicates { let state=journal.state;let groups=await Task.detached{ReadingWorkflow053.duplicateGroups(state)}.value;if !Task.isCancelled { duplicateGroups053=groups } } }
    }
    @ViewBuilder private var content:some View {
        switch page {
        case .organize:organize
        case .history:history
        case .sources:sources
        case .compare:compare
        case .duplicates:duplicates
        case .quotations:quotations
        case .output:output
        }
    }
    private var organize:some View {
        VStack(alignment:.leading,spacing:14) {
            Picker("核对状态",selection:$review) { ForEach(ReadingRecordExtras053.Review.allCases,id:\.self) { Text($0.rawValue).tag($0) } }
            TextField("颜色含义，例如：黄色＝重要观点",text:$meaning)
            TextField("章节名称",text:$chapter)
            Button("应用到所选资料") { journal.updateExtras053(ids) { $0.review=review;$0.colorMeaning=meaning;$0.chapter=chapter };message="已更新整理信息" }.disabled(ids.isEmpty)
            if case .record(let record)=single,let color=record.pdfOrigin?.color053 {
                Button("把 \(color) 的含义设为“\(meaning.isEmpty ? "无":meaning)”，应用到同色标注") {
                    ReadingColorSemantics053.set(color,meaning:meaning)
                    let matches=Set(journal.state.records.filter{$0.removed==nil && $0.pdfOrigin?.color053==color}.map{ReadingLibraryID.record($0.id)})
                    journal.updateExtras053(matches){$0.colorMeaning=meaning};message="已应用到 \(matches.count) 条同色标注；以后收录也会使用这个含义"
                }
            }
            Divider()
            Picker("新笔记模板",selection:$template) { ForEach(ReadingNoteTemplate053.allCases) { Text($0.rawValue).tag($0) } }
            if template != .blank { Text(template.body).font(.body).textSelection(.enabled) }
            Button("新建笔记") {
                if template == .blank { store.newReadingNote() }
                else { let record=ReadingRecord(kind:.note,note:template.body,citations:single?.citations053 ?? []);journal.add(record);store.openReadingItem(.record(record.id)) }
                dismiss()
            }
            Text("所有模板都是笔记；空白笔记在写入内容后才保存。").font(.caption).foregroundStyle(.secondary)
            if let item=single { Button("复制这条记录的快捷链接") { NSPasteboard.general.clearContents();NSPasteboard.general.setString(ReadingRecordLink053.url(item.id).absoluteString,forType:.string);message="已复制，可放入笔记或保存为快捷方式" } }
        }.textFieldStyle(.roundedBorder)
    }
    @ViewBuilder private var history:some View {
        if let item=single {
            VStack(alignment:.leading,spacing:12) {
                Text("当前："+item.title).font(.headline)
                Picker("历史版本",selection:$revisionID) { ForEach(revisions) { revision in Text(revision.date.formatted(date:.abbreviated,time:.standard)).tag(Optional(revision.id)) } }
                if let old=revisions.first(where:{$0.id==revisionID}) {
                    HStack(alignment:.top) {
                        historyText("历史内容",text:old.record.map{ReadingLibraryItem.record($0).text053} ?? old.essay.map{ReadingLibraryItem.essay($0).text053} ?? "")
                        historyText("当前内容",text:item.text053)
                    }
                    Button("备份当前内容并恢复此版本") { run {
                        let expected=journal.state;_=try await journal.makeBackup();guard journal.state==expected else { throw FolioError(message:"正文已变化，请重新核对") };journal.restoreRevision053(old);message="已恢复；恢复前版本仍在备份中"
                    } }
                } else { Text("尚无已保存的历史版本。继续编辑并自动保存后，这里会出现记录。").foregroundStyle(.secondary) }
            }
        } else { Text("请选择一条记录查看历史版本。") }
    }
    private func historyText(_ title:String,text:String)->some View { VStack(alignment:.leading) { Text(title).font(.headline);Text(text.isEmpty ? "（空白）":text).font(.system(size:16)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.topLeading) }.padding(12).background(.quaternary,in:RoundedRectangle(cornerRadius:8)) }
    @ViewBuilder private var sources:some View {
        if let source=single?.citations053.first {
            VStack(alignment:.leading,spacing:12) {
                Text("针对《"+source.title+"》修改书目信息；标注作者保持单独记录。").font(.callout)
                TextField("书名",text:$title);TextField("文献作者",text:$author)
                TextField("篇名",text:$publication.article);TextField("期刊 / 报刊",text:$publication.periodical)
                TextField("卷期",text:$publication.issue);TextField("出版日期（可按史料原文填写）",text:$publication.published);TextField("章节",text:$publication.chapter)
                Button("预览整本修改范围") { metadataPreview=journal.state;message="将修改 \(journal.state.records.filter{$0.citations.contains{ReadingBookIdentity.key($0.source.path)==ReadingBookIdentity.key(source.source.path)}}.count) 条现存记录的书目信息；引用副本另行核对更新。" }
                if let expected=metadataPreview {
                    Button("确认更新整本文献") { do { try journal.updateBookMetadata053(path:source.source.path,publication:publication,author:author,title:title,expected:expected);metadataPreview=nil;message="已更新，可以撤销批量操作" } catch { message=error.localizedDescription;metadataPreview=nil } }.disabled(title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                }
            }.textFieldStyle(.roundedBorder)
        } else { Text("请选择有出处的一条记录。") }
    }
    @ViewBuilder private var compare:some View {
        if (2...4).contains(ids.count) {
            HStack(alignment:.top,spacing:12) { ForEach(selected) { item in VStack(alignment:.leading,spacing:10) {
                Text(item.title).font(.headline);Text(item.sourceSummary).font(.caption).foregroundStyle(.secondary)
                Text(item.text053).font(.system(size:16)).textSelection(.enabled)
                ForEach(Array(item.citations053.enumerated()),id:\.offset) { _,c in Button(c.source.pageDescription+" · 查看原文") { _=store.reveal(c.source,beside:false) } }
            }.padding(12).frame(maxWidth:.infinity,alignment:.topLeading).background(.quaternary,in:RoundedRectangle(cornerRadius:8)) } }
        } else { Text("在资料库中按住 ⌘ 选择 2–4 条资料，再打开并排核对。") }
    }
    private var duplicates:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("相同原文和来源页的资料会列在一起。合并保留所有笔记、出处与引用副本，原记录移入最近删除。").foregroundStyle(.secondary)
            let groups=duplicateGroups053
            if groups.isEmpty { Text("没有发现重复资料") }
            ForEach(Array(groups.enumerated()),id:\.offset) { _,values in VStack(alignment:.leading,spacing:8) {
                ForEach(values) { r in Text(r.displayTitle+" · "+r.created.formatted(date:.abbreviated,time:.shortened));if !r.note.isEmpty { Text(r.note).font(.callout).textSelection(.enabled) } }
                Button("合并这 \(values.count) 条") { do { try journal.mergeDuplicates053(values.map(\.id));message="已合并，可撤销；原记录仍可恢复" } catch { message=error.localizedDescription } }
            }.padding(12).background(.quaternary,in:RoundedRectangle(cornerRadius:8)) }
        }
    }
    @ViewBuilder private var quotations:some View {
        if let source=single {
            VStack(alignment:.leading,spacing:14) {
                Picker("引用到笔记",selection:$destination) { Text("选择目标笔记").tag(ReadingLibraryID?.none);ForEach(ReadingWorkflow053.items(journal.state).filter{$0.kind=="笔记" && $0.id != source.id}) { item in Text(item.title).tag(Optional(item.id)) } }
                Button("插入冻结的引用副本") { if let destination { do { try journal.quote053(source,in:destination);message="已加入引用；原记录改变时，副本保持原样" } catch { message=error.localizedDescription } } }.disabled(destination==nil)
                ForEach(source.extras053.quotations ?? []) { q in
                    DisclosureGroup(q.title+" · "+q.captured.formatted(date:.abbreviated,time:.shortened)) {
                        Text(q.text).textSelection(.enabled)
                        let current=ReadingWorkflow053.items(journal.state).first{$0.id.uuid053==q.recordID && (q.targetKind==nil || $0.id.isEssay053==(q.targetKind=="essay"))}
                        if let current,current.text053 != q.text || current.citations053 != q.citations || current.modified053 != q.originalModified { Text("原记录已有修改").foregroundStyle(.orange);historyText("当前原记录",text:current.text053);Button("采用上方新版本") { do { try journal.refreshQuotation053(source.id,quotation:q.id,expected:q);message="引用副本已更新" } catch { message=error.localizedDescription } } }
                    }
                }
            }
        } else { Text("请选择一条资料，引用到另一条笔记，或核对这条笔记已有的引用。") }
    }
    private var output:some View {
        VStack(alignment:.leading,spacing:14) {
            Text("目录导出字段").font(.headline)
            LazyVGrid(columns:[GridItem(.adaptive(minimum:130))],alignment:.leading) { ForEach(ReadingCatalog053.Column.allCases,id:\.self) { c in Toggle(c.rawValue,isOn:Binding(get:{columns.contains(c)},set:{if $0 { columns.insert(c) } else { columns.remove(c) }})) } }
            HStack { Button("导出 CSV…") { exportCatalog(excel:false) };Button("导出 Excel…") { exportCatalog(excel:true) } }.disabled(columns.isEmpty || busy)
            Button("导出每条记录独立 Markdown…") { mirror(automatic:false) }.disabled(busy)
            Button("设置自动可读备份目录…") { mirror(automatic:true) }.disabled(busy)
            Button("停止自动可读备份") { do { try ReadingMirrorSettings053.disable(journal.folder);message="已停止自动备份，已有文件保留" } catch { message=error.localizedDescription } }
            Divider()
            Text("参考文献表").font(.headline)
            Text(ReadingWorkflow053.bibliography(selected).enumerated().map{"[\($0.offset+1)] "+$0.element}.joined(separator:"\n")).textSelection(.enabled)
            Button("创建升级前完整快照") { run { let backup=try await journal.makeBackup();message="快照已创建："+backup.date.formatted(date:.abbreviated,time:.shortened) } }
        }
    }
    private func run(_ action:@escaping @MainActor() async throws->Void) { guard !busy else { return };busy=true;Task { defer { busy=false };do { try await action() } catch { message=error.localizedDescription } } }
    private func exportCatalog(excel:Bool) {
        let panel=NSSavePanel();panel.nameFieldStringValue="阅读资料目录."+(excel ? "xlsx":"csv")
        guard panel.runModal() == .OK,let url=panel.url else { return }
        let expected=try? FileBaseline.capture(url),rows=selected,fields=ReadingCatalog053.Column.allCases.filter{columns.contains($0)}
        run { try await Task.detached {
            guard let expected else { throw FolioError(message:"无法检查目标文件") }
            try DocumentTaskOutput.write(to:url,expected:expected) { temp in if excel { try ReadingCatalog053.xlsx(rows,columns:fields,to:temp) } else { try Data(ReadingCatalog053.csv(rows,columns:fields).utf8).write(to:temp,options:.atomic) } }
        }.value;message="目录导出完成" }
    }
    private func mirror(automatic:Bool) {
        let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.canCreateDirectories=true;panel.message="选择保存 Markdown、图片和索引的目录"
        guard panel.runModal() == .OK,let parent=panel.url else { return }
        let state=journal.state,assets=journal.folder.appendingPathComponent("Assets"),folder=journal.folder
        run { try await journal.flush();let output=try await Task.detached { try ReadingReadable053.write(state,assets:assets,to:parent) }.value;if automatic { try ReadingMirrorSettings053.enable(parent,folder:folder);await ReadingMirrorWriter053.shared.schedule(journal.state,folder:folder) };message="已保存到 "+output.path }
    }
}

