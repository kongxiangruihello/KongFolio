import Foundation

/// Shared by all tabs; a failed read never becomes an empty writable library.
enum SignatureLibrary {
    static func read(storage:URL) throws -> [SignatureTemplate] {
        let file = storage.appendingPathComponent("Signatures.json")
        guard FileManager.default.fileExists(atPath:file.path) else { return [] }
        let result = try JSONDecoder().decode([SignatureTemplate].self,from:Data(contentsOf:file))
        guard Set(result.map(\.id)).count == result.count else { throw FolioError(message:"签名编号重复") }
        return result
    }
    static func write(_ values:[SignatureTemplate],storage:URL) throws {
        let file = storage.appendingPathComponent("Signatures.json")
        try FileManager.default.createDirectory(at:storage,withIntermediateDirectories:true)
        let data = try JSONEncoder().encode(values)
        guard try JSONDecoder().decode([SignatureTemplate].self,from:data).count == values.count else { throw FolioError(message:"签名保存校验失败") }
        try data.write(to:file,options:.atomic)
    }
}
