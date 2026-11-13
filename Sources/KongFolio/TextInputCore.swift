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
            if allowsMarkdownFormatting,key == "b" { session.wrap("**","**",placeholder:"粗体");return true }
            if allowsMarkdownFormatting,key == "i" { session.wrap("*","*",placeholder:"斜体");return true }
            if key == "f" { session.findRequest = UUID();return true }
            if key == "g" { session.find(session.lastQuery);return true }
        }
        if modifiers == [.command,.shift], key == "v" {
            session.cleanupFromClipboard = true
            session.cleanupRequest = UUID()
            return true
        }
        if modifiers == [.command,.option] {
            let action: WritingEdit.ParagraphAction?
            switch key {
            case "\u{F700}": action = .up
            case "\u{F701}": action = .down
            case "\r", "\u{3}": action = .split
            case "j": action = .merge
            default: action = nil
            }
            if let action { session.paragraph(action);return true }
        }
        if modifiers == [.command,.shift],key == "g" { session.find(session.lastQuery,backward:true);return true }
        return super.performKeyEquivalent(with:event)
    }
    var focused:(()->Void)?
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) {
        if !hasMarkedText(), let onEscape { onEscape() }
        else { super.cancelOperation(sender) }
    }
    override func becomeFirstResponder() -> Bool { restorePosition();let result = super.becomeFirstResponder();if result { focused?();WritingRegistry.attach(self,key:positionKey) };return result }
    var positionKey = ""
    var pendingPosition: WritingPositions.Position?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, pendingPosition != nil else { return }
        DispatchQueue.main.async { [weak self] in self?.restorePosition() }
    }
    func restorePosition() {
        guard window != nil, let pendingPosition, !hasMarkedText() else { return }
        WritingPositions.shared.restore(self,position:pendingPosition)
        self.pendingPosition = nil
    }
    override func paste(_ sender:Any?) {
        guard !hasMarkedText() else { super.paste(sender);return }
        breakUndoCoalescing()
        undoManager?.beginUndoGrouping()
        super.paste(sender)
        undoManager?.endUndoGrouping()
        breakUndoCoalescing()
    }
    var allowsMarkdownFormatting = true
    var supportsMarkdownLists = false
    var continuesMarkdownQuotes = false
    private let editingHistory = UndoManager()
    override func insertNewline(_ sender:Any?) {
        guard !hasMarkedText() else { super.insertNewline(sender);return }
        if continuesMarkdownQuotes, let edit = WritingEdit.quoteNewline(string,selection:selectedRange()) {
            WritingEdit.apply(edit,to:self)
        } else if supportsMarkdownLists, let edit = WritingEdit.newline(string,selection:selectedRange()) {
            WritingEdit.apply(edit,to:self)
        } else {
            breakUndoCoalescing()
            super.insertNewline(sender)
            breakUndoCoalescing()
        }
    }
    override func insertTab(_ sender:Any?) {
        if supportsMarkdownLists,!hasMarkedText(),let edit = WritingEdit.indent(string,selection:selectedRange(),outdent:false) { WritingEdit.apply(edit,to:self) } else { super.insertTab(sender) }
    }
    override func insertBacktab(_ sender:Any?) {
        if supportsMarkdownLists,!hasMarkedText(),let edit = WritingEdit.indent(string,selection:selectedRange(),outdent:true) { WritingEdit.apply(edit,to:self) } else { super.insertBacktab(sender) }
    }
    override var undoManager:UndoManager? { editingHistory }
    func finishEditingSession() {
        if !hasMarkedText() { committed?(self) }
        WritingPositions.shared.capture(self,key:positionKey)
        WritingPositions.shared.flush()
        WritingRegistry.detach(self,key:positionKey)
        committed = nil
        focused = nil
        delegate = nil
        editingHistory.removeAllActions()
    }
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
    private var scrollObserver:NSObjectProtocol?
    func observeScroll(_ scroll:NSScrollView,view:ComposingTextView) {
        scroll.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName:NSView.boundsDidChangeNotification,object:scroll.contentView,queue:.main) { [weak view] _ in MainActor.assumeIsolated { if let view { WritingPositions.shared.capture(view,key:view.positionKey) } } }
    }
    deinit { if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) } }
    init(read: @escaping () -> String, write: @escaping (String) -> Void) { self.read = read; self.write = write; accepted = read() }
    func synchronize(_ view: NSTextView) {
        let value=read();guard !view.hasMarkedText(),value != accepted else { return }
        if view.string != accepted {
            DispatchQueue.main.async { [weak self,weak view] in if let view { self?.publish(view) } };return
        }
        accepted=value;TextInputSync.replaceExternal(view,with:value)
    }
    func publish(_ view: NSTextView) {
        guard !view.hasMarkedText() else { return }
        let external=read()
        guard external != view.string else { accepted=external;return }
        let merged=ConcurrentText053.merge(base:accepted,local:view.string,external:external)
        if merged.text != view.string { TextInputSync.replaceExternal(view,with:merged.text) }
        if merged.conflict { (view as? ComposingTextView)?.writingSession?.message="另一处也修改了这条笔记，两份内容均已保留，请核对" }
        accepted=merged.text;write(merged.text);accepted=read()
    }
    func textViewDidChangeSelection(_ notification:Notification) { if let view = notification.object as? ComposingTextView { WritingPositions.shared.capture(view,key:view.positionKey) } }
    func textDidChange(_ notification: Notification) { if let view = notification.object as? NSTextView { publish(view) } }
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        let external=read();guard external != field.stringValue else { accepted=external;return }
        let result=ConcurrentText053.merge(base:accepted,local:field.stringValue,external:external,singleLine:true)
        if result.text != field.stringValue { field.stringValue=result.text };accepted=result.text;write(result.text);accepted=read()
    }
    func controlTextDidEndEditing(_ notification: Notification) { controlTextDidChange(notification) }
}

