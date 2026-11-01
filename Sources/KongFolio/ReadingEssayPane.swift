import SwiftUI

struct ReadingEssayPane: View {
    @ObservedObject var store:WorkspaceStore
    @ObservedObject var journal:ReadingJournal
    @State private var query = ""
    @State private var page = 0
    @AppStorage("readingRecordsPageSize") private var pageSize = 10
    private var current:ReadingEssay? { journal.essay(journal.currentEssayID) }
    @State private var essays:[ReadingEssay] = []
    private var pagination: ReadingPagination { ReadingPagination(total: essays.count, page: page, size: pageSize) }
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack { TextField("查找札记文字、书名或标签",text:$query); Button("新建札记") { page = 0; query = ""; _ = journal.newEssay() }.disabled(journal.unreadable) }
            List(Array(essays.dropFirst(pagination.range.lowerBound).prefix(pagination.size))) { essay in
                Button { journal.selectEssay(essay.id) } label: { Text(essay.title).lineLimit(2).help(essay.title).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle()) }.buttonStyle(.plain)
                    .listRowBackground(journal.currentEssayID == essay.id ? Color.accentColor.opacity(0.12) : .clear)
            }.frame(minHeight:80,maxHeight:current == nil ? 260 : 140).accessibilityLabel("札记列表")
            ReadingPageControls(pagination:pagination,page:$page,size:$pageSize)
            if let essay = current { ReadingEssayDetail(store:store,journal:journal,id:essay.id).id(essay.id) }
            else { Spacer(); Text("把摘录与自己的思考写成一篇札记").foregroundStyle(.secondary); Spacer() }
        }.task(id:ReadingSearchRequest(revision:journal.revisionID,query:query)) {
            do { try await Task.sleep(nanoseconds:300_000_000) } catch { return }
            let values = await ReadingSearchWorker.shared.essays(journal.state,query:query)
            if !Task.isCancelled { essays = values }
        }.onChange(of:query) { _,_ in page = 0 }.onChange(of:pageSize) { _,_ in page = 0 }
        .onChange(of:essays.count) { _,_ in page = pagination.index }
        .onChange(of:journal.draftEssay?.id) { _,id in if id != nil { page = 0; query = "" } }
    }
}
