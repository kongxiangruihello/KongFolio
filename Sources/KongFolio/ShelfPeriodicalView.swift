import SwiftUI

struct ReaderShelfIssue {
    let book: LibraryBook
    let key: ShelfIssueKey
    let current: ShelfPeriodicalIndex.Issue
    let previous: ShelfPeriodicalIndex.Issue?
    let next: ShelfPeriodicalIndex.Issue?

    init?(books:[LibraryBook],path:String) {
        let identity = ReadingBookIdentity.key(path)
        guard let book = books.first(where:{ReadingBookIdentity.key($0.path) == identity}),
              let key = ShelfIssueKey(book.issueMetadata) else { return nil }
        let index = ShelfPeriodicalIndex(books,publication:book.issueMetadata.periodical)
        guard let current = index.issues.first(where:{$0.id == key}) else { return nil }
        let neighbors = index.neighbors(of:book)
        self.book = book; self.key = key; self.current = current
        previous = neighbors.previous; next = neighbors.next
    }

    var heading: String {
        let year = key.year.isEmpty ? nil : key.year+" 年"
        let volume = key.volume.isEmpty ? nil : "第 "+key.volume+" 卷"
        return [book.issueMetadata.periodical,year,volume,"第 "+key.issue+" 期"].compactMap{$0}.joined(separator:" · ")
    }
}

struct ShelfIssueActions: View {
    let info: ReaderShelfIssue
    @ObservedObject var store: WorkspaceStore
    var body: some View {
        Text(info.heading)
        if let edition = info.book.shelfEdition { Text(edition.rawValue) }
        if info.book.shelfPreferredEdition == true { Text("本期首选版本") }
        Divider()
        move("上一期",issue:info.previous)
        move("下一期",issue:info.next)
        if info.current.editions.count > 1 {
            Menu("本期其他版本") {
                ForEach(info.current.editions.filter{$0.id != info.book.id}) { edition in
                    Button(edition.title+" · "+(edition.shelfEdition?.rawValue ?? "未标记版本")) { store.openShelfIssue(edition) }
                        .disabled(store.shelfQueueOpening)
                }
            }
        }
    }

    @ViewBuilder private func move(_ title:String,issue:ShelfPeriodicalIndex.Issue?) -> some View {
        if let issue {
            Button(title+" · 第 "+issue.id.issue+" 期") { store.openShelfIssue(issue.preferred) }.disabled(store.shelfQueueOpening)
            if let gap = info.key.missingIssues(toward:issue.id) { Text(gap+"，跳到已有期次") }
        } else { Button(title) {}.disabled(true) }
    }
}

struct ShelfPeriodicalOverview: View {
    let publication: String
    let index: ShelfPeriodicalIndex
    let progress: [String:ReadingProgress]
    let summaries: [String:ShelfRecordSummary]
    let open: (LibraryBook) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedGroup: ShelfPeriodicalIndex.Group.Key?
    @State private var page = 0

    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text(publication+" · 刊物总览").font(.title2).fontWeight(.semibold)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if index.groups.isEmpty {
                ContentUnavailableView("尚无可排序的期次",systemImage:"newspaper")
            } else {
                Picker("跳到年代和卷册",selection:$selectedGroup) {
                    ForEach(index.groups) { group in Text(group.title).tag(Optional(group.id)) }
                }
                if let group = index.groups.first(where:{$0.id == selectedGroup}) ?? index.groups.first {
                    issueList(group)
                }
            }
        }.padding(20).adaptiveSheet(width:780,height:620,minimumWidth:360)
            .onAppear { selectedGroup = index.groups.first?.id }
            .onChange(of:selectedGroup) { _,_ in page = 0 }
    }

    private func issueList(_ group:ShelfPeriodicalIndex.Group) -> some View {
        let pagination = ReadingPagination(total:group.issues.count,page:page,size:20)
        let issues = group.issues
        let latest = issues.flatMap(\.editions).compactMap{progress[$0.path]?.date}.max()
        let excerptIssues = issues.filter{excerptCount($0) > 0}.count
        return VStack(alignment:.leading,spacing:8) {
            Text("共 \(issues.count) 期 · \(excerptIssues) 期有摘录"+(latest.map{" · 最近阅读 "+$0.formatted(date:.abbreviated,time:.omitted)} ?? ""))
                .foregroundStyle(.secondary)
            List(Array(issues[pagination.range])) { issue in
                HStack {
                    VStack(alignment:.leading,spacing:4) {
                        Text("第 "+issue.id.issue+" 期 · "+issue.preferred.title).lineLimit(1)
                        Text("摘录 \(excerptCount(issue)) 条 · \(issue.editions.count) 个版本").font(.caption).foregroundStyle(.secondary)
                        if let date = issue.editions.compactMap({progress[$0.path]?.date}).max() {
                            Text("最近阅读 "+date.formatted(date:.abbreviated,time:.shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("打开") { open(issue.preferred) }.buttonStyle(.borderless)
                }.padding(.vertical,4)
            }
            HStack {
                Button("上一页") { page -= 1 }.disabled(pagination.index == 0)
                Text(pagination.label)
                Button("下一页") { page += 1 }.disabled(pagination.index >= pagination.last)
            }.font(.caption)
        }
    }

    private func excerptCount(_ issue:ShelfPeriodicalIndex.Issue) -> Int {
        issue.editions.reduce(0) { count,book in
            count+(summaries[ReadingBookIdentity.key(book.path)]?.counts["摘录",default:0] ?? 0)
        }
    }
}

struct ShelfScopeExport: Identifiable {
    let id = UUID()
    let title: String
    let paths: Set<String>
}

struct ShelfScopeExportView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var journal: ReadingJournal
    let request: ShelfScopeExport
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text("导出书架范围内的阅读记录").font(.title2).fontWeight(.semibold)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ReadingExportPane(store:store,journal:journal,shelfScope:request)
        }.padding(20).adaptiveSheet(width:900,height:720,minimumWidth:360)
    }
}
