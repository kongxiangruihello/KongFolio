import SwiftUI
struct NewDocumentMenu: View {
    @ObservedObject var store:WorkspaceStore
    var showTitle = false
    var body:some View {
        Menu {
            Button("PDF") { store.newPDF() }
            Button("文本文件") { store.newNote(format:.plain) }
            Button("HTML") { store.newNote(format:.html) }
            Button("Markdown") { store.newNote() }
        } label:{ if showTitle { Label("新建文件",systemImage:"doc.badge.plus") } else { Image(systemName:"doc.badge.plus").frame(width:28,height:28) } }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).help("新建文件：PDF、文本、HTML 或 Markdown").accessibilityLabel("新建文件")
    }
}
struct NewFileIcons: View {
    var store:WorkspaceStore?
    var body:some View { if let store { NewDocumentMenu(store:store) } }
}
