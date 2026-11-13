import SwiftUI

enum ReadingExcerptReviewQueue {
    static func records(_ state:ReadingJournalState,paths:Set<String>) -> [ReadingRecord] {
        guard !paths.isEmpty else { return [] }
        return state.records.filter { record in
            record.isExcerpt && record.removed == nil && record.hasContent &&
                (record.extras?.review == nil || record.extras?.review == .unreviewed) &&
                record.citations053.contains{paths.contains(ReadingBookIdentity.key($0.source.path))}
        }.sorted { $0.created == $1.created ? $0.id.uuidString < $1.id.uuidString : $0.created < $1.created }
    }
}

struct ReadingExcerptReviewPane: View {
    enum Scope: String, CaseIterable { case book = "本书", batch = "本批" }
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var journal: ReadingJournal
    let initialPath: String?
    let batchPaths: Set<String>
    let close: () -> Void
    @StateObject private var navigator = ReadingSourceNavigator()
    @State private var scope = Scope.book
    @State private var selection: UUID?
    private struct Correction: Identifiable {
        let record:ReadingRecord
        let segment:UUID?
        var id:UUID { segment ?? record.id }
    }
    @State private var editing: Correction?
    @State private var page = 0
    @State private var deferred = Set<UUID>()
    @State private var lastJudgment: Judgment?
    private struct Judgment {
        let id:UUID
        let status:ReadingRecordExtras053.Review
        let previous:ReadingRecordExtras053.Review?
    }

    private var paths: Set<String> {
        scope == .batch ? batchPaths : Set(initialPath.map{[ReadingBookIdentity.key($0)]} ?? [])
    }
    private var pending: [ReadingRecord] { ReadingExcerptReviewQueue.records(journal.state,paths:paths) }
    private var queue: [ReadingRecord] { pending.filter{!deferred.contains($0.id)} }

    var body: some View {
        let records = queue
        let pagination = ReadingPagination(total:records.count,page:page,size:10)
        VStack(alignment:.leading,spacing:8) {
            header(records.count)
            if let record = records.first(where:{$0.id == selection}) { details(record) }
            if records.isEmpty {
                Text(pending.isEmpty ? "这个范围暂无待核对的摘录。" : "剩余摘录已暂时跳过。").font(.caption).foregroundStyle(.secondary)
                Spacer()
            } else {
                List(Array(records[pagination.range])) { record in
                    Button { open(record) } label:{
                        VStack(alignment:.leading,spacing:3) {
                            Text(record.displayTitle).lineLimit(2)
                            Text(citation(for:record)?.display ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }.frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).listRowBackground(record.id == selection ? Color.accentColor.opacity(0.13) : Color.clear)
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
            .onAppear { if initialPath == nil && !batchPaths.isEmpty { scope = .batch } }
            .onChange(of:scope) { _,_ in navigator.cancel(); selection = nil; page = 0; deferred = [] }
            .onChange(of:pagination.last) { _,last in if page > last { page = last } }
            .onDisappear { navigator.cancel() }
            .sheet(item:$editing) { request in
                ReadingQuoteCorrectionView(journal:journal,record:request.record,segmentID:request.segment)
            }
            .sheet(item:$navigator.review) { ReadingSourceReviewSheet(request:$0,navigator:navigator,store:store).id($0.id) }
    }

    private func header(_ count:Int) -> some View {
        VStack(alignment:.leading,spacing:6) {
            HStack {
                Text("摘录核对 · \(count) 条").font(.headline)
                Spacer()
                Button("返回摘录",action:close)
            }
            if !deferred.isEmpty || lastJudgment != nil {
                PanelRow {
                    if !deferred.isEmpty {
                        Button("重看跳过的 \(deferred.count) 条") { deferred = [];page = 0 }
                    }
                    if lastJudgment != nil { Button("撤销上次判断",action:undoJudgment).disabled(journal.unreadable || navigator.busy) }
                }.font(.caption)
            }
            Picker("核对范围",selection:$scope) {
                Text(Scope.book.rawValue).tag(Scope.book).disabled(initialPath == nil)
                Text(Scope.batch.rawValue).tag(Scope.batch).disabled(batchPaths.isEmpty)
            }.pickerStyle(.segmented)
        }
    }

    private func details(_ record:ReadingRecord) -> some View {
        VStack(alignment:.leading,spacing:7) {
            Text(record.quote.isEmpty ? record.displayTitle : record.quote).font(.callout)
                .lineLimit(5).textSelection(.enabled)
            if navigator.busy { ProgressView().controlSize(.small) }
            correctionControl(record).disabled(journal.unreadable || navigator.busy)
            PanelRow {
                Button("已核对并继续") { advance(record,status:.verified) }.buttonStyle(.borderedProminent)
                Button("存疑并继续") { advance(record,status:.uncertain) }
                Button("暂时跳过") { advance(record,status:nil) }
            }.disabled(journal.unreadable || navigator.busy)
        }.padding(8).background(.quaternary,in:RoundedRectangle(cornerRadius:6))
    }

    @ViewBuilder private func correctionControl(_ record:ReadingRecord) -> some View {
        if let segments = record.excerptSegments {
            Menu("校订段落…") {
                ForEach(Array(segments.enumerated()),id:\.element.id) { index,segment in
                    Button("第 \(index+1) 段") { editing = Correction(record:record,segment:segment.id) }
                }
            }
        } else if !record.quote.isEmpty {
            Button("校订文字…") { editing = Correction(record:record,segment:nil) }
        }
    }

    private func citation(for record:ReadingRecord) -> ReadingCitation? {
        record.citations053.first{paths.contains(ReadingBookIdentity.key($0.source.path))}
    }

    private func open(_ record:ReadingRecord) {
        guard let citation = citation(for:record) else { return }
        selection = record.id
        navigator.open(citation,record:record,store:store)
    }

    private func advance(_ record:ReadingRecord,status:ReadingRecordExtras053.Review?) {
        let records = queue
        let next = records.firstIndex(where:{$0.id == record.id}).flatMap { index in
            records.dropFirst(index+1).first ?? records.first{$0.id != record.id}
        }
        if let status {
            lastJudgment = Judgment(id:record.id,status:status,previous:record.extras?.review)
            journal.updateExtras053([.record(record.id)]) { $0.review = status }
        } else { deferred.insert(record.id) }
        selection = nil
        if let next {
            if let index = queue.firstIndex(where:{$0.id == next.id}) { page = index/10 }
            open(next)
        }
    }
    private func undoJudgment() {
        guard let lastJudgment else { return }
        self.lastJudgment = nil
        guard let record = journal.record(lastJudgment.id),record.removed == nil,
              record.extras?.review == lastJudgment.status else { return }
        journal.updateExtras053([.record(lastJudgment.id)]) { $0.review = lastJudgment.previous }
        if let index = queue.firstIndex(where:{$0.id == lastJudgment.id}) {
            page = index/10
            open(record)
        }
    }

}
