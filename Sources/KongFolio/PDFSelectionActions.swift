import SwiftUI

struct PDFSelectionActions: View {
    let editable: Bool
    let compact: Bool
    let excerpt: () -> Void
    var addSelection: (() -> Void)? = nil
    var selectionCount: Int? = nil
    var selectionUnit = "段"
    var cancelSelection: (() -> Void)? = nil
    let note: () -> Void
    var insertInNote: (() -> Void)? = nil
    var noteTargetTitle: String? = nil
    let copy: () -> Void
    var copyAs: ((ReadingExcerptCopyFormat) -> Void)? = nil
    var openExisting: (() -> Void)? = nil
    var comment: (() -> Void)? = nil
    let mark: (MarkupStyle, MarkupColor?, Bool) -> Void

    @State private var showMarkup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let cancelSelection {
                HStack(spacing: 4) {
                    let title = selectionCount.map { "摘录（\($0) \(selectionUnit)）" } ?? "摘录"
                    action(title, icon: "text.quote", help: "将选区保存为摘录", primary: true, perform: excerpt)
                    action("取消", icon: "xmark", help: "取消增加选区（Esc）", perform: cancelSelection)
                }
            } else { standardActions }
            if let addSelection {
                action("增加选区", icon: "plus", help: "保留当前选区，再用鼠标选择其他区域", showTitle: true, perform: addSelection)
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .padding(6)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
        .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(.primary.opacity(0.17)).allowsHitTesting(false) }
        .shadow(color: .black.opacity(0.26), radius: 5, y: 2)
        .padding(compact ? 5 : 7)
        .fixedSize()
    }

    private var standardActions: some View {
        HStack(spacing: 4) {
            if let openExisting {
                action("打开已有摘录",icon:"text.quote",help:"此处已经摘录，打开原有记录",primary:true,perform:openExisting)
            } else {
                action("摘录",icon:"text.quote",help:"保存为摘录",primary:true,perform:excerpt)
            }
            action("写笔记", icon: "square.and.pencil", help: "针对所选原文写笔记", perform: note)
            if let insertInNote {
                action("加入当前笔记",icon:"text.append",help:noteTargetTitle.map { "加入《" + $0 + "》" } ?? "加入当前笔记",perform:insertInNote)
            }
            action("复制",icon:"doc.on.doc",help:"按上次选择的格式复制",perform:copy)
            if let copyAs {
                Menu {
                    ForEach([ReadingExcerptCopyFormat.citation, .text, .markdown],id:\.self) { format in
                        Button(format.rawValue) { copyAs(format) }
                    }
                } label: { AppIcon("chevron.down").font(.system(size:8,weight:.semibold)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("选择复制格式").accessibilityLabel("选择复制格式")
            }
            if editable {
                if let comment {
                    action("评论", icon: "text.bubble", help: "在所选文字旁添加 PDF 评论", perform: comment)
                }
                Divider().frame(height: 19).padding(.horizontal, 3)
                Button { showMarkup.toggle() } label: {
                    HStack(spacing:4) {
                        caption("标注", icon:"highlighter", showText:!compact)
                        AppIcon("chevron.down").font(.system(size:8,weight:.semibold))
                    }
                }
                .buttonStyle(PDFSelectionActionStyle(primary:false))
                .accessibilityLabel("标注")
                .help("高亮、下划线、删除线和批注")
                .popover(isPresented:$showMarkup,arrowEdge:.bottom) { markupOptions }
            }
        }
    }

    private var markupOptions: some View {
        VStack(alignment:.leading,spacing:5) {
            HStack(spacing:7) {
                ForEach(MarkupColor.allCases) { color in
                    Button { applyMarkup(.highlight,color:color) } label: {
                        Circle().fill(Color(nsColor:color.nsColor)).frame(width:15,height:15)
                            .frame(width:30,height:30)
                            .background(.quaternary,in:RoundedRectangle(cornerRadius:6))
                    }
                    .buttonStyle(.plain)
                    .help(color.rawValue+"色高亮")
                    .accessibilityLabel(color.rawValue+"色高亮")
                }
            }
            Divider()
            markupOption("下划线",icon:"underline",style:.underline)
            markupOption("删除线",icon:"strikethrough",style:.strikeOut)
            markupOption("高亮并加批注",icon:"text.bubble",style:.highlight,annotate:true)
        }.frame(width:145).padding(10).font(.system(size:13))
    }

    private func markupOption(_ title:String,icon:String,style:MarkupStyle,annotate:Bool = false) -> some View {
        Button { applyMarkup(style,annotate:annotate) } label: {
            Label(title,appIcon:icon).frame(maxWidth:.infinity,alignment:.leading)
        }.buttonStyle(.borderless).padding(.vertical,3)
    }

    private func applyMarkup(_ style:MarkupStyle,color:MarkupColor? = nil,annotate:Bool = false) {
        showMarkup = false
        mark(style,color,annotate)
    }

    private func action(_ title: String, icon: String, help: String, primary: Bool = false, showTitle: Bool = false,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            caption(title, icon: icon, showText: showTitle || primary || !compact, tone: primary ? AppIcon.onAccent : nil)
        }
        .buttonStyle(PDFSelectionActionStyle(primary: primary))
        .accessibilityLabel(title)
        .help(help)
    }

    private func caption(_ title: String, icon: String, showText: Bool, tone: Color? = nil) -> some View {
        HStack(spacing: 5) {
            AppIcon(icon, tone: tone)
            if showText { Text(title) }
        }
        .lineLimit(1)
    }
}

private struct PDFSelectionActionStyle: ButtonStyle {
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(primary ? Color.white : Color.primary)
            .padding(.horizontal, 8)
            .frame(minWidth: 32, minHeight: 31)
            .background(primary ? Color(nsColor: .systemBlue).opacity(configuration.isPressed ? 0.76 : 1)
                                : Color.primary.opacity(configuration.isPressed ? 0.15 : 0.055),
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}
