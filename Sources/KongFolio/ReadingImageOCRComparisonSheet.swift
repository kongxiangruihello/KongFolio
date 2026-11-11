import SwiftUI

struct ReadingImageOCRComparisonSheet: View {
    @ObservedObject var controller: ReadingImageOCRController
    let record: ReadingRecord
    let journal: ReadingJournal
    let onApply: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("校订扫描摘录").font(.headline)
            HSplitView {
                VStack(alignment:.leading) {
                    Text("原图").font(.caption)
                    if let image = record.imageAsset {
                        ReadingRecordImage(url:journal.assetURL(image),pending:journal.pendingImage(image))
                            .frame(maxWidth:.infinity,maxHeight:.infinity)
                    }
                }.frame(minWidth:180)
                VStack(alignment:.leading) {
                    Text("识别文字").font(.caption)
                    ReadingWritingEditor(text:$controller.text,label:"校订识别文字",identity:"ocr:"+record.id.uuidString)
                        .frame(minHeight:160,maxHeight:.infinity)
                    ReadingOCRSegmentEditor(controller:controller)
                }.frame(minWidth:220)
            }
            HStack {
                Button("返回") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("采用校订文字") { onApply();dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(18).adaptiveSheet(width:840,height:570,minimumWidth:480,flexibleHeight:true)
    }
}
