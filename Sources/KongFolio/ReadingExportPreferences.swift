import Foundation

struct ReadingExportOptions: Codable, Equatable {
    var fontName = "Songti SC"
    var fontSize:Double = 12
    var includeQuote = true
    var includeNote = true
    var includeSources = true
    var valid:Bool { !fontName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && fontName.count < 128 && fontSize.isFinite && (8...36).contains(fontSize) && (includeQuote || includeNote || includeSources) }
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
    static func load(defaults:UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey:key), let value = try? JSONDecoder().decode(Self.self,from:data), value.options.valid else { return Self() }; return value
    }
    func save(defaults:UserDefaults = .standard) { guard options.valid, let data = try? JSONEncoder().encode(self) else { return }; defaults.set(data,forKey:Self.key) }
    var directoryURL:URL? { guard let path = directoryPath, path.hasPrefix("/") else { return nil }; var directory:ObjCBool = false; guard FileManager.default.fileExists(atPath:path,isDirectory:&directory),directory.boolValue else { return nil }; return URL(fileURLWithPath:path,isDirectory:true) }
}
