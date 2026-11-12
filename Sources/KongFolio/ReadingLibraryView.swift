import SwiftUI

struct ReadingLibraryView: View {
    @ObservedObject var store:WorkspaceStore
    @ObservedObject var journal:ReadingJournal
    @Binding var section:ReadingDeskSection
    var compact = false
    var bookSource:ReadingCitation? = nil
    var initialItem:ReadingLibraryID? = nil
    @State private var openedInitialItem = false
    var showsDeskHeader = false
    @State private var restoredSession = false
    @State private var query = ""
    @State private var recent = false
    @State private var untagged = false
    @State private var filters:[SavedReadingFilter] = []
    @State private var selectedFilter:UUID?
    @State private var pendingFilterPage:Int?
    @State private var pendingNavigation:ReadingLibraryID?
    @State private var filterMessage = ""
    @State private var confirmBulk = false
    @State private var contextRequest:ReadingLibraryContextRequest?
    @State private var contextFocus = UUID()
    @StateObject private var sourceNavigator = ReadingSourceNavigator()
    @State private var copyGeneration = UUID()
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
    @State private var showFollowUps = false
    @State private var topicExcerpts: [ReadingRecord] = []
    @State private var showTopicNote = false
    @State private var versionPair: ReadingExcerptVersionPair?
    @State private var citationRecords: [ReadingRecord] = []
    @State private var showCitationFormat = false
    @State private var selection:Set<ReadingLibraryID> = []
    @State private var selectionOrder: [ReadingLibraryID] = []
    @State private var editing:ReadingLibraryID?
    @AppStorage("readingRecordsPageSize") private var size = 10
    @State private var items:[ReadingLibraryItem] = []
    @State private var options053=ReadingLibraryOptions053()
    @State private var showTools053=false
    @State private var searching053=false
    @State private var searchToken053=UUID()
    @State private var searchSubmission=UUID()
    @FocusState private var librarySearchFocused:Bool
    private struct SearchActivation:Equatable { var request:ReadingSearchRequest;var submission:UUID }
    private var request:ReadingSearchRequest { ReadingSearchRequest(revision:journal.revisionID,query:query,kind:kind,tag:tag,topic:topic,removed:removed,recent:recent,untagged:untagged,bookPath:bookSource?.source.path,options053:options053,indexFolder:journal.folder.path) }
    private var pagination:ReadingPagination { ReadingPagination(total:items.count,page:page,size:size) }
    var body:some View {
        observedContent
        .sheet(isPresented:$confirmBulk) { ReadingBulkConfirmation(journal:journal,ids:selection,removed:removed) { selection = [];editing = nil } }
        .sheet(item:$contextRequest) { request in
            switch request.kind {
            case .organize:ReadingOrganizationSheet(journal:journal,ids:request.ids)
            case .references:if let id = request.ids.first { ReadingReferencesView(journal:journal,id:id,openReference:{ entry in contextRequest = nil;store.openReadingReference(entry) }) }
            case .remove:ReadingBulkConfirmation(journal:journal,ids:request.ids,removed:request.removed) {
                selection.subtract(request.ids)
                if let id = editing,request.ids.contains(id) { editing = nil }
                for id in request.ids { if case .record(let uuid) = id { store.readingRecordSelection.remove(uuid);if store.readingRecordID == uuid { store.readingRecordID = nil };if store.pinnedReadingID == uuid { store.pinnedReadingID = nil } } }
            }
            }
        }
        .sheet(item:$sourceNavigator.review,onDismiss:{ sourceNavigator.cancel() }) { request in
            ReadingSourceReviewSheet(request:request,navigator:sourceNavigator,store:store).id(request.id)
        }
        .sheet(isPresented:$showOrganization) { ReadingOrganizationSheet(journal:journal,ids:selection) }
        .sheet(isPresented:$showReferences) { if let editing { ReadingReferencesView(journal:journal,id:editing,openReference:{ entry in showReferences = false;store.openReadingReference(entry) }) } }
        .sheet(isPresented:$showTags) { ReadingTagManager(journal:journal) }
        .sheet(isPresented:$showRelink) { ReadingBatchRelinkView(store:store,journal:journal) }
        .sheet(isPresented:$showTopicNote) {
            ReadingTopicNoteSheet(journal:journal,excerpts:topicExcerpts) { id in
                store.openReadingItem(.essay(id))
            }
        }
        .sheet(item:$versionPair) { ReadingExcerptVersionsSheet(journal:journal,pair:$0) }
        .sheet(isPresented:$showCitationFormat) {
            ReadingCitationClipboardSheet(records:citationRecords) { filterMessage = "已复制引文" }
        }
        .sheet(isPresented:$showFollowUps) {
            ReadingFollowUpsView(journal:journal) { item,question in
                if !store.openFollowUp(item,question:question) { filterMessage = "原句已改动，已打开对应笔记。" }
            }
        }
        .sheet(isPresented:$showBackups) { ReadingBackupView(journal:journal) }
        .sheet(isPresented:$showTools053) { ReadingTools053(store:store,journal:journal,ids:selection.isEmpty ? Set(editing.map{[$0]} ?? []):selection) }
        .onAppear {
            if let initialItem, !openedInitialItem {
                openedInitialItem = true
                navigate(initialItem)
            }
        }
        .onAppear { options053=ReadingLibraryOptions053.load(store.readingDefaults) }
        .onChange(of:options053) { _,value in page=0;value.save(store.readingDefaults) }
    }

    private var layout:some View {
        ReadingBrowserLayout(hasEditor:editing != nil,compact:compact,deskSection:showsDeskHeader ? $section : nil,onBack:{ editing = nil;selection = [] }) {
            browser
        } editor: {
            editor
        }
    }
    private var observedContent:some View {
        layout
        .task(id:SearchActivation(request:request,submission:searchSubmission)) {
            let token=UUID();searchToken053=token;searching053=true
            defer { if searchToken053==token { searching053=false } }
            let request = request
            do { try await Task.sleep(nanoseconds:300_000_000) } catch { return }
            let result = await ReadingSearchWorker.shared.library(journal.state,request:request)
            if !Task.isCancelled { items = result;if let desired = pendingFilterPage { page = ReadingPagination(total:result.count,page:desired,size:size).index;pendingFilterPage = nil };if let target = pendingNavigation,let i = result.firstIndex(where:{$0.id == target}) { page = i/size;editing = target;selection = [target];pendingNavigation = nil } }
        }
        .onAppear { if !restoredSession { restoredSession = true;if bookSource == nil && store.readingLibraryNavigation == nil { let s = ReadingLibrarySession.load(store.readingDefaults);query = s.query;kind = (s.kind == "札记" ? "笔记" : s.kind);tag = s.tag;topic = s.topic;recent = s.recent;untagged = s.untagged;removed = s.removed;pendingFilterPage = s.page;size = s.size } };do { filters = try SavedReadingFilter.load(journal.folder) } catch { filterMessage = error.localizedDescription };if bookSource == nil { if let preferred = store.readingLibraryPreferredKind { kind = preferred;store.readingLibraryPreferredKind = nil };if let target = store.readingLibraryNavigation { navigate(target) } } }
        .onChange(of:store.readingLibraryNavigationRequest) { _,_ in if bookSource == nil { if let preferred = store.readingLibraryPreferredKind { kind = preferred;store.readingLibraryPreferredKind = nil };if let target = store.readingLibraryNavigation { navigate(target) } } }
        .onDisappear { rememberPage();copyGeneration = UUID();contextFocus = UUID();sourceNavigator.cancel() }
        .onChange(of:page) { _,_ in rememberPage() }
        .onChange(of:journal.draftRecord?.id) { _,_ in validateEditing() }
        .onChange(of:journal.draftEssay?.id) { _,_ in validateEditing() }
        .onChange(of:journal.revisionID) { _,_ in validateEditing() }
        .onChange(of:recent) { _,_ in resetPage() }.onChange(of:untagged) { _,_ in resetPage() }
        .onChange(of:selection) { _,ids in
            selectionOrder = orderedSelection(ids)
            if ids.count == 1,let id = ids.first { editing = id; if case .record(let r) = id { store.readingRecordID = r;store.focusLibraryAnnotation053(r) } } }
        .onChange(of:query) { _,_ in resetPage() }.onChange(of:kind) { _,_ in resetPage() }.onChange(of:tag) { _,_ in resetPage() }.onChange(of:removed) { _,_ in resetPage() }
        .onChange(of:topic) { _,_ in resetPage() }
        .onChange(of:size) { _,_ in page = 0 }.onChange(of:items.count) { _,_ in page = pagination.index }
    }

    private var browser:some View {
        VStack(alignment:.leading,spacing:10) {
            searchField
            if searching053 { HStack { ProgressView().controlSize(.small);Text("正在检索阅读资料…").font(.caption).foregroundStyle(.secondary) } }
            HStack {
                newMenu
                Menu("待整理") {
                    Button("全部资料") { options053.triage = nil }
                    ForEach(ReadingTriage.allCases,id:\.self) { status in Button(status.rawValue) { options053.triage = status } }
                    Divider()
                    Button("待查问题…") { showFollowUps = true }
                }
                Spacer(minLength:0)
                Menu { libraryActions;Divider();organizationMenu } label:{Label("操作",systemImage:"ellipsis.circle")}
            }
            if let status = options053.triage {
                HStack {
                    Text(status.rawValue).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("完成这条，查看下一条",action:finishTriage).disabled(editing == nil || journal.unreadable)
                }
            }
            DisclosureGroup("筛选与整理") {
                ScrollView {
                VStack(alignment:.leading,spacing:8) {
                    HStack { savedFilters;Spacer() }
                    HStack { Toggle("近七天",isOn:$recent);Toggle("未加标签",isOn:$untagged) }
                    typePicker
                    TextField("按标签筛选",text:$tag).textFieldStyle(.roundedBorder)
                    topicPicker
                    Toggle("最近删除",isOn:$removed)
                    ReadingSearchControls053(options:$options053,showScope:false)
                }.padding(.top,6)
                }.frame(maxHeight:280)
            }.font(.system(size:13))
            if let checkpoint = journal.bulkCheckpoint { Button("撤销："+checkpoint.label) { do { try journal.undoBulk() } catch { filterMessage = error.localizedDescription } }.disabled(!journal.canUndoBulk) }
            if !filterMessage.isEmpty { Text(filterMessage).font(.caption).foregroundStyle(.orange) }
            itemList
            ReadingPageControls(pagination:pagination,page:$page,size:$size)
            if selection.count > 1 { Text("已选 \(selection.count) 条；删除后可在“最近删除”恢复。").font(.caption) }
        }
    }
    private var pageItems:[ReadingLibraryItem] { Array(items.dropFirst(pagination.range.lowerBound).prefix(pagination.size)) }
    private var itemList:some View {
        List(selection:Binding(get:{selection},set:{ updateSelection($0) })) {
            if options053.groupChapters {
                ForEach(Array(Set(pageItems.map(\.chapter053))).sorted(),id:\.self) { chapter in Section(chapter) { ForEach(pageItems.filter{$0.chapter053==chapter}) { item in libraryRow(item).tag(item.id) } } }
            } else { ForEach(pageItems) { item in libraryRow(item).tag(item.id) } }
        }
            .contextMenu(forSelectionType:ReadingLibraryID.self) { ids in
                ReadingLibraryContextMenu(context:ReadingLibraryContext.resolve(ids,state:journal.state,removed:removed),readOnly:journal.unreadable) { action in performContext(action,ids:ids) }
            } primaryAction:{ ids in performContext(.edit,ids:ids) }
            .accessibilityLabel("全部阅读资料")
            .overlay {
                if !searching053,!query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,items.isEmpty {
                    VStack(spacing:8) {
                        Image(systemName:"magnifyingglass").font(.title2).foregroundStyle(.secondary)
                        Text("未找到匹配的阅读资料").font(.headline)
                        Text("试试其他关键词，或展开“筛选与整理”检查条件。").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.padding().allowsHitTesting(false)
                }
            }
            .frame(minHeight:120,maxHeight:.infinity)
    }
    private func libraryRow(_ item:ReadingLibraryItem)->some View {
        VStack(alignment:.leading,spacing:4) {
            HStack(alignment:.top) {
                if let index = selectionOrder.firstIndex(of:item.id) {
                    Text("\(index+1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityLabel("第 \(index+1) 个选中")
                }
                if options053.showKind { Text(item.kind).font(.caption).foregroundStyle(.secondary).frame(width:62,alignment:.leading) }
                Text(SearchResultHighlight.text(item.title,query:query)).lineLimit(2).help(item.title).frame(maxWidth:options053.table ? options053.titleWidth:.infinity,alignment:.leading)
                if options053.table,options053.showSource { Text(item.sourceSummary).font(.caption).lineLimit(2).frame(width:options053.sourceWidth,alignment:.leading).help(item.sourceSummary) }
            }
            if !options053.table,options053.showSource,!item.sourceSummary.isEmpty { Text(item.sourceSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(item.sourceSummary) }
            if options053.groupChapters { Text(item.chapter053).font(.caption).foregroundStyle(.secondary) }
            if options053.showCreated { Text("收录 "+item.created.formatted(date:.abbreviated,time:.shortened)).font(.caption2).foregroundStyle(.secondary) }
            if options053.showModified { Text("修改 "+item.modified053.formatted(date:.abbreviated,time:.shortened)).font(.caption2).foregroundStyle(.secondary) }
            if let status = item.extras053.triage { Text(status.rawValue).font(.caption2).foregroundStyle(.orange) }
            if !query.isEmpty, let hit = ReadingTextSearch.fields(item,query:query,scope:options053.scope,exact:options053.exact,limit:1).first {
                Button {
                    selection = [item.id]
                    editing = item.id
                    store.writingSearchHit = hit
                    store.writingSearchRequest = UUID()
                } label: {
                    Text(hit.field.rawValue+" · ")+Text(SearchResultHighlight.text(hit.context,query:hit.matchedText))
                }.font(.caption).lineLimit(2).buttonStyle(.plain).foregroundStyle(.blue)
            } else if let context=item.matchingContext(query) {
                Text(SearchResultHighlight.text(context,query:query)).font(.caption).lineLimit(2)
            }
        }.onDrag { NSItemProvider(object:ReadingDrag053.text(item,assets:journal.folder.appendingPathComponent("Assets")) as NSString) }
    }
    @ViewBuilder private var editor:some View {
            if let editing {
                switch editing {
                case .record(let id):
                    if let record = journal.record(id) { ReadingSearchMatches(store:store,item:.record(record),query:query,scope:options053.scope,exact:options053.exact);LibraryRecordDetail(store:store,journal:journal,record:record,onNewLinkedNote:newLinkedNote,topPadding:showsDeskHeader ? 2 : 8).id(id).disabled(journal.unreadable || removed) }
                case .essay(let id):
                    if let essay = journal.essay(id) { ReadingSearchMatches(store:store,item:.essay(essay),query:query,scope:options053.scope,exact:options053.exact) }
                    LibraryEssayDetail(store:store,journal:journal,id:id,onExport:{section = .exports}).id(id).disabled(journal.unreadable || removed)
                }
            } else { Text("选择一条记录编辑；可统一新增、查找、导出或删除。删除后可以恢复。").font(.caption).foregroundStyle(.secondary) }
    }

    private var searchField:some View {
        VStack(alignment:.leading,spacing:8) {
            Label("搜索阅读资料",systemImage:"magnifyingglass").font(.headline)
            HStack(spacing:6) {
                TextField("摘录、标注、评论、笔记或出处关键词",text:$query)
                    .textFieldStyle(.roundedBorder).focused($librarySearchFocused)
                    .accessibilityLabel("阅读资料关键词").onSubmit(submitLibrarySearch)
                if !query.isEmpty {
                    Button { query="";librarySearchFocused=true } label:{Image(systemName:"xmark.circle.fill")}
                        .buttonStyle(.borderless).help("清空阅读资料搜索").accessibilityLabel("清空阅读资料搜索")
                }
                Button("搜索",action:submitLibrarySearch).buttonStyle(.borderedProminent)
                    .accessibilityLabel("搜索阅读资料").help("查找资料库记录；输入时也会自动更新结果")
            }
            Picker("搜索内容",selection:$options053.scope) {
                ForEach(ReadingLibraryOptions053.Scope.allCases,id:\.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.menu)
        }
    }
    private func submitLibrarySearch() {
        pendingFilterPage=nil;page=0;librarySearchFocused=true;searchSubmission=UUID()
    }
    private var newMenu:some View {
                Menu("新增") {
                    Button("摘录") { newRecord(.excerpt) }
                    Button("笔记") { newRecord(.note) }
                }.disabled(journal.unreadable)
    }
    @ViewBuilder private var libraryActions:some View {
                Button("阅读整理与输出…") { showTools053=true }
                Button("批量整理") { showOrganization = true }.disabled(selection.isEmpty || removed || journal.unreadable)
                Button("生成专题笔记…") { performContext(.topicNote,ids:selection) }.disabled(selection.isEmpty || removed || journal.unreadable)
                Button("引用关系") { showReferences = true }.disabled(editing == nil)
                Button("导出所选…") { store.prepareCheckedReadingExport(orderedSelection(selection));section = .exports }.disabled(selection.isEmpty || removed)
                Button("重新收录当前 PDF 标注与评论") { store.commandWorkspace?.scheduleReadingAnnotationImport() }.disabled(store.commandWorkspace == nil)
                Button("备份恢复") { showBackups = true }
                Button(removed ? "恢复所选" : "删除所选") { confirmBulk = true }.disabled(selection.isEmpty || journal.unreadable)
    }
    private var savedFilters:some View {
                Menu("常用筛选") {
                    Button("近七天笔记") { applyFilter(SavedReadingFilter(name:"近七天笔记",kind:"笔记",recent:true)) }
                    Button("尚未整理的记录") { applyFilter(SavedReadingFilter(name:"尚未整理",untagged:true)) }
                    Divider()
                    ForEach(filters) { value in Button(value.name) { applyFilter(value) } }
                    Divider();Button("保存当前筛选…") { saveFilter() }
                    if let selectedFilter { Button("删除当前常用筛选") { removeFilter(selectedFilter) } }
                }
    }
    private var organizationMenu:some View { Menu("资料整理") { Button("统一整理标签…") { showTags = true };Button("批量重新关联原文…") { showRelink = true } } }
    private var typePicker:some View { Picker("类型",selection:$kind) { ForEach(["全部","摘录","标注","PDF 评论","笔记"],id:\.self) { Text($0) } }.fixedSize() }
    private var topicPicker:some View { Picker("专题",selection:$topic) { Text("全部").tag("");ForEach(journal.topics,id:\.self) { Text($0).tag($0) } }.fixedSize() }

    private func updateSelection(_ ids: Set<ReadingLibraryID>) {
        selectionOrder = orderedSelection(ids)
        selection = ids
    }

    private func orderedSelection(_ ids: Set<ReadingLibraryID>) -> [ReadingLibraryID] {
        let existing = selectionOrder.filter { ids.contains($0) }
        let remaining = ids.subtracting(existing)
        let visible = items.map(\.id).filter { remaining.contains($0) }
        return existing+visible+remaining.subtracting(visible).sorted { $0.exportOrderKey < $1.exportOrderKey }
    }

    private func performContext(_ action:ReadingLibraryContextAction,ids:Set<ReadingLibraryID>) {
        switch action {
        case .newExcerpt:guard !journal.unreadable else { return };newRecord(.excerpt);return
        case .newNote:guard !journal.unreadable else { return };newRecord(.note);return
        case .newEssay:guard !journal.unreadable else { return };resetForNew();let id = newEssay();editing = .essay(id);selection = [];return
        default:break
        }
        let scope = ReadingLibraryContext.resolve(ids,state:journal.state,removed:removed)
        guard !scope.items.isEmpty else { filterMessage = "资料已变化，请重新打开右键菜单";return }
        switch action {
        case .edit:
            guard let item = scope.single else { return }
            selection = scope.ids;editing = item.id
            if case .record(let id) = item.id { store.readingRecordID = id }
            guard !scope.removed,!journal.unreadable else { return }
            let key:String
            switch item { case .record(let record):key = "note:"+record.id.uuidString;case .essay(let essay):guard let block = essay.blocks.first else { return };key = "essay:"+essay.id.uuidString+":"+block.id.uuidString }
            let token = UUID();contextFocus = token
            DispatchQueue.main.asyncAfter(deadline:.now()+0.15) { if contextFocus == token,editing == item.id { WritingRegistry.jump(key,range:WritingRegistry.selection(key) ?? NSRange(location:0,length:0)) } }
        case .copy:
            let token = UUID();copyGeneration = token;filterMessage = "正在准备复制 \(scope.items.count) 条资料…"
            Task { let text = await Task.detached(priority:.userInitiated) { scope.clipboardText() }.value;guard copyGeneration == token else { return };NSPasteboard.general.clearContents();if NSPasteboard.general.setString(text,forType:.string) { filterMessage = "已复制 \(scope.items.count) 条正文与出处" } else { filterMessage = "复制未完成，请重试" } }
        case .copyCitation:
            let text = ReadingCitationClipboardOptions.load().text(orderedExcerpts(scope))
            guard !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            filterMessage = NSPasteboard.general.setString(text,forType:.string) ? "已复制引文" : "复制未完成，请重试"
        case .citationFormat:
            citationRecords = orderedExcerpts(scope)
            if !citationRecords.isEmpty { showCitationFormat = true }
        case .topicNote:
            guard !scope.removed,!journal.unreadable,scope.excerpts.count == scope.items.count else {
                filterMessage = "请先勾选要编入专题笔记的摘录。"; return
            }
            topicExcerpts = orderedExcerpts(scope)
            showTopicNote = !topicExcerpts.isEmpty
        case .compareVersions:
            let excerpts = orderedExcerpts(scope)
            guard excerpts.count == 2,!scope.removed else { return }
            versionPair = ReadingExcerptVersionPair(left:excerpts[0].id,right:excerpts[1].id)
        case .triage(let status):
            guard !scope.removed,!journal.unreadable,scope.excerpts.count == scope.items.count else { return }
            journal.updateExtras053(scope.ids) { $0.triage = status }
            filterMessage = status.map{"已标记为"+$0.rawValue} ?? "已清除待整理标记"
        case .export:
            guard !scope.removed else { return };store.prepareCheckedReadingExport(orderedSelection(scope.ids));section = .exports
        case .organize:
            guard !scope.removed,!journal.unreadable else { return };contextRequest = ReadingLibraryContextRequest(kind:.organize,ids:scope.ids,removed:scope.removed)
        case .references:guard scope.single != nil else { return };contextRequest = ReadingLibraryContextRequest(kind:.references,ids:scope.ids,removed:scope.removed)
        case .remove:guard !journal.unreadable else { return };contextRequest = ReadingLibraryContextRequest(kind:.remove,ids:scope.ids,removed:scope.removed)
        case .source(let source):
            guard let item = scope.single, let citation = scope.sources().first(where:{$0.source == source}) else {
                filterMessage = "资料来源已变化，请重新打开菜单";return
            }
            if case .record(let record) = item { sourceNavigator.open(citation,record:record,store:store) }
            else { store.reveal(source,beside:false) }
        case .append:
            guard scope.canAppend,!journal.unreadable else { return };let id = journal.currentEssayID ?? journal.newEssay();for record in scope.records { store.insertReadingRecord(record,in:id) };store.openReadingDesk(.essays,window:true)
        case .newExcerpt,.newNote,.newEssay:break
        }
    }

    private func orderedExcerpts(_ context:ReadingLibraryContext) -> [ReadingRecord] {
        let byID = Dictionary(uniqueKeysWithValues:context.excerpts.map{($0.id,$0)})
        return orderedSelection(context.ids).compactMap { id in
            guard case .record(let recordID) = id else { return nil }
            return byID[recordID]
        }
    }

    private func finishTriage() {
        guard let editing, let index = items.firstIndex(where:{$0.id == editing}),
              items[index].extras053.triage == options053.triage else { return }
        let next = items.dropFirst(index+1).first ?? items.first(where:{$0.id != editing})
        journal.updateExtras053([editing]) {
            if $0.triage == .verify { $0.review = .verified }
            $0.triage = nil
        }
        self.editing = next?.id
        pendingNavigation = next?.id
        updateSelection(Set(next.map{[$0.id]} ?? []))
    }

    private func applyFilter(_ value:SavedReadingFilter) {
        let previous = request
        pendingFilterPage = value.page;selectedFilter = filters.contains(where:{$0.id == value.id}) ? value.id : nil
        query = value.query;kind = value.kind == "札记" ? "笔记" : value.kind;tag = value.tag;topic = value.topic;recent = value.recent;untagged = value.untagged;removed = value.removed;size = value.size
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
        guard bookSource == nil else { return }
        ReadingLibrarySession(query:query,kind:kind,tag:tag,topic:topic,recent:recent,untagged:untagged,removed:removed,page:page,size:size).save(store.readingDefaults)
        guard pendingFilterPage == nil,let id = selectedFilter,let current = filters.first(where:{$0.id == id}),current.query == query,current.kind == kind,current.tag == tag,current.topic == topic,current.recent == recent,current.untagged == untagged,current.removed == removed else { return }
        do { var values = try SavedReadingFilter.load(journal.folder);guard let i = values.firstIndex(where:{$0.id == id}) else { return };values[i].page = page;values[i].size = size;try SavedReadingFilter.save(values,folder:journal.folder);filters = values } catch { filterMessage = error.localizedDescription }
    }
    private func navigate(_ target:ReadingLibraryID) {
        let previous = request
        resetForNew();options053.triage = nil;pendingNavigation = target;editing = target;selection = []
        if case .record(let id) = target { store.readingRecordID = id }
        // A new window has no search rows yet. Keep the target until the asynchronous result installs it.
        if previous == request,let i = items.firstIndex(where:{$0.id == target}) {
            page = i/size;selection = [target];pendingNavigation = nil
        }
    }
    private var editingDraft:Bool { switch editing { case .record(let id): return journal.draftRecord?.id == id; case .essay(let id): return journal.draftEssay?.id == id; case nil: return false } }
    private func resetPage() { if pendingFilterPage == nil { page = 0 }; selection = []; if !editingDraft { editing = nil } }
    private func resetForNew() { selectedFilter = nil;pendingFilterPage = nil;recent = false;untagged = false;query = ""; tag = ""; topic = ""; kind = "全部"; removed = false; page = 0 }
    private func validateEditing() {
        guard let editing else { return }
        let valid:Bool
        switch editing {
        case .record(let id):valid = journal.record(id).map{($0.removed != nil) == removed} ?? false
        case .essay(let id):valid = journal.essay(id).map{($0.removed != nil) == removed} ?? false
        }
        if !valid { self.editing = nil;selection.remove(editing) }
    }
    private func newLinkedNote(_ source: ReadingRecord) {
        guard let record = store.prepareReadingNote(linked:source) else { return }
        resetForNew()
        selection = []
        editing = .record(record.id)
    }
    private func newEssay()->UUID { journal.beginLibraryEssay(source:bookSource) }
    private func newRecord(_ kind:ReadingRecord.Kind) { resetForNew(); let record = journal.beginLibraryRecord(kind,source:bookSource); store.readingRecordID = record.id; selection = []; editing = .record(record.id) }
}
