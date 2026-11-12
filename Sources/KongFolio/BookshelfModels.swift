import Foundation
import CryptoKit
import Darwin

enum ShelfReadingStatus: String, CaseIterable, Codable, Identifiable {
    case unread = "待读", reading = "在读", finished = "已读"
    var id: Self { self }
}

enum ShelfSort: String, CaseIterable {
    case recent = "最近阅读", added = "添加时间", title = "书名", author = "作者", year = "年代"
}

extension LibraryBook {
    var shelfTopics: [String] { ShelfBrowse.topics((topics ?? []) + [category]) }
    var isPDF: Bool { URL(fileURLWithPath:path).pathExtension.lowercased() == "pdf" }
    func shelfStatus(_ progress: ReadingProgress?) -> ShelfReadingStatus {
        readingStatus ?? (progress?.visited.isEmpty == false ? .reading : .unread)
    }
    func matchingShelfField(_ query: String) -> String? {
        let query = query.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        let fields = [("书名",title),("作者",shelfAuthor ?? ""),("刊名",shelfPeriodical ?? ""),
                      ("年代",shelfYear ?? ""),("专题",shelfTopics.joined(separator:" ")),
                      ("标签",(shelfTags ?? []).joined(separator:" ")),("文件名",path)]
        return fields.first { AnnotationFilter.folded($0.1).contains(AnnotationFilter.folded(query)) }?.0
    }
}

enum ShelfBrowse {
    static func topics(_ values: [String]) -> [String] {
        var known = Set<String>()
        return values.map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }
            .filter { !$0.isEmpty && known.insert(AnnotationFilter.folded($0)).inserted }
    }
    static func ordered(_ books:[LibraryBook], sort:ShelfSort, progress:[String:ReadingProgress]) -> [LibraryBook] {
        books.sorted { a,b in
            func text(_ lhs:String?,_ rhs:String?) -> ComparisonResult {
                let lhs = lhs ?? "", rhs = rhs ?? ""
                if lhs.isEmpty != rhs.isEmpty { return lhs.isEmpty ? .orderedDescending : .orderedAscending }
                return lhs.localizedStandardCompare(rhs)
            }
            switch sort {
            case .recent:
                let lhs = progress[a.path]?.date ?? .distantPast, rhs = progress[b.path]?.date ?? .distantPast
                if lhs != rhs { return lhs > rhs }
                if a.added != b.added { return a.added > b.added }
            case .added:
                if a.added != b.added { return a.added > b.added }
            case .author, .year:
                let cmp = sort == .author ? text(a.shelfAuthor,b.shelfAuthor) : text(a.shelfYear,b.shelfYear)
                if cmp != .orderedSame { return cmp == .orderedAscending }
            case .title: break
            }
            let cmp = text(a.title,b.title)
            return cmp == .orderedSame ? a.path < b.path : cmp == .orderedAscending
        }
    }
    static func recent(_ books:[LibraryBook], progress:[String:ReadingProgress]) -> [LibraryBook] {
        let reading = books.filter {
            progress[$0.path]?.visited.isEmpty == false && $0.shelfStatus(progress[$0.path]) == .reading
        }
        return Array(ordered(reading,sort:.recent,progress:progress).prefix(6))
    }
}

enum ShelfFileStatus: Equatable {
    case available, cloud, missing
    var label: String? {
        switch self {
        case .available: nil
        case .cloud: "待下载"
        case .missing: "需重新定位"
        }
    }
    static func read(_ url: URL) -> Self {
        let values = try? url.resourceValues(forKeys:[.isUbiquitousItemKey,.ubiquitousItemDownloadingStatusKey])
        if values?.isUbiquitousItem == true, values?.ubiquitousItemDownloadingStatus == .notDownloaded { return .cloud }
        var info = stat()
        guard lstat(url.path,&info) == 0 else { return .missing }
        return (info.st_flags & UInt32(SF_DATALESS)) != 0 ? .cloud : .available
    }
    static func digest(_ url: URL) throws -> String? {
        guard read(url) == .available else { return nil }
        let input = try FileHandle(forReadingFrom:url)
        defer { try? input.close() }
        var hasher = SHA256()
        while let bytes = try input.read(upToCount:1_048_576), !bytes.isEmpty {
            try Task.checkCancellation()
            hasher.update(data:bytes)
        }
        return hasher.finalize().map { String(format:"%02x",$0) }.joined()
    }
}
