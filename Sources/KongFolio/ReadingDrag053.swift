import Foundation

/// Plain Markdown uses the native text view's insertion cursor and undo transaction.
/// The quotation, source, dates and images are frozen in the inserted text.
enum ReadingDrag053 {
    static func text(_ item:ReadingLibraryItem,assets:URL)->String {
        let snapshot:ReadingExportSnapshot
        switch item {case .record(let r):snapshot=ReadingExportSnapshot(title:r.displayTitle,records:[r]);case .essay(let e):snapshot=ReadingExportSnapshot(title:e.title,essay:e)}
        let folder=assets.absoluteString.hasSuffix("/") ? String(assets.absoluteString.dropLast()):assets.absoluteString
        return ReadingRecordExport.markdown(snapshot,imageFolder:folder)+"\n[原记录]("+ReadingRecordLink053.url(item.id).absoluteString+")\n"
    }
}
