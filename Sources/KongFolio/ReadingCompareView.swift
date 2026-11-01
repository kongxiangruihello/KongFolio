import SwiftUI
struct ReadingCompareView: View {
    @ObservedObject var journal:ReadingJournal
    let backup:ReadingBackup
    let item:ReadingLibraryID
    let restore:(Int,ReadingJournalState)->Void
    @State private var paragraph = 0
    private var old:String { ReadingVersionCompare.ownText(item,state:backup.state) }
    private var current:String { ReadingVersionCompare.ownText(item,state:journal.state) }
    var body:some View {
        DisclosureGroup("对比我的文字／恢复单段") {
            VStack(alignment:.leading,spacing:8) {
                HStack { Text("备份中的文字").frame(maxWidth:.infinity,alignment:.leading);Text("当前文字").frame(maxWidth:.infinity,alignment:.leading) }
                ScrollView { LazyVStack(alignment:.leading,spacing:3) { ForEach(ReadingVersionCompare.lines(old:old,new:current)) { line in HStack(alignment:.top) { Text(line.old.isEmpty ? "　" : line.old).frame(maxWidth:.infinity,alignment:.leading);Text(line.new.isEmpty ? "　" : line.new).frame(maxWidth:.infinity,alignment:.leading) }.textSelection(.enabled).padding(3).background(line.changed ? Color.orange.opacity(0.15) : .clear) } } }.frame(height:140)
                Text("橙色标记同一行位置的差异。只恢复自己的文字，原文、引用和其他段落保持当前内容；恢复前另存手动备份。").font(.caption)
                let parts = ReadingVersionCompare.paragraphs(item,state:backup.state)
                Picker("备份中的段落",selection:$paragraph) { ForEach(parts.indices,id:\.self) { i in Text("第 \(i+1) 段 · "+String(parts[i].prefix(35))).tag(i) } }
                Button("恢复这一段") { restore(paragraph,journal.state) }.disabled(parts.isEmpty || paragraph>=parts.count || journal.restoring)
            }
        }.onChange(of:backup.id) { _,_ in paragraph = 0 }.onChange(of:item) { _,_ in paragraph = 0 }
    }
}
