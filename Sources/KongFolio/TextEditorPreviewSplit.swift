import SwiftUI

struct TextEditorPreviewSplit: View {
    @ObservedObject var note: MarkdownNote
    var allowsPreview = true
    @AppStorage("KongFolio.textPreviewEditorFraction") private var fraction = 0.55
    private let dividerWidth: CGFloat = 18
    private let minimumPaneWidth: CGFloat = 180

    var body: some View {
        GeometryReader { geometry in
            let preview = allowsPreview && note.format != .plain && LayoutMetrics.showsPreview(preferred:note.showPreview,width:geometry.size.width)
            let width = geometry.size.width
            let editorWidth = preview ? min(width-dividerWidth-minimumPaneWidth,max(minimumPaneWidth,width*safeFraction)) : width
            HStack(spacing:0) {
                MarkdownTextView(note:note).frame(width:editorWidth)
                if preview {
                    PreviewResizeHandle(editorWidth:editorWidth) { position in
                        resize(to:position,totalWidth:width)
                    }
                    .frame(width:dividerWidth)
                    .frame(maxHeight:.infinity)
                    .accessibilityElement(children:.ignore)
                    .accessibilityLabel("编辑区与预览区分隔条")
                    .accessibilityValue("\(Int((editorWidth/width*100).rounded()))%")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: resize(to:editorWidth+width*0.05,totalWidth:width)
                        case .decrement: resize(to:editorWidth-width*0.05,totalWidth:width)
                        @unknown default: break
                        }
                    }
                    VStack(spacing:0) {
                        if !note.previewMessage.isEmpty { Text(note.previewMessage).font(.caption).foregroundStyle(.orange).padding(8) }
                        HStack { Label("导出预览",systemImage:"doc.text.magnifyingglass");Spacer();Button("定位预览") { note.locatePreview(focus:true) };Button("返回正文") { note.locateSource(focus:true) } }.font(.system(size:12)).padding(10).background(.bar)
                        MarkdownPreview(note:note)
                    }.frame(maxWidth:.infinity,maxHeight:.infinity)
                }
            }
        }
    }
    private func resize(to position:CGFloat,totalWidth:CGFloat) {
        let minimum = max(minimumPaneWidth,totalWidth*0.2)
        let maximum = min(totalWidth-dividerWidth-minimumPaneWidth,totalWidth*0.8)
        fraction = min(maximum,max(minimum,position))/totalWidth
    }

    private var safeFraction: Double { fraction.isFinite ? min(0.8,max(0.2,fraction)) : 0.55 }
}


private struct PreviewResizeHandle: NSViewRepresentable {
    let editorWidth: CGFloat
    let resize: (CGFloat) -> Void

    func makeNSView(context:Context) -> HandleView {
        let view = HandleView()
        view.toolTip = "左右拖动，调整正文和预览的宽度"
        return view
    }

    func updateNSView(_ view:HandleView,context:Context) {
        view.editorWidth = editorWidth
        view.resize = resize
    }

    final class HandleView: NSView {
        var editorWidth: CGFloat = 0
        var resize: ((CGFloat) -> Void)?
        private var dragStart: (mouseX: CGFloat, editorWidth: CGFloat)?
        private var tracking: NSTrackingArea?
        private var hovered = false { didSet { needsDisplay = true } }

        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds,cursor:.resizeLeftRight)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event:NSEvent) { hovered = true }
        override func mouseExited(with event:NSEvent) { hovered = false }

        override func mouseDown(with event:NSEvent) {
            dragStart = (event.locationInWindow.x,editorWidth)
            needsDisplay = true
        }

        override func mouseDragged(with event:NSEvent) {
            guard let dragStart else { return }
            resize?(dragStart.editorWidth + event.locationInWindow.x - dragStart.mouseX)
        }

        override func mouseUp(with event:NSEvent) {
            dragStart = nil
            hovered = bounds.contains(convert(event.locationInWindow,from:nil))
        }

        override func draw(_ dirtyRect:NSRect) {
            let active = hovered || dragStart != nil
            let color = active ? NSColor.controlAccentColor : NSColor.separatorColor
            if active {
                color.withAlphaComponent(0.12).setFill()
                bounds.fill()
            }
            color.setFill()
            NSRect(x:bounds.midX-0.5,y:0,width:1,height:bounds.height).fill()
            NSBezierPath(roundedRect:NSRect(x:bounds.midX-2,y:bounds.midY-14,width:4,height:28),
                         xRadius:2,yRadius:2).fill()
        }
    }
}
