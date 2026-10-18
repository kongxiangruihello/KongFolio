import AppKit
import PDFKit

/// The first use of PDFKit, Vision, Core Image and the Chinese fonts in a new run of the app loads a good deal of system
/// code. Doing a little of each shortly after launch, in the background, moves that wait away from the first file the
/// reader opens. The time it takes goes to the performance log, so the effect can be seen.
enum AppWarmup {
    static func start() {
        Task.detached(priority: .utility) {
            // Let the window come up (and a file that launched the app begin to load) first.
            try? await Task.sleep(nanoseconds: 800_000_000)
            let began = Date()
            let page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: 200, height: 200), for: .mediaBox)
            let document = PDFDocument()
            document.insert(page, at: 0)
            if let data = document.dataRepresentation(), let again = PDFDocument(data: data), let first = again.page(at: 0) {
                _ = first.thumbnail(of: CGSize(width: 64, height: 64), for: .cropBox)
                _ = again.string
            }
            _ = DocumentServices.context
            _ = NSFont(name: "PingFang SC", size: 12)
            _ = NSFont(name: "Songti SC", size: 12)
            _ = DocumentServices.supportedOCRLanguages
            PerfLog.record("启动预热", name: "PDFKit、Core Image、字体、Vision", pages: 0, seconds: Date().timeIntervalSince(began))
        }
    }
}
