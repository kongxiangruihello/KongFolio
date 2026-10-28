import Foundation
struct WordCachedImage: Codable { var name: String; var id: Int; var bytes: Data }
struct WordCachedPage: Codable {
    var key: String
    var body: String
    var image: WordCachedImage?
    var characters: Int
    static func key(source: String?, index: Int, options: WordExportOptions, outline: [OutlineEntry], regions: [Int: [RecognizedLine]]) throws -> String {
        struct Context: Codable { var source: String?; var index: Int; var options: WordExportOptions; var outline: [OutlineEntry]; var regions: [Int: [RecognizedLine]] }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return OCRPageCache.digest(try encoder.encode(Context(source: source, index: index, options: options, outline: outline, regions: regions)))
    }
}
