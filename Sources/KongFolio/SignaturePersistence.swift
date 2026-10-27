import AppKit
import CryptoKit
import PDFKit
import UniformTypeIdentifiers

struct SignatureEditArchive: Codable {
    var base: Data
    var preserved: Bool
    var size: CGSize
    var rotation: Int
    var items: [PlacedSignature]
    func validate() throws {
        guard PDFDocument(data: base)?.pageCount == 1, size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              items.allSatisfy({ $0.rect.origin.x.isFinite && $0.rect.origin.y.isFinite && $0.rect.width.isFinite && $0.rect.height.isFinite && $0.rect.width > 0 && $0.rect.height > 0 && SignatureImage.loadData($0.png) != nil }) else {
            throw FolioError(message: "签名编辑记录损坏")
        }
    }
}

extension SignatureImage {
    static func loadData(_ data: Data) -> CGImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }
}

/// Plain PDFs remain usable in every viewer; the editing source is kept locally and accepted only for the exact saved bytes.
enum SignaturePersistence {
    struct Record: Codable { var digest: String; var layers: [Int: SignatureEditArchive] }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func location(_ pdf: URL, storage: URL) -> URL {
        storage.appendingPathComponent("SignatureEdits", isDirectory: true).appendingPathComponent(digest(Data(pdf.standardizedFileURL.path.utf8)) + ".json")
    }
    static func write(_ layers: [Int: SignatureEditArchive], pdf: URL, storage: URL) throws {
        let target = location(pdf, storage: storage)
        guard !layers.isEmpty else { try? FileManager.default.removeItem(at: target); return }
        let record = Record(digest: digest(try Data(contentsOf: pdf)), layers: layers)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: target, options: .atomic)
    }
    static func read(pdf: URL, bytes: Data, storage: URL) -> [Int: SignatureEditArchive] {
        guard let data = try? Data(contentsOf: location(pdf, storage: storage)), let record = try? JSONDecoder().decode(Record.self, from: data), record.digest == digest(bytes),
              record.layers.values.allSatisfy({ (try? $0.validate()) != nil }) else { return [:] }
        return record.layers
    }
}

extension Workspace {
    var signatureEditArchives: [Int: SignatureEditArchive] {
        var result: [Int: SignatureEditArchive] = [:]
        for index in 0..<count {
            guard let page = document.page(at: index), let layer = signatureLayer(for: page), !layer.items.isEmpty else { continue }
            result[index] = SignatureEditArchive(base: layer.base, preserved: layer.preserved, size: layer.size, rotation: layer.rotation, items: layer.items)
        }
        return result
    }
    func restoreSignatureEdits(_ archives: [Int: SignatureEditArchive]) {
        signatureLayers = [:]
        for (index, value) in archives {
            guard let page = document.page(at: index), (try? value.validate()) != nil else { continue }
            signatureLayers[ObjectIdentifier(page)] = SignatureLayer(base: value.base, preserved: value.preserved, size: value.size, rotation: value.rotation, items: value.items, page: page)
        }
    }
    func replacePlacedSignature(_ item: PlacedSignature, in layer: SignatureLayer) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let original = try SignatureImage.load(url).unwrap("无法读取签名图片")
            let processed = try SignatureImage.process(original, options: SignatureOptions()).unwrap("签名图片处理失败")
            let png = try SignatureImage.pngData(processed).unwrap("签名图片编码失败")
            try replacePlacedSignature(item, in: layer, png: png)
        } catch { self.error = error.localizedDescription }
    }
    func replacePlacedSignature(_ item: PlacedSignature, in layer: SignatureLayer, png: Data) throws {
        guard signatureLayer(for: layer.page) === layer, SignatureImage.loadData(png) != nil else { throw FolioError(message: "页面或签名图片已失效") }
        let before = try snapshot()
        var items = layer.items
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { throw FolioError(message: "签名已不存在") }
        items[index].png = png
        try rebake(layer, items: items)
        pushUndo(.snapshot(before)); changed(); status = "已替换签名，可撤销"
    }
}
