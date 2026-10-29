import PDFKit

/// Page assembly must not discard document-level labels, forms, destinations, tags or encryption.
enum SnapshotSafety {
    static func requiresOriginalSerialization(_ document:PDFDocument) -> Bool {
        if document.isEncrypted { return true }
        if let ref = document.documentRef, let catalog = ref.catalog {
            for key in ["AcroForm","PageLabels","Names","Dests","StructTreeRoot","OCProperties","Threads"] {
                var object: CGPDFObjectRef?
                if CGPDFDictionaryGetObject(catalog,key,&object) { return true }
            }
        }
        for index in 0..<document.pageCount {
            for annotation in document.page(at:index)?.annotations ?? [] {
                if annotation.destination != nil || annotation.action is PDFActionGoTo || annotation.type == PDFAnnotationSubtype.widget.rawValue { return true }
            }
        }
        return false
    }
}
