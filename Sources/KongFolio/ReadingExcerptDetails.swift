import SwiftUI

struct ReadingExcerptRemarkField: View {
    @ObservedObject var journal: ReadingJournal
    let recordID: UUID

    var body: some View {
        StableTextField("随手备注（可留空）",text:Binding(
            get:{ journal.record(recordID)?.excerptRemark ?? "" },
            set:{ value in
                guard journal.record(recordID)?.excerptRemark ?? "" != value else { return }
                journal.editRecord(recordID) { $0.excerptRemark = value.isEmpty ? nil : value }
            }
        ))
    }
}

struct ReadingExcerptSegmentsView: View {
    @ObservedObject var journal: ReadingJournal
    let record: ReadingRecord
    let editing: Bool
    let openSource: (ReadingCitation) -> Void
    let showContext: (SourceRef) -> Void
    var focusedIdentity: String? = nil
    @State private var comparing:ReadingExcerptSegment?

    var body: some View {
        ForEach(Array(record.textExcerptSegments.enumerated()),id:\.element.id) { index,segment in
            let identity = "segment:"+record.id.uuidString+":"+segment.id.uuidString
            let originalIdentity = "segment-original:"+record.id.uuidString+":"+segment.id.uuidString
            VStack(alignment:.leading,spacing:6) {
                HStack {
                    Text("第 \(index+1) 段 · "+ReadingRecordMetadata.date(segment.captured))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("校订对照…") { comparing = segment }.buttonStyle(.borderless)
                        .disabled(journal.unreadable || record.removed != nil)
                }
                if editing {
                    ReadingWritingEditor(text:Binding(
                        get:{ journal.record(record.id)?.textExcerptSegments.first(where:{$0.id == segment.id})?.text ?? segment.text },
                        set:{ value in journal.editRecord(record.id) { $0.reviseExcerptSegment(segment.id,text:value) } }
                    ),label:"第 \(index+1) 段摘录",identity:identity)
                    .frame(height:160).border(.quaternary)
                } else { Text(segment.text).textSelection(.enabled) }
                if let original = segment.originalText,original != segment.text {
                    if focusedIdentity == originalIdentity {
                        Text("校订前原文").font(.caption).foregroundStyle(.secondary)
                        Text(original).textSelection(.enabled).id(originalIdentity)
                    } else {
                        DisclosureGroup("校订前原文") { Text(original).textSelection(.enabled) }
                    }
                }
                ForEach(Array(segment.sources(in:record).enumerated()),id:\.offset) { _,citation in
                    VStack(alignment:.leading,spacing:4) {
                        Text(citation.display).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        HStack {
                            Button("返回原文") { openSource(citation) }
                            Button("上下文…") { showContext(citation.source) }
                        }.font(.caption)
                    }
                }
            }.frame(maxWidth:.infinity,alignment:.leading).padding(8).id(identity)
                .background(.quaternary.opacity(0.4),in:RoundedRectangle(cornerRadius:6))
        }.sheet(item:$comparing) { segment in
            ReadingQuoteCorrectionView(journal:journal,record:record,segmentID:segment.id)
        }
    }
}
