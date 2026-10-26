import Foundation
import CryptoKit
import PDFKit

/// Independent, atomic page checkpoints. Their context includes the input bytes, all recipe settings and pipeline version.
struct OCRPageCache {
    struct Page: Codable {
        var context: String
        var index: Int
        var pdf: Data
        var lines: [RecognizedLine]?
        var recognized: Bool
    }
    private struct Envelope: Codable { var payload: Data; var digest: String }
    let directory: URL
    let context: String
    static func digest(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    init(root: URL, source: Data, recipe: WorkRecipe) throws {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        var hash=SHA256();hash.update(data:Data(("KongFolio-OCR-026-v1|"+ProcessInfo.processInfo.operatingSystemVersionString).utf8));hash.update(data:source);hash.update(data:try encoder.encode(recipe))
        context=hash.finalize().map { String(format:"%02x",$0) }.joined()
        directory=root.appendingPathComponent(context,isDirectory:true)
    }
    func read(_ index: Int) -> Page? {
        guard let data=try? Data(contentsOf:directory.appendingPathComponent("\(index).json")),
              let envelope=try? JSONDecoder().decode(Envelope.self,from:data), Self.digest(envelope.payload)==envelope.digest,
              let page=try? JSONDecoder().decode(Page.self,from:envelope.payload),page.context==context,page.index==index,
              let doc=PDFDocument(data:page.pdf),!doc.isLocked,doc.pageCount==1 else { return nil }
        return page
    }
    func write(index: Int, page: PDFPage, lines: [RecognizedLine]?, recognized: Bool) throws {
        let doc=PDFDocument();doc.insert(page.copy() as! PDFPage,at:0)
        let payload=try JSONEncoder().encode(Page(context:context,index:index,pdf:try doc.dataRepresentation().unwrap("无法保存 OCR 页检查点"),lines:lines,recognized:recognized))
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try JSONEncoder().encode(Envelope(payload:payload,digest:Self.digest(payload))).write(to:directory.appendingPathComponent("\(index).json"),options:.atomic)
    }
}
