import SwiftUI

struct CorrectionDictionaryView: View {
    @ObservedObject var research: ResearchStore
    @ObservedObject var library: BookLibrary
    @ObservedObject var controller: ResearchController
    var workspace: Workspace?
    @State private var from = ""
    @State private var to = ""
    @State private var scope = "全局"
    @State private var editing: ScopedCorrection?
    private var path: String { workspace?.displayPath ?? "" }
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Text("分书／分类校对词典").font(.headline)
            HStack { TextField("误识文字",text:$from); TextField("改为",text:$to)
                Picker("范围",selection:$scope) { Text("全部资料").tag("全局"); if !path.isEmpty { Text("当前书籍").tag(path) }; ForEach(Array(Set(library.books.map(\.category))).filter { !$0.isEmpty }.sorted(),id:\.self) { Text("分类："+$0).tag($0) } }
                Button("添加规则") { do { guard !from.isEmpty, from != to else { throw FolioError(message:"请输入不同的原文与替换结果") }; try research.update { $0.dictionary.append(ScopedCorrection(from:from,to:to,scope:scope)) }; from = ""; to = "" } catch { controller.message = error.localizedDescription } }
            }
            ForEach(research.state.dictionary) { rule in
                HStack { Text(rule.from+" → "+rule.to); Text(rule.scope == path ? "当前书籍" : rule.scope == "全局" ? "全部资料" : URL(fileURLWithPath:rule.scope).lastPathComponent).foregroundStyle(.secondary); Spacer()
                    Button("编辑") { editing = rule }
                    Button(rule.enabled ? "停用" : "启用") { update { state in if let i = state.dictionary.firstIndex(where: { $0.id == rule.id }) { state.dictionary[i].enabled.toggle() } } }
                    Button("删除") { update { $0.dictionary.removeAll { $0.id == rule.id } } }
                }
            }
            let rules = research.rules(path:path,project:library.book(path:path)?.category ?? "")
            ForEach(CorrectionConflicts.messages(rules),id:\.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            HStack { Button("预览当前书籍命中") { if CorrectionConflicts.messages(rules).contains(where: { $0.contains("多个替换结果") }) { controller.message = "请先处理多个替换结果冲突" } else if let store = workspace?.store { controller.previewCorrections(store) } }; Button("应用预览中的校正") { if let w = workspace, let revision = controller.correctionRevision { w.applyOCRBatch(controller.correctionHits,expected:revision) } }.disabled(controller.correctionHits.isEmpty) }
            ForEach(Array(controller.correctionHits.prefix(100))) { Text("第\($0.page+1)页："+$0.markedContext+" → "+$0.to).font(.caption) }
        }.onChange(of:research.state.dictionary) { _,_ in controller.correctionHits = [] }.sheet(item:$editing) { rule in CorrectionRuleEditor(rule:rule,research:research) }
    }
    private func update(_ change:(inout ResearchStore.State)->Void) { do { try research.update(change); controller.correctionHits = [] } catch { controller.message = error.localizedDescription } }
}
struct CorrectionRuleEditor: View {
    @State var rule: ScopedCorrection
    @ObservedObject var research: ResearchStore
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    var body: some View {
        VStack(alignment:.leading,spacing:12) { Text("修改校对规则").font(.headline); TextField("原文字",text:$rule.from); TextField("替换为",text:$rule.to); Text("范围："+rule.scope).font(.caption); Toggle("启用",isOn:$rule.enabled); Text(message)
            HStack { Button("取消") { dismiss() }; Button("保存") { do { guard !rule.from.isEmpty, rule.from != rule.to else { throw FolioError(message:"原文不能为空或与结果相同") }; try research.update { value in if let i = value.dictionary.firstIndex(where: { $0.id == rule.id }) { value.dictionary[i] = rule } }; dismiss() } catch { message = error.localizedDescription } } }
        }.padding(20).frame(width:420)
    }
}
