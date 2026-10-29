import SwiftUI

struct ReadingDeskView: View {
    @ObservedObject var store:WorkspaceStore
    @ObservedObject var journal:ReadingJournal
    @Binding var section:ReadingDeskSection
    var compact = false
    @State private var query = ""
    @State private var tag = ""
    @State private var bookOnly = true
    @State private var recent = false
    @State private var removed = false
    @State private var page = 0
    private var path:String? { store.commandWorkspace?.displayPath }
    private var matches:[ReadingRecord] {
        journal.state.records.filter {
            ($0.removed != nil) == removed && (section == .search || (section == .notes ? $0.kind == .note : $0.kind != .note)) &&
            $0.matches(query,book:section == .search || !bookOnly ? nil : path,tag:tag,after:recent ? Date().addingTimeInterval(-7*86400) : nil)
        }.sorted { $0.modified == $1.modified ? $0.id.uuidString < $1.id.uuidString : $0.modified > $1.modified }
    }
    private var hits:[ReadingDeskHit] {
        var values = matches.map { ReadingDeskHit.record($0) }
        if section == .search { values += journal.state.essays.filter { ($0.removed != nil) == removed && $0.matches(query) && (tag.isEmpty || $0.tags.contains(tag)) && (!recent || $0.modified >= Date().addingTimeInterval(-7*86400)) }.map { ReadingDeskHit.essay($0) } }
        return values.sorted { $0.date > $1.date }
    }
    private var lastPage:Int { max(0,(hits.count-1)/30) }
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {
                Text("阅读记录").font(.headline)
                Spacer()
                if compact { Button { store.openReadingDesk(section,window:true) } label:{Image(systemName:"arrow.up.left.and.arrow.down.right")}.help("在独立窗口中打开阅读记录") }
            }
            Picker("记录类型",selection:$section) { ForEach(ReadingDeskSection.allCases,id:\.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu)
            if section == .exports { ReadingExportPane(store:store,journal:journal) }
            else if section == .essays { ReadingEssayPane(store:store,journal:journal) }
            else { records }
            Divider()
            HStack {
                Text(journal.saveStatus).font(.caption).foregroundStyle(journal.error == nil ? Color.secondary : .red).lineLimit(3)
                if journal.error != nil { Button("重试保存") { Task { try? await journal.flush() } } }
            }
            if journal.unreadable { Button("保留损坏文件并恢复上一份记录") { do { try journal.recoverPrevious() } catch { store.present(error) } } }
        }.padding(compact ? 10 : 18)
        .onChange(of:query) { _,_ in page = 0 }.onChange(of:tag) { _,_ in page = 0 }.onChange(of:path) { _,_ in page = 0 }
        .onChange(of:section) { _,_ in page = 0 }
    }
    private var records:some View {
        VStack(alignment:.leading,spacing:8) {
            TextField("搜索摘录、笔记、书名或页码",text:$query).textFieldStyle(.roundedBorder)
            HStack {
                if section != .search { Toggle("仅当前书",isOn:$bookOnly).disabled(path == nil) }
                Toggle("最近七天",isOn:$recent)
            }.font(.caption)
            HStack {
                TextField("按标签筛选",text:$tag)
                Toggle("最近移除",isOn:$removed).font(.caption)
            }
            if section == .notes { Menu("新建笔记") { Button("当前页笔记") { store.newReadingNote() }; Button("整本书心得") { store.newReadingNote(bookWide:true) }; if let current = journal.record(store.readingRecordID) { Button("关联这条摘录的笔记") { store.newReadingNote(linked:current) } } }.disabled(journal.unreadable) }
            List { ForEach(Array(hits.dropFirst(min(page,lastPage)*30).prefix(30))) { hit in
                switch hit {
                case .record(let record): row(record)
                case .essay(let essay): Button { journal.selectEssay(essay.id); section = .essays } label: { Label(essay.title+" · 札记",systemImage:"doc.text").lineLimit(2).help(essay.title) }.buttonStyle(.plain)
                }
            } }
                .frame(minHeight:100,maxHeight:store.readingRecordID == nil ? .infinity : 180)
                .overlay { if hits.isEmpty { Text("这里保存你的摘录、笔记和札记").font(.caption).foregroundStyle(.secondary) } }
            HStack {
                Text("\(hits.count) 条").font(.caption); Spacer()
                Button { page = max(0,page-1) } label:{ Image(systemName:"chevron.left") }.disabled(page == 0).help("上一页记录")
                Text("\(min(page,lastPage)+1)/\(lastPage+1)").font(.caption)
                Button { page += 1 } label:{ Image(systemName:"chevron.right") }.disabled(page >= lastPage).help("下一页记录")
            }
            if let record = journal.record(store.readingRecordID) { ReadingRecordDetail(store:store,journal:journal,record:record).id(record.id).disabled(journal.unreadable) }
        }
    }
    private func row(_ record:ReadingRecord) -> some View {
        HStack(alignment:.top) {
            Toggle("选择记录",isOn:Binding(get:{store.readingRecordSelection.contains(record.id)},set:{ if $0 { store.readingRecordSelection.insert(record.id) } else { store.readingRecordSelection.remove(record.id) } })).labelsHidden()
            Button { store.readingRecordID = record.id } label: {
                VStack(alignment:.leading,spacing:3) {
                    Text(record.displayTitle).lineLimit(2).help(record.displayTitle)
                    if let source = record.citations.first { Text(source.display).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(source.display) }
                    if !record.tags.isEmpty { Text(record.tags.joined(separator:" · ")).font(.caption).foregroundStyle(.blue) }
                }.frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }.padding(.vertical,3).listRowBackground(store.readingRecordID == record.id ? Color.accentColor.opacity(0.12) : .clear)
    }
}
struct ReadingRecordDetail: View {
    @ObservedObject var store:WorkspaceStore
    @ObservedObject var journal:ReadingJournal
    let record:ReadingRecord
    @State private var editQuote = false
    @State private var showLinkPicker = false
    @StateObject private var imageOCR = ReadingImageOCRController()
    private var current:ReadingRecord { journal.record(record.id) ?? record }
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:10) {
                TextField("记录标题（可留空）",text:binding(\.title))
                if current.kind != .note {
                    HStack { Text("摘录原文").font(.caption); Spacer(); Button(editQuote ? "完成文字校正" : "校正摘录文字") { editQuote.toggle() } }
                    if editQuote { TextEditor(text:binding(\.quote)).frame(height:100).border(.quaternary) }
                    else if !current.quote.isEmpty { Text(current.quote).textSelection(.enabled) }
                }
                if current.kind == .note && !current.quote.isEmpty { Text("关联原文").font(.caption); Text(current.quote).textSelection(.enabled) }
                if let image = current.imageAsset { ReadingRecordImage(url:journal.assetURL(image),pending:journal.pendingImage(image)).frame(maxHeight:220) }
                if current.kind == .image { imageRecognition }
                if current.kind == .note { Button("关联更多摘录…") { showLinkPicker = true } }
                Text(current.kind == .note ? "我的笔记" : "我的理解与评论").font(.caption)
                TextEditor(text:binding(\.note)).frame(minHeight:120).border(.quaternary).accessibilityLabel("阅读笔记正文")
                TextField("标签，以逗号分隔",text:Binding(get:{current.tags.joined(separator:", ")},set:{ text in journal.editRecord(record.id) { $0.tags = Self.tags(text) } }))
                ForEach(Array(current.citations.prefix(20).enumerated()),id:\.offset) { _,citation in
                    VStack(alignment:.leading) {
                        Text(current.wholeBook ? "《"+citation.title+"》 · 整本书" : citation.display).font(.caption).textSelection(.enabled)
                        HStack {
                            Button("返回原文") { _ = store.reveal(citation.source,beside:false) }.disabled(citation.source.path.isEmpty)
                            Button("重新关联…") { relink(citation) }
                        }
                    }
                }
                if current.citations.count > 20 { Text("另有来源页，导出时一并保留").font(.caption) }
                HStack {
                    Button("加入札记") { let id = journal.state.currentEssay ?? journal.newEssay(); journal.insert(current,in:id); store.openReadingDesk(.essays,window:true) }
                    Button("导出这条记录") { store.readingRecordSelection = [record.id]; store.readingExportEssay = false; store.openReadingDesk(.exports,window:true) }
                }
                if current.kind != .note { Button("针对摘录写笔记") { store.newReadingNote(linked:current) } }
                if current.removed != nil { Button("恢复记录") { journal.editRecord(record.id) { $0.removed = nil } } }
                else { Button("移到最近移除") { journal.editRecord(record.id) { $0.removed = Date() }; store.readingRecordID = nil; store.readingRecordSelection.remove(record.id) } }
            }
        }.onDisappear { imageOCR.cancel() }.sheet(isPresented:$showLinkPicker) {
            ReadingRecordPicker(journal:journal) { other in
                journal.editRecord(record.id) { value in
                    guard !value.linkedRecords.contains(other.id) else { return }
                    value.linkedRecords.append(other.id)
                    if !other.quote.isEmpty { value.quote += (value.quote.isEmpty ? "" : "\n\n")+other.quote }
                    for citation in other.citations where !value.citations.contains(citation) { value.citations.append(citation) }
                }
            }
        }
    }
    private var imageRecognition:some View {
        VStack(alignment:.leading,spacing:6) {
            HStack {
                Menu("识别摘录图片文字") {
                    Button("横排文字") { imageOCR.recognize(current,journal:journal,vertical:false) }
                    Button("竖排文字") { imageOCR.recognize(current,journal:journal,vertical:true) }
                }.disabled(imageOCR.busy)
                if imageOCR.busy { ProgressView().controlSize(.small); Button("取消识别") { imageOCR.cancel() } }
            }
            if !imageOCR.text.isEmpty {
                Text(imageOCR.text).lineLimit(8).textSelection(.enabled)
                Button("采用识别文字") { journal.editRecord(record.id) { $0.quote = imageOCR.text }; editQuote = true }
            }
            if !imageOCR.message.isEmpty { Text(imageOCR.message).font(.caption) }
        }
    }
    private func binding(_ key:WritableKeyPath<ReadingRecord,String>) -> Binding<String> { Binding(get:{current[keyPath:key]},set:{text in journal.editRecord(record.id) { $0[keyPath:key] = text }}) }
    static func tags(_ text:String) -> [String] { var seen = Set<String>(); return text.replacingOccurrences(of:"，",with:",").split(separator:",").map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter{!$0.isEmpty && seen.insert($0).inserted} }
    private func relink(_ citation:ReadingCitation) {
        let panel = NSOpenPanel(); panel.message = "选择这条记录的原书；记录文字和原页码保留，请核对来源。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if citation.source.path.isEmpty { journal.relink(old:"",to:url,recordID:record.id) }
            else { try store.library.relink(path:citation.source.path,to:url,defaults:store.readingDefaults) }
        } catch { store.present(error) }
    }
}
struct ReadingRecordImage: View {
    var url:URL
    var pending:Data? = nil
    @State private var image:NSImage?
    @State private var failed = false
    var body:some View {
        Group { if let image { Image(nsImage:image).resizable().scaledToFit() } else { Text(failed ? "图片暂不可用，可返回原文查看" : "正在载入图片摘录…").font(.caption) } }
            .task(id:url.path+(pending == nil ? ":disk" : ":pending")) { let file = url; let data:Data?; if let pending { data = pending } else { data = await Task.detached(priority:.utility) { try? Data(contentsOf:file) }.value }; guard !Task.isCancelled else { return }; image = data.flatMap(NSImage.init(data:)); failed = image == nil }
    }
}

@MainActor final class ReadingDeskSession:ObservableObject {
    @Published var section:ReadingDeskSection
    init(_ section:ReadingDeskSection) { self.section = section }
}
struct ReadingDeskWindowView:View {
    @ObservedObject var store:WorkspaceStore
    @ObservedObject var session:ReadingDeskSession
    var body:some View { ReadingDeskView(store:store,journal:store.journal,section:$session.section).task { await store.importLegacyReadingRecords() } }
}
@MainActor final class ReadingDeskWindowManager {
    static let shared = ReadingDeskWindowManager()
    private var windows:[ObjectIdentifier:ReadingDeskWindowController] = [:]
    func show(_ store:WorkspaceStore) {
        let key = ObjectIdentifier(store)
        if let controller = windows[key] {
            if !(controller.session.section == .essays && store.readingDeskSection == .excerpts) { controller.session.section = store.readingDeskSection }
            controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); return
        }
        let controller = ReadingDeskWindowController(store:store,section:store.readingDeskSection)
        controller.closed = { [weak self] in self?.windows[key] = nil }; windows[key] = controller
        controller.window?.center(); controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
}
@MainActor final class ReadingDeskWindowController:NSWindowController,NSWindowDelegate {
    let session:ReadingDeskSession
    var closed:(()->Void)?
    init(store:WorkspaceStore,section:ReadingDeskSection) {
        session = ReadingDeskSession(section)
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:940,height:760),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title = "摘录、笔记与札记"; window.identifier = NSUserInterfaceItemIdentifier("reading-desk")
        window.minSize = NSSize(width:600,height:460); window.isReleasedWhenClosed = false
        super.init(window:window); window.delegate = self
        window.contentView = NSHostingView(rootView:ReadingDeskWindowView(store:store,session:session))
    }
    required init?(coder:NSCoder) { fatalError("not used") }
    func windowWillClose(_ notification:Notification) { window?.contentView = nil; closed?() }
}

private enum ReadingDeskHit:Identifiable {
    case record(ReadingRecord),essay(ReadingEssay)
    var id:String { switch self { case .record(let value): return "record:"+value.id.uuidString; case .essay(let value): return "essay:"+value.id.uuidString } }
    var date:Date { switch self { case .record(let value): return value.modified; case .essay(let value): return value.modified } }
}
struct ReadingRecordPicker:View {
    @ObservedObject var journal:ReadingJournal
    var choose:(ReadingRecord)->Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var page = 0
    private var records:[ReadingRecord] { journal.state.records.filter{$0.kind != .note && $0.removed == nil && $0.matches(query)}.sorted{$0.modified > $1.modified} }
    private var lastPage:Int { max(0,(records.count-1)/30) }
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            Text("选择要关联的摘录").font(.headline); TextField("查找摘录或书名",text:$query)
            List(Array(records.dropFirst(min(page,lastPage)*30).prefix(30))) { record in
                HStack { VStack(alignment:.leading) { Text(record.displayTitle).lineLimit(2); Text(record.citations.map(\.display).joined(separator:" · ")).font(.caption).lineLimit(1) }; Spacer(); Button("关联") { choose(record); dismiss() } }
            }
            HStack { Button("关闭") { dismiss() }; Spacer(); Button("上一页") { page = max(0,page-1) }.disabled(page == 0); Text("\(min(page,lastPage)+1)/\(lastPage+1)"); Button("下一页") { page += 1 }.disabled(page >= lastPage) }
        }.padding(18).adaptiveSheet(width:700,height:520,minimumWidth:360).onChange(of:query) { _,_ in page = 0 }
    }
}
