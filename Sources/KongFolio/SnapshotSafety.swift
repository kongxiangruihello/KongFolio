import PDFKit

/// Page assembly must not discard document-level structures or independently subset embedded fonts.
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
            guard let page = document.page(at:index) else { continue }
            // PDFKit serializes each copied page with its own font subset. Joining those PDFs can
            // reuse a font name with a different glyph map: the page looks right but searches fail.
            // Keep one serialization scope for all text resources, including inherited resources
            // and form XObjects. Image-only scans can still use the yielding page-by-page path.
            if hasTextResources(page) { return true }
            for annotation in page.annotations {
                if annotation.destination != nil || annotation.action is PDFActionGoTo
                    || annotation.type == PDFAnnotationSubtype.widget.rawValue
                    || annotation.type == PDFAnnotationSubtype.freeText.rawValue { return true }
            }
        }
        return false
    }

    private static func hasTextResources(_ page:PDFPage) -> Bool {
        guard let ref = page.pageRef else { return page.numberOfCharacters > 0 }
        var node:CGPDFDictionaryRef? = ref.dictionary
        for _ in 0..<64 {
            guard let dictionary = node else { return false }
            var resources:CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(dictionary,"Resources",&resources), let resources {
                var fonts:CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(resources,"Font",&fonts),let fonts,CGPDFDictionaryGetCount(fonts)>0 { return true }
                var objects:CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(resources,"XObject",&objects),let objects {
                    var formFound=false
                    withUnsafeMutablePointer(to:&formFound) { result in
                        CGPDFDictionaryApplyFunction(objects,{ _,object,context in
                            var stream:CGPDFStreamRef?
                            guard let context,CGPDFObjectGetValue(object,.stream,&stream),let stream else { return }
                            guard let streamDictionary = CGPDFStreamGetDictionary(stream) else {
                                context.assumingMemoryBound(to:Bool.self).pointee=true;return
                            }
                            var subtype:UnsafePointer<CChar>?
                            if !CGPDFDictionaryGetName(streamDictionary,"Subtype",&subtype)
                                || subtype.map({String(cString:$0) != "Image"}) != false {
                                context.assumingMemoryBound(to:Bool.self).pointee=true
                            }
                        },result)
                    }
                    if formFound { return true }
                }
                return false
            }
            var parent:CGPDFDictionaryRef?
            _ = CGPDFDictionaryGetDictionary(dictionary,"Parent",&parent);node=parent
        }
        return true // An invalid/cyclic inherited resource tree must not enter page assembly.
    }
}
