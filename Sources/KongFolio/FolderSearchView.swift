import SwiftUI
import AppKit

struct FolderSearchView: View {
    @ObservedObject var store:WorkspaceStore
    @ObservedObject var model:FolderSearchModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected:UUID?
    @State private var showIssues=false
    private var result:FolderSearchHit? { model.results.first { $0.id==selected } }
    private var occupied:Bool { model.running || model.openingID != nil }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("跨文件全文搜索").font(.title2.bold())
            HStack {
                Button("选择文件夹…") { chooseFolder() }
                Text(model.folder?.path ?? "请选择存放 PDF 的文件夹").font(.caption).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
                Toggle("包含子文件夹",isOn:$model.recursive)
            }.disabled(occupied)
            HStack {
                TextField("搜索词句（简繁通查、忽略中文换行）",text:$model.query).onSubmit { model.start() }.disabled(occupied)
                if model.running { Button(model.stopping ? "正在停止…" : "停止") { model.cancel() }.disabled(model.stopping) }
                else { Button("搜索") { model.start() }.disabled(model.folder==nil || model.query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || model.openingID != nil).buttonStyle(.borderedProminent) }
            }
            HStack {
                Text("已检查 \(model.scanned) / \(model.total) 份 PDF · \(model.results.count) 处匹配").font(.caption.monospacedDigit())
                if !model.searchedQuery.isEmpty { Text("结果词句：\(model.searchedQuery)").font(.caption).lineLimit(1) }
                Spacer()
                if model.running || model.openingID != nil { ProgressView().controlSize(.small) }
            }
            if !model.progressText.isEmpty { Text(model.progressText).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            List(selection:$selected) {
                ForEach(model.results) { result in
                    VStack(alignment:.leading,spacing:5) {
                        HStack {
                            Text(result.url.lastPathComponent).font(.headline)
                            Text("第 \(result.hit.page+1) 页"+(result.hit.label.map { " · 印刷页码 \($0)" } ?? "")).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(result.hit.snippet).font(.body).lineLimit(3)
                        Text(result.relativePath).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(result.url.path)
                    }.padding(.vertical,5).tag(result.id)
                    .onTapGesture(count:2) { open(result) }
                    .contextMenu {
                        Button("打开并定位") { open(result) }.disabled(occupied)
                        Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([result.url]) }
                    }
                }
            }.listStyle(.inset)
            if !model.noTextFiles.isEmpty || !model.problems.isEmpty {
                HStack {
                    Button("无文字 \(model.noTextFiles.count) 份 · 提示 \(model.problems.count) 项") { showIssues.toggle() }
                    if !model.noTextFiles.isEmpty {
                        Button("无文字 PDF 加入任务中心…") {
                            store.batchQueue.add(model.noTextFiles);store.showOCRTasksAfterSearch=true;dismiss()
                        }.disabled(occupied || store.batchQueue.running)
                    }
                }
                if showIssues {
                    ScrollView {
                        Text((model.noTextFiles.map { $0.path+"：未提取到文字，可先 OCR" }+model.problems).joined(separator:"\n"))
                            .font(.caption).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                    }.frame(maxHeight:100)
                }
            }
            if !model.message.isEmpty { Text(model.message).font(.callout).textSelection(.enabled).lineLimit(3) }
            Text("搜索已保存的 PDF 文字；扫描件请先 OCR。文字索引保存在本机，隐藏文件、软件包与文件夹内的符号链接不参与搜索。打开结果前核对原文件，保留已打开文档的未保存编辑。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("关闭") { model.cancel();dismiss() }.keyboardShortcut(.cancelAction)
                Button("清除文字索引") { model.clearIndex() }.disabled(occupied)
                Button("导出结果…") { export() }.disabled(occupied || model.searchedQuery.isEmpty)
                Spacer()
                Button("打开并定位") { if let result { open(result) } }.disabled(result==nil || occupied).buttonStyle(.borderedProminent)
            }
        }.padding(20).frame(width:960,height:720)
        .onDisappear { model.cancel();model.remember() }
    }
    private func chooseFolder() {
        let panel=NSOpenPanel();panel.canChooseFiles=false;panel.canChooseDirectories=true;panel.allowsMultipleSelection=false
        if panel.runModal() == .OK { model.folder=panel.url;model.remember() }
    }
    private func open(_ result:FolderSearchHit) {
        guard !occupied else { return }
        Task { if await model.open(result,in:store) { dismiss() } }
    }
    private func export() {
        let panel=NSSavePanel();panel.allowedContentTypes=[.plainText];panel.nameFieldStringValue="KongFolio-搜索结果.txt"
        guard panel.runModal() == .OK,let url=panel.url else { return }
        do { try model.report().write(to:url,atomically:true,encoding:.utf8) }
        catch { model.message="导出失败："+error.localizedDescription }
    }
}
