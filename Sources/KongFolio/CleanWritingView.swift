import SwiftUI

struct CleanWritingView: View {
    @ObservedObject var note:MarkdownNote
    @ObservedObject var session:CleanWritingSession
    @MainActor init(note:MarkdownNote) { self.note = note;self.session = note.cleanSession }
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            Text("清爽编辑：图片与校勘资料保留在原文件中。段落支持中文输入和撤销；结构工具与全篇查找请切换“源码”。").font(.caption).foregroundStyle(.secondary)
            ScrollView { LazyVStack(alignment:.leading,spacing:10) {
                ForEach(Array(session.blocks.dropFirst(session.page*20).prefix(20))) { block in
                    switch block.kind {
                    case .text:
                        StableTextEditor(text:Binding(get:{session.blocks.first{$0.id == block.id}?.source ?? block.source},set:{ value in note.text = session.edit(block.id,text:value) }),label:"正文段落",identity:"clean:"+note.id.uuidString+":"+block.id.uuidString,markdown:true).frame(minHeight:60,maxHeight:180).disabled(note.readOnly)
                    case .image:
                        VStack(alignment:.leading) { CleanWritingImage(reference:block.reference,base:note.fileURL?.deletingLastPathComponent() ?? note.recoveryBaseURL);Text(block.title.isEmpty ? "图片" : block.title).font(.caption) }.padding(8).background(.quaternary.opacity(0.3))
                    case .metadata:Label(block.title,systemImage:"text.badge.checkmark").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } }
            HStack { Text("\(session.blocks.count) 段");Spacer();Button("上一页") { session.page-=1 }.disabled(session.page == 0);Text("\(session.page+1)");Button("下一页") { session.page+=1 }.disabled((session.page+1)*20>=session.blocks.count) }.font(.caption)
        }.padding(10).onAppear { session.load(note.text) }.onChange(of:note.text) { _,value in session.load(value);session.page = min(session.page,max(0,(session.blocks.count-1)/20)) }
    }
}
struct CleanWritingImage: View {
    let reference:String;let base:URL?
    @State private var bytes:Data?
    @State private var message = ""
    var body:some View {
        Group { if let bytes,let image = NSImage(data:bytes) { Image(nsImage:image).resizable().scaledToFit().frame(maxHeight:260) } else { Text(message.isEmpty ? "正在载入图片…" : message).font(.caption) } }
            .task(id:reference) { let reference = reference,base = base;do { let result = try await Task.detached(priority:.utility) { try TextMedia.read(reference,baseURL:base) }.value;if !Task.isCancelled { bytes = result } } catch { if !Task.isCancelled { message = error.localizedDescription } } }
    }
}
