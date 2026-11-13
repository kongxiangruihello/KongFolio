import SwiftUI
struct NewDocumentMenu: View {
    @ObservedObject var store:WorkspaceStore
    var showTitle = false
    var body:some View {
        Menu {
            Button("PDF") { store.newPDF() }
            Button("Markdown (.md)") { store.newNote() }
            Button("纯文本 (.txt)") { store.newNote(format:.plain) }
            Button("HTML (.html)") { store.newNote(format:.html) }
        } label:{ if showTitle { Label("新建文件",systemImage:"doc.badge.plus") } else { Image(systemName:"doc.badge.plus").frame(width:28,height:28) } }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).help("新建文件：PDF、文本、HTML 或 Markdown").accessibilityLabel("新建文件")
    }
}
struct NewFileIcons: View {
    var store:WorkspaceStore?
    var body:some View { if let store { NewDocumentMenu(store:store) } }
}
