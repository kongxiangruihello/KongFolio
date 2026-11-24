import AppKit
import SwiftUI

/// Keeps mouse tracking in one AppKit view so the cell's click and drag actions never compete.
struct PDFThumbnailPointer: NSViewRepresentable {
    let click: (NSEvent) -> Void
    let drag: () -> (payload: String, image: NSImage?)?
    let propose: (PageDrag) -> NSDragOperation
    let hover: (Bool?) -> Void
    let drop: (String, Bool) -> Bool
    let open: () -> Void
    let extract: () -> Void
    var vertical = false
    var pageActions: [PageAction] = []

    struct PageAction {
        let title: String
        var enabled = true
        let perform: () -> Void
    }

    func makeNSView(context: Context) -> Surface {
        let view = Surface()
        view.registerForDraggedTypes([.string])
        return view
    }

    func updateNSView(_ view: Surface, context: Context) { view.actions = self }

    final class Surface: NSView, NSDraggingSource {
        var actions: PDFThumbnailPointer?
        private var pressed: NSPoint?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            pressed = convert(event.locationInWindow, from: nil)
        }

        override func mouseUp(with event: NSEvent) {
            defer { pressed = nil }
            guard pressed != nil, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            actions?.click(event)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let pressed else { return }
            let point = convert(event.locationInWindow, from: nil)
            guard hypot(point.x - pressed.x, point.y - pressed.y) >= 4 else { return }
            self.pressed = nil
            guard let drag = actions?.drag() else { return }

            let item = NSDraggingItem(pasteboardWriter: drag.payload as NSString)
            let fallback = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [.systemBlue, .systemCyan]))
            let image = drag.image ?? fallback ?? NSImage(size: bounds.size)
            let scale = min(1, 100 / max(1, image.size.width), 125 / max(1, image.size.height))
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            item.setDraggingFrame(NSRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                         width: size.width, height: size.height), contents: image)
            beginDraggingSession(with: [item], event: event, source: self).animatesToStartingPositionsOnCancelOrFail = true
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .withinApplication ? [.move, .copy] : []
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            actions?.hover(nil)
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            let after = isAfter(sender)
            guard let text = sender.draggingPasteboard.string(forType: .string),
                  let payload = PageDrag.decode(text),
                  let proposal = actions?.propose(payload), !proposal.isEmpty else { return [] }
            actions?.hover(after)
            return proposal
        }

        override func draggingExited(_ sender: NSDraggingInfo?) { actions?.hover(nil) }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            defer { actions?.hover(nil) }
            let after = isAfter(sender)
            guard let text = sender.draggingPasteboard.string(forType: .string),
                  let payload = PageDrag.decode(text),
                  let proposal = actions?.propose(payload), !proposal.isEmpty else { return false }
            return actions?.drop(text, after) ?? false
        }

        private func isAfter(_ sender: NSDraggingInfo) -> Bool {
            let point = convert(sender.draggingLocation, from: nil)
            return actions?.vertical == true ? point.y < bounds.midY : point.x >= bounds.midX
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            let menu = NSMenu()
            if let actions, actions.vertical {
                menu.autoenablesItems = false
                for (index, action) in actions.pageActions.enumerated() {
                    let item = NSMenuItem(title: action.title, action: #selector(performPageAction(_:)), keyEquivalent: "")
                    item.target = self
                    item.tag = index
                    item.isEnabled = action.enabled
                    menu.addItem(item)
                }
                return menu
            }
            for (title, action) in [("打开此页", #selector(openPage)), ("提取选中页面…", #selector(extractPages))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
            return menu
        }

        @objc private func performPageAction(_ item: NSMenuItem) {
            guard let items = actions?.pageActions, items.indices.contains(item.tag), items[item.tag].enabled else { return }
            items[item.tag].perform()
        }

        @objc private func openPage() { actions?.open() }
        @objc private func extractPages() { actions?.extract() }
    }
}
