import SwiftUI

struct PDFSelectionActions: View {
    let editable: Bool
    let compact: Bool
    let excerpt: () -> Void
    let note: () -> Void
    var insertInNote: (() -> Void)? = nil
    let copy: () -> Void
    let mark: (MarkupStyle, MarkupColor?, Bool) -> Void

    @State private var showMarkup = false

    var body: some View {
        HStack(spacing: 4) {
            action("摘录", icon: "text.quote", help: "保存为摘录", primary: true, perform: excerpt)
            action("写笔记", icon: "square.and.pencil", help: "针对所选原文写笔记", perform: note)
            if let insertInNote {
                action("插入笔记",icon:"text.append",help:"把原文和出处插入右侧固定笔记的光标处",perform:insertInNote)
            }
            action("复制", icon: "doc.on.doc", help: "复制原文和出处", perform: copy)
            if editable {
                Divider().frame(height: 19).padding(.horizontal, 3)
                Button { showMarkup.toggle() } label: {
                    HStack(spacing:4) {
                        caption("标注", icon:"highlighter", showText:!compact)
                        Image(systemName:"chevron.down").font(.system(size:8,weight:.semibold))
                    }
                }
                .buttonStyle(PDFSelectionActionStyle(primary:false))
                .accessibilityLabel("标注")
                .help("高亮、下划线、删除线和批注")
                .popover(isPresented:$showMarkup,arrowEdge:.bottom) { markupOptions }
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .padding(6)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
        .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(.primary.opacity(0.17)) }
        .shadow(color: .black.opacity(0.26), radius: 5, y: 2)
        .padding(compact ? 5 : 7)
        .fixedSize()
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
            Label(title,systemImage:icon).frame(maxWidth:.infinity,alignment:.leading)
        }.buttonStyle(.borderless).padding(.vertical,3)
    }

    private func applyMarkup(_ style:MarkupStyle,color:MarkupColor? = nil,annotate:Bool = false) {
        showMarkup = false
        mark(style,color,annotate)
    }

    private func action(_ title: String, icon: String, help: String, primary: Bool = false,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            caption(title, icon: icon, showText: primary || !compact)
        }
        .buttonStyle(PDFSelectionActionStyle(primary: primary))
        .accessibilityLabel(title)
        .help(help)
    }

    private func caption(_ title: String, icon: String, showText: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
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
