import SwiftUI

struct EditorDisplaySheet: View {
    @ObservedObject var note:MarkdownNote
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            Text("编辑区显示设置").font(.title2.bold())
            Text("放大文字、调整行宽与间距，设置会自动记住。只影响屏幕显示，导出与打印使用各自的版式设置。").font(.body).foregroundStyle(.secondary)
            Form {
                Stepper("编辑字号：\(Int(note.editorDisplay.size))",value:$note.editorDisplay.size,in:14...30)
                Picker("编辑字体",selection:$note.editorDisplay.face) { ForEach(EditorDisplayOptions.Face.allCases,id:\.self) { Text($0.rawValue).tag($0) } }
                Picker("正文行宽",selection:$note.editorDisplay.column) { ForEach(EditorDisplayOptions.Column.allCases,id:\.self) { Text($0.rawValue).tag($0) } }
                Picker("行间距",selection:$note.editorDisplay.lineHeight) { Text("紧凑 · 1.3").tag(1.3);Text("舒适 · 1.6").tag(1.6);Text("宽松 · 1.9").tag(1.9) }
            }
            Text("文献阅读与札记写作\n让文字保持清晰，在舒适的行宽中整理思考。").font(.system(size:note.editorDisplay.size,design:note.editorDisplay.face == .serif ? .serif : note.editorDisplay.face == .mono ? .monospaced : .default)).lineSpacing(note.editorDisplay.size*(note.editorDisplay.lineHeight-1)).padding(20).frame(maxWidth:.infinity,alignment:.leading).background(Color(nsColor:.textBackgroundColor),in:RoundedRectangle(cornerRadius:8))
            HStack { Button("恢复默认") { note.editorDisplay = EditorDisplayOptions() };Spacer();Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).adaptiveSheet(width:520,height:440,minimumWidth:400,flexibleHeight:true)
    }
}
