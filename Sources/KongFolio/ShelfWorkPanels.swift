import SwiftUI
import PDFKit

struct ShelfImportRequest: Identifiable {
    let id = UUID()
    let drafts: [ShelfImportDraft]
}

struct ShelfImportReview: View {
    @Environment(\.dismiss) private var dismiss
    @State private var drafts:[ShelfImportDraft]
    @State private var chosen:Set<URL>
    @State private var batchPeriodical = ""
    @State private var batchTopic = ""
    @State private var page = 0
    let existing: [LibraryBook]
    let onImport: ([ShelfImportDraft]) -> Void

    init(request:ShelfImportRequest,existing:[LibraryBook] = [],onImport:@escaping ([ShelfImportDraft])->Void) {
        _drafts = State(initialValue:request.drafts)
        _chosen = State(initialValue:Set(request.drafts.map(\.id)))
        self.existing = existing
        self.onImport = onImport
    }

    var body:some View {
        let pagination = ReadingPagination(total:drafts.count,page:page,size:20)
        let warnings = ShelfImportAudit.warnings(drafts,chosen:chosen,existing:existing)
        let knownNames = Array(Set(existing.map{$0.issueMetadata.periodical}.filter{!$0.isEmpty})).sorted()
        VStack(alignment:.leading,spacing:12) {
            Text("核对要加入书架的文献").font(.headline)
            Text("书名、刊名、年代和期次来自文件名，可在添加前修改。").font(.caption).foregroundStyle(.secondary)
            PanelRow {
                TextField("统一刊名",text:$batchPeriodical).frame(width:165)
                if !knownNames.isEmpty {
                    Menu("沿用书架刊名") {
                        ForEach(knownNames,id:\.self) { name in Button(name) { batchPeriodical = name } }
                    }
                }
                TextField("批量加入专题",text:$batchTopic).frame(width:165)
                Button("应用到所选") { applyBatch() }.disabled(chosen.isEmpty || (batchPeriodical.isEmpty && batchTopic.isEmpty))
            }
            if !warnings.isEmpty {
                Label("\(warnings.count) 份需要核对",systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            List(Array(pagination.range),id:\.self) { index in
                let id = drafts[index].id
                VStack(alignment:.leading,spacing:6) {
                    HStack {
                        Toggle("选择 "+drafts[index].title,isOn:Binding(get:{chosen.contains(id)},set:{ value in
                            if value { chosen.insert(id) } else { chosen.remove(id) }
                        })).labelsHidden()
                        StableTextField("书名",text:$drafts[index].title)
                    }
                    PanelRow {
                        StableTextField("刊名",text:$drafts[index].periodical).frame(width:150)
                        StableTextField("年代",text:$drafts[index].year).frame(width:70)
                        StableTextField("卷",text:$drafts[index].volume).frame(width:60)
                        StableTextField("期",text:$drafts[index].issue).frame(width:60)
                        StableTextField("专题",text:$drafts[index].topic).frame(width:110)
                    }
                    if let issues = warnings[id] {
                        Text(issues.joined(separator:" · ")).font(.caption).foregroundStyle(.orange)
                    }
                    Text(id.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(id.path)
                }.padding(.vertical,4)
            }
            PanelRow {
                Button("全选") { chosen = Set(drafts.map(\.id)) }
                Button("取消选择") { chosen.removeAll() }
                Button("上一页") { page -= 1 }.disabled(page == 0)
                Text(pagination.label).font(.caption)
                Button("下一页") { page += 1 }.disabled(page >= pagination.last)
            }
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("添加所选 \(chosen.count) 份") {
                    let values = drafts.filter{chosen.contains($0.id)}
                    dismiss()
                    onImport(values)
                }.buttonStyle(.borderedProminent).disabled(chosen.isEmpty)
            }
        }.padding(20).adaptiveSheet(width:780,height:590,minimumWidth:360)
    }

    private func applyBatch() {
        for index in drafts.indices where chosen.contains(drafts[index].id) {
            if !batchPeriodical.isEmpty { drafts[index].periodical = batchPeriodical }
            if !batchTopic.isEmpty { drafts[index].topic = batchTopic }
        }
    }
}

struct ShelfFileFacts {
    let name: String
    let status: ShelfFileStatus
    let pages: Int?
    let cover: Data?

    static func read(_ url:URL, knownPages:Int? = nil) async -> Self {
        let status = ShelfFileStatus.read(url)
        let pdf = status == .available && url.pathExtension.lowercased() == "pdf" ? PDFDocument(url:url) : nil
        let count = pdf.flatMap{!$0.isLocked && $0.pageCount > 0 ? $0.pageCount : nil} ?? knownPages
        let thumbnail = status == .available ? (try? await LibraryCoverLoader.shared.load(url)) : nil
        return Self(name:url.lastPathComponent,status:status,pages:count,cover:thumbnail)
    }
}

struct ShelfCompareFiles: View {
    let original: LibraryBook
    let candidate: URL
    let knownPages: Int?
    var detail = ""
    var confirm: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var first: ShelfFileFacts?
    @State private var second: ShelfFileFacts?
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("核对文献文件").font(.headline)
            if !detail.isEmpty { Text(detail).foregroundStyle(.secondary) }
            HStack(alignment:.top,spacing:16) {
                column("书架中的文件", facts:first)
                Divider()
                column("待核对文件", facts:second)
            }
            HStack {
                Button("关闭") { dismiss() }
                Spacer()
                if let confirm { Button("确认关联") { confirm();dismiss() }.disabled(second == nil) }
            }
        }.padding(20).adaptiveSheet(width:660,height:480,minimumWidth:360)
        .task {
            let path = URL(fileURLWithPath:original.path)
            let job = Task.detached(priority:.utility) {
                async let a = ShelfFileFacts.read(path,knownPages:knownPages)
                async let b = ShelfFileFacts.read(candidate)
                return await (a,b)
            }
            let result = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            guard !Task.isCancelled else { return }
            (first,second) = result
        }
    }

    private func column(_ title:String,facts:ShelfFileFacts?) -> some View {
        VStack(alignment:.leading,spacing:6) {
            Text(title).font(.subheadline.weight(.semibold))
            if let facts {
                Text(facts.name).lineLimit(2).help(facts.name)
                Text(facts.pages.map{"\($0) 页"} ?? "页数不可用").font(.caption)
                if let cover = facts.cover, let image = NSImage(data:cover) {
                    Image(nsImage:image).resizable().scaledToFit().frame(maxHeight:230)
                } else { Text(facts.status.label ?? "首页不可预览").font(.caption).foregroundStyle(.secondary) }
            } else { ProgressView().controlSize(.small) }
        }.frame(maxWidth:.infinity,alignment:.topLeading)
    }
}

struct ShelfFileIssues: View {
    let books:[LibraryBook]
    let progress:[String:ReadingProgress]
    let relink:(LibraryBook)->Void
    @Environment(\.dismiss) private var dismiss
    @State private var issues:[Entry] = []
    @State private var loading = true
    @State private var page = 0
    @State private var comparison: Comparison?

    private struct Entry: Identifiable {
        let book: LibraryBook
        let status: ShelfFileStatus
        let versions: [LibraryBook]
        var id: UUID { book.id }
    }
    private struct Comparison: Identifiable {
        let id = UUID()
        let original: LibraryBook
        let candidate: LibraryBook
    }
    var body:some View {
        let pagination = ReadingPagination(total:issues.count,page:page,size:20)
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text("需要处理的文件").font(.headline)
                Spacer()
                Button("完成") { dismiss() }
            }
            if loading { ProgressView("正在检查文件位置…") }
            else if issues.isEmpty { Text("当前书架没有需要处理的文件。").foregroundStyle(.secondary) }
            List(Array(issues[pagination.range])) { entry in
                HStack {
                    VStack(alignment:.leading,spacing:4) {
                        Text(entry.book.title).font(.callout.weight(.semibold)).lineLimit(1).help(entry.book.title)
                        if let label = entry.status.label { Text(label).font(.caption).foregroundStyle(.orange) }
                        if !entry.versions.isEmpty { Text("有 \(entry.versions.count) 份疑似其他版本").font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if !entry.versions.isEmpty {
                        Menu("对照版本") {
                            ForEach(entry.versions) { candidate in
                                Button(URL(fileURLWithPath:candidate.path).lastPathComponent) {
                                    comparison = Comparison(original:entry.book,candidate:candidate)
                                }
                            }
                        }.fixedSize()
                    }
                    if entry.status == .missing { Button("重新定位…") { dismiss();relink(entry.book) } }
                    if entry.status == .cloud {
                        Button("请求下载") { download(entry.book) }
                    }
                }
            }
            HStack {
                Text("\(issues.count) 项").font(.caption)
                Spacer()
                Button("上一页") { page -= 1 }.disabled(page == 0)
                Text(pagination.label).font(.caption)
                Button("下一页") { page += 1 }.disabled(page >= pagination.last)
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
        }.padding(20).adaptiveSheet(width:720,height:560,minimumWidth:360)
        .task {
            let job = Task.detached(priority:.utility) { () -> [Entry] in
                let versions = ShelfText.versions(books)
                var values:[Entry] = []
                for book in books {
                    if Task.isCancelled { break }
                    let status = ShelfFileStatus.read(URL(fileURLWithPath:book.path))
                    let others = versions[book.id] ?? []
                    if status != .available || !others.isEmpty { values.append(Entry(book:book,status:status,versions:others)) }
                }
                return values
            }
            let values = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            guard !Task.isCancelled else { return }
            issues = values
            loading = false
        }
        .sheet(item:$comparison) { pair in
            ShelfCompareFiles(original:pair.original,candidate:URL(fileURLWithPath:pair.candidate.path),
                              knownPages:progress[pair.original.path]?.pages,detail:"核对首页与页数，书架会分别保留这两份文献。")
        }
    }
    @State private var message = ""
    private func download(_ book:LibraryBook) {
        Task {
            do {
                let url = URL(fileURLWithPath:book.path)
                try await Task.detached(priority:.utility) { try FileManager.default.startDownloadingUbiquitousItem(at:url) }.value
                message = "已请求下载 "+book.title
            } catch { message = error.localizedDescription }
        }
    }
}
