import SwiftUI

struct ReadingTopicNoteSheet: View {
    @ObservedObject var journal: ReadingJournal
    let open: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var excerpts: [ReadingRecord]
    @State private var title = ""
    @State private var message = ""

    init(journal:ReadingJournal,excerpts:[ReadingRecord],open:@escaping(UUID)->Void) {
        self.journal = journal
        self.open = open
        _excerpts = State(initialValue:excerpts)
    }

    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("用摘录生成专题笔记").font(.headline)
            TextField("专题笔记标题",text:$title)
            List {
                ForEach(Array(excerpts.enumerated()),id:\.element.id) { index,record in
                    HStack {
                        VStack(alignment:.leading) {
                            Text(record.displayTitle).lineLimit(2)
                            Text(record.citations053.first?.display ?? "无出处").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("上移") { excerpts.swapAt(index,index-1) }.disabled(index == 0)
                        Button("下移") { excerpts.swapAt(index,index+1) }.disabled(index+1 == excerpts.count)
                    }
                }
            }.frame(minHeight:220)
            if !message.isEmpty { Text(message).foregroundStyle(.red) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("生成并编辑") {
                    do { let id = try journal.makeTopicNote(title:title,excerpts:excerpts.map(\.id)); dismiss(); open(id) }
                    catch { message = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).adaptiveSheet(width:640,height:470,minimumWidth:440)
    }
}

struct ReadingExcerptVersionPair: Identifiable {
    var id: UUID { right }
    let left: UUID
    let right: UUID
}

struct ReadingExcerptVersionsSheet: View {
    @ObservedObject var journal: ReadingJournal
    let pair: ReadingExcerptVersionPair
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""

    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("史料版本对照").font(.headline)
            if let left = journal.record(pair.left), left.removed == nil,
               let right = journal.record(pair.right), right.removed == nil {
                let linked = left.extras?.versionExcerpts?.contains(right.id) == true
                HSplitView {
                    column(left).frame(minWidth:230,maxWidth:.infinity)
                    column(right).frame(minWidth:230,maxWidth:.infinity)
                }
                HStack {
                    if !message.isEmpty { Text(message).font(.caption) }
                    Spacer()
                    Button(linked ? "解除版本关联" : "关联这两个版本") {
                        do {
                            try journal.setExcerptVersions(left.id,right.id,linked:!linked)
                            message = linked ? "已解除关联" : "已关联两个版本"
                        } catch { message = error.localizedDescription }
                    }.disabled(journal.unreadable)
                    Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            } else {
                ContentUnavailableView("有一个版本暂不可用",systemImage:"doc.text")
                Button("关闭") { dismiss() }
            }
        }.padding(20).adaptiveSheet(width:820,height:550,minimumWidth:520)
    }

    private func column(_ record:ReadingRecord) -> some View {
        ScrollView {
            VStack(alignment:.leading,spacing:10) {
                Text(record.displayTitle).font(.title3.bold()).textSelection(.enabled)
                ForEach(Array(record.citations053.enumerated()),id:\.offset) { _,citation in
                    Text(ReadingExportOrdering.citation(citation)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let name = record.imageAsset {
                    ReadingRecordImage(url:journal.assetURL(name),pending:journal.pendingImage(name)).frame(maxHeight:280)
                }
                if !record.quote.isEmpty { Text(record.quote).textSelection(.enabled) }
                if let original = record.originalOCR ?? record.originalQuote,original != record.quote {
                    DisclosureGroup("校订前文字") { Text(original).textSelection(.enabled) }
                }
                if !record.note.isEmpty || record.excerptRemark?.isEmpty == false {
                    Divider()
                    Text("我的判断").font(.headline)
                    Text([record.excerptRemark ?? "",record.note].filter{!$0.isEmpty}.joined(separator:"\n\n")).textSelection(.enabled)
                }
            }.frame(maxWidth:.infinity,alignment:.leading).padding(10)
        }
    }
}

struct ReadingCitationClipboardSheet: View {
    let records: [ReadingRecord]
    let copied: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var options = ReadingCitationClipboardOptions.load()

    var body: some View {
        let text = options.text(records)
        VStack(alignment:.leading,spacing:12) {
            Text("复制引文格式").font(.headline)
            Toggle("附印刷页码",isOn:$options.printedPage)
            Toggle("附返回原文链接",isOn:$options.sourceLink)
            ScrollView { Text(text).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("复制并记住格式") {
                    NSPasteboard.general.clearContents()
                    if NSPasteboard.general.setString(text,forType:.string) {
                        options.save(); dismiss(); copied()
                    }
                }.keyboardShortcut(.defaultAction).disabled(text.isEmpty)
            }
        }.padding(20).adaptiveSheet(width:600,height:420,minimumWidth:380)
    }
}

struct ReadingFollowUpButton: View {
    @ObservedObject var journal: ReadingJournal
    let item: ReadingLibraryID
    let identity: String
    var block: UUID? = nil
    @State private var target: ReadingFollowUp?
    @State private var question = ""
    @State private var notice = ""

    var body: some View {
        HStack {
            Button("添加待查问题…") {
                guard let selected = WritingRegistry.followUpSelection(identity),
                      let draft = ReadingFollowUp.capture(question:"待查",text:selected.text,selection:selected.range,block:block) else {
                    notice = "请把光标放在要标记的句子内，或先选中文字。"
                    return
                }
                notice = ""; question = ""; target = draft
            }.disabled(journal.unreadable || journal.libraryItem053(item) == nil)
            if !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(.secondary) }
        }
        .sheet(item:$target) { draft in
            VStack(alignment:.leading,spacing:12) {
                Text("添加待查问题").font(.headline)
                Text(draft.passage).font(.callout).foregroundStyle(.secondary).lineLimit(5)
                TextField("需要核实什么？",text:$question)
                HStack {
                    Button("取消") { target = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("保存") {
                        let saved = ReadingFollowUp(id:draft.id,question:question.trimmingCharacters(in:.whitespacesAndNewlines),
                                                    passage:draft.passage,offset:draft.offset,block:draft.block)
                        journal.saveFollowUp(saved,in:item)
                        target = nil
                    }.keyboardShortcut(.defaultAction).disabled(question.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                }
            }.padding(20).adaptiveSheet(width:490,height:230,minimumWidth:350,flexibleHeight:true)
        }
    }
}

struct ReadingFollowUpsView: View {
    @ObservedObject var journal: ReadingJournal
    var only: ReadingLibraryID? = nil
    let open: (ReadingLibraryItem,ReadingFollowUp) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var includeResolved = false

    var body: some View {
        let entries = ReadingLibraryItem.results(journal.state)
        let visible = entries.filter { item in
            (only == nil || only == item.id) &&
                (item.extras053.followUps ?? []).contains { includeResolved || $0.resolved == nil }
        }
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text("待查问题").font(.headline)
                Spacer()
                Toggle("显示已解决",isOn:$includeResolved)
                Button("完成") { dismiss() }
            }
            if visible.isEmpty {
                ContentUnavailableView("暂无待查问题",systemImage:"checkmark.circle")
            } else {
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:12) {
                        ForEach(visible) { item in
                            ForEach((item.extras053.followUps ?? []).filter{includeResolved || $0.resolved == nil}) { question in
                                VStack(alignment:.leading,spacing:6) {
                                    Text(question.question).font(.headline).textSelection(.enabled)
                                    Text(item.title+" · "+question.passage).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                    HStack {
                                        Button("回到笔记") { dismiss(); open(item,question) }
                                        Button(question.resolved == nil ? "标为已解决" : "重新打开") {
                                            var changed = question
                                            changed.resolved = changed.resolved == nil ? Date() : nil
                                            journal.saveFollowUp(changed,in:item.id)
                                        }.disabled(journal.unreadable)
                                    }
                                }.frame(maxWidth:.infinity,alignment:.leading)
                            }
                            Divider()
                        }
                    }
                }
            }
        }.padding(20).adaptiveSheet(width:640,height:480,minimumWidth:420)
    }
}
