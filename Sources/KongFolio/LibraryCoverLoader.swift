import Foundation
import PDFKit
import Darwin

/// A single worker and bounded cache serve visible rows. Covers never request cloud downloads.
actor LibraryCoverLoader {
    static let shared = LibraryCoverLoader()
    private let cache = NSCache<NSString,NSData>()
    private(set) var renderCount = 0
    init() { cache.countLimit = 160; cache.totalCostLimit = 12*1024*1024 }
    static func mayReadCover(ubiquitous: Bool, status: URLUbiquitousItemDownloadingStatus?, dataless: Bool) -> Bool {
        !dataless && (!ubiquitous || status == .current || status == .downloaded)
    }
    func load(_ original:URL) throws -> Data? {
        var url = original; url.removeAllCachedResourceValues()
        try Task.checkCancellation()
        guard url.pathExtension.lowercased() == "pdf" else { return nil }
        let metadata = try url.resourceValues(forKeys:[.isUbiquitousItemKey,.ubiquitousItemDownloadingStatusKey,.contentModificationDateKey,.fileSizeKey])
        var info = stat(); let found = url.withUnsafeFileSystemRepresentation { path -> Bool in guard let path else { return false }; return lstat(path,&info) == 0 }
        guard found, Self.mayReadCover(ubiquitous:metadata.isUbiquitousItem == true,status:metadata.ubiquitousItemDownloadingStatus,dataless:(info.st_flags & UInt32(SF_DATALESS)) != 0) else { return nil }
        let path = url.standardizedFileURL.path
        let size = metadata.fileSize ?? 0
        let modified = metadata.contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = "\(path):\(size):\(modified)" as NSString
        if let found = cache.object(forKey:key) { return found as Data }
        let bytes: Data? = try autoreleasepool {
            try Task.checkCancellation()
            guard let doc = PDFDocument(data:try Data(contentsOf:url,options:.mappedIfSafe)), !doc.isLocked, let page = doc.page(at:0) else { return nil }
            let image = try DocumentServices.render(page,maxDimension:140)
            try Task.checkCancellation(); return SignatureImage.pngData(image)
        }
        if let bytes { cache.setObject(bytes as NSData,forKey:key,cost:bytes.count); renderCount += 1 }
        return bytes
    }
}
