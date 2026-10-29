import SwiftUI

struct AcademicTextEditor: NSViewRepresentable {
    @ObservedObject var controller: ResearchController
    func makeCoordinator() -> Coordinator { Coordinator(controller) }
    func makeNSView(context:Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let text = NSTextView(); text.isRichText = false; text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false
        text.font = .systemFont(ofSize:13); text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true; text.textContainerInset = NSSize(width:8,height:8); text.allowsUndo = true
        text.delegate = context.coordinator; controller.academicTextView = text; scroll.documentView = text; return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != controller.academicText { view.string = controller.academicText; let max = (view.string as NSString).length; let range = controller.academicSelection; view.setSelectedRange(NSRange(location:min(range.location,max),length:min(range.length,max-min(range.location,max)))) }
    }
    static func dismantleNSView(_ scroll:NSScrollView,coordinator:Coordinator) { if coordinator.controller.academicTextView === scroll.documentView { coordinator.controller.academicTextView = nil }; (scroll.documentView as? NSTextView)?.delegate = nil; scroll.documentView = nil }
    final class Coordinator:NSObject,NSTextViewDelegate {
        let controller: ResearchController
        init(_ controller:ResearchController) { self.controller = controller }
        func textDidChange(_ notification:Notification) { guard let view = notification.object as? NSTextView else { return }; controller.academicSelection = view.selectedRange(); controller.academicText = view.string }
        func textViewDidChangeSelection(_ notification:Notification) { if let view = notification.object as? NSTextView { controller.academicSelection = view.selectedRange() } }
    }
}
