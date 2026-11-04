import AppKit

/// Screen-only preferences. Export and document contents keep their own layout.
struct EditorDisplayOptions: Codable, Equatable {
    static let key = "KongFolio.editorDisplay050"
    enum Face: String, Codable, CaseIterable { case system = "系统字体", serif = "宋体", mono = "等宽字体" }
    enum Column: String, Codable, CaseIterable { case comfortable = "舒适行宽", wide = "宽行", full = "铺满编辑区" }
    var size = 18.0
    var lineHeight = 1.6
    var face = Face.system
    var column = Column.comfortable
    var valid: Bool { size.isFinite && (14...30).contains(size) && lineHeight.isFinite && (1.2...2).contains(lineHeight) }
    var width: Double { switch column { case .comfortable: return 760; case .wide: return 1000; case .full: return .greatestFiniteMagnitude } }
    func inset(viewport: Double) -> Double { guard viewport.isFinite else { return 20 };let edge = viewport < 420 ? 16.0 : 28.0;return max(edge,(viewport-width)/2) }
    static func load(_ defaults: UserDefaults = .standard) -> Self {
        guard let bytes = defaults.data(forKey:key),let value = try? JSONDecoder().decode(Self.self,from:bytes),value.valid else { return Self() };return value
    }
    func save(_ defaults: UserDefaults = .standard) { guard valid,let bytes = try? JSONEncoder().encode(self) else { return };defaults.set(bytes,forKey:Self.key) }
    var font: NSFont { switch face { case .system: return .systemFont(ofSize:size);case .serif: return NSFont(name:"Songti SC",size:size) ?? .systemFont(ofSize:size);case .mono: return .monospacedSystemFont(ofSize:size,weight:.regular) } }
}

/// Changes presentation without replacing characters or rebuilding the native editor.
class DisplayTextView: ComposingTextView {
    var displayOptions: EditorDisplayOptions? { didSet { updateDisplay() } }
    private var applied: EditorDisplayOptions?
    override func setFrameSize(_ size:NSSize) { super.setFrameSize(size);updateMargins() }
    override func unmarkText() { super.unmarkText();updateDisplay() }
    func updateDisplay() {
        guard let options = displayOptions,options.valid,!hasMarkedText() else { return }
        updateMargins()
        guard applied != options else { return }
        let selections = selectedRanges,origin = enclosingScrollView?.contentView.bounds.origin
        let paragraph = NSMutableParagraphStyle();paragraph.lineSpacing = options.size*(options.lineHeight-1);paragraph.paragraphSpacing = options.size*0.25
        let attributes:[NSAttributedString.Key:Any] = [.font:options.font,.foregroundColor:NSColor.textColor,.paragraphStyle:paragraph]
        let undoEnabled = undoManager?.isUndoRegistrationEnabled == true
        if undoEnabled { undoManager?.disableUndoRegistration() }
        font = options.font;defaultParagraphStyle = paragraph;typingAttributes = attributes
        textStorage?.addAttributes(attributes,range:NSRange(location:0,length:(string as NSString).length))
        if undoEnabled { undoManager?.enableUndoRegistration() }
        selectedRanges = selections;applied = options
        if let origin,let scroll = enclosingScrollView { scroll.contentView.scroll(to:origin);scroll.reflectScrolledClipView(scroll.contentView) }
    }
    private func updateMargins() {
        guard let options = displayOptions,options.valid,!hasMarkedText() else { return }
        let inset = NSSize(width:options.inset(viewport:frame.width),height:24)
        if textContainerInset != inset { textContainerInset = inset }
    }
}
