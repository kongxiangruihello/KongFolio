import Foundation

enum ReadingRecordMetadata {
    private static let lock = NSLock()
    private static let formatter:DateFormatter = { let f=DateFormatter();f.locale=Locale(identifier:"zh_CN");f.dateFormat="yyyy-MM-dd HH:mm:ss XXX";return f }()
    static func date(_ value:Date)->String { lock.lock();defer{lock.unlock()};return formatter.string(from:value) }
    static func lines(_ record:ReadingRecord,includeSources:Bool = true)->[String] {
        var values:[String] = []
        if includeSources {
            if record.citations053.isEmpty { values.append("出处：独立笔记（未关联文献）") }
            for citation in record.citations053 {
                values.append("出处："+ReadingExportOrdering.citation(citation))
                values.append("原文件："+citation.source.fileName)
                if !citation.source.path.isEmpty { values.append("文件位置："+citation.source.path) }
                if let tracking=citation.tracking { values.append("摘录时 PDF 页：\(tracking.capturedPage+1)");if tracking.needsReview == true { values.append("原页发生变动，请重新核对出处") } }
            }
        }
        if let origin = record.pdfOrigin {
            values.append("PDF 类型："+origin.type)
            if let author = origin.author,!author.isEmpty { values.append("PDF 作者："+author) }
            values.append("原创建时间："+(origin.originalCreated.map(date) ?? origin.originalCreatedRaw.map{$0+"（原始记录）"} ?? "未记录"))
            values.append("原修改时间："+(origin.originalModified.map(date) ?? "未记录"))
            values.append("收录时间："+date(record.created))
            values.append("资料库修改："+date(record.modified))
            if let missing = origin.missingSince { values.append("原 PDF 中已移除："+date(missing)+"；资料库仍保留记录") }
        } else {
            values.append("记录时间："+date(record.created));values.append("修改时间："+date(record.modified))
        }
        if let extras=record.extras {
            if let review=extras.review { values.append("核对状态："+review.rawValue) }
            if let meaning=extras.colorMeaning,!meaning.isEmpty { values.append("颜色含义："+meaning) }
            if let chapter=extras.chapter,!chapter.isEmpty { values.append("章节："+chapter) }
        }
        return values
    }
    static func essayLines(_ essay:ReadingEssay)->[String] { ["创建时间："+date(essay.created),"修改时间："+date(essay.modified)] }
}
