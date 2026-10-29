import AppKit
import PDFKit

/// PDFKit's automatic Vision analysis can retain closed scan documents on recent macOS.
/// This personal-use build opts out when that runtime switch exists. It is not public API:
/// always check both selectors, use their BOOL ABI, and fall back on systems without them.
/// Existing PDF text, form widgets and links remain; KongFolio's explicit OCR is independent.
/// Evidence: local Vision retain traces; https://developer.apple.com/forums/thread/841562
@MainActor enum PDFAnalysisPolicy {
    @discardableResult static func configure(_ view: PDFView) -> Bool {
        view.enableDataDetectors = false
        guard #available(macOS 26, *) else { return false }
        let setter = NSSelectorFromString("setDocumentAnalysisEnabled:")
        let getter = NSSelectorFromString("isDocumentAnalysisEnabled")
        guard view.responds(to:setter), view.responds(to:getter),
              let setMethod = view.method(for:setter), let getMethod = view.method(for:getter) else { return false }
        typealias SetFlag = @convention(c) (AnyObject,Selector,Bool) -> Void
        typealias GetFlag = @convention(c) (AnyObject,Selector) -> Bool
        unsafeBitCast(setMethod,to:SetFlag.self)(view,setter,false)
        return !unsafeBitCast(getMethod,to:GetFlag.self)(view,getter)
    }
}
@MainActor class ManagedPDFView: PDFView {
    private(set) var automaticAnalysisSuppressed = false
    override init(frame: NSRect) { super.init(frame:frame); automaticAnalysisSuppressed = PDFAnalysisPolicy.configure(self) }
    required init?(coder:NSCoder) { super.init(coder:coder); automaticAnalysisSuppressed = PDFAnalysisPolicy.configure(self) }
}
