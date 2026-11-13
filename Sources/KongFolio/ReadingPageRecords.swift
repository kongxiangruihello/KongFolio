import SwiftUI

enum ReadingPageRecords {
    static func items(_ state:ReadingJournalState,path:String,page:Int) -> [ReadingLibraryItem] {
        let key = ReadingBookIdentity.key(path)
        guard !key.isEmpty else { return [] }
        return ReadingLibraryItem.results(state).filter { item in
            let citations:[ReadingCitation]
            if case .record(let record) = item {
                guard record.isExcerpt || record.kind == .note else { return false }
                citations = record.wholeBook ? record.citations.filter{record.isInlineNoteCitation($0)} : item.citations053
            } else { citations = item.citations053 }
            return citations.contains { citation in
                citation.source.invalidPage053 != true && citation.source.page == page &&
                    ReadingBookIdentity.key(citation.source.path) == key
            }
        }
    }
}

struct ReadingPageRecordsPane: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var workspace: Workspace
    @ObservedObject var journal: ReadingJournal
    let close: () -> Void
    @State private var page = 0
    @State private var items:[ReadingLibraryItem] = []

    var body: some View {
        let pagination = ReadingPagination(total:items.count,page:page,size:10)
        VStack(alignment:.leading,spacing:9) {
            HStack {
                Text("本页记录 · 第 \(workspace.selection+1) 页").font(.headline)
                Spacer()
                Button("返回",action:close)
            }
            if items.isEmpty {
                Text("本页暂无摘录或笔记。").foregroundStyle(.secondary)
                Spacer()
            } else {
                List(Array(items[pagination.range])) { item in
                    Button {
                        close()
                        store.openPageReadingItem(item)
                    } label: {
                        VStack(alignment:.leading,spacing:4) {
                            Text(item.title).lineLimit(2)
                            Text(item.kind).font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                HStack {
                    Button("上一页") { page -= 1 }.disabled(pagination.index == 0)
                    Spacer()
                    Text(pagination.label)
                    Spacer()
                    Button("下一页") { page += 1 }.disabled(pagination.index >= pagination.last)
                }.font(.caption)
            }
        }.padding(10)
            .task(id:Request(path:workspace.readingJournalPath ?? "",page:workspace.selection,revision:journal.revisionID)) {
                let state = journal.state
                let path = workspace.readingJournalPath ?? ""
                let selection = workspace.selection
                let values = await Task.detached(priority:.userInitiated) { ReadingPageRecords.items(state,path:path,page:selection) }.value
                guard !Task.isCancelled else { return }
                items = values
                page = min(page,ReadingPagination(total:values.count,page:page,size:10).last)
            }
            .onChange(of:workspace.selection) { _,_ in page = 0; items = [] }
    }

    private struct Request:Equatable {
        let path:String
        let page:Int
        let revision:Int
    }
}

extension WorkspaceStore {
    func openPageReadingItem(_ item:ReadingLibraryItem) {
        switch item {
        case .record(let record):
            if record.isExcerpt {
                revealCapturedExcerpt(record,message:"已打开本页摘录",opensEditor:true)
            } else {
                pinnedReadingID = nil
                showReadingPanel(.notes,noteID:record.id)
            }
        case .essay: openReadingItem(item.id)
        }
    }
}
