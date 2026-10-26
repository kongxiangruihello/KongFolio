import SwiftUI
import PDFKit

/// Both PDF views use a shared zoom ratio and normalized scroll position, including differently sized pages.
struct PDFDifferenceCanvas: NSViewRepresentable {
    var before: PDFDocument
    var after: PDFDocument
    var left: Int?
    var right: Int?
    var zoom: Double
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSStackView {
        let stack=LayoutStack();stack.orientation = .horizontal;stack.distribution = .fillEqually;stack.spacing=8
        stack.laidOut = { [weak coordinator=context.coordinator] in coordinator?.fit() }
        for pdf in context.coordinator.views {
            pdf.displayMode = .singlePage;pdf.autoScales=true;pdf.backgroundColor = .windowBackgroundColor
            stack.addArrangedSubview(pdf)
        }
        context.coordinator.install()
        return stack
    }
    func updateNSView(_ view: NSStackView, context: Context) {
        context.coordinator.update(before,after,left:left,right:right,zoom:zoom)
    }
    static func dismantleNSView(_ view: NSStackView, coordinator: Coordinator) { coordinator.observers.forEach(NotificationCenter.default.removeObserver) }
    final class LayoutStack:NSStackView {
        var laidOut:(()->Void)?
        override func layout() { super.layout();laidOut?() }
    }
    final class Coordinator {
        let views=[PDFView(),PDFView()]
        var observers:[NSObjectProtocol]=[]
        var synchronizing=false
        var lastZoom:Double = -1
        var lastPages:[Int?]=[]
        var clips=Set<ObjectIdentifier>()
        var fittedSizes:[CGSize]=[]
        func scroll(_ view:NSView) -> NSScrollView? {
            if let scroll=view as? NSScrollView { return scroll }
            return view.subviews.compactMap { self.scroll($0) }.first
        }
        func install() {
            for i in views.indices {
                if let clip=scroll(views[i])?.contentView,clips.insert(ObjectIdentifier(clip)).inserted {
                    clip.postsBoundsChangedNotifications=true
                    observers.append(NotificationCenter.default.addObserver(forName:NSView.boundsDidChangeNotification,object:clip,queue:.main) { [weak self] _ in self?.synchronize(from:i) })
                }
            }
        }
        func fit(force:Bool=false) {
            let sizes=views.map(\.bounds.size)
            guard force || sizes != fittedSizes else { return }
            let previous=synchronizing;synchronizing=true;defer { synchronizing=previous }
            for view in views where view.document != nil && view.bounds.width>0 && view.bounds.height>0 {
                view.autoScales=false;view.scaleFactor=max(0.01,view.scaleFactorForSizeToFit*max(1,lastZoom))
            }
            fittedSizes=sizes;install()
        }
        func synchronize(from index:Int) {
            guard !synchronizing,let source=scroll(views[index]),let target=scroll(views[1-index]),let a=source.documentView,let b=target.documentView else { return }
            synchronizing=true;defer { synchronizing=false }
            let x=max(0,source.contentView.bounds.minX)/max(1,a.bounds.width-source.contentView.bounds.width)
            let y=max(0,source.contentView.bounds.minY)/max(1,a.bounds.height-source.contentView.bounds.height)
            target.contentView.scroll(to:CGPoint(x:x*max(0,b.bounds.width-target.contentView.bounds.width),y:y*max(0,b.bounds.height-target.contentView.bounds.height)))
            target.reflectScrolledClipView(target.contentView)
        }
        func update(_ before:PDFDocument,_ after:PDFDocument,left:Int?,right:Int?,zoom:Double) {
            synchronizing=true;defer { synchronizing=false }
            let docs=[before,after],pages=[left,right]
            let changed=lastPages != pages || lastZoom != zoom || views[0].document !== before || views[1].document !== after
            for i in views.indices {
                if pages[i] == nil { views[i].document=nil;continue }
                if views[i].document !== docs[i] { views[i].document=docs[i] }
                if let page=pages[i].flatMap({ docs[i].page(at:$0) }),views[i].currentPage !== page { views[i].go(to:page) }
            }
            lastPages=pages;lastZoom=zoom
            if changed { fit(force:true) }
            install()
        }
    }
}

struct ComparisonViewer: View {
    let before: PDFDocument
    let after: PDFDocument
    let rows: [PageDifference]
    var leftTitle="原件"
    var rightTitle="处理结果"
    @Binding var selection: Int
    @State private var zoom=1.0
    @State private var changedOnly=false
    private var row: PageDifference? { rows.first { $0.id==selection } }
    private var visible:[PageDifference] { changedOnly ? rows.filter(\.changed) : rows }
    var body: some View {
        VStack(spacing:8) {
            HStack {
                Button { step(-1) } label:{ Image(systemName:"chevron.left") }.disabled(visible.first?.id==selection || visible.isEmpty)
                Picker("页面",selection:$selection) { ForEach(visible) { Text($0.title).tag($0.id) } }.frame(maxWidth:390)
                Button { step(1) } label:{ Image(systemName:"chevron.right") }.disabled(visible.last?.id==selection || visible.isEmpty)
                Toggle("只看差异",isOn:$changedOnly).onChange(of:changedOnly) { _,_ in if !visible.contains(where:{$0.id==selection}),let first=visible.first { selection=first.id } }
                Spacer()
                Button("适合页面") { zoom=1 }
                Slider(value:$zoom,in:1...5).frame(width:110)
                Text("\(Int(zoom*100))%").font(.caption.monospacedDigit()).frame(width:42)
            }
            HStack { Text(leftTitle).frame(maxWidth:.infinity);Text(rightTitle).frame(maxWidth:.infinity) }.font(.caption)
            if let row,!visible.isEmpty {
                PDFDifferenceCanvas(before:before,after:after,left:row.before,right:row.after,zoom:zoom)
                Text(row.title).font(.caption).foregroundStyle(.secondary)
            } else { ContentUnavailableView("没有差异页面",systemImage:"doc.on.doc").frame(maxWidth:.infinity,maxHeight:.infinity) }
        }
    }
    private func step(_ delta:Int) { guard let i=visible.firstIndex(where:{$0.id==selection}),visible.indices.contains(i+delta) else { return };selection=visible[i+delta].id }
}

struct RecipeTrialView: View {
    let source: URL
    let recipe: WorkRecipe
    let replacements: [ReplacementRule]
    @Environment(\.dismiss) private var dismiss
    @State private var range="1-3"
    @State private var selection=0
    @State private var before:PDFDocument?
    @State private var after:PDFDocument?
    @State private var rows:[PageDifference]=[]
    @State private var running=false
    @State private var message=""
    @State private var task:Task<Void,Never>?
    @State private var worker:Task<RecipeTrial.Result,Error>?
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("配方试跑与对照 · \(source.lastPathComponent)").font(.title2.bold())
            HStack {
                TextField("原件页码（最多 6 页）",text:$range).frame(width:220).disabled(running)
                Button("试跑所选页") { run() }.disabled(running)
                if running { ProgressView().controlSize(.small) }
                Spacer();Button(running ? "取消试跑" : "关闭") { if running { worker?.cancel();task?.cancel() } else { dismiss() } }
            }
            Text("临时试跑不写输出文件；自动裁边依据试跑页估算，整本执行时可能不同。仅预览 PDF 效果，Word 与章节导出在正式任务执行。").font(.caption).foregroundStyle(.secondary)
            if let before,let after { ComparisonViewer(before:before,after:after,rows:rows,selection:$selection) }
            else { Spacer();Text("先选取几页检查切分、纠偏、裁边、OCR 和压缩效果。").foregroundStyle(.secondary);Spacer() }
            Text(message).font(.caption).textSelection(.enabled)
        }.padding(20).frame(width:1100,height:740).interactiveDismissDisabled(running)
        .onAppear { if !recipe.pageRange.isEmpty { range=recipe.pageRange } }
        .onDisappear { worker?.cancel();task?.cancel() }
    }
    private func run() {
        let range=range,recipe=recipe,source=source,replacements=replacements
        running=true;before=nil;after=nil;message="正在试跑…"
        let job=Task.detached(priority:.userInitiated) {
            try RecipeTrial.run(source:source,range:range,recipe:recipe,replacements:replacements)
        }
        worker=job
        task=Task {
            do { let result=try await job.value;try Task.checkCancellation();before=PDFDocument(data:result.before);after=PDFDocument(data:result.after);rows=result.rows;selection=0;message=result.message }
            catch is CancellationError { message="试跑已取消" }
            catch { message=error.localizedDescription }
            running=false;worker=nil;task=nil
        }
    }
}
