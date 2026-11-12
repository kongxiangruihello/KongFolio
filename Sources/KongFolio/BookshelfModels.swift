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
    var canQueueReading: Bool { isPDF || URL(fileURLWithPath:path).pathExtension.lowercased() == "kongfolio" }
    func shelfStatus(_ progress: ReadingProgress?) -> ShelfReadingStatus {
        readingStatus ?? (progress?.visited.isEmpty == false ? .reading : .unread)
    }
    var issueMetadata: (periodical:String,year:String,volume:String,issue:String) {
        if let shelfPeriodical, let shelfYear, let shelfVolume, let shelfIssue {
            return (shelfPeriodical,shelfYear,shelfVolume,shelfIssue)
        }
        let inferred = ShelfText.infer(title)
        let filename = URL(fileURLWithPath:path).deletingPathExtension().lastPathComponent
        let alternative = filename == title ? inferred : ShelfText.infer(filename)
        return (shelfPeriodical ?? (inferred.periodical.isEmpty ? alternative.periodical : inferred.periodical),
                shelfYear ?? (inferred.year.isEmpty ? alternative.year : inferred.year),
                shelfVolume ?? (inferred.volume.isEmpty ? alternative.volume : inferred.volume),
                shelfIssue ?? (inferred.issue.isEmpty ? alternative.issue : inferred.issue))
    }

    func matchingShelfField(_ query: String) -> String? {
        let query = query.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        let target = ShelfText.key(query)
        guard !target.isEmpty else { return nil }
        let metadata = issueMetadata
        let issue = metadata.issue.isEmpty ? "" : ShelfText.key(metadata.issue+"期")
        let volume = metadata.volume.isEmpty ? "" : ShelfText.key(metadata.volume+"卷")
        if target.range(of:#"^[0-9]+期$"#,options:.regularExpression) != nil { return target == issue ? "期次" : nil }
        if target.range(of:#"^[0-9]+卷$"#,options:.regularExpression) != nil { return target == volume ? "卷册" : nil }
        if !issue.isEmpty, target == String(issue.dropLast()) { return "期次" }
        let fields = [("书名",title),("作者",shelfAuthor ?? ""),("刊名",metadata.periodical),
                      ("年代",metadata.year),("专题",shelfTopics.joined(separator:" ")),
                      ("标签",(shelfTags ?? []).joined(separator:" ")),("文件名",path)]
        return fields.first { ShelfText.key($0.1).contains(target) }?.0
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
                let cmp = sort == .author ? text(a.shelfAuthor,b.shelfAuthor) : text(a.issueMetadata.year,b.issueMetadata.year)
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
