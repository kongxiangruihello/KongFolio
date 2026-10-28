import SwiftUI

struct ReadingHistorySheet: View {
    @ObservedObject var store: WorkspaceStore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelRow {
                Text("个人书架与阅读记录").font(.headline)
                Spacer()
                Button("完成") { store.showReadingHistory = false }.keyboardShortcut(.cancelAction)
            }
            TabView(selection: $store.libraryTab) {
                BookLibraryView(store: store, library: store.library).tabItem { Label("个人书架", systemImage: "books.vertical") }.tag(0)
                ShortcutManagerView(store: store, library: store.library).tabItem { Label("阅读快捷方式", systemImage: "link") }.tag(1)
            }
        }.padding(20).adaptiveSheet(width: 980, height: 680, minimumWidth: 360)
    }
}
