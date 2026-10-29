import SwiftUI
import QuickLookUI

struct AcademicFilePreview: NSViewRepresentable {
    var url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame:.zero,style:.normal)!
        view.shouldCloseWithWindow = false; view.autostarts = false; return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) { if (view.previewItem as? NSURL) != url as NSURL { view.previewItem = url as NSURL } }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.previewItem = nil; view.close() }
}
