import SwiftUI

struct StableTextEditor: NSViewRepresentable {
    @Environment(\.isEnabled) private var enabled
    @Binding var text: String
    var label: String
    var identity = ""
    var session:WritingSession? = nil
    var markdown = false
    var onFocus:(()->Void)? = nil
    func makeCoordinator() -> StableInputCoordinator { StableInputCoordinator(read:{text},write:{text = $0}) }
    func makeNSView(context:Context) -> NSScrollView {
        let scroll = NSScrollView(frame:NSRect(x:0,y:0,width:400,height:150)); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let view = ComposingTextView(frame:scroll.bounds); view.string = text;view.positionKey = identity;view.focused = onFocus;view.writingSession = session;WritingRegistry.attach(view,key:identity);view.supportsMarkdownLists = markdown;session?.view = view; view.isRichText = false; view.allowsUndo = true; view.font = .systemFont(ofSize:14); view.textContainerInset = NSSize(width:8,height:8)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false; view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true; view.textContainer?.containerSize = NSSize(width:400,height:CGFloat.greatestFiniteMagnitude)
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false; view.isAutomaticTextReplacementEnabled = false; view.isAutomaticSpellingCorrectionEnabled = false
        view.isEditable = enabled; view.setAccessibilityLabel(label); view.delegate = context.coordinator; view.committed = { [weak coordinator = context.coordinator] in coordinator?.publish($0) }; scroll.documentView = view;WritingPositions.shared.restore(view,key:identity); context.coordinator.observeScroll(scroll,view:view); return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) { context.coordinator.read = { text }; context.coordinator.write = { text = $0 }; if let view = scroll.documentView as? NSTextView { view.isEditable = enabled;session?.view = view; context.coordinator.synchronize(view) } }
    static func dismantleNSView(_ scroll:NSScrollView,coordinator:StableInputCoordinator) { if let view = scroll.documentView as? ComposingTextView { view.finishEditingSession() }; scroll.documentView = nil }
}

struct StableTextField: NSViewRepresentable {
    @Environment(\.isEnabled) private var enabled
    let placeholder: String
    @Binding var text: String
    init(_ placeholder:String,text:Binding<String>) { self.placeholder = placeholder; _text = text }
    func makeCoordinator() -> StableInputCoordinator { StableInputCoordinator(read:{text},write:{text = $0}) }
    func makeNSView(context:Context) -> NSTextField { let view = NSTextField(string:text); view.isEnabled = enabled; view.placeholderString = placeholder; view.setAccessibilityLabel(placeholder); view.delegate = context.coordinator; return view }
    func updateNSView(_ view:NSTextField,context:Context) {
        view.isEnabled = enabled
        let changed = context.coordinator.accepted != text; context.coordinator.read = { text }; context.coordinator.write = { text = $0 }
        if let editor = view.currentEditor() as? NSTextView { if !editor.hasMarkedText() && changed { context.coordinator.synchronize(editor) } }
        else if view.stringValue != text { view.stringValue = text }
    }
    static func dismantleNSView(_ view:NSTextField,coordinator:StableInputCoordinator) { view.delegate = nil }
}
