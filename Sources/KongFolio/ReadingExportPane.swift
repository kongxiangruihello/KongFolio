import SwiftUI
import UniformTypeIdentifiers

struct ReadingExportPane: View {
    enum Scope:String,CaseIterable { case selected = "所选资料",book = "当前书的全部记录",essay = "当前笔记",library = "全部阅读资料" }
    @ObservedObject var store:WorkspaceStore
    @ObservedObject var journal:ReadingJournal
    @StateObject private var controller = ReadingExportController()
    @State private var scope = Scope.selected
    @State private var preferences = ReadingExportPreferences.load()
    @State private var profiles = ReadingExportProfile.load()
    @State private var useManualOrder = false
    private var sort: ReadingExportOrdering.Sort { useManualOrder ? .manual : (preferences.sort ?? .date) }
    private var sortSelection: Binding<ReadingExportOrdering.Sort> {
        Binding(get:{sort},set:{ value in
            useManualOrder = value == .manual
            if !useManualOrder { preferences.sort = value }
            page = 0
        })
    }
    @State private var order:[String] = []
    @State private var excluded:Set<String> = []
    @State private var page = 0
    @State private var showBatch = false
    @State private var showReview = false
    @State private var showIncremental = false
    private var format:ReadingRecordExport.Format { preferences.format }
    private var candidates:[ReadingExportItem] {
        if scope == .essay { guard let essay = journal.essay(journal.currentEssayID),journal.draftEssay?.id != essay.id,essay.hasContent else { return [] };return [.essay(essay)] }
        let ids = store.readingRecordSelection.isEmpty ? Set(store.readingRecordID.map{[$0]} ?? []) : store.readingRecordSelection
        let records = journal.state.records.filter { r in r.hasContent && r.removed == nil && (scope == .library || (scope == .selected ? (ids.contains(r.id) || store.readingLibraryExportSelection.contains(.record(r.id))) : (store.commandWorkspace?.readingJournalPath.map { ReadingLibraryItem.record(r).isFromBook($0) } ?? false))) }.map(ReadingExportItem.record)
        let essays = journal.state.essays.filter { e in e.hasContent && e.removed == nil && (scope == .library || (scope == .selected && store.readingLibraryExportSelection.contains(.essay(e.id))) || (scope == .book && (store.commandWorkspace?.readingJournalPath.map { ReadingLibraryItem.essay(e).isFromBook($0) } ?? false))) }.map(ReadingExportItem.essay)
        var items = ReadingExportOrdering.sorted(records+essays,by:sort)
        if sort == .manual { let positions = Dictionary(order.enumerated().map{($0.element,$0.offset)},uniquingKeysWith:min);items = items.enumerated().sorted{(positions[$0.element.id] ?? Int.max,$0.offset)<(positions[$1.element.id] ?? Int.max,$1.offset)}.map(\.element) }
        return items
    }
    private var snapshot:ReadingExportSnapshot {
        let items = candidates.filter{!excluded.contains($0.id)}
        let records = items.compactMap { if case .record(let r) = $0 { return r };return nil }
        let essays = items.compactMap { if case .essay(let e) = $0 { return e };return nil }
        let title = scope == .essay ? (essays.first?.title ?? "笔记") : (scope == .book ? (store.commandWorkspace?.title ?? "文献")+" · 阅读笔记" : "阅读资料")
        return ReadingExportSnapshot(title:title,records:records,essays:essays.isEmpty ? nil : essays,order:items.map(\.id),options:preferences.options)
    }
    private var empty:Bool { snapshot.orderedItems.isEmpty }
    private var pagination:ReadingPagination { ReadingPagination(total:candidates.count,page:page,size:10) }
    private var previewCurrent:Bool { controller.previewDigest == snapshot.digest && controller.previewFormat == format }
    var body:some View {
        GeometryReader { proxy in
        let settingsHeight = min(420,max(130,proxy.size.height*0.55))
        VStack(alignment:.leading,spacing:10) {
            ScrollView {
            VStack(alignment:.leading,spacing:10) {
            settings
            DisclosureGroup("导出清单 · 已选 \(snapshot.orderedItems.count)/\(candidates.count) 项") { selectionList }
            HStack { Button("检查图片、原文与出处…") { showReview = true }.disabled(empty || controller.busy);Button("新增与修改内容导出…") { showIncremental = true } }
            ForEach(ReadingExportOrdering.warnings(snapshot),id:\.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("刷新实际预览") { controller.preview(snapshot,assets:assets,format:format) }.disabled(empty || !preferences.options.valid || controller.busy)
                Button("导出文件…",action:export).disabled(empty || !preferences.options.valid || controller.busy || (format == .word && !previewCurrent))
                Button("批量／资料包…") { showBatch = true }.disabled(empty || !preferences.options.valid)
                if controller.busy { ProgressView().controlSize(.small);Button("取消") { controller.cancel() } }
            }
            ReadingExportStructureView(options:$preferences.options)
            }
            }.frame(height:settingsHeight)
            if let file = controller.previewURL { AcademicFilePreview(url:file).frame(height:max(80,proxy.size.height-settingsHeight-70)).clipped() }
            else { Text("可预览实际生成的 Word、PDF 或 Markdown。Word 请先核对实际预览；PDF 和 Markdown 可直接导出。").foregroundStyle(.secondary).frame(maxWidth:.infinity,maxHeight:.infinity) }
            if controller.previewURL != nil && !previewCurrent { Text("内容、顺序或格式已变化，请刷新预览。Word 导出前需要当前预览。").font(.caption).foregroundStyle(.orange) }
            HStack { Text(controller.message).font(.caption).lineLimit(2).textSelection(.enabled);if let file = controller.lastExportURL { Button("打开刚导出的文件") { NSWorkspace.shared.open(file) }.font(.caption) } }
        }.frame(width:proxy.size.width,height:proxy.size.height,alignment:.topLeading)
        }.onAppear { scope = store.readingExportEssay ? .essay : ((!store.readingLibraryExportSelection.isEmpty || store.readingRecordID != nil || !store.readingRecordSelection.isEmpty) ? .selected : .book) }
        .onDisappear { controller.close() }.onChange(of:preferences) { _,value in value.save() }
        .onChange(of:scope) { _,_ in page = 0;excluded = [];order = [] }.onChange(of:candidates.count) { _,_ in page = pagination.index }
        .sheet(isPresented:$showReview) { ReadingOutputReviewView(store:store,snapshot:snapshot,assets:assets) }
        .sheet(isPresented:$showIncremental) { ReadingIncrementalExportView(journal:journal,controller:store.incrementalExport,options:preferences.options) }
        .sheet(isPresented:$showBatch) { ReadingExportBatchView(store:store,journal:journal,snapshot:snapshot) }
    }
    private var assets:URL { journal.folder.appendingPathComponent("Assets") }
    private var settings:some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {
                Picker("导出范围",selection:$scope) { ForEach(Scope.allCases,id:\.self) { Text($0.rawValue).tag($0) } }
                Menu("套用模板") { ForEach(ReadingExportProfile.presets+profiles) { profile in Button(profile.name) { preferences.options = profile.options;if let format = profile.format { preferences.format = format } } } }
                Menu("管理模板") { ForEach(profiles) { profile in Button("删除："+profile.name) { do { let updated = profiles.filter{$0.id != profile.id};try ReadingExportProfile.save(updated);profiles = updated } catch { controller.message = error.localizedDescription } } } }.disabled(profiles.isEmpty)
                Button("保存模板…") { if let name = TextPrompt.ask("保存导出模板",detail:"保存格式、字体、版式、内容顺序与出处选项",button:"保存"),!name.isEmpty { do { var updated = profiles;updated.append(ReadingExportProfile(name:name,format:preferences.format,options:preferences.options));try ReadingExportProfile.save(updated);profiles = updated } catch { controller.message = error.localizedDescription } } }
            }
            Picker("排列",selection:sortSelection) {
                ForEach(ReadingExportOrdering.Sort.allCases,id:\.self) { Text($0.rawValue).tag($0) }
            }
            Picker("导出格式",selection:$preferences.format) { ForEach(ReadingRecordExport.Format.allCases,id:\.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            HStack {
                Picker("字体",selection:$preferences.options.fontName) { Text("宋体").tag("Songti SC");Text("苹方").tag("PingFang SC");Text("Times New Roman").tag("Times New Roman") }
                Stepper("字号 \(Int(preferences.options.fontSize))",value:$preferences.options.fontSize,in:8...36,step:1)
            }
            DisclosureGroup("行距与页边距") {
                HStack { Stepper("行距 "+String(format:"%.1f",preferences.options.lineHeight ?? 1.4),value:Binding(get:{preferences.options.lineHeight ?? 1.4},set:{preferences.options.lineHeight = $0}),in:1...2.5,step:0.1);Stepper("页边距 \(Int(preferences.options.margin ?? 70.87)) 点",value:Binding(get:{preferences.options.margin ?? 70.87},set:{preferences.options.margin = $0}),in:20...120,step:5) }
            }
            HStack { Toggle("原文（含图片）",isOn:$preferences.options.includeQuote);Toggle("我的笔记／论述",isOn:$preferences.options.includeNote);Toggle("出处",isOn:$preferences.options.includeSources) }
            Toggle("Word 出处使用脚注",isOn:Binding(get:{preferences.options.footnotes ?? false},set:{preferences.options.footnotes = $0})).disabled(!preferences.options.includeSources)
            Text("设置会自动记住。字体和版式用于 Word／PDF；脚注用于 Word，其他格式保留正文出处。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var selectionList:some View {
        VStack(alignment:.leading,spacing:6) {
            ForEach(Array(candidates.dropFirst(pagination.range.lowerBound).prefix(pagination.size))) { item in
                HStack { Toggle(item.title,isOn:Binding(get:{!excluded.contains(item.id)},set:{if $0 { excluded.remove(item.id) } else { excluded.insert(item.id) }})).lineLimit(1).help(item.title);Spacer();Button("上移") { move(item.id,-1) };Button("下移") { move(item.id,1) } }.font(.caption)
            }
            HStack { Text("第 \(pagination.index+1)/\(pagination.last+1) 页");Spacer();Button("上一页") { page = max(0,page-1) }.disabled(pagination.index == 0);Button("下一页") { page += 1 }.disabled(pagination.index>=pagination.last) }.font(.caption)
        }
    }
    private func move(_ id:String,_ delta:Int) { var ids = candidates.map(\.id);guard let i = ids.firstIndex(of:id),ids.indices.contains(i+delta) else { return };ids.swapAt(i,i+delta);order = ids;useManualOrder = true }
    private func export() {
        let panel = NSSavePanel();panel.allowedContentTypes = [UTType(filenameExtension:format.ext) ?? .data];panel.directoryURL = preferences.directoryURL;panel.nameFieldStringValue = ReadingExportJobs.filename(snapshot.title)+"."+format.ext
        guard panel.runModal() == .OK,let url = panel.url else { return }
        preferences.directoryPath = url.deletingLastPathComponent().path;preferences.save()
        let value = snapshot,kind = format,assets = assets
        do { let baseline = try FileBaseline.capture(url);Task { do { try await journal.flush();controller.export(value,format:kind,assets:assets,to:url,expected:baseline) } catch { controller.message = error.localizedDescription } } } catch { controller.message = error.localizedDescription }
    }
}
