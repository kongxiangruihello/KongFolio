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

    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("校订扫描摘录").font(.headline)
            HSplitView {
                VStack(alignment:.leading) {
                    Text("原图").font(.caption)
                    if let image = record.imageAsset {
                        ReadingRecordImage(url:journal.assetURL(image),pending:journal.pendingImage(image),
                                           region:controller.segments.first(where:{$0.id == selectedSegment})?.box)
                            .frame(maxWidth:.infinity,maxHeight:.infinity)
                    }
                }.frame(minWidth:180)
                VStack(alignment:.leading) {
                    Text("识别文字").font(.caption)
                    ReadingWritingEditor(text:$controller.text,label:"校订识别文字",identity:"ocr:"+record.id.uuidString)
                        .frame(minHeight:160,maxHeight:.infinity)
                    ScrollView {
                        ReadingOCRSegmentEditor(controller:controller) { selectedSegment = $0.id }
                    }.frame(maxHeight:245)
                }.frame(minWidth:220)
            }
            HStack {
                Button("返回") { dismiss() }.keyboardShortcut(.cancelAction)
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
