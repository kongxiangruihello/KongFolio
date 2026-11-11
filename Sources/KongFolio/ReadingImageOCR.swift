import Foundation
import AppKit

enum ReadingImageOCRMode: String, CaseIterable, Identifiable {
    case horizontal = "横排文字"
    case vertical = "竖排文字"
    case traditional = "竖排古籍（优先繁体）"
    var id: Self { self }
}

struct ReadingImageOCRRequest: Equatable {
    let recordID: UUID
    let mode: ReadingImageOCRMode
}

actor ReadingImageOCRWorker {
    static let shared = ReadingImageOCRWorker()
    func recognize(file:URL,pending:Data?,vertical:Bool,traditional:Bool) throws -> [ReadingOCRSegment] {
        try Task.checkCancellation(); try OCRResourceGate.shared.acquire(); defer { OCRResourceGate.shared.release() }
        let data:Data
        if let pending { data = pending } else { data = try Data(contentsOf:file,options:.mappedIfSafe) }
        let image = try SignatureImage.loadData(data).unwrap("摘录图片无法读取")
        let languages = traditional ? ["zh-Hant","zh-Hans","en-US"] : OCRSettings().languages
        let lines = try vertical ? DocumentServices.recognizeVertical(image,languages:languages) : DocumentServices.recognize(image,languages:languages)
        try Task.checkCancellation()
        return ReadingOCRSegments.make(lines,vertical:vertical)
    }
}
@MainActor final class ReadingImageOCRController:ObservableObject {
    @Published var busy = false
    @Published var text = ""
    @Published var segments:[ReadingOCRSegment] = []
    @Published private(set) var originalText = ""
    @Published var message = ""
    private var task:Task<Void,Never>?
    private var generation = UUID()
    func recognize(_ record:ReadingRecord,journal:ReadingJournal,vertical:Bool,traditional:Bool = false) {
        guard let name = record.imageAsset else { return }
        cancel(); let token = UUID(); generation = token; busy = true; text = ""; message = "正在识别图片…"
        let file = journal.assetURL(name), pending = journal.pendingImage(name)
        task = Task { [weak self] in
            do {
                let result = try await ReadingImageOCRWorker.shared.recognize(file:file,pending:pending,vertical:vertical,traditional:traditional)
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.segments = result;self.text = ReadingOCRSegments.text(result); self.originalText = self.text; self.busy = false; self.message = result.isEmpty ? "未识别到文字，可保留图片摘录" : "请核对后采用；原图与原 PDF 保留"
            } catch { guard let self, self.generation == token else { return }; self.busy = false; self.message = FolioCancellation.matches(error) ? "已取消识别" : error.localizedDescription }
        }
    }
    func restoreSegments(_ record:ReadingRecord) { guard !busy,segments.isEmpty,let saved = record.ocrSegments else { return };segments = saved;text = record.quote;originalText = record.originalOCR ?? ReadingOCRSegments.text(saved) }
    func moveSegment(_ id:UUID,delta:Int) { guard let i = segments.firstIndex(where:{$0.id == id}),segments.indices.contains(i+delta) else { return };segments.swapAt(i,i+delta) }
    func cancel() { generation = UUID(); task?.cancel(); task = nil; busy = false }
}
