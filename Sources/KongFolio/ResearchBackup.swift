import Foundation

struct ResearchBackup: Codable {
    struct Asset: Codable { var path: String; var bytes: Data; var digest: String }
    var version = 1
    var created = Date()
    var sourceStorage: String? = nil
    var aliases: [String: String]? = nil
    var catalog: BookLibrary.Catalog
    var research: ResearchStore.State
    var originalDigests: [String: String] = [:]
    var originals: [String: Data]
    var companions: [Asset]
    var progress: [String: Data]
    static let allowedFolders: Set<String> = ["ReadingJournal", "ReadingRulers", "ReadingDocuments", "SignatureEdits", "AcademicDrafts", "NoteAssets", "Boards", "WordDrafts", "TableDrafts", "Research", "Library", "History", "TextHistory", "Notes", "Conflicts"]
    func validate() throws {
        guard version == 1, originals.count <= 10000, companions.count <= 100000 else { throw FolioError(message: "备份版本或数量无效") }
        guard Set(originals.keys) == Set(originalDigests.keys), Set(companions.map(\.path)).count == companions.count else { throw FolioError(message: "备份目录重复或原书索引不完整") }
        guard originals.keys.allSatisfy({ originalDigests[$0] == OCRPageCache.digest(originals[$0]!) }) else { throw FolioError(message: "原书备份校验失败") }
        for item in companions {
            let parts = item.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !item.path.hasPrefix("/"), parts.count >= 2, parts.allSatisfy({ !$0.contains("\0") && !$0.isEmpty && $0 != "." && $0 != ".." }), Self.allowedFolders.contains(String(parts[0])), OCRPageCache.digest(item.bytes) == item.digest else { throw FolioError(message: "备份路径或内容校验失败") }
        }
        guard catalog.version == 1, research.version == 1 else { throw FolioError(message: "资料格式不受支持") }
    }
    static func capture(storage: URL, catalog: BookLibrary.Catalog, research: ResearchStore.State, progress: [String: Data], includeOriginals: Bool) throws -> Self {
        var originals: [String: Data] = [:], companions: [Asset] = []
        if includeOriginals {
            let journalFile = storage.appendingPathComponent("ReadingJournal/catalog.json")
            let journal = FileManager.default.fileExists(atPath:journalFile.path) ? try JSONDecoder().decode(ReadingJournalState.self,from:Data(contentsOf:journalFile)) : nil
            let records = (journal?.records ?? []) + (journal?.essays.flatMap{$0.blocks.compactMap(\.record)} ?? [])
            let paths = Set(catalog.books.map(\.path) + records.flatMap{$0.citations.map(\.source.path)}.filter{!$0.isEmpty})
            for path in paths {
                try Task.checkCancellation()
                let url = URL(fileURLWithPath: path), bytes = try Data(contentsOf: url, options: .mappedIfSafe)
                originals[ReadingProgress.canonicalPath(path)] = bytes
                if TextImport.handles(url), let text = try? TextImport.decode(bytes) {
                    for image in TextAssets.references(text, format: TextDocumentFormat.forURL(url)) {
                        if let file = TextMedia.resolve(image.reference, baseURL: url.deletingLastPathComponent()) {
                            _ = try TextMedia.read(image.reference, baseURL: url.deletingLastPathComponent())
                            originals[ReadingProgress.canonicalPath(file.path)] = try Data(contentsOf: file, options: .mappedIfSafe)
                        }
                    }
                    let regex = try NSRegularExpression(pattern: #"kongfolio://source\?ref=[A-Za-z0-9%+/=]+"#)
                    for hit in regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
                        if let link = URL(string: (text as NSString).substring(with: hit.range)), let source = SourceLink.source(link) {
                            let resolved = try SourceLink.resolved(source, baseURL: url.deletingLastPathComponent())
                            originals[ReadingProgress.canonicalPath(resolved.path)] = try Data(contentsOf: URL(fileURLWithPath: resolved.path), options: .mappedIfSafe)
                        }
                    }
                }
            }
        }
        for folder in allowedFolders where folder != "Library" && folder != "Research" {
            let base = storage.appendingPathComponent(folder).resolvingSymlinksInPath().standardizedFileURL
            if let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
                for case let url as URL in enumerator {
                    try Task.checkCancellation()
                    let value = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard value.isRegularFile == true, value.isSymbolicLink != true else { continue }
                    let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
                    let canonical = url.standardizedFileURL.path
                    guard canonical.hasPrefix(base.path + "/") else { throw FolioError(message: "备份枚举路径不属于资料目录") }
                    companions.append(Asset(path: folder + "/" + canonical.dropFirst(base.path.count + 1), bytes: bytes, digest: OCRPageCache.digest(bytes)))
                }
            }
        }
        var aliases: [String: String] = [:]
        func collect(_ value: Any) {
            if let path = value as? String, path.hasPrefix("/") { let canonical = ReadingProgress.canonicalPath(path); if originals[canonical] != nil { aliases[path] = canonical } }
            if let array = value as? [Any] { array.forEach(collect) }
            if let dictionary = value as? [String: Any] { dictionary.keys.forEach(collect); dictionary.values.forEach(collect) }
        }
        for asset in companions { if let json = try? JSONSerialization.jsonObject(with: asset.bytes) { collect(json) } }
        collect(catalog.books.map(\.path)); collect(research.labels.keys.map { $0 }); collect(progress.keys.map { $0 })
        let backup = Self(sourceStorage: storage.standardizedFileURL.path, aliases: aliases, catalog: catalog, research: research, originalDigests: originals.mapValues(OCRPageCache.digest), originals: originals, companions: companions, progress: progress)
        try backup.validate(); return backup
    }
    struct Range: Codable { var offset: Int; var length: Int }
    struct Manifest: Codable { var metadata: ResearchBackup; var originals: [String: Range]; var companions: [Range] }
    static let magic = Data("KONGFOLIO-READING-BACKUP\n".utf8)
    /// Original PDFs are streamed from mapped storage in bounded chunks; encoding never copies the whole library.
    func write(_ target: URL, expected: FileBaseline) throws {
        try validate()
        var metadata = self; metadata.originals = [:]
        for i in metadata.companions.indices { metadata.companions[i].bytes = Data() }
        var offset = 0, originals: [String: Range] = [:], companions: [Range] = []
        for key in self.originals.keys.sorted() { let bytes = self.originals[key]!; originals[key] = Range(offset: offset, length: bytes.count); offset += bytes.count }
        for asset in self.companions { companions.append(Range(offset: offset, length: asset.bytes.count)); offset += asset.bytes.count }
        let manifest = try JSONEncoder().encode(Manifest(metadata: metadata, originals: originals, companions: companions))
        guard manifest.count <= 32_000_000 else { throw FolioError(message: "备份索引过大，请分组备份") }
        try DocumentTaskOutput.write(to: target, expected: expected) { staging in
            guard FileManager.default.createFile(atPath: staging.path, contents: nil) else { throw FolioError(message: "无法创建备份") }
            let handle = try FileHandle(forWritingTo: staging); defer { try? handle.close() }
            try handle.write(contentsOf: Self.magic)
            var size = UInt64(manifest.count).bigEndian
            try withUnsafeBytes(of: &size) { try handle.write(contentsOf: Data($0)) }
            try handle.write(contentsOf: manifest)
            func append(_ bytes: Data) throws {
                for start in stride(from: bytes.startIndex, to: bytes.endIndex, by: 4*1024*1024) {
                    try Task.checkCancellation(); try handle.write(contentsOf: bytes[start..<min(bytes.endIndex,start+4*1024*1024)])
                }
            }
            for key in self.originals.keys.sorted() { try append(self.originals[key]!) }
            for asset in self.companions { try append(asset.bytes) }
            try handle.synchronize()
        }
    }
    static func read(_ url: URL) throws -> Self {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        if !data.starts(with: magic) { let value = try PropertyListDecoder().decode(Self.self, from: data); try value.validate(); return value }
        guard data.count >= magic.count+8 else { throw FolioError(message: "备份头部损坏") }
        let length = data[magic.count..<magic.count+8].reduce(UInt64(0)) { ($0<<8)|UInt64($1) }
        guard length <= 32_000_000, length <= UInt64(data.count-magic.count-8) else { throw FolioError(message: "备份索引损坏") }
        let start = magic.count+8, payload = start+Int(length)
        let manifest = try JSONDecoder().decode(Manifest.self, from: data[start..<payload])
        var value = manifest.metadata
        guard manifest.companions.count == value.companions.count else { throw FolioError(message: "备份资料目录不完整") }
        func bytes(_ range: Range) throws -> Data {
            guard range.offset >= 0, range.length >= 0, range.offset <= data.count-payload, range.length <= data.count-payload-range.offset else { throw FolioError(message: "备份内容范围无效") }
            return data[payload+range.offset..<payload+range.offset+range.length]
        }
        value.originals = try manifest.originals.mapValues(bytes)
        for i in value.companions.indices { value.companions[i].bytes = try bytes(manifest.companions[i]) }
        try value.validate(); return value
    }
    /// Restoration creates an independent directory. Originals and the current app catalog are never overwritten.
    func restore(in directory: URL) throws -> (root: URL, missing: [String]) {
        try validate()
        let root = directory.appendingPathComponent("KongFolio-恢复-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        do {
            let booksFolder = root.appendingPathComponent("Books"); try FileManager.default.createDirectory(at: booksFolder, withIntermediateDirectories: true)
            var map: [String: String] = [:], missing: [String] = []
            let support = root.appendingPathComponent("AppData")
            for (path,bytes) in originals {
                let file = booksFolder.appendingPathComponent(UUID().uuidString + "-" + URL(fileURLWithPath: path).lastPathComponent)
                try bytes.write(to: file, options: .atomic); map[path] = file.path
            }
            for (alias,canonical) in aliases ?? [:] { if let destination = map[canonical] { map[alias] = destination } }
            for book in catalog.books where map[book.path] == nil {
                if FileManager.default.fileExists(atPath: book.path) { map[book.path] = book.path } else { missing.append(book.path) }
            }
            func mappedPath(_ path: String) -> String? {
                map[path] ?? map[ReadingProgress.canonicalPath(path)] ?? map[URL(fileURLWithPath: path).standardizedFileURL.path] ?? map[URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path]
            }
            func rewrittenText(_ text: String) -> String {
                var result = text
                if let sourceStorage {
                    for folder in Self.allowedFolders {
                        let old = URL(fileURLWithPath: sourceStorage).appendingPathComponent(folder).absoluteString, new = support.appendingPathComponent(folder).absoluteString
                        let oldPrefix = old.hasSuffix("/") ? old : old + "/", newPrefix = new.hasSuffix("/") ? new : new + "/"
                        result = result.replacingOccurrences(of: oldPrefix, with: newPrefix)
                    }
                }
                if let regex = try? NSRegularExpression(pattern: #"kongfolio://source\?ref=[A-Za-z0-9%+/=]+"#) {
                    let string = NSMutableString(string: result)
                    for hit in regex.matches(in: result, range: NSRange(location: 0, length: (result as NSString).length)).reversed() {
                        guard let url = URL(string: (result as NSString).substring(with: hit.range)), var source = SourceLink.source(url), let moved = mappedPath(source.path) else { continue }
                        source.path = moved; source.relativePath = nil
                        if let link = SourceLink.url(source) { string.replaceCharacters(in: hit.range, with: link.absoluteString) }
                    }
                    result = string as String
                }
                return result
            }
            for (old,bytes) in originals where TextImport.handles(URL(fileURLWithPath: old)) {
                guard let target = map[old], let text = try? TextImport.decode(bytes) else { continue }
                let result = NSMutableString(string: text), base = URL(fileURLWithPath: old).deletingLastPathComponent()
                for image in TextAssets.references(text, format: TextDocumentFormat.forURL(URL(fileURLWithPath: old))).reversed() {
                    if let resolved = TextMedia.resolve(image.reference, baseURL: base), let moved = mappedPath(resolved.path) { result.replaceCharacters(in: image.range, with: URL(fileURLWithPath: moved).absoluteString) }
                }
                try rewrittenText(result as String).write(to: URL(fileURLWithPath: target), atomically: true, encoding: .utf8)
            }
            func remap(_ value: Any) -> Any {
                if let value = value as? String {
                    if let path = map[value] { return path }
                    if value.hasPrefix("/"), let path = map[URL(fileURLWithPath: value).resolvingSymlinksInPath().standardizedFileURL.path] { return path }
                    if let sourceStorage, value.hasPrefix(sourceStorage + "/") { return support.path + value.dropFirst(sourceStorage.count) }
                    return rewrittenText(value)
                }
                if let array = value as? [Any] { return array.map(remap) }
                if let dictionary = value as? [String: Any] {
                    var result: [String: Any] = [:]
                    for key in dictionary.keys.sorted() {
                        let mapped = key.hasPrefix("/") ? mappedPath(key) ?? key : key
                        let outputKey = result[mapped] == nil ? mapped : key
                        result[outputKey] = remap(dictionary[key]!)
                    }
                    if let path = dictionary["path"] as? String, let key = dictionary["key"] as? String, key.hasPrefix(path + ":"), let destination = mappedPath(path) { result["key"] = destination + key.dropFirst(path.count) }
                    if let path = dictionary["path"] as? String, let digest = dictionary["digest"] as? String, let destination = mappedPath(path) {
                        let oldDigest = originalDigests[path] ?? originalDigests[ReadingProgress.canonicalPath(path)] ?? originalDigests[URL(fileURLWithPath: path).standardizedFileURL.path]
                        if oldDigest == digest, let bytes = try? Data(contentsOf: URL(fileURLWithPath: destination), options: .mappedIfSafe) { result["digest"] = OCRPageCache.digest(bytes) }
                    }
                    return result
                }
                return value
            }
            func rewritten(_ bytes: Data) -> Data {
                guard let json = try? JSONSerialization.jsonObject(with: bytes, options: .fragmentsAllowed), let result = try? JSONSerialization.data(withJSONObject: remap(json), options: [.fragmentsAllowed]) else { return bytes }
                return result
            }
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            for asset in companions {
                let output = support.appendingPathComponent(asset.path)
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try rewritten(asset.bytes).write(to: output, options: .atomic)
            }
            for (old,new) in map where old != new {
                for folder in ["ReadingRulers", "ReadingDocuments", "SignatureEdits", "AcademicDrafts", "WordDrafts", "TableDrafts", "History", "TextHistory"] {
                    let oldURL = URL(fileURLWithPath: old), newURL = URL(fileURLWithPath: new)
                    let oldIdentity = folder == "ReadingDocuments" ? oldURL.resolvingSymlinksInPath().standardizedFileURL.path : oldURL.standardizedFileURL.path
                    let newIdentity = folder == "ReadingDocuments" ? newURL.resolvingSymlinksInPath().standardizedFileURL.path : newURL.standardizedFileURL.path
                    let hashOld = OCRPageCache.digest(Data(oldIdentity.utf8))
                    let hashNew = OCRPageCache.digest(Data(newIdentity.utf8))
                    let base = support.appendingPathComponent(folder)
                    let aliases = oldIdentity.hasPrefix("/private/var/") ? [oldIdentity,String(oldIdentity.dropFirst(8))] : [oldIdentity]
                    for identity in aliases {
                        let oldHash = identity == oldIdentity ? hashOld : OCRPageCache.digest(Data(identity.utf8))
                        for ext in [".json", ""] {
                            let source = base.appendingPathComponent(oldHash + ext), destination = base.appendingPathComponent(hashNew + ext)
                            if source != destination, FileManager.default.fileExists(atPath: source.path), !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.moveItem(at: source, to: destination) }
                        }
                    }
                }
            }
            var next = catalog
            next.books = catalog.books.map { book in var book = book; book.path = map[book.path] ?? book.path; book.bookmark = nil; return book }
            next.shortcuts = catalog.shortcuts.map { item in var item = item; item.shortcut.path = map[item.shortcut.path] ?? item.shortcut.path; item.shortcut.bookmark = nil; item.file = nil; item.baseline = nil; return item }
            for (old,new) in map where old != new { next.relocated[old] = new }
            try FileManager.default.createDirectory(at: support.appendingPathComponent("Library"), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: support.appendingPathComponent("Library/catalog.json"), options: .atomic)
            try FileManager.default.createDirectory(at: support.appendingPathComponent("Research"), withIntermediateDirectories: true)
            try rewritten(JSONEncoder().encode(research)).write(to: support.appendingPathComponent("Research/catalog.json"), options: .atomic)
            var movedProgress: [String: Data] = [:]
            for (path, bytes) in progress { movedProgress[map[path] ?? path] = bytes }
            try PropertyListEncoder().encode(movedProgress).write(to: root.appendingPathComponent("ReadingProgress.plist"))
            return (root, missing)
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
}
