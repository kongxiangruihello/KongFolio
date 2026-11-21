import AppKit
import SwiftUI

struct ReaderToolDropPosition: Equatable {
    let action: FileToolbarAction
    let after: Bool
}

struct ReaderToolFrames: PreferenceKey {
    static let space = "reader-tool-order"
    static let defaultValue: [FileToolbarAction: CGRect] = [:]

    static func reduce(value: inout [FileToolbarAction: CGRect], nextValue: () -> [FileToolbarAction: CGRect]) {
        value.merge(nextValue()) { _, newer in newer }
    }
}

/// A click keeps the original AppKit events so native menus can use their normal mouse tracking.
struct ReaderToolbarMouseTrack {
    enum Result {
        case forward, consume
        case click(NSEvent, NSEvent)
        case preview(ReaderToolDropPosition?)
        case drop(FileToolbarAction, ReaderToolDropPosition?)
    }

    private struct Press {
        let event: NSEvent
        let point: CGPoint
        let action: FileToolbarAction
        var dragging = false
        var cancelled = false
    }

    private var press: Press?
    var isPressed: Bool { press != nil }

    mutating func handle(_ event: NSEvent, at point: CGPoint, frames: [FileToolbarAction: CGRect]) -> Result {
        let target = frames.first { $0.value.contains(point) }
        let position = target.map { ReaderToolDropPosition(action: $0.key, after: point.x >= $0.value.midX) }
        switch event.type {
        case .leftMouseDown:
            guard let target else { return .forward }
            press = Press(event: event, point: point, action: target.key)
            return .consume
        case .leftMouseDragged:
            guard var current = press else { return .forward }
            guard !current.cancelled else { return .consume }
            if !current.dragging && moved(from: current.point, to: point) {
                current.dragging = true
                press = current
            }
            return current.dragging ? .preview(position) : .consume
        case .leftMouseUp:
            guard let current = press else { return .forward }
            press = nil
            guard !current.cancelled else { return .consume }
            if current.dragging { return .drop(current.action, position) }
            guard target?.key == current.action, !moved(from: current.point, to: point) else { return .consume }
            return .click(current.event, event)
        case .keyDown where event.keyCode == 53 && press?.dragging == true:
            press?.cancelled = true
            return .preview(nil)
        default:
            return .forward
        }
    }

    private func moved(from start: CGPoint, to end: CGPoint) -> Bool {
        hypot(end.x - start.x, end.y - start.y) >= 5
    }
}

struct ReaderToolbarPointer: NSViewRepresentable {
    let frames: [FileToolbarAction: CGRect]
    let preview: (ReaderToolDropPosition?) -> Void
    let move: (FileToolbarAction, ReaderToolDropPosition) -> Void

    func makeNSView(context: Context) -> Surface { Surface() }

    func updateNSView(_ view: Surface, context: Context) {
        view.actions = self
    }

    static func dismantleNSView(_ view: Surface, coordinator: ()) { view.stopMonitoring() }

    final class Surface: NSView {
        var actions: ReaderToolbarPointer?
        private var monitor: Any?
        private var track = ReaderToolbarMouseTrack()
        private var replayedDown: NSEvent?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow !== window { stopMonitoring() }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self else { return event }
                    return self.route(event)
                }
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            track = ReaderToolbarMouseTrack()
            replayedDown = nil
        }

        private func route(_ event: NSEvent) -> NSEvent? {
            guard let window, let actions else { return event }
            if event.type == .leftMouseDown, let replayedDown {
                self.replayedDown = nil
                if event.timestamp == replayedDown.timestamp && event.eventNumber == replayedDown.eventNumber &&
                    event.windowNumber == replayedDown.windowNumber { return event }
            }
            guard event.window === window || (track.isPressed && event.type != .leftMouseDown) else { return event }
            let point = event.window === window ? convert(event.locationInWindow, from: nil) : CGPoint(x: -1, y: -1)
            switch track.handle(event, at: point, frames: actions.frames) {
            case .forward:
                return event
            case .consume:
                break
            case let .click(down, up):
                replayedDown = down
                // Queue mouse-up first so it is available if the mouse-down opens a native menu's tracking loop.
                NSApp.postEvent(up, atStart: true)
                NSApp.postEvent(down, atStart: true)
            case let .preview(position):
                actions.preview(position)
            case let .drop(source, position):
                actions.preview(nil)
                if let position { actions.move(source, position) }
            }
            return nil
        }
    }
}
