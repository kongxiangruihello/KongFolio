import SwiftUI
import UniformTypeIdentifiers

struct ReaderToolDropPosition: Equatable {
    let action: FileToolbarAction
    let after: Bool
}

private struct ReaderToolDragPayload: Codable {
    static let contentType = UTType(exportedAs: "com.kongfolio.toolbar-item", conformingTo: .data)
    let toolbarID: UUID
    let action: String

    func itemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        if let data = try? JSONEncoder().encode(self) {
            provider.registerDataRepresentation(forTypeIdentifier: Self.contentType.identifier, visibility: .ownProcess) { completion in
                completion(data, nil)
                return nil
            }
        }
        return provider
    }
}

struct DraggableReaderTool: ViewModifier {
    let action: FileToolbarAction
    let toolbarID: UUID
    @Binding var insertion: ReaderToolDropPosition?
    let move: (FileToolbarAction, FileToolbarAction, Bool) -> Void
    @State private var width: CGFloat = 34

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onDrag {
                ReaderToolDragPayload(toolbarID: toolbarID, action: action.rawValue).itemProvider()
            }
            .onDrop(of: [ReaderToolDragPayload.contentType], delegate: ReaderToolDrop(
                toolbarID: toolbarID, action: action, midpoint: width / 2, insertion: $insertion, move: move
            ))
            .overlay(alignment: insertion?.after == true ? .trailing : .leading) {
                if insertion?.action == action {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 3, height: 28)
                        .allowsHitTesting(false)
                }
            }
    }
}

@MainActor
private struct ReaderToolDrop: DropDelegate {
    let toolbarID: UUID
    let action: FileToolbarAction
    let midpoint: CGFloat
    @Binding var insertion: ReaderToolDropPosition?
    let move: (FileToolbarAction, FileToolbarAction, Bool) -> Void

    func dropEntered(info: DropInfo) { showInsertion(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        showInsertion(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if insertion?.action == action { insertion = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        insertion = nil
        let after = info.location.x >= midpoint
        let type = ReaderToolDragPayload.contentType
        guard let provider = info.itemProviders(for: [type]).first else { return false }
        _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
            guard let data, let payload = try? JSONDecoder().decode(ReaderToolDragPayload.self, from: data),
                  let source = FileToolbarAction(rawValue: payload.action) else { return }
            Task { @MainActor in
                guard payload.toolbarID == toolbarID else { return }
                move(source, action, after)
            }
        }
        return true
    }

    private func showInsertion(_ info: DropInfo) {
        let position = ReaderToolDropPosition(action: action, after: info.location.x >= midpoint)
        if insertion != position { insertion = position }
    }
}
