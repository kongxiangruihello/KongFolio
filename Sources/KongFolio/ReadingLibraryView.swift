import SwiftUI

struct ReadingLibraryView: View {
    @ObservedObject var store:WorkspaceStore
    @ObservedObject var journal:ReadingJournal
    @Binding var section:ReadingDeskSection
    @State private var query = ""
    @State private var kind = "全部"
    @State private var tag = ""
    @State private var removed = false
    @State private var page = 0
    @State private var topic = ""
    @State private var showOrganization = false
    @State private var showReferences = false
    @State private var showBackups = false
    @State private var selection:Set<ReadingLibraryID> = []
    @State private var editing:ReadingLibraryID?
    @AppStorage("readingRecordsPageSize") private var size = 10
    private var items:[ReadingLibraryItem] { ReadingLibraryItem.results(journal.state,query:query,kind:kind,tag:tag,removed:removed).filter { topic.isEmpty || $0.tags.contains("专题："+topic) } }
    private var pagination:ReadingPagination { ReadingPagination(total:items.count,page:page,size:size) }
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {
                TextField("搜索全部摘录、笔记、札记和出处",text:$query).textFieldStyle(.roundedBorder)
                Menu("新增") {
                    Button("摘录") { newRecord(.excerpt) }
                    Button("笔记") { newRecord(.note) }
                    Button("札记") { resetForNew(); let id = journal.newEssay(); editing = .essay(id); selection = [] }
                }.disabled(journal.unreadable)
                Button("批量整理") { showOrganization = true }.disabled(selection.isEmpty || removed || journal.unreadable)
                Button("引用关系") { showReferences = true }.disabled(editing == nil)
                Button("备份恢复") { showBackups = true }
                Button(removed ? "恢复所选" : "删除所选") { journal.setRemoved(selection,removed:!removed); selection = []; editing = nil }.disabled(selection.isEmpty || journal.unreadable)
            }
            HStack {
                Picker("类型",selection:$kind) { ForEach(["全部","摘录","图片摘录","笔记","札记"],id:\.self) { Text($0) } }.fixedSize()
                TextField("按标签筛选",text:$tag)
                Picker("专题",selection:$topic) { Text("全部").tag(""); ForEach(journal.topics,id:\.self) { Text($0).tag($0) } }.fixedSize()
                Toggle("最近删除",isOn:$removed)
            }
            List(selection:$selection) { ForEach(Array(items.dropFirst(pagination.range.lowerBound).prefix(pagination.size))) { item in
                HStack { Text(item.kind).font(.caption).foregroundStyle(.secondary).frame(width:62,alignment:.leading); Text(item.title).lineLimit(2).help(item.title) }.tag(item.id)
            } }.frame(minHeight:100,maxHeight:editing == nil ? .infinity : 190).accessibilityLabel("全部阅读资料")
            ReadingPageControls(pagination:pagination,page:$page,size:$size)
            if selection.count > 1 { Text("已选 \(selection.count) 条；删除后可在“最近删除”恢复。").font(.caption) }
            if let editing {
                switch editing {
                case .record(let id):
                    if let record = journal.record(id) { ReadingRecordDetail(store:store,journal:journal,record:record).id(id).disabled(journal.unreadable || removed) }
                case .essay(let id):
                    ReadingEssayDetail(store:store,journal:journal,id:id,onExport:{section = .exports}).id(id).disabled(journal.unreadable || removed)
                }
            } else { Text("选择一条记录编辑；可统一新增、查找、导出或删除。删除后可以恢复。").font(.caption).foregroundStyle(.secondary) }
        }
        .onChange(of:selection) { _,ids in if ids.count == 1,let id = ids.first { editing = id; if case .record(let r) = id { store.readingRecordID = r } } }
        .onChange(of:query) { _,_ in resetPage() }.onChange(of:kind) { _,_ in resetPage() }.onChange(of:tag) { _,_ in resetPage() }.onChange(of:removed) { _,_ in resetPage() }
        .onChange(of:topic) { _,_ in resetPage() }
        .onChange(of:size) { _,_ in page = 0 }.onChange(of:items.count) { _,_ in page = pagination.index }
        .sheet(isPresented:$showOrganization) { ReadingOrganizationSheet(journal:journal,ids:selection) }
        .sheet(isPresented:$showReferences) { if let editing { ReadingReferencesView(journal:journal,id:editing) } }
        .sheet(isPresented:$showBackups) { ReadingBackupView(journal:journal) }
    }
    private var editingDraft:Bool { switch editing { case .record(let id): return journal.draftRecord?.id == id; case .essay(let id): return journal.draftEssay?.id == id; case nil: return false } }
    private func resetPage() { page = 0; selection = []; if !editingDraft { editing = nil } }
    private func resetForNew() { query = ""; tag = ""; topic = ""; kind = "全部"; removed = false; page = 0 }
    private func newRecord(_ kind:ReadingRecord.Kind) { resetForNew(); let record = ReadingRecord(kind:kind); journal.beginNote(record); store.readingRecordID = record.id; selection = []; editing = .record(record.id) }
}
