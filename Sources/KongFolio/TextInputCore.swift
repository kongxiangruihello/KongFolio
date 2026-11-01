import AppKit

/// Native text storage owns the composition, selection and undo stack; model echoes never replace it.
class ComposingTextView: NSTextView {
    weak var writingSession:WritingSession?
    override func performKeyEquivalent(with event:NSEvent) -> Bool {
        guard window?.firstResponder === self,!hasMarkedText() else { return super.performKeyEquivalent(with:event) }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock,.numericPad,.function])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if modifiers == .command,key == "z" { if undoManager?.canUndo == true { undoManager?.undo();committed?(self) };return true }
        if modifiers == [.command,.shift],key == "z" { if undoManager?.canRedo == true { undoManager?.redo();committed?(self) };return true }
        guard let session = writingSession else { return super.performKeyEquivalent(with:event) }
        if modifiers == .command {
            if key == "b" { session.wrap("**","**",placeholder:"粗体");return true }
            if key == "i" { session.wrap("*","*",placeholder:"斜体");return true }
            if key == "f" { session.findRequest = UUID();return true }
            if key == "g" { session.find(session.lastQuery);return true }
        }
        if modifiers == [.command,.shift],key == "g" { session.find(session.lastQuery,backward:true);return true }
        return super.performKeyEquivalent(with:event)
    }
    var focused:(()->Void)?
    override func becomeFirstResponder() -> Bool { let result = super.becomeFirstResponder();if result { focused?();WritingRegistry.attach(self,key:positionKey) };return result }
    var positionKey = ""
    var supportsMarkdownLists = false
    private let editingHistory = UndoManager()
    override func insertNewline(_ sender:Any?) {
        if supportsMarkdownLists,!hasMarkedText(),let edit = WritingEdit.newline(string,selection:selectedRange()) { WritingEdit.apply(edit,to:self) } else { super.insertNewline(sender) }
    }
    override func insertTab(_ sender:Any?) {
        if supportsMarkdownLists,!hasMarkedText(),let edit = WritingEdit.indent(string,selection:selectedRange(),outdent:false) { WritingEdit.apply(edit,to:self) } else { super.insertTab(sender) }
    }
    override func insertBacktab(_ sender:Any?) {
        if supportsMarkdownLists,!hasMarkedText(),let edit = WritingEdit.indent(string,selection:selectedRange(),outdent:true) { WritingEdit.apply(edit,to:self) } else { super.insertBacktab(sender) }
    }
    override var undoManager:UndoManager? { editingHistory }
    func finishEditingSession() { WritingPositions.shared.capture(self,key:positionKey);WritingPositions.shared.flush(); committed = nil; focused = nil; delegate = nil; editingHistory.removeAllActions() }
    var committed: ((NSTextView) -> Void)?
    override func insertText(_ text: Any, replacementRange: NSRange) { super.insertText(text, replacementRange:replacementRange); if !hasMarkedText() { committed?(self) } }
    override func unmarkText() { super.unmarkText(); committed?(self) }
    override func resignFirstResponder() -> Bool { let result = super.resignFirstResponder(); if result && !hasMarkedText() { committed?(self); WritingPositions.shared.capture(self,key:positionKey) }; return result }
}

@MainActor enum TextInputSync {
    static func replaceExternal(_ view: NSTextView, with value: String) {
        guard !view.hasMarkedText(), view.string != value else { return }
        let old = view.string, selections = view.selectedRanges, origin = view.enclosingScrollView?.contentView.bounds.origin
        let prefix = String(zip(old,value).prefix { $0 == $1 }.map(\.0)).utf16.count
        let oldLength = old.utf16.count, newLength = value.utf16.count
        let suffix = String(zip(old.reversed(),value.reversed()).prefix { $0 == $1 }.map(\.0)).utf16.count
        let commonSuffix = min(suffix,min(oldLength-prefix,newLength-prefix))
        let oldEnd = oldLength-commonSuffix, newEnd = newLength-commonSuffix
        func mapped(_ offset:Int) -> Int { if offset <= prefix { return offset }; if offset >= oldEnd { return max(0,min(newLength,offset+newEnd-oldEnd)) }; return min(newEnd,prefix+offset-prefix) }
        // An explicit outside replacement (restore/reload) invalidates old text ranges.
        // Typing echoes and marked text return before this point and keep their undo history.
        view.undoManager?.removeAllActions()
        view.string = value
        view.selectedRanges = selections.map { item in let r = item.rangeValue; let start = mapped(min(r.location,oldLength)), end = mapped(min(NSMaxRange(r),oldLength)); return NSValue(range:NSRange(location:start,length:max(0,end-start))) }
        if let origin, let scroll = view.enclosingScrollView { scroll.contentView.scroll(to:origin); scroll.reflectScrolledClipView(scroll.contentView) }
    }
}

@MainActor final class StableInputCoordinator: NSObject, NSTextViewDelegate, NSTextFieldDelegate {
    var read: () -> String
    var write: (String) -> Void
    private(set) var accepted: String
    init(read: @escaping () -> String, write: @escaping (String) -> Void) { self.read = read; self.write = write; accepted = read() }
    func synchronize(_ view: NSTextView) { let value = read(); guard !view.hasMarkedText(), value != accepted else { return }; accepted = value; TextInputSync.replaceExternal(view,with:value) }
    func publish(_ view: NSTextView) { guard !view.hasMarkedText(), read() != view.string else { return }; accepted = view.string; write(view.string); accepted = read() }
    func textViewDidChangeSelection(_ notification:Notification) { if let view = notification.object as? ComposingTextView { WritingPositions.shared.capture(view,key:view.positionKey) } }
    func textDidChange(_ notification: Notification) { if let view = notification.object as? NSTextView { publish(view) } }
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        guard read() != field.stringValue else { return }; accepted = field.stringValue; write(field.stringValue); accepted = read()
    }
    func controlTextDidEndEditing(_ notification: Notification) { controlTextDidChange(notification) }
}

