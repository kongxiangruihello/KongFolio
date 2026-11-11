import Foundation

struct ReadingExportOptions: Codable, Equatable {
    var fontName = "Songti SC"
    var fontSize:Double = 12
    var includeQuote = true
    var includeNote = true
    var includeSources = true
    var lineHeight:Double? = nil
    var margin:Double? = nil
    var footnotes:Bool? = nil
    var sourceLinks:[String:String]? = nil
    var blockOrder:[String]? = nil
    var quoteHeading:String? = nil
    var noteHeading:String? = nil
    var sourcesHeading:String? = nil
    var imageHeading:String? = nil
    var showRecordTitles:Bool? = nil
    var nativeWordComments:Bool? = nil
    var includeRegionImages:Bool? = nil
    var bibliography053:Bool? = nil
    var shortenedCitations053:Bool? = nil
    var structuralOrder:[String] { let allowed = ["quote","note","sources"];var seen = Set<String>();return ((blockOrder ?? allowed)+allowed).filter{allowed.contains($0) && seen.insert($0).inserted} }
    var layout:TextLayoutOptions { var value = TextLayoutOptions();value.fontName = fontName;value.fontSize = fontSize;value.lineHeight = lineHeight ?? 1.4;value.margin = margin ?? 70.87;return value }
    var valid:Bool { !fontName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && fontName.count < 128 && fontSize.isFinite && (8...36).contains(fontSize) && layout.valid && (includeQuote || includeNote || includeSources) }
    func heading(_ record:ReadingRecord) -> String {
        if !record.title.isEmpty { return record.title }
        let text = includeQuote && record.kind != .note ? record.quote : (includeNote ? record.note : "")
        return String(text.split(separator:"\n").first?.prefix(48) ?? Substring(record.kind.rawValue))
    }
}
struct ReadingExportPreferences: Codable, Equatable {
    static let key = "KongFolio.readingExportPreferences"
    var format = ReadingRecordExport.Format.word
    var options = ReadingExportOptions()
    var directoryPath:String?
    var sort:ReadingExportOrdering.Sort? = nil
    static func load(defaults:UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey:key), let value = try? JSONDecoder().decode(Self.self,from:data), value.options.valid else { return Self() }; return value
    }
    func save(defaults:UserDefaults = .standard) { guard options.valid, let data = try? JSONEncoder().encode(self) else { return }; defaults.set(data,forKey:Self.key) }
    var directoryURL:URL? { guard let path = directoryPath, path.hasPrefix("/") else { return nil }; var directory:ObjCBool = false; guard FileManager.default.fileExists(atPath:path,isDirectory:&directory),directory.boolValue else { return nil }; return URL(fileURLWithPath:path,isDirectory:true) }
}

struct ReadingExportProfile:Codable,Identifiable {
    var id = UUID()
    var name:String
    var format:ReadingRecordExport.Format? = nil
    var options:ReadingExportOptions
    static var presets:[Self] {
        var excerpts = ReadingExportOptions();excerpts.includeNote = false;excerpts.lineHeight = 1.3;excerpts.margin = 56;excerpts.footnotes = true
        var notes = ReadingExportOptions();notes.lineHeight = 1.5
        var body = ReadingExportOptions()
        body.noteHeading = "正文"
        body.sourcesHeading = "出处"
        var essay = ReadingExportOptions();essay.lineHeight = 1.6;essay.margin = 80;essay.footnotes = true
        return [Self(id:UUID(uuidString:"00000000-0000-0000-0000-000000000104")!,name:"正文与出处",options:body),Self(id:UUID(uuidString:"00000000-0000-0000-0000-000000000101")!,name:"摘录汇编",options:excerpts),Self(id:UUID(uuidString:"00000000-0000-0000-0000-000000000102")!,name:"读书笔记",options:notes),Self(id:UUID(uuidString:"00000000-0000-0000-0000-000000000103")!,name:"研究笔记",options:essay)]
    }
    static func load(defaults:UserDefaults = .standard) -> [Self] { guard let data = defaults.data(forKey:"KongFolio.readingExportProfiles"),let profiles = try? JSONDecoder().decode([Self].self,from:data) else { return [] };return profiles.filter{$0.options.valid} }
    static func save(_ profiles:[Self],defaults:UserDefaults = .standard) throws { guard profiles.count<=100,profiles.allSatisfy({$0.options.valid && !$0.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}) else { throw FolioError(message:"模板名称或设置无效，最多保存 100 份模板") };defaults.set(try JSONEncoder().encode(profiles),forKey:"KongFolio.readingExportProfiles") }
}
