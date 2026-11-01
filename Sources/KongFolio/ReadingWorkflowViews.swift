import SwiftUI
import UniformTypeIdentifiers

struct ReadingTagField: View {
    @ObservedObject var journal:ReadingJournal
    let label:String
    @Binding var text:String
    var body:some View {
        VStack(alignment:.leading,spacing:4) {
            StableTextField(label,text:$text)
            if !journal.tagSuggestions(text).isEmpty {
                ScrollView(.horizontal,showsIndicators:false) { HStack { Text("已有标签").font(.caption).foregroundStyle(.secondary);ForEach(journal.tagSuggestions(text),id:\.self) { suggestion in Button(suggestion) { var parts = text.replacingOccurrences(of:"，",with:",").components(separatedBy:",");if !parts.isEmpty { parts.removeLast() };parts.append(suggestion);text = ReadingJournal.normalizedTags(parts.joined(separator:",")).joined(separator:", ") }.font(.caption) } } }
            }
        }
    }
}
struct ReadingTagManager: View {
    @ObservedObject var journal:ReadingJournal
    @Environment(\.dismiss) private var dismiss
    @State private var old = ""
    @State private var new = ""
    @State private var busy = false
    @State private var message = ""
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            Text("统一整理标签").font(.headline)
            Picker("原标签",selection:$old) { Text("请选择").tag("");ForEach(journal.allTags,id:\.self) { Text($0).tag($0) } }
            StableTextField("新的标签名称",text:$new)
            Text(journal.allTags.contains(new) ? "目标标签已存在，应用后会合并，并去掉同一记录内的重复标签。" : "统一修改记录与札记的标签，保留正文和插入札记时的引用副本。").font(.caption)
            Text(message).font(.caption).textSelection(.enabled)
            HStack { Button("关闭") { dismiss() }.disabled(busy);Spacer();Button("备份并应用") { apply() }.disabled(old.isEmpty || new.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || old == new || busy || journal.unreadable) }
        }.padding(22).adaptiveSheet(width:540,height:300)
    }
    private func apply() {
        let before = journal.state,source = old,destination = new
        busy = true;Task { do { _ = try await journal.makeBackup();guard journal.state == before else { throw FolioError(message:"记录已变化，请重新核对后应用") };try journal.renameTag(source,to:destination);try await journal.flush();message = "标签已更新，修改前备份已保留";old = "" } catch { message = error.localizedDescription };busy = false }
    }
}
struct ReadingBatchRelinkView: View {
    @ObservedObject var store:WorkspaceStore
    @ObservedObject var journal:ReadingJournal
    @Environment(\.dismiss) private var dismiss
    @State private var proposals:[ReadingRelinkProposal] = []
    @State private var selections:[String:URL] = [:]
    @State private var expected:ReadingJournalState?
    @State private var busy = false
    @State private var message = "选择文献文件夹，查找失效原文。只有唯一同名候选会预选，仍需你确认。"
    @State private var task:Task<Void,Never>?
    @State private var page = 0
    private var pagination:ReadingPagination { ReadingPagination(total:proposals.count,page:page,size:10) }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { Text("批量重新关联原文").font(.headline);Spacer();Button("关闭") { task?.cancel();dismiss() }.disabled(busy && !selections.isEmpty) }
            HStack { Button("选择文献文件夹…",action:scan).disabled(busy);if busy { ProgressView().controlSize(.small);Button("取消") { task?.cancel() } } }
            Text(message).font(.caption).textSelection(.enabled)
            List {
                ForEach(Array(proposals.dropFirst(pagination.range.lowerBound).prefix(pagination.size))) { proposal in
                    VStack(alignment:.leading,spacing:5) {
                        Text(proposal.title).lineLimit(1).help(proposal.old)
                        HStack {
                            Toggle("采用",isOn:Binding(get:{selections[proposal.old] != nil},set:{if !$0 { selections[proposal.old] = nil } else if proposal.candidates.count == 1 { selections[proposal.old] = proposal.candidates[0] }})).disabled(proposal.candidates.count != 1 && selections[proposal.old] == nil)
                            Text(selections[proposal.old]?.path ?? (proposal.candidates.isEmpty ? "未找到同名文件，请手动选择" : "存在多个候选，请手动确认")).font(.caption).lineLimit(2)
                            Button("指定文件…") { choose(proposal) }.disabled(busy)
                        }
                    }
                }
            }
            HStack { Text(pagination.label);Button("上一页") { page = max(0,page-1) }.disabled(pagination.index == 0);Button("下一页") { page += 1 }.disabled(pagination.index>=pagination.last);Spacer();Button("核对并关联所选 \(selections.count) 份") { apply() }.disabled(selections.isEmpty || busy || journal.unreadable) }
            Text("确认前检查文献能否读取及页数。页码、摘录文字保留；同名不同版本仍需你核对内容。修改前保留手动备份。").font(.caption).foregroundStyle(.secondary)
        }.padding(20).adaptiveSheet(width:760,height:550)
        .onDisappear { task?.cancel() }
    }
    private func choose(_ proposal:ReadingRelinkProposal) { let panel = NSOpenPanel();panel.allowedContentTypes = [.pdf];panel.message = "为「"+proposal.title+"」选择原文，原页码保留";guard panel.runModal() == .OK,let file = panel.url else { return };selections[proposal.old] = file }
    private func scan() {
        let panel = NSOpenPanel();panel.canChooseDirectories = true;panel.canChooseFiles = false;guard panel.runModal() == .OK,let folder = panel.url else { return }
        let value = journal.state;busy = true;selections = [:];proposals = [];expected = nil
        task = Task { do { let result = try await ReadingRelinkWorker.shared.scan(value,folder:folder);try Task.checkCancellation();proposals = result;expected = value;page = 0;for row in result where row.candidates.count == 1 { selections[row.old] = row.candidates[0] };message = result.isEmpty ? "没有发现失效原文" : "发现 \(result.count) 份失效原文，请核对候选文件" } catch { message = FolioCancellation.matches(error) ? "已取消查找" : error.localizedDescription };busy = false }
    }
    private func apply() {
        guard let expected,journal.state == expected else { message = "记录已变化，请重新扫描";return }
        let mapping = selections,rows = proposals;busy = true
        task = Task { do { try await ReadingRelinkWorker.shared.validate(mapping,proposals:rows);try Task.checkCancellation();guard journal.state == expected else { throw FolioError(message:"记录已变化，请重新扫描") };_ = try await journal.makeBackup();try Task.checkCancellation();guard journal.state == expected else { throw FolioError(message:"备份期间记录已变化，请重新扫描") };journal.relinkBatch(mapping);try await journal.flush()
                var failed = 0;for (old,url) in mapping { do { try store.library.relink(path:old,to:url,defaults:store.readingDefaults,validated:true) } catch { failed += 1 } }
                message = "已关联 \(mapping.count) 份原文，记录已保存"+(failed>0 ? "；\(failed) 份书架快捷方式未能同步，请在书架核对" : "");selections = [:];proposals = [];self.expected = nil
            } catch { message = FolioCancellation.matches(error) ? "已取消；已提交的关联可在备份中核对" : error.localizedDescription };busy = false }
    }
}
