import SwiftUI

struct TextEditorPreviewSplit: View {
    @ObservedObject var note: MarkdownNote
    @AppStorage("KongFolio.textPreviewEditorFraction") private var fraction = 0.55
    var body: some View {
        GeometryReader { geometry in
            let preview = note.format != .plain && LayoutMetrics.showsPreview(preferred:note.showPreview,width:geometry.size.width)
            let width = geometry.size.width
            HStack(spacing:0) {
                MarkdownTextView(note:note).frame(width:preview ? max(180,min(width-188,width*safeFraction)) : width)
                if preview {
                    Rectangle().fill(.quaternary).frame(width:8).contentShape(Rectangle())
                        .overlay { Rectangle().fill(.secondary.opacity(0.4)).frame(width:1) }
                        .gesture(DragGesture(coordinateSpace:.named("text-editor-split")).onChanged { value in fraction = min(0.8,max(0.2,value.location.x/max(1,width))) })
                        .accessibilityLabel("编辑区与预览区分隔条")
                        .accessibilityAdjustableAction { direction in fraction = min(0.8,max(0.2,safeFraction+(direction == .increment ? 0.05 : -0.05))) }
                        .help("拖动调整编辑区与预览区的宽度")
                    VStack(spacing:0) {
                        if !note.previewMessage.isEmpty { Text(note.previewMessage).font(.caption).foregroundStyle(.orange).padding(8) }
                        MarkdownPreview(note:note)
                    }.frame(maxWidth:.infinity,maxHeight:.infinity)
                }
            }.coordinateSpace(name:"text-editor-split")
        }
    }
    private var safeFraction: Double { fraction.isFinite ? min(0.8,max(0.2,fraction)) : 0.55 }
}
