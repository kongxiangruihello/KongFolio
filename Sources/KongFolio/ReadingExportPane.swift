import SwiftUI
import UniformTypeIdentifiers

struct ReadingExportPane: View {
    typealias Scope = ReadingExportScope
    @ObservedObject var store:WorkspaceStore
    @ObservedObject var journal:ReadingJournal
    @StateObject private var controller = ReadingExportController()
    @State private var scope = Scope.selected
    @State private var preferences = ReadingExportPreferences.load()
    @State private var profiles = ReadingExportProfile.load()
    @State private var lastExport = ReadingExportProfile.lastSuccessful()
    @State private var pendingSort: ReadingExportOrdering.Sort?
    @State private var temporarySort: ReadingExportOrdering.Sort?
    private var sort: ReadingExportOrdering.Sort { temporarySort ?? preferences.sort ?? .date }
    private var sortSelection: Binding<ReadingExportOrdering.Sort> {
        Binding(get:{sort},set:{ value in
            if value == .manual || value == .selection { temporarySort = value }
            else { temporarySort = nil; preferences.sort = value }
            page = 0
        })
    }
    @State private var order:[String] = []
    @State private var excluded:Set<String> = []
    @State private var page = 0
    @State private var showBatch = false
    @State private var showReview = false
    @State private var showIncremental = false
    @State private var preparation: Task<Void,Never>?
    private var preparing: Bool { preparation != nil }
    private var format:ReadingRecordExport.Format { preferences.format }
    private var candidates:[ReadingExportItem] {
        if scope == .essay { guard let essay = journal.essay(journal.currentEssayID),journal.draftEssay?.id != essay.id,essay.hasContent else { return [] };return [.essay(essay)] }
        let ids = store.readingRecordSelection.isEmpty ? Set(store.readingRecordID.map{[$0]} ?? []) : store.readingRecordSelection
        let records = journal.state.records.filter { r in r.hasContent && r.removed == nil && (scope == .library || (scope == .selected ? (ids.contains(r.id) || store.readingLibraryExportSelection.contains(.record(r.id))) : (store.commandWorkspace?.readingJournalPath.map { ReadingLibraryItem.record(r).isFromBook($0) } ?? false))) }.map(ReadingExportItem.record)
        let essays = journal.state.essays.filter { e in e.hasContent && e.removed == nil && (scope == .library || (scope == .selected && store.readingLibraryExportSelection.contains(.essay(e.id))) || (scope == .book && (store.commandWorkspace?.readingJournalPath.map { ReadingLibraryItem.essay(e).isFromBook($0) } ?? false))) }.map(ReadingExportItem.essay)
        let selectedOrder = (store.readingLibraryExportOrder.isEmpty ?
            store.readingRecordSelectionOrder.map(ReadingLibraryID.record) : store.readingLibraryExportOrder).map(\.exportOrderKey)
        var items = ReadingExportOrdering.sorted(records+essays,by:sort,selection:selectedOrder)
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
        VStack(alignment:.leading,spacing:10) {
            ScrollView {
                VStack(alignment:.leading,spacing:14) {
                    HStack {
                        Text("内容与格式").font(.headline)
                        Spacer()
                        Menu("套用模板") {
                            if let lastExport { Button("上次成功导出的设置") { apply(lastExport) }; Divider() }
                            ForEach(ReadingExportProfile.presets+profiles) { profile in Button(profile.name) { apply(profile) } }
                        }
                    }
                    settings
                    DisclosureGroup("核对导出清单 · \(snapshot.orderedItems.count)/\(candidates.count) 项") { selectionList }
                    DisclosureGroup("版式与模板") {
                        layoutSettings
                        ReadingExportStructureView(options:$preferences.options)
                    }
                    Divider()
                    previewSection
                }.padding(.trailing,8)
            }
            Divider()
            footer
        }.onAppear {
            scope = store.readingExportEssay ? .essay : ((!store.readingLibraryExportSelection.isEmpty || store.readingRecordID != nil || !store.readingRecordSelection.isEmpty) ? .selected : (store.commandWorkspace?.readingJournalPath == nil ? .library : .book))
            if scope == .selected { temporarySort = .selection }
        }
        .onDisappear { preparation?.cancel(); controller.close() }.onChange(of:preferences) { _,value in value.save() }
         .onChange(of:scope) { _,value in
            page = 0; excluded = []; order = []
            temporarySort = value == .selected ? .selection : nil
            if let pendingSort { sortSelection.wrappedValue = pendingSort; self.pendingSort = nil }
        }.onChange(of:candidates.count) { _,_ in page = pagination.index }
        .sheet(isPresented:$showReview) { ReadingOutputReviewView(store:store,snapshot:snapshot,assets:assets) }
        .sheet(isPresented:$showIncremental) { ReadingIncrementalExportView(journal:journal,controller:store.incrementalExport,options:preferences.options) }
        .sheet(isPresented:$showBatch) { ReadingExportBatchView(store:store,journal:journal,snapshot:snapshot) }
    }
    private var assets:URL { journal.folder.appendingPathComponent("Assets") }
    private var previewSection: some View {
        VStack(alignment:.leading,spacing:8) {
            ViewThatFits(in:.horizontal) {
                HStack { Text("核对与预览").font(.headline); Spacer(); reviewActions }
                VStack(alignment:.leading,spacing:8) { Text("核对与预览").font(.headline); reviewActions }
            }
            let summary = ReadingExportOrdering.summary(snapshot)
            if summary.items > 0 {
                Text("\(summary.items) 项 · "+sort.rawValue+" · \(summary.images) 张图片")
                    .font(.callout)
                if !preferences.options.includeSources {
                    Text("成稿不附出处").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("无出处 \(summary.missingSources) 项 · 出处待核对 \(summary.sourcesToReview) 项")
                        .font(.caption).foregroundStyle(summary.missingSources + summary.sourcesToReview > 0 ? Color.orange : Color.secondary)
                }
            }
            ForEach(ReadingExportOrdering.warnings(snapshot),id:\.self) { warning in
                Text(warning).font(.caption).foregroundStyle(.orange)
            }
            if previewCurrent, let file = controller.previewURL {
                AcademicFilePreview(url:file).frame(height:320).clipped()
            } else {
                Text(empty ? "没有可导出的资料，请更换范围或勾选记录。" :
                     format == .word ? "Word 导出前，请生成预览并核对内容。" : "可先生成预览，也可直接导出。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var reviewActions: some View {
        HStack {
            Button("检查图片与出处…") { showReview = true }
            Button(previewCurrent ? "刷新预览" : "生成预览",action:preview)
                .disabled(!preferences.options.valid)
        }.disabled(empty || controller.busy || preparing)
    }

    private var footer: some View {
        VStack(alignment:.leading,spacing:8) {
            if !controller.message.isEmpty {
                Text(controller.message).font(.caption).lineLimit(2).textSelection(.enabled)
            }
            ViewThatFits(in:.horizontal) {
                HStack { Text("\(snapshot.orderedItems.count) 项 · "+format.rawValue).font(.callout);Spacer();saveActions }
                VStack(alignment:.trailing,spacing:6) {
                    Text("\(snapshot.orderedItems.count) 项 · "+format.rawValue).font(.callout)
                    saveActions
                }.frame(maxWidth:.infinity,alignment:.trailing)
            }
        }
    }

    private var saveActions: some View {
        HStack {
            if preparing || controller.busy { ProgressView().controlSize(.small) }
            if controller.busy { Button("取消") { controller.cancel() } }
            Menu("更多导出") {
                Button("批量导出或资料包…") { showBatch = true }.disabled(empty || !preferences.options.valid)
                Button("仅导出新增与修改…") { showIncremental = true }
                if let file = controller.lastExportURL {
                    Divider()
                    Button("打开刚导出的文件") { NSWorkspace.shared.open(file) }
                }
            }.disabled(preparing || controller.busy)
            Button("选择位置并导出…",action:export)
                .buttonStyle(.borderedProminent)
                .disabled(empty || !preferences.options.valid || preparing || controller.busy || (format == .word && !previewCurrent))
        }
    }

    private var settings:some View {
        VStack(alignment:.leading,spacing:8) {
            Picker("导出范围",selection:$scope) {
                ForEach(Scope.allCases,id:\.self) { Text($0.rawValue).tag($0) }
            }
            Picker("导出格式",selection:$preferences.format) {
                ForEach(ReadingRecordExport.Format.allCases,id:\.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            Picker("顺序",selection:sortSelection) {
                ForEach(ReadingExportOrdering.Sort.allCases.filter { $0 != .selection || scope == .selected },id:\.self) { Text($0.rawValue).tag($0) }
            }
            Toggle("原文（含图片）",isOn:$preferences.options.includeQuote)
            Toggle("我的笔记",isOn:$preferences.options.includeNote)
            Toggle("出处",isOn:$preferences.options.includeSources)
        }
    }

    private var layoutSettings: some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {
                Menu("管理模板") { ForEach(profiles) { profile in Button("删除："+profile.name) { do { let updated = profiles.filter{$0.id != profile.id};try ReadingExportProfile.save(updated);profiles = updated } catch { controller.message = error.localizedDescription } } } }.disabled(profiles.isEmpty)
                Button("保存模板…") { if let name = TextPrompt.ask("保存导出模板",detail:"保存格式、字体、版式、内容顺序与出处选项",button:"保存"),!name.isEmpty { do { var updated = profiles;updated.append(ReadingExportProfile(name:name,format:preferences.format,options:preferences.options,scope:scope,sort:reusableSort));try ReadingExportProfile.save(updated);profiles = updated } catch { controller.message = error.localizedDescription } } }
            }
            HStack {
                Picker("字体",selection:$preferences.options.fontName) { Text("宋体").tag("Songti SC");Text("苹方").tag("PingFang SC");Text("Times New Roman").tag("Times New Roman") }
                Stepper("字号 \(Int(preferences.options.fontSize))",value:$preferences.options.fontSize,in:8...36,step:1)
            }
            DisclosureGroup("行距与页边距") {
                HStack { Stepper("行距 "+String(format:"%.1f",preferences.options.lineHeight ?? 1.4),value:Binding(get:{preferences.options.lineHeight ?? 1.4},set:{preferences.options.lineHeight = $0}),in:1...2.5,step:0.1);Stepper("页边距 \(Int(preferences.options.margin ?? 70.87)) 点",value:Binding(get:{preferences.options.margin ?? 70.87},set:{preferences.options.margin = $0}),in:20...120,step:5) }
            }
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
    private func move(_ id:String,_ delta:Int) { var ids = candidates.map(\.id);guard let i = ids.firstIndex(of:id),ids.indices.contains(i+delta) else { return };ids.swapAt(i,i+delta);order = ids;temporarySort = .manual }
    private var reusableSort: ReadingExportOrdering.Sort? { sort == .manual ? nil : sort }

    private func apply(_ profile:ReadingExportProfile) {
        preferences.options = profile.options
        if let format = profile.format { preferences.format = format }
        let available = profile.scope != .book || store.commandWorkspace?.readingJournalPath != nil
        let hasEssay = profile.scope != .essay || journal.essay(journal.currentEssayID)?.hasContent == true
        if let target = profile.scope, available && hasEssay && target != scope {
            pendingSort = profile.sort
            scope = target
        } else if let sort = profile.sort, sort != .selection || scope == .selected {
            sortSelection.wrappedValue = sort
        }
        if !available { controller.message = "打开要导出的 PDF 后，可切换到当前书的全部记录。" }
    }

    private func preview() {
        let value = snapshot, kind = format
        withSavedRecords {
            controller.preview(value,assets:assets,format:kind)
        }
    }

    private func export() {
        let value = snapshot, kind = format
        let profile = ReadingExportProfile(name:"上次成功导出",format:kind,options:preferences.options,scope:scope,sort:reusableSort)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension:kind.ext) ?? .data]
        panel.directoryURL = preferences.directoryURL
        panel.nameFieldStringValue = ReadingExportJobs.filename(value.title)+"."+kind.ext
        guard panel.runModal() == .OK, let url = panel.url else { return }
        preferences.directoryPath = url.deletingLastPathComponent().path
        preferences.save()
        do {
            let baseline = try FileBaseline.capture(url)
            withSavedRecords {
                controller.export(value,format:kind,assets:assets,to:url,expected:baseline) {
                    profile.rememberSuccessful()
                    lastExport = profile
                }
            }
        } catch { controller.message = error.localizedDescription }
    }

    private func withSavedRecords(_ operation: @escaping @MainActor () -> Void) {
        guard preparation == nil else { return }
        preparation = Task {
            defer { preparation = nil }
            do {
                try await journal.flush()
                try Task.checkCancellation()
                operation()
            } catch {
                if !FolioCancellation.matches(error) { controller.message = error.localizedDescription }
            }
        }
    }
}
