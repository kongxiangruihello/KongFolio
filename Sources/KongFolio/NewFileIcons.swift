import SwiftUI

/// The same four compact actions accompany the KongFolio branding in PDF and text editor toolbars.
struct NewFileIcons: View {
    var store: WorkspaceStore?
    var spacing: CGFloat = 8
    @AppStorage(ToolbarPreferences.key) private var saved = ""
    var body: some View {
        if let store {
            HStack(spacing: spacing) {
                ForEach(ToolbarPreferences.decode(saved).visible.filter(\.isNewFile)) { action in
                    icon(action.title, symbol: action.symbol) {
                        switch action {
                        case .newPDF: store.newPDF()
                        case .newMarkdown: store.newNote()
                        case .newText: store.newNote(format: .plain)
                        case .newHTML: store.newNote(format: .html)
                        default: break
                        }
                    }
                }
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
