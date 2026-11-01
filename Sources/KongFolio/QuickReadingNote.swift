import SwiftUI

struct QuickReadingNote:View {
    @ObservedObject var store:WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("随手记一句").font(.headline)
            if let workspace = store.commandWorkspace,workspace.count>0 { Text(workspace.displayName+" · "+workspace.readingCitation().source.pageDescription).font(.caption).lineLimit(2) }
            StableTextEditor(text:$text,label:"随手笔记").frame(width:360,height:150)
            HStack { Button("取消") { dismiss() };Spacer();Button("记下并继续") {
                let citations = store.commandWorkspace.flatMap{$0.count>0 ? [$0.readingCitation()] : nil} ?? []
                store.journal.add(ReadingRecord(kind:.note,note:text,citations:citations));dismiss()
            }.disabled(text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || store.journal.unreadable) }
        }.padding(16)
    }
}
