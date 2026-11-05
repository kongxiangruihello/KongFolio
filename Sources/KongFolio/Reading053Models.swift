import Foundation

struct ReadingPublication053:Codable,Equatable,Hashable {
    var article=""
    var periodical=""
    var issue=""
    var published=""
    var chapter=""
    var summary:String { [article,periodical,issue,published].filter{!$0.isEmpty}.joined(separator:"，") }
}
struct ReadingSourceIdentity053:Codable,Equatable,Hashable {
    var documentID:UUID
    var capturedPage:Int
    var pageFingerprint:String?
    var capturedPageLabel:String?
    var needsReview:Bool? = nil
}
struct ReadingRegion053:Codable,Equatable,Identifiable {
    var id=UUID()
    var asset:String
    var citation:ReadingCitation
}
struct ReadingQuotation053:Codable,Equatable,Identifiable {
    var id=UUID()
    var recordID:UUID
    var title:String
    var text:String
    var citations:[ReadingCitation]
    var captured=Date()
    var kind:String? = nil
    var originalCreated:Date? = nil
    var originalModified:Date? = nil
    var assets:[String]? = nil
    var pdfOrigin:ReadingPDFOrigin? = nil
    var targetKind:String? = nil
}
struct ReadingRecordExtras053:Codable,Equatable {
    enum Review:String,Codable,CaseIterable { case unreviewed="待核对",verified="已核对",uncertain="存疑" }
    var review:Review? = nil
    var colorMeaning:String? = nil
    var chapter:String? = nil
    var visualAsset:String? = nil
    var regions:[ReadingRegion053]? = nil
    var quotations:[ReadingQuotation053]? = nil
    var hasContent:Bool { !(regions ?? []).isEmpty || !(quotations ?? []).isEmpty }
    var assets:[String] { (visualAsset.map{[$0]} ?? [])+(regions ?? []).map(\.asset)+(quotations ?? []).flatMap{$0.assets ?? []} }
}
enum ReadingNoteTemplate053:String,CaseIterable,Identifiable {
    case blank="空白笔记",reflection="读书心得",source="史料核对",concept="概念辨析"
    var id:String { rawValue }
    var body:String { switch self {
    case .blank:return ""
    case .reflection:return "# 读书心得\n\n## 主要观点\n\n## 我的思考\n\n## 需要追查的问题\n"
    case .source:return "# 史料核对\n\n## 原文与出处\n\n## 史料背景\n\n## 可以确认的内容\n\n## 存疑之处\n"
    case .concept:return "# 概念辨析\n\n## 概念及原文用法\n\n## 不同文献中的解释\n\n## 我的判断\n"
    } }
}
enum ReadingRecordLink053 {
    static func url(_ id:ReadingLibraryID)->URL {
        var c=URLComponents();c.scheme="kongfolio";c.host="record"
        switch id { case .record(let id):c.queryItems=[URLQueryItem(name:"id",value:id.uuidString),URLQueryItem(name:"kind",value:"record")];case .essay(let id):c.queryItems=[URLQueryItem(name:"id",value:id.uuidString),URLQueryItem(name:"kind",value:"essay")] }
        return c.url!
    }
    static func parse(_ url:URL)->ReadingLibraryID? {
        guard url.scheme=="kongfolio",url.host=="record",let c=URLComponents(url:url,resolvingAgainstBaseURL:false),let value=c.queryItems?.first(where:{$0.name=="id"})?.value,let id=UUID(uuidString:value) else { return nil }
        guard let kind=c.queryItems?.first(where:{$0.name=="kind"})?.value,["record","essay"].contains(kind) else { return nil };return kind=="essay" ? .essay(id):.record(id)
    }
}
extension ReadingLibraryItem {
    var modified053:Date { switch self {case .record(let r):return r.modified;case .essay(let e):return e.modified} }
    var citations053:[ReadingCitation] {
        let values:[ReadingCitation]
        switch self {case .record(let r):values=r.citations053;case .essay(let e):values=e.blocks.flatMap{$0.record?.citations053 ?? []}+(e.extras?.regions ?? []).map(\.citation)+(e.extras?.quotations ?? []).flatMap(\.citations)}
        return values.reduce(into:[]){ if !$0.contains($1) { $0.append($1) } }
    }
    var extras053:ReadingRecordExtras053 { switch self {case .record(let r):return r.extras ?? ReadingRecordExtras053();case .essay(let e):return e.extras ?? ReadingRecordExtras053()} }
    var text053:String { switch self {case .record(let r):return [r.quote,r.pdfOrigin?.contents ?? "",r.note].filter{!$0.isEmpty}.joined(separator:"\n\n");case .essay(let e):return e.blocks.map{[$0.record?.quote ?? "",$0.text].filter{!$0.isEmpty}.joined(separator:"\n\n")}.joined(separator:"\n\n")} }
    var chapter053:String { extras053.chapter ?? citations053.first?.publication?.chapter ?? "未分章节" }
}
@MainActor extension ReadingJournal {
    func libraryItem053(_ id:ReadingLibraryID)->ReadingLibraryItem? {
        switch id { case .record(let id):return state.records.first(where:{$0.id==id && $0.removed==nil}).map(ReadingLibraryItem.record);case .essay(let id):return state.essays.first(where:{$0.id==id && $0.removed==nil}).map(ReadingLibraryItem.essay) }
    }
    func updateExtras053(_ ids:Set<ReadingLibraryID>,_ edit:(inout ReadingRecordExtras053)->Void) {
        change { state in
            for i in state.records.indices where ids.contains(.record(state.records[i].id)) { var v=state.records[i].extras ?? ReadingRecordExtras053();edit(&v);state.records[i].extras=v;state.records[i].modified=Date() }
            for i in state.essays.indices where ids.contains(.essay(state.essays[i].id)) { var v=state.essays[i].extras ?? ReadingRecordExtras053();edit(&v);state.essays[i].extras=v;state.essays[i].modified=Date() }
        }
    }
    func addAsset053(_ data:Data)throws->String {
        guard !unreadable else { throw FolioError(message:"请先恢复阅读资料") }
        guard let decoded=SignatureImage.loadData(data),let image=SignatureImage.pngData(decoded) else { throw FolioError(message:"无法读取资料图片") }
        let name=OCRPageCache.digest(image)+".png"
        let folder=folder.appendingPathComponent("Assets");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let file=folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath:file.path) { guard try Data(contentsOf:file)==image else { throw FolioError(message:"图片校验冲突") } }
        else { try image.write(to:file,options:.atomic) }
        return name
    }
    func restoreRevision053(_ revision:ReadingRecordHistory.Revision) {
        change { s in
            if var r=revision.record { r.modified=Date();if let i=s.records.firstIndex(where:{$0.id==r.id}) { s.records[i]=r } else { s.records.append(r) } }
            if var e=revision.essay { e.modified=Date();if let i=s.essays.firstIndex(where:{$0.id==e.id}) { s.essays[i]=e } else { s.essays.append(e) } }
        }
    }
}
extension ReadingRecord {
    var citations053:[ReadingCitation] { (citations+(extras?.regions ?? []).map(\.citation)+(extras?.quotations ?? []).flatMap(\.citations)).reduce(into:[]){if !$0.contains($1){$0.append($1)}} }
    var assetNames053:[String] { (imageAsset.map{[$0]} ?? [])+(extras?.assets ?? []) }
    mutating func remapAssets053(_ names:[String:String]) {
        if let old=imageAsset { imageAsset=names[old] ?? old }
        if let old=extras?.visualAsset { extras?.visualAsset=names[old] ?? old }
        if var regions=extras?.regions { for i in regions.indices { regions[i].asset=names[regions[i].asset] ?? regions[i].asset };extras?.regions=regions }
        if var quotes=extras?.quotations { for i in quotes.indices { quotes[i].assets=quotes[i].assets?.map{names[$0] ?? $0} };extras?.quotations=quotes }
    }
}
extension ReadingJournalState {
    var assetNames053:Set<String> { Set((records+essays.flatMap{$0.blocks.compactMap(\.record)}).flatMap(\.assetNames053)+essays.flatMap{$0.extras?.assets ?? []}) }
}
extension ReadingRecordExtras053 {
    mutating func remapAssets053(_ names:[String:String]) {
        if let old=visualAsset { visualAsset=names[old] ?? old }
        if var regions { for i in regions.indices { regions[i].asset=names[regions[i].asset] ?? regions[i].asset };self.regions=regions }
        if var quotations { for i in quotations.indices { quotations[i].assets=quotations[i].assets?.map{names[$0] ?? $0} };self.quotations=quotations }
    }
}

extension ReadingLibraryID { var isEssay053:Bool { if case .essay=self { return true };return false } }
