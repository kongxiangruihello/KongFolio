import AppKit

@MainActor final class WritingPositions {
    struct Position:Codable { var selection:NSRange;var x:Double;var y:Double;var date:Date }
    static let shared = WritingPositions()
    private let defaults:UserDefaults
    private var restoring = false
    private var values:[String:Position]
    private var timer:Task<Void,Never>?
    init(defaults:UserDefaults = .standard) {
        self.defaults = defaults;values = defaults.data(forKey:"KongFolio.writingPositions").flatMap{try? JSONDecoder().decode([String:Position].self,from:$0)} ?? [:]
    }
    func capture(_ view:NSTextView,key:String) {
        guard !restoring,!key.isEmpty,!view.hasMarkedText(),(view as? ComposingTextView)?.pendingPosition == nil else { return }
        let origin = view.enclosingScrollView?.contentView.bounds.origin ?? .zero
        values[key] = Position(selection:view.selectedRange(),x:origin.x,y:origin.y,date:Date())
        if values.count>500 { for key in values.sorted(by:{$0.value.date>$1.value.date}).dropFirst(500).map(\.key) { values[key] = nil } }
        timer?.cancel();timer = Task { [weak self] in do { try await Task.sleep(nanoseconds:400_000_000) } catch { return };self?.flush() }
    }
    func position(for key:String) -> Position? { values[key] }
    func restore(_ view:NSTextView,key:String) {
        if let position = values[key] { restore(view,position:position) }
    }
    func restore(_ view:NSTextView,position p:Position) {
        guard !view.hasMarkedText(),p.x.isFinite,p.y.isFinite else { return }
        restoring = true;defer { restoring = false }
        view.setSelectedRange(MarkdownNote.clamp(p.selection,to:view.string.utf16.count))
        if let scroll = view.enclosingScrollView { scroll.layoutSubtreeIfNeeded();if let container = view.textContainer { view.layoutManager?.ensureLayout(for:container) };scroll.contentView.scroll(to:CGPoint(x:max(0,p.x),y:max(0,p.y)));scroll.reflectScrolledClipView(scroll.contentView) }
    }
    func flush() { timer?.cancel();timer = nil;if let data = try? JSONEncoder().encode(values) { defaults.set(data,forKey:"KongFolio.writingPositions") } }
}

@MainActor enum WritingRegistry {
    final class Entry { weak var view:NSTextView?;init(_ view:NSTextView) { self.view = view } }
    private static var entries:[String:Entry] = [:]
    static func attach(_ view:NSTextView,key:String) { guard !key.isEmpty else { return };entries = entries.filter{$0.value.view != nil};entries[key] = Entry(view) }
    static func jumpIfCurrent(_ hit:ReadingTextHit) { guard let view = entries[hit.identity]?.view,view.string == hit.source,!view.hasMarkedText() else { return };jump(hit.identity,range:hit.range) }
    static func focus(_ key:String) -> Bool {
        guard let view = entries[key]?.view, let window = view.window, !view.hasMarkedText() else { return false }
        return window.makeFirstResponder(view)
    }
    static func followUpSelection(_ key:String) -> (text:String,range:NSRange)? {
        guard let view = entries[key]?.view, !view.hasMarkedText() else { return nil }
        return (view.string,view.selectedRange())
    }
    static func selection(_ key:String) -> NSRange? { entries[key]?.view?.selectedRange() }
    static func insertAtCursor(_ text:String,key:String,expected:String,window:NSWindow?) -> Bool {
        guard let view = entries[key]?.view,let editorWindow = view.window,
              window == nil || window === editorWindow,view.isEditable,!view.hasMarkedText(),view.string == expected else { return false }
        let cursor = MarkdownNote.clamp(view.selectedRange(),to:view.string.utf16.count).location
        let before = view.string
        let insertion = NSRange(location:cursor,length:0)
        let caret = NSRange(location:cursor+text.utf16.count,length:0)
        WritingEdit.apply(TextEdit(range:insertion,replacement:text,selection:caret),to:view)
        guard view.string != before else { return false }
        view.scrollRangeToVisible(view.selectedRange())
        return true
    }
    static func jump(_ key:String,range:NSRange) { guard let view = entries[key]?.view,!view.hasMarkedText() else { return };let r = MarkdownNote.clamp(range,to:view.string.utf16.count);view.setSelectedRange(r);view.scrollRangeToVisible(r);view.window?.makeFirstResponder(view) }
}
