import Foundation
import PDFKit

struct ReadingSourceInput {
    let url: URL
    var bytes: Data? = nil
    var workspaceID: UUID? = nil
    var revision: UUID? = nil
    var storedDigest: String? = nil

    func document() -> PDFDocument? {
        if let bytes { return PDFDocument(data:bytes) }
        if url.pathExtension.lowercased() == "kongfolio", let archive = try? ProjectArchive.read(url) {
            return PDFDocument(data:archive.pdf)
        }
        return PDFDocument(url:url)
    }
}

struct ReadingSourcePage: Identifiable {
    let index: Int
    let label: String?
    let text: String
    let fingerprint: String?
    var id: Int { index }
}

struct ReadingSourceInspection {
    var input: ReadingSourceInput
    var digest: String?
    var pageCount = 0
    var candidates: [ReadingSourcePage] = []
    var exact: ReadingSourcePage?
}

enum ReadingSourceRecovery {
    /// Rasterize a small, fixed-size gray image. The digest follows the content through page inserts and moves.
    static func fingerprint(_ page: PDFPage) -> String? {
        let side = 48
        let box = page.bounds(for:.cropBox)
        guard box.width > 0,box.height > 0,
              let context = CGContext(data:nil,width:side,height:side,bitsPerComponent:8,bytesPerRow:side,
                                      space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(gray:1,alpha:1)
        context.fill(CGRect(x:0,y:0,width:side,height:side))
        context.scaleBy(x:CGFloat(side)/box.width,y:CGFloat(side)/box.height)
        context.translateBy(x:-box.minX,y:-box.minY)
        page.draw(with:.cropBox,to:context)
        guard let data = context.data else { return nil }
        return OCRPageCache.digest(Data(bytes:data,count:side*side))
    }

    static func page(_ document: PDFDocument, at index: Int, fingerprint digest: String? = nil) -> ReadingSourcePage? {
        guard let page = document.page(at:index) else { return nil }
        let text = (page.string ?? "").split(whereSeparator:\.isWhitespace).joined(separator:" ")
        return ReadingSourcePage(index:index,label:ReadingServices.pageLabel(page,index:index),
                                 text:String(text.prefix(180)),fingerprint:digest ?? fingerprint(page))
    }

    static func inspect(_ input: ReadingSourceInput, citation: ReadingCitation, quote: String) throws -> ReadingSourceInspection {
        try Task.checkCancellation()
        let digest: String?
        let document: PDFDocument?
        if input.bytes == nil && input.url.pathExtension.lowercased() == "pdf" {
            let bytes = try Data(contentsOf:input.url,options:.mappedIfSafe)
            digest = OCRPageCache.digest(bytes)
            document = PDFDocument(data:bytes)
        } else {
            digest = try input.storedDigest ?? input.bytes.map(OCRPageCache.digest) ?? FileBaseline.capture(input.url).digest
            document = input.document()
        }
        var result = ReadingSourceInspection(input:input,digest:digest)
        guard let document,!document.isLocked else { return result }
        result.pageCount = document.pageCount
        let source = citation.source
        if digest != nil, digest == source.fingerprint, source.invalidPage053 != true,
           citation.tracking?.needsReview != true, let current = page(document,at:source.page) {
            result.exact = current
            return result
        }
        let originalFingerprint = citation.tracking?.visualFingerprint
        let rawAnchor = source.anchor ?? String(quote.prefix(60))
        let anchor = AnnotationFilter.folded(rawAnchor).filter { !$0.isWhitespace }
        // A short string often appears on many pages and is only useful for manual comparison.
        let useAnchor = anchor.count >= 8
        let scanLimit = 800
        let complete = document.pageCount <= scanLimit
        let start = max(0,min(source.page-scanLimit/2,document.pageCount-scanLimit))
        let indices = complete ? 0..<document.pageCount : start..<(start+scanLimit)
        var images:[ReadingSourcePage] = []
        var passages:[ReadingSourcePage] = []
        if originalFingerprint != nil || useAnchor {
            for index in indices {
                try Task.checkCancellation()
                let match: (visual:Bool,text:Bool,digest:String?) = autoreleasepool {
                    guard let candidate = document.page(at:index) else { return (false,false,nil) }
                    let candidateDigest = originalFingerprint == nil ? nil : fingerprint(candidate)
                    let visual = candidateDigest != nil && candidateDigest == originalFingerprint
                    let text = useAnchor && AnnotationFilter.folded(candidate.string ?? "").filter{!$0.isWhitespace}.contains(anchor)
                    return (visual,text,candidateDigest)
                }
                if match.visual || match.text, let candidate = page(document,at:index,fingerprint:match.digest) {
                    if match.visual { images.append(candidate) }
                    if match.text { passages.append(candidate) }
                }
            }
        }
        // A unique visual match wins. Several identical scans remain ambiguous unless the original text singles one out.
        let visualIDs = Set(images.map(\.index))
        let narrowed = passages.filter { visualIDs.contains($0.index) }
        let matches = images.count > 1 && !narrowed.isEmpty ? narrowed : (images.isEmpty ? passages : images)
        if complete && matches.count == 1 { result.exact = matches[0] }
        result.candidates = Array(matches.prefix(24))
        return result
    }

    static func preview(_ input: ReadingSourceInput, index: Int) -> (ReadingSourcePage,Data?)? {
        guard let document = input.document(), let page = document.page(at:index),
              let summary = self.page(document,at:index) else { return nil }
        let bitmap = page.thumbnail(of:CGSize(width:300,height:390),for:.cropBox)
        return (summary,bitmap.tiffRepresentation)
    }
}

extension ReadingJournal {
    func repairCitation(in id: UUID, original: ReadingCitation, replacement: ReadingCitation) {
        guard original != replacement, record(id)?.citations053.contains(original) == true else { return }
        editRecord(id) { record in
            record.citations = record.citations.map { $0 == original ? replacement : $0 }
            if var regions = record.extras?.regions {
                for index in regions.indices where regions[index].citation == original { regions[index].citation = replacement }
                record.extras?.regions = regions
            }
            if var quotes = record.extras?.quotations {
                for index in quotes.indices {
                    quotes[index].citations = quotes[index].citations.map { $0 == original ? replacement : $0 }
                }
                record.extras?.quotations = quotes
            }
        }
    }
}
