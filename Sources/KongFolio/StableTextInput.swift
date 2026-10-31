import SwiftUI

struct StableTextEditor: NSViewRepresentable {
    @Binding var text: String
    var label: String
    func makeCoordinator() -> StableInputCoordinator { StableInputCoordinator(read:{text},write:{text = $0}) }
    func makeNSView(context:Context) -> NSScrollView {
        let scroll = NSScrollView(frame:NSRect(x:0,y:0,width:400,height:150)); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let view = ComposingTextView(frame:scroll.bounds); view.string = text; view.isRichText = false; view.allowsUndo = true; view.font = .systemFont(ofSize:14); view.textContainerInset = NSSize(width:8,height:8)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false; view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true; view.textContainer?.containerSize = NSSize(width:400,height:CGFloat.greatestFiniteMagnitude)
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false; view.isAutomaticTextReplacementEnabled = false; view.isAutomaticSpellingCorrectionEnabled = false
        view.setAccessibilityLabel(label); view.delegate = context.coordinator; view.committed = { [weak coordinator = context.coordinator] in coordinator?.publish($0) }; scroll.documentView = view; return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) { context.coordinator.read = { text }; context.coordinator.write = { text = $0 }; if let view = scroll.documentView as? NSTextView { context.coordinator.synchronize(view) } }
    static func dismantleNSView(_ scroll:NSScrollView,coordinator:StableInputCoordinator) { if let view = scroll.documentView as? ComposingTextView { view.committed = nil; view.delegate = nil }; scroll.documentView = nil }
}

struct StableTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    init(_ placeholder:String,text:Binding<String>) { self.placeholder = placeholder; _text = text }
    func makeCoordinator() -> StableInputCoordinator { StableInputCoordinator(read:{text},write:{text = $0}) }
    func makeNSView(context:Context) -> NSTextField { let view = NSTextField(string:text); view.placeholderString = placeholder; view.setAccessibilityLabel(placeholder); view.delegate = context.coordinator; return view }
    func updateNSView(_ view:NSTextField,context:Context) {
        let changed = context.coordinator.accepted != text; context.coordinator.read = { text }; context.coordinator.write = { text = $0 }
        if let editor = view.currentEditor() as? NSTextView { if !editor.hasMarkedText() && changed { context.coordinator.synchronize(editor) } }
        else if view.stringValue != text { view.stringValue = text }
    }
    static func dismantleNSView(_ view:NSTextField,coordinator:StableInputCoordinator) { view.delegate = nil }
}
