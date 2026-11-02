import SwiftUI

struct ReadingLibraryView: View {
    @ObservedObject var store:WorkspaceStore
    @ObservedObject var journal:ReadingJournal
    @Binding var section:ReadingDeskSection
    @State private var query = ""
    @State private var recent = false
    @State private var untagged = false
    @State private var filters:[SavedReadingFilter] = []
    @State private var selectedFilter:UUID?
    @State private var pendingFilterPage:Int?
    @State private var pendingNavigation:ReadingLibraryID?
    @State private var filterMessage = ""
    @State private var confirmBulk = false
    @State private var showTags = false
    @State private var showRelink = false
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
    @State private var items:[ReadingLibraryItem] = []
    private var request:ReadingSearchRequest { ReadingSearchRequest(revision:journal.revisionID,query:query,kind:kind,tag:tag,topic:topic,removed:removed,recent:recent,untagged:untagged) }
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
                Button("导出所选…") { store.readingLibraryExportSelection = selection;store.readingRecordSelection = Set(selection.compactMap { if case .record(let id) = $0 { return id };return nil });store.readingExportEssay = false;section = .exports }.disabled(selection.isEmpty || removed)
                Button("备份恢复") { showBackups = true }
                Button(removed ? "恢复所选" : "删除所选") { confirmBulk = true }.disabled(selection.isEmpty || journal.unreadable)
            }
            HStack {
                Menu("常用筛选") {
                    Button("近七天笔记") { applyFilter(SavedReadingFilter(name:"近七天笔记",kind:"笔记",recent:true)) }
                    Button("尚未整理的记录") { applyFilter(SavedReadingFilter(name:"尚未整理",untagged:true)) }
                    Divider()
                    ForEach(filters) { value in Button(value.name) { applyFilter(value) } }
                    Divider();Button("保存当前筛选…") { saveFilter() }
                    if let selectedFilter { Button("删除当前常用筛选") { removeFilter(selectedFilter) } }
                }
                Toggle("近七天",isOn:$recent);Toggle("未加标签",isOn:$untagged)
                Menu("资料整理") { Button("统一整理标签…") { showTags = true };Button("批量重新关联原文…") { showRelink = true } }
            }
            if let checkpoint = journal.bulkCheckpoint { Button("撤销："+checkpoint.label) { do { try journal.undoBulk() } catch { filterMessage = error.localizedDescription } }.disabled(!journal.canUndoBulk) }
            if !filterMessage.isEmpty { Text(filterMessage).font(.caption).foregroundStyle(.orange) }
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
                    if let record = journal.record(id) { ReadingSearchMatches(store:store,item:.record(record),query:query);ReadingRecordDetail(store:store,journal:journal,record:record).id(id).disabled(journal.unreadable || removed) }
                case .essay(let id):
                    if let essay = journal.essay(id) { ReadingSearchMatches(store:store,item:.essay(essay),query:query) }
                    ReadingEssayDetail(store:store,journal:journal,id:id,onExport:{section = .exports}).id(id).disabled(journal.unreadable || removed)
                }
            } else { Text("选择一条记录编辑；可统一新增、查找、导出或删除。删除后可以恢复。").font(.caption).foregroundStyle(.secondary) }
        }
        .task(id:request) {
            let request = request
            do { try await Task.sleep(nanoseconds:300_000_000) } catch { return }
            let result = await ReadingSearchWorker.shared.library(journal.state,request:request)
            if !Task.isCancelled { items = result;if let desired = pendingFilterPage { page = ReadingPagination(total:result.count,page:desired,size:size).index;pendingFilterPage = nil };if let target = pendingNavigation,let i = result.firstIndex(where:{$0.id == target}) { page = i/size;editing = target;selection = [target];pendingNavigation = nil } }
        }
        .onAppear { do { filters = try SavedReadingFilter.load(journal.folder) } catch { filterMessage = error.localizedDescription };if let target = store.readingLibraryNavigation { navigate(target) } }
        .onChange(of:store.readingLibraryNavigationRequest) { _,_ in if let target = store.readingLibraryNavigation { navigate(target) } }
        .onChange(of:page) { _,_ in rememberPage() }
        .onChange(of:recent) { _,_ in resetPage() }.onChange(of:untagged) { _,_ in resetPage() }
        .onChange(of:selection) { _,ids in if ids.count == 1,let id = ids.first { editing = id; if case .record(let r) = id { store.readingRecordID = r } } }
        .onChange(of:query) { _,_ in resetPage() }.onChange(of:kind) { _,_ in resetPage() }.onChange(of:tag) { _,_ in resetPage() }.onChange(of:removed) { _,_ in resetPage() }
        .onChange(of:topic) { _,_ in resetPage() }
        .onChange(of:size) { _,_ in page = 0 }.onChange(of:items.count) { _,_ in page = pagination.index }
        .sheet(isPresented:$confirmBulk) { ReadingBulkConfirmation(journal:journal,ids:selection,removed:removed) { selection = [];editing = nil } }
        .sheet(isPresented:$showOrganization) { ReadingOrganizationSheet(journal:journal,ids:selection) }
        .sheet(isPresented:$showReferences) { if let editing { ReadingReferencesView(journal:journal,id:editing,open:{ target in showReferences = false;store.openReadingItem(target) }) } }
        .sheet(isPresented:$showTags) { ReadingTagManager(journal:journal) }
        .sheet(isPresented:$showRelink) { ReadingBatchRelinkView(store:store,journal:journal) }
        .sheet(isPresented:$showBackups) { ReadingBackupView(journal:journal) }
    }

    private func applyFilter(_ value:SavedReadingFilter) {
        let previous = request
        pendingFilterPage = value.page;selectedFilter = filters.contains(where:{$0.id == value.id}) ? value.id : nil
        query = value.query;kind = value.kind;tag = value.tag;topic = value.topic;recent = value.recent;untagged = value.untagged;removed = value.removed;size = value.size
        selection = [];editing = nil
        if previous == request { page = ReadingPagination(total:items.count,page:value.page,size:size).index;pendingFilterPage = nil }
    }
    private func saveFilter() {
        guard let name = TextPrompt.ask("保存常用筛选",detail:"保存关键词、类型、标签、专题和当前分页位置",button:"保存"),!name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return }
        do { var values = try SavedReadingFilter.load(journal.folder);let value = SavedReadingFilter(name:name,query:query,kind:kind,tag:tag,topic:topic,recent:recent,untagged:untagged,removed:removed,page:page,size:size);values.append(value);try SavedReadingFilter.save(values,folder:journal.folder);filters = values;selectedFilter = value.id;filterMessage = "已保存筛选" } catch { filterMessage = error.localizedDescription }
    }
    private func removeFilter(_ id:UUID) {
        do { var values = try SavedReadingFilter.load(journal.folder);values.removeAll{$0.id == id};try SavedReadingFilter.save(values,folder:journal.folder);filters = values;selectedFilter = nil } catch { filterMessage = error.localizedDescription }
    }
    private func rememberPage() {
        guard pendingFilterPage == nil,let id = selectedFilter,let current = filters.first(where:{$0.id == id}),current.query == query,current.kind == kind,current.tag == tag,current.topic == topic,current.recent == recent,current.untagged == untagged,current.removed == removed else { return }
        do { var values = try SavedReadingFilter.load(journal.folder);guard let i = values.firstIndex(where:{$0.id == id}) else { return };values[i].page = page;values[i].size = size;try SavedReadingFilter.save(values,folder:journal.folder);filters = values } catch { filterMessage = error.localizedDescription }
    }
    private func navigate(_ target:ReadingLibraryID) {
        let previous = request
        resetForNew();pendingNavigation = target;editing = target;selection = []
        if case .record(let id) = target { store.readingRecordID = id }
        // A new window has no search rows yet. Keep the target until the asynchronous result installs it.
        if previous == request,let i = items.firstIndex(where:{$0.id == target}) {
            page = i/size;selection = [target];pendingNavigation = nil
        }
    }
    private var editingDraft:Bool { switch editing { case .record(let id): return journal.draftRecord?.id == id; case .essay(let id): return journal.draftEssay?.id == id; case nil: return false } }
    private func resetPage() { if pendingFilterPage == nil { page = 0 }; selection = []; if !editingDraft { editing = nil } }
    private func resetForNew() { selectedFilter = nil;pendingFilterPage = nil;recent = false;untagged = false;query = ""; tag = ""; topic = ""; kind = "全部"; removed = false; page = 0 }
    private func newRecord(_ kind:ReadingRecord.Kind) { resetForNew(); let record = ReadingRecord(kind:kind); journal.beginNote(record); store.readingRecordID = record.id; selection = []; editing = .record(record.id) }
}
