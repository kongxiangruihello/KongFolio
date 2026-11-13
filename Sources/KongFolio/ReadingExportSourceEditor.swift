import SwiftUI
import UniformTypeIdentifiers

struct ReadingExportSourceTarget: Equatable {
    let item: ReadingLibraryID
    let block: UUID?
    let index: Int

    @MainActor func record(in journal:ReadingJournal) -> ReadingRecord? {
        switch journal.libraryItem053(item) {
        case .record(let record): return record
        case .essay(let essay): return essay.blocks.first{$0.id == block}?.record
        case nil: return nil
        }
    }

    @MainActor func apply(_ citation:ReadingCitation,replacing expected:ReadingCitation?,in journal:ReadingJournal) throws {
        guard !journal.unreadable, let record = record(in:journal),
              record.citations.indices.contains(index) ? record.citations[index] == expected : index == record.citations.count && expected == nil else {
            throw FolioError(message:"这条出处已改变，请回到核对列表重新打开")
        }
        func update(_ record:inout ReadingRecord) {
            if record.citations.indices.contains(index) {
                let previous = record.citations[index]
                record.citations[index] = citation
                record.replaceInlineCitation(previous,with:citation)
            }
            else { record.citations.append(citation) }
        }
        switch item {
        case .record(let id): journal.editRecord(id,update)
        case .essay(let id):
            journal.editEssay(id) { essay in
                guard let i = essay.blocks.firstIndex(where:{$0.id == block}),var copy = essay.blocks[i].record else { return }
                update(&copy)
                essay.blocks[i].record = copy
            }
        }
    }
}

extension ReadingExportSnapshot {
    @MainActor func refreshed(in journal:ReadingJournal) -> Self {
        var result = self
        result.records = records.compactMap { record in
            guard case .record(let current) = journal.libraryItem053(.record(record.id)) else { return nil }
            return current
        }
        result.essay = essay.flatMap { essay in
            guard case .essay(let current) = journal.libraryItem053(.essay(essay.id)) else { return nil }
            return current
        }
        result.essays = essays?.compactMap { essay in
            guard case .essay(let current) = journal.libraryItem053(.essay(essay.id)) else { return nil }
            return current
        }
        return result
    }
}

struct ReadingExportSourceEditor: View {
    @ObservedObject var journal: ReadingJournal
    let target: ReadingExportSourceTarget
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var original: ReadingCitation?
    @State private var draft = ReadingCitation(source:SourceRef(path:"",fileName:"",page:0),title:"")
    @State private var page = "1"
    @State private var error = ""
    @State private var pickedPDF = false
    @State private var saving = false
    @State private var work: Task<Void,Never>?

    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("修正出处").font(.title2.bold())
            StableTextField("书名",text:$draft.title)
            StableTextField("作者",text:$draft.author)
            StableTextField("版本／卷次",text:Binding(get:{draft.edition ?? ""},set:{draft.edition=$0.isEmpty ? nil : $0}))
            HStack {
                StableTextField("PDF 页码",text:$page)
                StableTextField("印刷页码",text:Binding(get:{draft.source.pageLabel ?? ""},set:{draft.source.pageLabel=$0.isEmpty ? nil : $0}))
            }
            HStack {
                Text(draft.source.path.isEmpty ? "尚未关联 PDF" : draft.source.fileName).lineLimit(1).help(draft.source.path)
                Spacer()
                Button("重新定位 PDF…",action:choosePDF).disabled(saving)
            }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { work?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存出处",action:save).buttonStyle(.borderedProminent).disabled(saving)
            }
        }.padding(22).adaptiveSheet(width:550,height:370,minimumWidth:360)
            .onAppear {
                let citations = target.record(in:journal)?.citations ?? []
                if citations.indices.contains(target.index) {
                    original = citations[target.index]
                    draft = citations[target.index]
                    page = String(draft.source.page+1)
                }
            }
            .onDisappear { work?.cancel() }
    }

    private func choosePDF() {
        let panel = DocumentOpenPanel.files()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        DocumentOpenPanel.coordinator.present(panel,presentation:.separate) { _,urls in
            guard let url = urls.first else { return }
            pickedPDF = true
            draft.source.path = url.path
            draft.source.fileName = url.lastPathComponent
            if draft.title.isEmpty { draft.title = url.deletingPathExtension().lastPathComponent }
            error = ""
        }
    }

    private func save() {
        guard let index = Int(page.trimmingCharacters(in:.whitespaces)),index > 0,index <= 100_000,
              !draft.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {
            error = "请填写书名和有效的 PDF 页码";return
        }
        guard !draft.source.path.isEmpty else { error = "请先选择原文 PDF";return }
        var updated = draft
        updated.source.page = index-1
        let changed = pickedPDF || original == nil || original?.source.page != updated.source.page || original?.source.path != updated.source.path
        error = ""
        saving = true
        work = Task {
            defer { saving = false; work = nil }
            do {
                if changed {
                    let url = URL(fileURLWithPath:updated.source.path)
                    let worker = Task.detached(priority:.userInitiated) {
                        try await CloudFilePreparation.prepare([url]) { _ in }
                        return try PDFImportProbe053.inspect(url)
                    }
                    let facts = try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
                    guard index <= facts.pages else { throw FolioError(message:"原文只有 \(facts.pages) 页，请修改页码") }
                    updated.source.fingerprint = facts.digest
                    updated.source.rects = []
                    updated.source.anchor = nil
                    updated.source.invalidPage053 = nil
                    updated.source.relativePath = nil
                    updated.tracking = nil
                }
                try Task.checkCancellation()
                try target.apply(updated,replacing:original,in:journal)
                onSave()
                dismiss()
            } catch where FolioCancellation.matches(error) {} catch { self.error = error.localizedDescription }
        }
    }
}
