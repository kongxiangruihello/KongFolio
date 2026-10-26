import Foundation
import PDFKit

struct FolderSearchHit: Identifiable {
    let id=UUID()
    var url:URL
    var relativePath:String
    var fingerprint:String
    var query:String
    var hit:SearchHit
}
struct FolderSearchFile {
    var url:URL
    var hits:[FolderSearchHit]=[]
    var pages=0
    var textPages=0
    var cached=false
    var warning:String?
    var error:String?
    var needsOCR:Bool { error==nil && pages>0 && textPages==0 }
}
struct FolderSearchSummary {
    var totalFiles=0
    var files:[FolderSearchFile]=[]
    var discoveryErrors:[String]=[]
    var indexWarning:String?
    var truncated=false
    var hits:[FolderSearchHit] { files.flatMap(\.hits) }
}

enum FolderSearchService {
    enum Event {
        case discovered(Int)
        case reading(String)
        case page(String,Int,Int)
        case file(Int,Int,FolderSearchFile)
    }
    struct Verified { var data:Data;var source:SourceRef }
    static let resultLimit=1000
    static func enumerate(_ folder:URL,recursive:Bool) throws -> (files:[URL],errors:[String]) {
        let root=folder.standardizedFileURL.resolvingSymlinksInPath()
        let values=try root.resourceValues(forKeys:[.isDirectoryKey])
        guard values.isDirectory==true else { throw FolioError(message:"请选择可读取的文件夹") }
        var options:FileManager.DirectoryEnumerationOptions=[.skipsHiddenFiles,.skipsPackageDescendants]
        if !recursive { options.insert(.skipsSubdirectoryDescendants) }
        var errors:[String]=[]
        guard let enumerator=FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey],options:options,errorHandler:{ url,error in errors.append(url.path+"："+error.localizedDescription);return true }) else { throw FolioError(message:"无法读取这个文件夹") }
        var files:[URL]=[]
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            do {
                let properties=try url.resourceValues(forKeys:[.isSymbolicLinkKey,.isRegularFileKey])
                // DirectoryEnumerator does not follow symbolic links. skipDescendants on a file can skip the next real directory.
                if properties.isSymbolicLink==true { continue }
                if properties.isRegularFile==true,url.pathExtension.lowercased()=="pdf" { files.append(url.standardizedFileURL) }
            } catch { errors.append(url.path+"："+error.localizedDescription) }
        }
        return (files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending },errors)
    }
    static func relativePath(_ url:URL,in folder:URL) -> String {
        let path=folder.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix=path.hasSuffix("/") ? path : path+"/"
        return url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.lastPathComponent
    }
    static func indexedPage(_ page:PDFPage,index:Int) -> FolderSearchPage {
        let glyphs=OrderedText.glyphs(of:page)
        return FolderSearchPage(index:index,text:glyphs?.map(\.text).joined() ?? page.string ?? "",label:ReadingServices.pageLabel(page,index:index),glyphs:glyphs)
    }
    static func matches(_ page:FolderSearchPage,query:String,limit:Int,cache:inout [String:String]) -> [SearchHit] {
        guard limit>0 else { return [] }
        let ranges=ReadingServices.matches(in:page.text,query:query,cache:&cache,limit:limit)
        let text=page.text as NSString
        var starts:[Int]=[]
        if let glyphs=page.glyphs,!ranges.isEmpty { var position=0;for glyph in glyphs { starts.append(position);position+=glyph.text.utf16.count } }
        return ranges.map { found in
            let low=max(0,found.location-24),high=min(text.length,NSMaxRange(found)+48)
            let snippet=text.substring(with:text.rangeOfComposedCharacterSequences(for:NSRange(location:low,length:high-low))).replacingOccurrences(of:"\n",with:" ")
            var strips:[CGRect]?
            if let glyphs=page.glyphs,let first=starts.firstIndex(of:found.location),let last=starts.lastIndex(where:{$0<NSMaxRange(found)}) {
                var boxes:[CGRect]=[],column:Int?
                for glyph in glyphs[first...max(first,last)] {
                    if column==glyph.column,let tail=boxes.last { boxes[boxes.count-1]=tail.union(glyph.box) }
                    else { boxes.append(glyph.box);column=glyph.column }
                }
                strips=boxes
            }
            return SearchHit(page:page.index,range:found,snippet:ReadingServices.repairIdeographs(snippet),label:page.label,strips:strips)
        }
    }
    static func run(folder:URL,query:String,recursive:Bool,indexURL:URL,limit:Int=resultLimit,terms:FolderSearchTerms = FolderSearchTerms(),event:@escaping @Sendable (Event)->Void = { _ in }) throws -> FolderSearchSummary {
        let query=query.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !query.isEmpty else { throw FolioError(message:"请输入要搜索的文字") }
        guard limit>0 else { throw FolioError(message:"搜索结果上限必须大于零") }
        let discovery=try enumerate(folder,recursive:recursive)
        event(.discovered(discovery.files.count))
        var result=FolderSearchSummary(totalFiles:discovery.files.count,discoveryErrors:discovery.errors)
        let index:FolderSearchIndex?
        do { index=try FolderSearchIndex(url:indexURL) }
        catch { index=nil;result.indexWarning="索引不可用，本次直接搜索："+error.localizedDescription }
        var totalHits=0,foldingCache:[String:String]=[:]
        for (offset,url) in discovery.files.enumerated() {
            try Task.checkCancellation()
            let file:FolderSearchFile=try autoreleasepool {
                do {
                    return try searchFile(url,folder:folder,query:query,index:index,limit:max(0,limit-totalHits),cache:&foldingCache,terms:terms,event:event)
                } catch is CancellationError { throw CancellationError() }
                catch { return FolderSearchFile(url:url,error:error.localizedDescription) }
            }
            totalHits+=file.hits.count;result.files.append(file);event(.file(offset,discovery.files.count,file))
            if totalHits>=max(1,limit) { result.truncated=true;break }
        }
        try Task.checkCancellation()
        return result
    }
    private static func searchFile(_ url:URL,folder:URL,query:String,index:FolderSearchIndex?,limit:Int,cache:inout [String:String],terms:FolderSearchTerms,event:@escaping @Sendable (Event)->Void) throws -> FolderSearchFile {
        event(.reading(url.lastPathComponent))
        let data=try Data(contentsOf:url),digest=OCRPageCache.digest(data)
        let indexDigest=digest+"|"+ProcessInfo.processInfo.operatingSystemVersionString
        try Task.checkCancellation()
        var file=FolderSearchFile(url:url)
        func append(_ page:FolderSearchPage,cache:inout [String:String],file:inout FolderSearchFile) throws {
            try Task.checkCancellation()
            file.pages+=1
            if !page.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { file.textPages+=1 }
            guard terms.accepts(page.text,cache:&cache) else { return }
            file.hits += matches(page,query:query,limit:max(0,limit-file.hits.count),cache:&cache).map {
                FolderSearchHit(url:url,relativePath:relativePath(url,in:folder),fingerprint:digest,query:query,hit:$0)
            }
        }
        do {
            if try index?.read(path:url.path,digest:indexDigest,visit:{
                try append($0,cache:&cache,file:&file)
                if $0.index%5==0 { event(.page(url.lastPathComponent,$0.index+1,0)) }
            })==true { file.cached=true;return file }
        } catch is CancellationError { throw CancellationError() }
        catch { file=FolderSearchFile(url:url,warning:"页缓存无效，已重新读取原件") }
        guard let document=PDFDocument(data:data) else { throw FolioError(message:"PDF 已损坏或无法读取") }
        guard !document.isLocked else { throw FolioError(message:"PDF 需要密码；请先解锁并保存副本") }
        guard document.pageCount>0 else { throw FolioError(message:"PDF 没有页面") }
        var writing=false
        if let index {
            do { try index.begin(path:url.path,digest:indexDigest,pages:document.pageCount);writing=true }
            catch { index.rollback();file.warning="索引写入失败，本次仍可搜索："+error.localizedDescription }
        }
        defer { if writing { index?.rollback() } }
        for position in 0..<document.pageCount {
            try Task.checkCancellation()
            try autoreleasepool {
                let page=try document.page(at:position).unwrap("无法读取第 \(position+1) 页")
                let value=indexedPage(page,index:position)
                try append(value,cache:&cache,file:&file)
                if writing {
                    do { try index?.write(value,path:url.path) }
                    catch { index?.rollback();writing=false;file.warning="索引写入失败，本次仍可搜索："+error.localizedDescription }
                }
            }
            if position%5==0 || position+1==document.pageCount { event(.page(url.lastPathComponent,position+1,document.pageCount)) }
        }
        try Task.checkCancellation()
        if writing {
            do { try index?.commit(path:url.path,textPages:file.textPages);writing=false }
            catch { index?.rollback();writing=false;file.warning="索引保存失败，本次仍可搜索："+error.localizedDescription }
        }
        return file
    }
    /// A hit belongs to the searched snapshot; changed/deleted files must be searched again before navigation.
    static func verify(_ result:FolderSearchHit) throws -> Verified {
        try Task.checkCancellation()
        let data=try Data(contentsOf:result.url)
        guard OCRPageCache.digest(data)==result.fingerprint else { throw FolioError(message:"文件在搜索后已变化，请重新搜索后打开") }
        guard let document=PDFDocument(data:data) else { throw FolioError(message:"命中页面已无法读取") }
        return Verified(data:data,source:try source(result,in:document))
    }
    /// A file is read, hashed and parsed once even when hundreds of its matches are selected.
    static func verifiedExcerpts(_ results:[FolderSearchHit]) throws -> [(String,SourceRef)] {
        var references:[UUID:SourceRef]=[:]
        for (_,values) in Dictionary(grouping:results,by:{ $0.url.standardizedFileURL.path }) {
            try Task.checkCancellation()
            guard let first=values.first else { continue }
            let data=try Data(contentsOf:first.url),fingerprint=OCRPageCache.digest(data)
            guard values.allSatisfy({ $0.fingerprint==fingerprint }) else { throw FolioError(message:"文件在搜索后已变化，请重新搜索后摘录") }
            guard let document=PDFDocument(data:data) else { throw FolioError(message:"无法读取来源 PDF") }
            for value in values { try Task.checkCancellation();references[value.id]=try source(value,in:document) }
        }
        return try results.map { value in
            var reference=try references[value.id].unwrap("无法定位摘录来源")
            reference.anchor=value.query
            return (value.hit.snippet,reference)
        }
    }
    private static func source(_ result:FolderSearchHit,in document:PDFDocument) throws -> SourceRef {
        guard let page=document.page(at:result.hit.page) else { throw FolioError(message:"命中页面已无法读取") }
        var rects:[CGRect]
        if let strips=result.hit.strips {
            rects=strips.map { OrderedText.pageRect(forFraction:$0,cropBox:page.bounds(for:.cropBox),rotation:page.rotation) }
        } else {
            guard let selection=page.selection(for:result.hit.range) else { throw FolioError(message:"无法定位这处文字，请重新搜索") }
            rects=selection.selectionsByLine().map { $0.bounds(for:page) }
        }
        rects=rects.filter { !$0.isEmpty && !$0.isInfinite && !$0.isNull }
        try Task.checkCancellation()
        return SourceRef(path:result.url.path,fileName:result.url.lastPathComponent,page:result.hit.page,pageLabel:result.hit.label,rects:rects)
    }
}
