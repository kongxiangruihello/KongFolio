import Foundation

enum FileToolbarAction:String,CaseIterable,Identifiable {
    case open,library,excerpt,note,essay,annotate,tools,save,newPDF,newMarkdown,newText,newHTML,quickNote,export,books,jobs,sidebar
    var id:String { rawValue }
    var title:String { switch self { case .open:return "打开文件";case .library:return "资料库";case .excerpt:return "摘录";case .note:return "当前页笔记";case .essay:return "札记";case .annotate:return "标注工具";case .tools:return "快捷工具";case .save:return "保存";case .newPDF:return "新建 PDF";case .newMarkdown:return "新建 Markdown";case .newText:return "新建文本文件";case .newHTML:return "新建 HTML";case .quickNote:return "速记（⌥⌘N）";case .export:return "导出";case .books:return "个人书架与阅读记录";case .jobs:return "后台任务";case .sidebar:return "页面导航" } }
    var symbol:String { switch self { case .open:return "folder";case .library:return "books.vertical.fill";case .excerpt:return "text.quote";case .note:return "note.text.badge.plus";case .essay:return "doc.richtext";case .annotate:return "pencil.tip.crop.circle";case .tools:return "square.grid.2x2";case .save:return "square.and.arrow.down";case .newPDF:return "doc.badge.plus";case .newMarkdown:return "square.and.pencil";case .newText:return "doc.text";case .newHTML:return "chevron.left.forwardslash.chevron.right";case .quickNote:return "pencil.and.scribble";case .export:return "square.and.arrow.up";case .books:return "books.vertical";case .jobs:return "checklist";case .sidebar:return "sidebar.left" } }
}
enum SingleRowToolbarPolicy {
    static func titleWidth(_ width:Double)->Double { 0 }
    static func visibleCount(width:Double)->Int { guard width.isFinite else { return 0 };return max(0,min(FileToolbarAction.allCases.count,Int((max(0,width)-titleWidth(width)-24-78)/36))) }
    static func visible(width:Double)->[FileToolbarAction] { Array(FileToolbarAction.allCases.prefix(visibleCount(width:width))) }
    static func hidden(width:Double)->[FileToolbarAction] { Array(FileToolbarAction.allCases.dropFirst(visibleCount(width:width))) }
}
