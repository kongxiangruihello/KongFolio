import SwiftUI
import PDFKit

struct EditionAnchorsEditor: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var research: ResearchStore
    @ObservedObject var controller: ResearchController
    @StateObject private var draft = EditionAnchorDraft()
    private var path: String { workspace.displayPath ?? "" }
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Text("点选页面建立版本锚点").font(.headline)
            HStack { TextField("对应表名称",text:$draft.name); Button("载入当前版本") { loadLeft() }; Button("选择对照版本…") { chooseRight() } }
            Text(draft.rightPath.isEmpty ? "左右各翻到对应页面，然后点击建立对应。" : "对照："+URL(fileURLWithPath:draft.rightPath).lastPathComponent).font(.caption)
            HStack {
                VStack { if let doc = draft.leftPDF { Stepper("当前第 \(draft.left+1) 页",value:$draft.left,in:0...max(0,doc.pageCount-1)); ResearchPagePicker(document:doc,page:$draft.left) } else { Text("请载入当前版本") } }
                VStack { if let doc = draft.rightPDF { Stepper("对照第 \(draft.right+1) 页",value:$draft.right,in:0...max(0,doc.pageCount-1)); ResearchPagePicker(document:doc,page:$draft.right) } else { Text("请选择对照版本") } }
            }.frame(height:280)
            Button("建立对应：\(draft.left+1) ↔ \(draft.right+1)") {
                draft.pairs.removeAll { $0.left == draft.left || $0.right == draft.right }; draft.pairs.append(.init(left:draft.left,right:draft.right)); draft.pairs.sort { $0.left < $1.left }
            }.disabled(draft.leftPDF == nil || draft.rightPDF == nil)
            ForEach(draft.pairs.indices,id:\.self) { i in
                HStack { Text("\(draft.pairs[i].left+1) ↔ \(draft.pairs[i].right+1)"); TextField("章节说明",text:Binding(get:{draft.pairs[i].title},set:{draft.pairs[i].title=$0})); Button("查看") { draft.left = draft.pairs[i].left; draft.right = draft.pairs[i].right }; Button("删除") { draft.pairs.remove(at:i) } }
            }
            HStack {
                Button("保存对应表") { let edition = EditionCorrespondence(id:draft.editingID ?? UUID(),name:draft.name,leftPath:path,rightPath:draft.rightPath,pairs:draft.pairs); controller.saveEdition(edition,workspace:workspace,research:research) }.disabled(draft.pairs.isEmpty || draft.rightPath.isEmpty || controller.busy)
                Button("新建另一份") { draft.pairs = []; draft.editingID = nil; draft.name = "版本对应" }
            }
            ForEach(research.state.editions.filter { $0.contains(path) }) { edition in
                HStack { Text(edition.name); Spacer(); Button("修改") { edit(edition) }; Button("并排预览同步") { workspace.applyResearchEdition(edition) }; Button("删除记录") { do { try research.update { $0.editions.removeAll { $0.id == edition.id } } } catch { controller.message = error.localizedDescription } } }
            }
        }.onAppear { loadLeft() }.onChange(of:path) { _,_ in draft.generation = UUID(); draft.leftPDF = nil; draft.pairs = []; draft.editingID = nil; loadLeft() }
        .onDisappear { draft.leftPDF = nil; draft.rightPDF = nil }
        .onReceive(NotificationCenter.default.publisher(for:NSWindow.willCloseNotification)) { note in if (note.object as? NSWindow)?.identifier?.rawValue == "research-workbench" { draft.leftPDF = nil; draft.rightPDF = nil } }
    }
    private func loadLeft() { controller.loadEditionLeft(draft,workspace:workspace) }
    private func chooseRight() { guard let file = controller.chooseFile(pdfOnly:true) else { return }; controller.loadEditionRight(draft,file:file) }
    private func edit(_ edition:EditionCorrespondence) {
        guard edition.isLeft(path) else { controller.message = "请打开对应表的左侧版本后修改，当前仍可并排同步"; return }
        draft.editingID = edition.id; draft.name = edition.name; draft.pairs = edition.pairs; controller.loadEditionRight(draft,file:URL(fileURLWithPath:edition.rightPath))
    }
}
struct ResearchPagePicker: NSViewRepresentable {
    var document: PDFDocument
    @Binding var page: Int
    func makeCoordinator() -> Coordinator { Coordinator($page) }
    func makeNSView(context:Context) -> PDFView {
        let view = PDFView(); view.autoScales = true; view.displayMode = .singlePageContinuous
        context.coordinator.token = NotificationCenter.default.addObserver(forName:.PDFViewPageChanged,object:view,queue:.main) { [weak view,weak coordinator = context.coordinator] _ in
            guard let view, let current = view.currentPage, let document = view.document else { return }
            let index = document.index(for:current); guard index != NSNotFound else { return }
            DispatchQueue.main.async { [weak coordinator] in coordinator?.selected.wrappedValue = index }
        }; return view
    }
    func updateNSView(_ view:PDFView,context:Context) {
        context.coordinator.selected = $page
        if view.document !== document { view.document = document; context.coordinator.last = nil }
        if context.coordinator.last != page, let target = document.page(at:max(0,min(page,document.pageCount-1))) { context.coordinator.last = page; view.go(to:target) }
    }
    static func dismantleNSView(_ view:PDFView,coordinator:Coordinator) { if let token = coordinator.token { NotificationCenter.default.removeObserver(token) }; coordinator.token = nil; view.document = nil; view.clearSelection() }
    final class Coordinator { var selected: Binding<Int>; var last:Int?; var token:NSObjectProtocol?; init(_ value:Binding<Int>) { selected = value }; deinit { if let token { NotificationCenter.default.removeObserver(token) } } }
}
