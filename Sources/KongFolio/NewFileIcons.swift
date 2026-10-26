import SwiftUI

/// The same four compact actions accompany the KongFolio branding in PDF and text editor toolbars.
struct NewFileIcons: View {
    var store: WorkspaceStore?
    var spacing: CGFloat = 8
    var body: some View {
        if let store {
            HStack(spacing: spacing) {
                icon("新建 PDF", symbol: "doc.badge.plus") { store.newPDF() }
                icon("新建 Markdown 文件", symbol: "square.and.pencil") { store.newNote() }
                icon("新建文本文件", symbol: "doc.plaintext") { store.newNote(format: .plain) }
                icon("新建 HTML 文件", symbol: "chevron.left.forwardslash.chevron.right") { store.newNote(format: .html) }
            }.fixedSize()
        }
    }
    private func icon(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15)).frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Brand.accent)
        .accessibilityLabel(title)
        .help(title)
    }
}
