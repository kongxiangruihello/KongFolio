import SwiftUI

struct PDFPageToolButtons: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        Group {
            Button { present { workspace.showPageSplit = true } } label: {
                Label("拆分页面…", appIcon: "rectangle.split.2x1")
            }
            Button { present { workspace.openCrop() } } label: {
                Label("裁剪页面…", appIcon: "crop")
            }
            Button { present { workspace.openCrop(detectingBlankEdges: true) } } label: {
                Label("清除空白边…", appIcon: "doc.viewfinder")
            }
        }
        .disabled(!canEdit)
    }

    private var canEdit: Bool {
        workspace.count > 0 && !workspace.busy && !workspace.readingLocked
            && workspace.placingSignature == nil && !workspace.drawingInProgress
    }

    private func present(_ action: @escaping () -> Void) {
        guard canEdit else { return }
        if workspace.showTools {
            workspace.showTools = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if canEdit { action() }
            }
        } else { action() }
    }
}
