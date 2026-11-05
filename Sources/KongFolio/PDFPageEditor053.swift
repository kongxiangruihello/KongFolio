import SwiftUI

struct PDFPageEditor053:View {
    @ObservedObject var workspace:Workspace
    @State private var deleteConfirmation=false
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            Text("共 \(workspace.count) 页 · 已选 \(workspace.effectivePages.count) 页").font(.callout)
            if workspace.readingLocked {
                Text("当前处于阅读模式。切换后可以增删和排列页面。").font(.caption).foregroundStyle(.secondary)
                Button("切换为编辑模式") { workspace.toggleReadingLock() }
            }
            Group {
                Menu("增加页面") {
                    Button("在当前页后增加空白页") { workspace.insertBlankPage() }
                    Button("在当前页前增加空白页") { workspace.insertBlankPage(before:true) }
                    Button("从 PDF 或图片插入…") { workspace.open(insert:true) }
                }
                HStack { Button("前移") { workspace.move(-1) };Button("后移") { workspace.move(1) } }
                HStack { Button("复制页") { workspace.duplicatePages() };Button("旋转") { workspace.rotate() } }
                Button("删除所选页面…",role:.destructive) { deleteConfirmation=true }.disabled(workspace.effectivePages.count>=workspace.count)
            }.disabled(workspace.readingLocked || workspace.busy)
            Text("按住 ⌘ 可选择多页。页面修改会自动保存，可用撤销恢复。").font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(0..<workspace.count,id:\.self) { i in
                    Button {
                        if NSEvent.modifierFlags.contains(.command) {
                            if workspace.selectedPages.contains(i) { workspace.selectedPages.remove(i) } else { workspace.selectedPages.insert(i) }
                            if workspace.selectedPages.isEmpty { workspace.selectedPages=[i] }
                        } else { workspace.selectPage(i);workspace.selectedPages=[i] }
                    } label:{ HStack { Image(systemName:workspace.selectedPages.contains(i) ? "checkmark.circle.fill":"circle");Text("第 \(i+1) 页");Spacer();if i==workspace.selection { Image(systemName:"eye") } } }.buttonStyle(.plain)
                }
            }
        }.padding(10)
        .confirmationDialog("删除 \(workspace.effectivePages.count) 页？",isPresented:$deleteConfirmation) { Button("删除页面",role:.destructive) { workspace.remove() } }
    }
}
