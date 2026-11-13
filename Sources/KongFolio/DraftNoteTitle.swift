import SwiftUI

struct DraftNoteTitle: View {
    @ObservedObject var note:MarkdownNote
    @State private var name = ""
    @State private var hovering = false
    @FocusState private var focused:Bool
    var body:some View {
        Group {
            if note.fileURL == nil {
                HStack(spacing:5) {
                    TextField("笔记名称",text:$name).textFieldStyle(.plain).focused($focused)
                        .onSubmit(commit).onExitCommand { name = note.title;focused = false }
                        .accessibilityLabel("笔记名称，回车确认")
                    Image(systemName:"pencil").font(.system(size:12)).foregroundStyle(.secondary).opacity(hovering || focused ? 1 : 0).accessibilityHidden(true)
                }
                .padding(.horizontal,5).padding(.vertical,3)
                .background(hovering || focused ? Color.accentColor.opacity(0.08) : .clear,in:RoundedRectangle(cornerRadius:5))
                .onHover { hovering = $0 }
                .help(note.title+"\n点击即可修改名称，回车确认")
                .onAppear { name = note.title }
                .onChange(of:note.title) { _,value in if !focused { name = value } }
                .onChange(of:focused) { old,value in if old && !value { commit() } }
            } else {
                Text(note.title).truncationMode(.middle).help(note.fileURL?.path ?? note.title)
            }
        }.font(.system(size:17,weight:.semibold)).lineLimit(1)
    }
    private func commit() {
        guard (NSApp?.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() != true else { return }
        guard name != note.title else { focused = false;return }
        do { try note.renameDraft(to:name);name = note.title;focused = false }
        catch { name = note.title;focused = false;note.error = error.localizedDescription }
    }
}
