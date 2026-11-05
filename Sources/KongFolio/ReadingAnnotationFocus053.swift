import Foundation
import PDFKit

extension WorkspaceStore {
    func focusLibraryAnnotation053(_ id:UUID) {
        guard let record=journal.record(id),let origin=record.pdfOrigin,let source=record.citations.first?.source,source.invalidPage053 != true,let w=commandWorkspace,w.matches(path:source.path),let page=w.document.page(at:source.page) else { return }
        guard let mark=page.annotations.first(where:{ReadingPDFCapture.identity($0,on:page,index:source.page)==origin.annotationID}) else { return }
        w.selectedAnnotation=mark;w.selectPage(source.page);w.note=mark.contents ?? "";w.pdfView?.go(to:mark.bounds,on:page)
    }
}
