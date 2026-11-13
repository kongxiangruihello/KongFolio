import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct ReadingSourceReview: Identifiable {
    let id = UUID()
    let recordID: UUID
    let citation: ReadingCitation
    let quote: String
    let inspection: ReadingSourceInspection?
    let message: String
}

@MainActor final class ReadingSourceNavigator: ObservableObject {
    @Published var review: ReadingSourceReview?
    @Published private(set) var busy = false
    private var job: Task<Void,Never>?
    private var generation = UUID()

    func open(_ citation: ReadingCitation, record: ReadingRecord, store: WorkspaceStore, reviewOnly: Bool = false) {
        cancel()
        review = nil
        let original = citation.source
        if TextImport.handles(URL(fileURLWithPath:original.path)), !original.path.isEmpty {
            store.reveal(original,beside:false)
            return
        }
        let resolved = ReadingDocumentRegistry053.shared(store.storage).resolve(original.path,documentID:citation.tracking?.documentID)
        let path = store.library.resolve(ReadingShortcut(path:resolved,title:original.fileName,position:original.position)).path
        let workspace = store.tabs.compactMap(\.workspace).first { $0.count > 0 && $0.matches(path:path) }
        if !reviewOnly, ReadingBookIdentity.key(path) == ReadingBookIdentity.key(original.path),
           let workspace, !workspace.dirty, workspace.fileBaseline?.digest != nil,
           workspace.fileBaseline?.digest == original.fingerprint, original.invalidPage053 != true,
           citation.tracking?.needsReview != true, workspace.document.page(at:original.page) != nil {
            var source = original
            source.path = path
            if !source.rects.isEmpty { source.anchor = nil }
            else if let anchor = source.anchor, let page = workspace.document.page(at:source.page) {
                source.rects = ReadingSourceRecovery.passageRects(page,anchor:anchor)
                if !source.rects.isEmpty { source.anchor = nil }
            }
            if !source.rects.isEmpty || (source.anchor == nil && record.quote.isEmpty) {
                store.reveal(source,beside:false)
                return
            }
        }
        let seed = ReadingSourceReview(recordID:record.id,citation:citation,quote:record.quote,inspection:nil,message:"")
        guard !path.isEmpty, FileManager.default.fileExists(atPath:path) || workspace != nil else {
            review = ReadingSourceReview(recordID:record.id,citation:citation,quote:record.quote,inspection:nil,message:"找不到原文件，请选择它现在的位置。")
            return
        }
        inspect(URL(fileURLWithPath:path),seed:seed,store:store,reviewOnly:reviewOnly,workspace:workspace)
    }

    func inspect(_ url: URL, seed: ReadingSourceReview, store: WorkspaceStore, reviewOnly: Bool = true, workspace: Workspace? = nil) {
        cancel()
        let token = generation
        busy = true
        job = Task { [weak self] in
            defer { if self?.generation == token { self?.busy = false } }
            do {
                var input = ReadingSourceInput(url:url)
                if let workspace {
                    input.revision = workspace.revision
                    input.workspaceID = workspace.id
                    input.storedDigest = workspace.dirty ? nil : workspace.fileBaseline?.digest
                    input.bytes = try await workspace.snapshotForBackgroundSave().pdf
                }
                let snapshot = input
                let worker = Task.detached(priority:.userInitiated) {
                    if snapshot.bytes == nil { try await CloudFilePreparation.prepare([snapshot.url]) { _ in } }
                    return try ReadingSourceRecovery.inspect(snapshot,citation:seed.citation,quote:seed.quote)
                }
                let found = try await withTaskCancellationHandler(operation:{ try await worker.value },onCancel:{ worker.cancel() })
                guard !Task.isCancelled, let self, self.generation == token else { return }
                if !reviewOnly, let exact = found.exact {
                    self.finish(seed,inspection:found,page:exact,store:store,manual:false)
                } else {
                    let message = found.pageCount == 0 ? "无法读取这份 PDF，请另选文件。" :
                        (found.candidates.count > 1 ? "发现多个相似页面，请核对后选择。" : "请核对原始记录与预览页面。")
                    self.review = ReadingSourceReview(recordID:seed.recordID,citation:seed.citation,quote:seed.quote,inspection:found,message:message)
                }
            } catch {
                guard let self,self.generation == token,!FolioCancellation.matches(error) else { return }
                self.review = ReadingSourceReview(recordID:seed.recordID,citation:seed.citation,quote:seed.quote,inspection:nil,
                                                  message:"读取出处失败："+error.localizedDescription)
            }
        }
    }

    func confirm(_ review: ReadingSourceReview, page: ReadingSourcePage, store: WorkspaceStore) {
        guard let inspection = review.inspection else { return }
        cancel()
        let token = generation
        busy = true
        job = Task { [weak self] in
            defer { if self?.generation == token { self?.busy = false } }
            let input = inspection.input
            let valid: Bool
            if let id = input.workspaceID {
                valid = store.tabs.compactMap(\.workspace).first { $0.id == id }?.revision == input.revision
            } else {
                let digest = await Task.detached { try? FileBaseline.capture(input.url).digest }.value
                valid = digest != nil && digest == inspection.digest
            }
            guard let self,self.generation == token,!Task.isCancelled else { return }
            if valid { self.finish(review,inspection:inspection,page:page,store:store,manual:true) }
            else {
                let workspace = store.tabs.compactMap(\.workspace).first { $0.id == input.workspaceID && $0.count > 0 }
                self.inspect(input.url,seed:review,store:store,workspace:workspace)
            }
        }
    }

    private func finish(_ request: ReadingSourceReview, inspection: ReadingSourceInspection, page: ReadingSourcePage, store: WorkspaceStore, manual: Bool) {
        let input = inspection.input
        if let id = input.workspaceID, store.tabs.compactMap(\.workspace).first(where:{ $0.id == id })?.revision != input.revision {
            inspect(input.url,seed:request,store:store)
            return
        }
        var citation = request.citation
        let oldPage = citation.source.page
        let sameVersion = citation.source.fingerprint != nil && citation.source.fingerprint == inspection.digest
        citation.source.path = input.url.path
        citation.source.fileName = input.url.lastPathComponent
        citation.source.page = page.index
        citation.source.pageLabel = page.label
        citation.source.invalidPage053 = nil
        if let verified = input.storedDigest ?? (input.bytes == nil ? inspection.digest : nil) {
            citation.source.fingerprint = verified
        }
        let sameVisualPage = request.citation.tracking?.visualFingerprint.map { $0 == page.fingerprint } == true
        let sameOriginalPage = sameVersion && oldPage == page.index
        if citation.source.rects.isEmpty || (!sameOriginalPage && !sameVisualPage) {
            citation.source.rects = page.passage
            if manual && page.passage.isEmpty { citation.source.anchor = nil }
        }
        let identity = ReadingDocumentRegistry053.shared(store.storage).identity(input.url.path,digest:input.storedDigest ?? (input.bytes == nil ? inspection.digest : nil))
        if citation.tracking == nil {
            citation.tracking = ReadingSourceIdentity053(documentID:identity.id,capturedPage:oldPage,pageFingerprint:nil,
                                                         capturedPageLabel:request.citation.source.pageLabel)
        }
        citation.tracking?.documentID = identity.id
        citation.tracking?.visualFingerprint = page.fingerprint
        citation.tracking?.needsReview = nil
        let workspace = store.tabs.compactMap(\.workspace).first { $0.count > 0 && $0.matches(path:input.url.path) }
        citation.tracking?.pageFingerprint = workspace?.pageIdentity053(page.index)
        store.journal.repairCitation(in:request.recordID,original:request.citation,replacement:citation)
        review = nil
        var target = citation.source
        // The worker already verified this page. Avoid a second, unbounded scan on the UI thread.
        target.anchor = nil
        store.reveal(target,beside:false)
    }

    func openRecordedPage(_ request: ReadingSourceReview, store: WorkspaceStore) {
        guard let inspection = request.inspection,
              (0..<inspection.pageCount).contains(request.citation.source.page),
              request.citation.source.invalidPage053 != true else { return }
        var source = request.citation.source
        source.path = inspection.input.url.path
        source.anchor = nil
        source.rects = []
        source.keep = nil
        review = nil
        store.reveal(source,beside:false)
    }

    func cancel() {
        generation = UUID()
        job?.cancel()
        job = nil
        busy = false
    }
}

struct ReadingSourceReviewSheet: View {
    let request: ReadingSourceReview
    @ObservedObject var navigator: ReadingSourceNavigator
    @ObservedObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var pageNumber: Int
    @State private var preview: Data?
    @State private var inspectedPage: ReadingSourcePage?

    init(request:ReadingSourceReview,navigator:ReadingSourceNavigator,store:WorkspaceStore) {
        self.request = request
        self.navigator = navigator
        self.store = store
        let suggested = request.inspection?.exact?.index ?? request.inspection?.candidates.first?.index ?? request.citation.source.page
        _pageNumber = State(initialValue:max(1,min(suggested+1,request.inspection?.pageCount ?? 1)))
    }

    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("核对笔记出处").font(.headline)
            HSplitView {
                ScrollView {
                    VStack(alignment:.leading,spacing:8) {
                        Text(request.citation.title).font(.title3.bold()).textSelection(.enabled)
                        Text(request.citation.source.fileName)
                        Text("记录时 PDF 第 \((request.citation.tracking?.capturedPage ?? request.citation.source.page)+1) 页")
                        if let label = request.citation.tracking?.capturedPageLabel { Text("原印刷页码 "+label) }
                        if let asset = store.journal.record(request.recordID)?.imageAsset {
                            ReadingRecordImage(url:store.journal.assetURL(asset),pending:store.journal.pendingImage(asset))
                                .frame(maxHeight:180)
                        }
                        if !request.quote.isEmpty { Text(request.quote).textSelection(.enabled) }
                        else if let anchor = request.citation.source.anchor { Text(anchor).textSelection(.enabled) }
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }.frame(minWidth:180)
                VStack(alignment:.leading,spacing:8) {
                    Text(request.message).foregroundStyle(.secondary)
                    if let inspection = request.inspection, inspection.pageCount > 0 {
                        Text(inspection.input.url.lastPathComponent).lineLimit(1).help(inspection.input.url.path)
                        if !inspection.candidates.isEmpty {
                            Menu("选择候选页") {
                                ForEach(inspection.candidates) { page in
                                    Button("PDF 第 \(page.index+1) 页"+(page.label.map{" · "+$0} ?? "")) { pageNumber = page.index+1 }
                                }
                            }
                        }
                        HStack {
                            TextField("PDF 页码",value:$pageNumber,format:.number).frame(width:85)
                            Stepper("共 \(inspection.pageCount) 页",value:$pageNumber,in:1...inspection.pageCount)
                        }
                        if let preview,let image = NSImage(data:preview) {
                            Image(nsImage:image).resizable().scaledToFit().frame(maxWidth:.infinity,maxHeight:300)
                        }
                        if let inspectedPage {
                            if !inspectedPage.passage.isEmpty {
                                Label("已找到唯一匹配的原句，返回时会高亮。",systemImage:"checkmark.circle")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else if !request.citation.source.rects.isEmpty,
                                      let fingerprint = inspectedPage.fingerprint,
                                      fingerprint == request.citation.tracking?.visualFingerprint {
                                Label("与原页图像一致，返回时会标出原选区。",systemImage:"checkmark.circle")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("确认后会返回此页。").font(.caption).foregroundStyle(.secondary)
                            }
                            if !inspectedPage.text.isEmpty {
                                Text(inspectedPage.text).lineLimit(3).font(.caption).textSelection(.enabled)
                            }
                        }
                    }
                    Spacer(minLength:0)
                }.frame(minWidth:230)
            }
            HStack {
                Button("选择 PDF…") { chooseFile() }
                if navigator.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { navigator.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                if let inspection = request.inspection, request.citation.source.invalidPage053 != true,
                   (0..<inspection.pageCount).contains(request.citation.source.page) {
                    Button("仅打开记录页") { navigator.openRecordedPage(request,store:store) }.disabled(navigator.busy)
                }
                Button("确认关联并返回") {
                    if let inspectedPage, inspectedPage.index == pageNumber-1 {
                        navigator.confirm(request,page:inspectedPage,store:store)
                    }
                }.keyboardShortcut(.defaultAction).disabled(navigator.busy || inspectedPage?.index != pageNumber-1)
            }
        }.padding(18).adaptiveSheet(width:760,height:570,minimumWidth:510,flexibleHeight:true)
        .task(id:pageNumber) {
            preview = nil
            inspectedPage = nil
            guard let inspection = request.inspection, pageNumber > 0,pageNumber <= inspection.pageCount else { return }
            let index = pageNumber-1
            let anchor = request.citation.source.anchor ?? String(request.quote.prefix(60))
            let result = await Task.detached(priority:.userInitiated) {
                ReadingSourceRecovery.preview(inspection.input,index:index,anchor:anchor)
            }.value
            guard !Task.isCancelled else { return }
            inspectedPage = result?.0
            preview = result?.1
        }
    }

    private func chooseFile() {
        let panel = DocumentOpenPanel.files()
        panel.allowedContentTypes = [.pdf,UTType(filenameExtension:"kongfolio") ?? .pdf]
        panel.allowsMultipleSelection = false
        panel.message = "选择这条笔记的原始 PDF"
        DocumentOpenPanel.coordinator.present(panel,presentation:.separate) { _,urls in
            guard let url = urls.first else { return }
            navigator.inspect(url,seed:request,store:store)
        }
    }
}


extension WorkspaceStore {
    func openLinkedReadingSource(_ url: URL,source: SourceRef) {
        if TextImport.handles(URL(fileURLWithPath:source.path)) {
            reveal(source,beside:false)
            return
        }
        let link = url.absoluteString
        if source.relativePath == nil {
            for record in journal.state.records where record.removed == nil {
                if let tracked = record.inlineNoteCitations?.first(where:{ $0.link == link && record.hasInlineNoteLink($0.link) }) {
                    linkedSourceNavigator.open(tracked.citation,record:record,store:self)
                    return
                }
            }
        }
        let citation = ReadingCitation(source:source,title:source.fileName)
        linkedSourceNavigator.open(citation,record:ReadingRecord(kind:.excerpt,citations:[citation]),store:self)
    }
}
