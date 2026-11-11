import Foundation

enum FileToolbarAction:String,CaseIterable,Identifiable {
    case search,pdfPages,newFile,comment,open,library,excerpt,note,essay,annotate,tools,signature,save,newPDF,newMarkdown,newText,newHTML,quickNote,export,books,jobs,sidebar
    static var allCases:[Self] { [.newFile,.open,.search,.annotate,.sidebar,.export,.pdfPages,.excerpt,.note,.library,.save,.books,.tools,.signature,.jobs] }
    var unified:Self { switch self { case .newPDF,.newMarkdown,.newText,.newHTML:return .newFile;case .comment:return .annotate;case .essay,.quickNote:return .note;default:return self } }
    var id:String { rawValue }
    var title:String { switch self { case .search:return "搜索 PDF";case .pdfPages:return "编辑 PDF 页面"; case .newFile:return "新建文件";case .comment:return "PDF 评论";case .open:return "打开文件";case .library:return "资料库";case .excerpt:return "摘录";case .note:return "笔记";case .essay:return "笔记";case .annotate:return "标注工具";case .tools:return "PDF 工具";case .signature:return "图片签名";case .save:return "保存";case .newPDF:return "新建 PDF";case .newMarkdown:return "新建 Markdown";case .newText:return "新建文本文件";case .newHTML:return "新建 HTML";case .quickNote:return "笔记（⌥⌘N）";case .export:return "导出";case .books:return "个人书架与阅读记录";case .jobs:return "后台任务";case .sidebar:return "右侧面板" } }
    var symbol:String { switch self { case .search:return "magnifyingglass";case .pdfPages:return "square.and.pencil"; case .newFile:return "doc.badge.plus";case .comment:return "text.bubble";case .open:return "folder";case .library:return "rectangle.stack";case .excerpt:return "text.quote";case .note:return "note.text.badge.plus";case .essay:return "doc.richtext";case .annotate:return "pencil.tip.crop.circle";case .tools:return "square.grid.2x2";case .signature:return "signature";case .save:return "square.and.arrow.down";case .newPDF:return "doc.badge.plus";case .newMarkdown:return "square.and.pencil";case .newText:return "doc.text";case .newHTML:return "chevron.left.forwardslash.chevron.right";case .quickNote:return "pencil.and.scribble";case .export:return "square.and.arrow.up";case .books:return "books.vertical";case .jobs:return "checklist";case .sidebar:return "sidebar.right" } }
}
enum SingleRowToolbarPolicy {
    static func titleWidth(_ width:Double)->Double { 0 }
    static func visibleCount(width:Double)->Int { guard width.isFinite else { return 0 };return max(0,min(FileToolbarAction.allCases.count,Int((max(0,width)-titleWidth(width)-24-174)/36))) }
    static func visible(width:Double)->[FileToolbarAction] { Array(FileToolbarAction.allCases.prefix(visibleCount(width:width))) }
    static func hidden(width:Double)->[FileToolbarAction] { Array(FileToolbarAction.allCases.dropFirst(visibleCount(width:width))) }
}

extension FileToolbarAction {
    var menuTitle:String {
        switch self {
        case .search:return "搜索当前 PDF 正文（右侧面板，⌃F）"
        case .library:return "资料库（独立窗口）"
        case .essay:return "笔记"
        case .note:return "笔记：为当前 PDF 写笔记（⌥⌘N），在资料库统一管理"
        case .annotate:return "标注工具（文档上方）"
        case .tools:return "快捷工具（对话框）"
        case .quickNote:return "笔记（⌥⌘N）"
        case .books:return "个人书架与阅读记录（对话框）"
        case .jobs:return "后台任务（对话框）"
        case .sidebar:return "右侧面板：搜索 PDF、摘录和笔记"
        default:return title
        }
    }
}
