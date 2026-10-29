import SwiftUI

struct ResearchTopicEditor: View {
    @ObservedObject var research: ResearchStore
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var controller: ResearchController
    @State private var name = ""
    @State private var selected: UUID?
    private var topic: ResearchTopic? { research.state.topics?.first { $0.id == selected } }
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Text("专题摘录稿").font(.headline)
            HStack { TextField("专题名称",text:$name); Button("新建专题") { do { let trimmed = name.trimmingCharacters(in:.whitespacesAndNewlines); guard !trimmed.isEmpty else { throw FolioError(message:"请填写专题名称") }; let value = ResearchTopic(name:trimmed); try research.update { if $0.topics == nil { $0.topics = [] }; $0.topics?.append(value) }; selected = value.id } catch { controller.message = error.localizedDescription } } }
            Picker("专题",selection:$selected) { Text("请选择").tag(nil as UUID?); ForEach(research.state.topics ?? []) { Text($0.name).tag(Optional($0.id)) } }
            Text("先在“批注与校对”筛选批注，再点击“加入专题”。这里可排序、补充论述及导出。").font(.caption)
            if let topic {
                TextField("标题",text:binding(\.name))
                TextEditor(text:binding(\.introduction)).frame(height:100).border(.quaternary).help("专题开头的论述")
                ForEach(topic.items) { item in
                    VStack(alignment:.leading,spacing:6) {
                        HStack { Text(URL(fileURLWithPath:item.annotation.path).lastPathComponent+" · 第\(item.annotation.page+1)页").font(.caption); Spacer(); Button("上移") { change { $0.move(item.id,delta:-1) } }; Button("下移") { change { $0.move(item.id,delta:1) } }; Button("移除") { change { $0.items.removeAll { $0.id == item.id } } } }
                        Text(item.annotation.quote).textSelection(.enabled)
                        TextField("补充自己的论述",text:Binding(get:{ self.topic?.items.first { $0.id == item.id }?.reflection ?? "" },set:{ text in change { value in if let i = value.items.firstIndex(where: { $0.id == item.id }) { value.items[i].reflection = text } } }))
                    }.padding(8).background(.quaternary.opacity(0.3))
                }
                HStack { Button("导出 Markdown…") { controller.exportTopic(topic,store:store,word:false) }; Button("导出 Word…") { controller.exportTopic(topic,store:store,word:true) } }.disabled(controller.busy)
            }
        }
    }
    private func binding(_ key:WritableKeyPath<ResearchTopic,String>) -> Binding<String> { Binding(get:{topic?[keyPath:key] ?? ""},set:{ value in change { $0[keyPath:key] = value } }) }
    private func change(_ operation:(inout ResearchTopic)->Void) {
        do { try research.update { value in if let index = value.topics?.firstIndex(where: { $0.id == selected }) { operation(&value.topics![index]) } } } catch { controller.message = error.localizedDescription }
    }
}
