import Foundation
import AppKit

actor ReadingImageOCRWorker {
    static let shared = ReadingImageOCRWorker()
    func recognize(file:URL,pending:Data?,vertical:Bool) throws -> String {
        try Task.checkCancellation(); try OCRResourceGate.shared.acquire(); defer { OCRResourceGate.shared.release() }
        let data:Data
        if let pending { data = pending } else { data = try Data(contentsOf:file,options:.mappedIfSafe) }
        let image = try SignatureImage.loadData(data).unwrap("摘录图片无法读取")
        let lines = try vertical ? DocumentServices.recognizeVertical(image,languages:OCRSettings().languages) : DocumentServices.recognize(image,languages:OCRSettings().languages)
        try Task.checkCancellation()
        return OrderedText.paragraphs(regions:lines,pageText:lines.map(\.text).joined(separator:"\n"),mergeLines:false,keepColumns:vertical).joined(separator:"\n")
    }
}
@MainActor final class ReadingImageOCRController:ObservableObject {
    @Published var busy = false
    @Published var text = ""
    @Published var message = ""
    private var task:Task<Void,Never>?
    private var generation = UUID()
    func recognize(_ record:ReadingRecord,journal:ReadingJournal,vertical:Bool) {
        guard let name = record.imageAsset else { return }
        cancel(); let token = UUID(); generation = token; busy = true; text = ""; message = "正在识别图片…"
        let file = journal.assetURL(name), pending = journal.pendingImage(name)
        task = Task { [weak self] in
            do {
                let result = try await ReadingImageOCRWorker.shared.recognize(file:file,pending:pending,vertical:vertical)
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.text = result; self.busy = false; self.message = result.isEmpty ? "未识别到文字，可保留图片摘录" : "请核对后采用；原图与原 PDF 保留"
            } catch { guard let self, self.generation == token else { return }; self.busy = false; self.message = FolioCancellation.matches(error) ? "已取消识别" : error.localizedDescription }
        }
    }
    func cancel() { generation = UUID(); task?.cancel(); task = nil; busy = false }
}
