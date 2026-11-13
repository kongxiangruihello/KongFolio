import SwiftUI

struct ReadingImageOCRComparisonSheet: View {
    @ObservedObject var controller: ReadingImageOCRController
    let record: ReadingRecord
    let journal: ReadingJournal
    let store: WorkspaceStore
    @State private var context: ReadingContextRequest?
    @State private var selectedSegment: UUID?
    @State private var initialSegments: [ReadingOCRSegment] = []
    @State private var showSegmentChoice = false
    let onApply: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var originalRecognition:String { record.originalOCR ?? controller.originalText }

    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("校订扫描摘录").font(.headline)
            HSplitView {
                if let image = record.imageAsset {
                    ReadingOCRImagePane(url:journal.assetURL(image),pending:journal.pendingImage(image),
                                        region:controller.segments.first(where:{$0.id == selectedSegment})?.box)
                        .frame(minWidth:190)
                }
                VStack(alignment:.leading) {
                    Text("校订文字").font(.headline)
                    if !originalRecognition.isEmpty {
                        DisclosureGroup("查看原始识别文字") {
                            ScrollView { Text(originalRecognition).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }
                                .frame(maxHeight:90)
                        }.font(.caption)
                    }
                    ReadingWritingEditor(text:$controller.text,label:"校订识别文字",identity:"ocr:"+record.id.uuidString)
                        .frame(minHeight:160,maxHeight:.infinity)
                    ScrollView {
                        ReadingOCRSegmentEditor(controller:controller) { selectedSegment = $0.id }
                    }.frame(maxHeight:245)
                }.frame(minWidth:220)
            }
            HStack {
                Button("返回") { dismiss() }.keyboardShortcut(.cancelAction)
                if let citation = record.citations.first { Text(citation.source.pageDescription).font(.caption).foregroundStyle(.secondary) }
                if let source = record.citations.first?.source {
                    Button("原文上下文…") { context = ReadingContextRequest(source:source) }.disabled(source.path.isEmpty)
                }
                Spacer()
                Button("采用校订文字") {
                    if controller.segments != initialSegments, controller.text != ReadingOCRSegments.text(controller.segments) {
                        showSegmentChoice = true
                    } else { apply() }
                }.keyboardShortcut(.defaultAction).disabled(controller.busy)
            }
        }.padding(18).adaptiveSheet(width:840,height:570,minimumWidth:480,flexibleHeight:true)
        .onAppear { initialSegments = controller.segments; selectedSegment = controller.segments.first?.id }
        .confirmationDialog("选择保存的校订正文",isPresented:$showSegmentChoice) {
            Button("按逐段校订合并并保存") { controller.text = ReadingOCRSegments.text(controller.segments); apply() }
            Button("保存上方正文") { apply() }
            Button("继续校对",role:.cancel) {}
        }
        .sheet(item:$context) { request in ReadingContextView(store:store,source:request.source) }
    }
    private func apply() { onApply(); dismiss() }
}

private struct ReadingOCRImagePane: View {
    let url:URL
    let pending:Data?
    let region:CGRect?
    @State private var image:NSImage?
    @State private var failed = false
    @State private var zoom = 1.0
    @State private var turns = 0

    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {
                Text("原始图片").font(.headline)
                Spacer()
                Button { zoom = max(1,zoom-0.5) } label:{Image(systemName:"minus.magnifyingglass")}
                    .help("缩小原图").accessibilityLabel("缩小原图").disabled(zoom <= 1)
                Button { zoom = 1;turns = 0 } label:{Text("\(Int(zoom*100))%").monospacedDigit()}
                    .help("恢复适合窗口和原始方向")
                Button { zoom = min(4,zoom+0.5) } label:{Image(systemName:"plus.magnifyingglass")}
                    .help("放大原图").accessibilityLabel("放大原图").disabled(zoom >= 4)
                Button { turns = (turns+1)%4 } label:{Image(systemName:"rotate.right")}
                    .help("顺时针旋转 90°").accessibilityLabel("旋转原图")
            }.buttonStyle(.borderless)
            if let image {
                GeometryReader { geometry in
                    ScrollView([.horizontal,.vertical]) {
                        preview(image,in:geometry.size)
                            .frame(minWidth:geometry.size.width,minHeight:geometry.size.height)
                    }.background(.quaternary.opacity(0.4))
                }
            } else {
                Text(failed ? "原图暂不可用" : "正在载入原图…").foregroundStyle(.secondary)
                Spacer()
            }
        }.task(id:url.path) {
            let file = url
            let bytes: Data?
            if let pending { bytes = pending }
            else { bytes = await Task.detached(priority:.utility) { try? Data(contentsOf:file) }.value }
            guard !Task.isCancelled else { return }
            image = bytes.flatMap(NSImage.init(data:))
            failed = image == nil
        }
    }

    private func preview(_ image:NSImage,in viewport:CGSize) -> some View {
        let native = image.size
        let rotated = turns % 2 != 0
        let fit = rotated ? CGSize(width:native.height,height:native.width) : native
        let scale = min(viewport.width/max(1,fit.width),viewport.height/max(1,fit.height))*zoom
        let size = CGSize(width:max(1,native.width*scale),height:max(1,native.height*scale))
        return Image(nsImage:image).resizable().frame(width:size.width,height:size.height)
            .overlay {
                if let region,let box = ReadingOCRSegments.previewRegion(region,in:size) {
                    Rectangle().fill(Color.orange.opacity(0.20))
                        .overlay{Rectangle().strokeBorder(.orange,lineWidth:2)}
                        .frame(width:box.width,height:box.height).position(x:box.midX,y:box.midY)
                }
            }.rotationEffect(.degrees(Double(turns)*90))
            .frame(width:rotated ? size.height : size.width,height:rotated ? size.width : size.height)
    }
}
