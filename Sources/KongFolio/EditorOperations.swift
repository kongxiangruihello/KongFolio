import Foundation

/// All ranges are UTF-16 offsets into the captured source. Callers reject a changed source before applying.
struct EditorBlock: Identifiable, Equatable {
    var id:Int { range.location }; var range:NSRange; var title:String
}
enum EditorBlocks {
    static func blocks(_ text:String, sections:Bool) -> [EditorBlock] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        var lines:[(NSRange,String)] = [], p = 0
        while p < ns.length { let r = ns.lineRange(for:NSRange(location:p,length:0));lines.append((r,ns.substring(with:r)));p = NSMaxRange(r) }
        if sections {
            var fence:String?;var starts:[(Int,String)] = []
            for (r,line) in lines {
                let s = line.trimmingCharacters(in:.whitespacesAndNewlines)
                if s.hasPrefix("```") || s.hasPrefix("~~~") { let mark = String(s.prefix(3));if fence == mark { fence = nil } else if fence == nil { fence = mark };continue }
                if fence == nil,s.range(of:#"^#{1,6}\s+"#,options:.regularExpression) != nil { starts.append((r.location,s)) }
            }
            if !starts.isEmpty {
                let minimum = starts.map { $0.1.prefix(while:{$0 == "#"}).count }.min() ?? 1
                starts = starts.filter { $0.1.prefix(while:{$0 == "#"}).count == minimum }
                if starts[0].0 > 0 { starts.insert((0,"开篇"),at:0) }
                return starts.enumerated().map { i,v in EditorBlock(range:NSRange(location:v.0,length:(i+1 < starts.count ? starts[i+1].0 : ns.length)-v.0),title:v.1) }
            }
        }
        var result:[EditorBlock] = [];var start:Int?
        for (r,line) in lines {
            if line.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                if let s = start { let end = NSMaxRange(r);result.append(EditorBlock(range:NSRange(location:s,length:end-s),title:String(ns.substring(with:NSRange(location:s,length:r.location-s)).prefix(70))));start = nil }
            } else if start == nil { start = r.location }
        }
        if let s = start { result.append(EditorBlock(range:NSRange(location:s,length:ns.length-s),title:String(ns.substring(from:s).prefix(70)))) }
        return result
    }
    static func edit(_ source:String, blocks:[EditorBlock], index:Int, action:String) -> TextEdit? {
        guard blocks.indices.contains(index) else { return nil };let ns = source as NSString,b = blocks[index]
        guard NSMaxRange(b.range) <= ns.length else { return nil }
        let content = ns.substring(with:b.range)
        switch action {
        case "delete": return TextEdit(range:b.range,replacement:"",selection:NSRange(location:b.range.location,length:0))
        case "copy":
            let separator = content.hasSuffix("\n") ? "" : "\n\n", value = separator+content
            return TextEdit(range:NSRange(location:NSMaxRange(b.range),length:0),replacement:value,selection:NSRange(location:NSMaxRange(b.range)+separator.utf16.count,length:content.utf16.count))
        default:
            let j = action == "up" ? index-1 : index+1;guard blocks.indices.contains(j) else { return nil }
            let first = blocks[min(index,j)].range,last = blocks[max(index,j)].range
            let earlier = ns.substring(with:first),later = ns.substring(with:last)
            let middle = ns.substring(with:NSRange(location:NSMaxRange(first),length:last.location-NSMaxRange(first)))
            let separator = later.hasSuffix("\n") || earlier.isEmpty ? "" : "\n\n"
            let replacement = later+separator+middle+earlier
            return TextEdit(range:NSRange(location:first.location,length:NSMaxRange(last)-first.location),replacement:replacement,selection:NSRange(location:index < j ? first.location+later.utf16.count+separator.utf16.count+middle.utf16.count : first.location,length:content.utf16.count))
        }
    }
}
struct EditorMatch: Identifiable { var id:Int { range.location };var range:NSRange;var context:String }
struct EditorReplacePlan {
    let source:String;let scope:NSRange;let matches:[EditorMatch]
    init(source:String,query:String,scope:NSRange? = nil) throws {
        self.source = source;let ns = source as NSString;self.scope = MarkdownNote.clamp(scope ?? NSRange(location:0,length:ns.length),to:ns.length)
        guard !query.isEmpty else { matches = [];return }
        let regex = try NSRegularExpression(pattern:NSRegularExpression.escapedPattern(for:query),options:.caseInsensitive)
        matches = regex.matches(in:source,range:self.scope).map { hit in
            let r = NSRange(location:max(0,hit.range.location-20),length:min(ns.length,NSMaxRange(hit.range)+30)-max(0,hit.range.location-20))
            return EditorMatch(range:hit.range,context:ns.substring(with:r).replacingOccurrences(of:"\n",with:" ↵ "))
        }
    }
    func edit(selected:Set<Int>,replacement:String) -> TextEdit? {
        let hits = matches.filter { selected.contains($0.id) };guard !hits.isEmpty else { return nil }
        let result = NSMutableString(string:(source as NSString).substring(with:scope))
        for hit in hits.reversed() { result.replaceCharacters(in:NSRange(location:hit.range.location-scope.location,length:hit.range.length),with:replacement) }
        return TextEdit(range:scope,replacement:result as String,selection:NSRange(location:scope.location,length:result.length))
    }
}
struct EditorDiffHunk: Identifiable, Equatable {
    var id:Int;var previous:NSRange;var current:NSRange;var before:String;var after:String
}
enum EditorDiff {
    private static func lines(_ text:String) -> [(String,NSRange)] {
        let ns = text as NSString;var result:[(String,NSRange)] = [];var p = 0
        while p < ns.length { let r = ns.lineRange(for:NSRange(location:p,length:0));result.append((ns.substring(with:r),r));p = NSMaxRange(r) };return result
    }
    static func hunks(old:String,new:String) -> [EditorDiffHunk] {
        guard old != new else { return [] }
        let a = lines(old), b = lines(new)
        // Bound worst-case difference work on unrelated long manuscripts; retain a safe coarse hunk.
        if a.count+b.count > 6000 || a.count*b.count > 4_000_000 { return [EditorDiffHunk(id:0,previous:NSRange(location:0,length:old.utf16.count),current:NSRange(location:0,length:new.utf16.count),before:old,after:new)] }
        let changes = b.map(\.0).difference(from:a.map(\.0));var removed = Set<Int>(),inserted = Set<Int>()
        for change in changes { switch change { case .remove(let i,_,_):removed.insert(i);case .insert(let i,_,_):inserted.insert(i) } }
        var i = 0,j = 0,result:[EditorDiffHunk] = []
        func offset(_ values:[(String,NSRange)],_ index:Int,_ total:Int)->Int { index < values.count ? values[index].1.location : total }
        while i < a.count || j < b.count {
            if i < a.count,j < b.count,!removed.contains(i),!inserted.contains(j) { i+=1;j+=1;continue }
            let startA = i,startB = j
            while i < a.count,removed.contains(i) { i+=1 }
            while j < b.count,inserted.contains(j) { j+=1 }
            if startA == i && startB == j { break }
            let ar = NSRange(location:offset(a,startA,old.utf16.count),length:offset(a,i,old.utf16.count)-offset(a,startA,old.utf16.count))
            let br = NSRange(location:offset(b,startB,new.utf16.count),length:offset(b,j,new.utf16.count)-offset(b,startB,new.utf16.count))
            result.append(EditorDiffHunk(id:result.count,previous:ar,current:br,before:(old as NSString).substring(with:ar),after:(new as NSString).substring(with:br)))
        }
        return result
    }
    static func restore(_ hunk:EditorDiffHunk) -> TextEdit { TextEdit(range:hunk.current,replacement:hunk.before,selection:NSRange(location:hunk.current.location,length:hunk.before.utf16.count)) }
}
struct EditorMergePart: Identifiable {
    var id:Int;var range:NSRange;var base:String;var local:String;var external:String
    var conflict:Bool { local != base && external != base && local != external }
    var automatic:String { local == base ? external : local }
}
struct EditorMergePlan {
    let base:String;let local:String;let external:String;let parts:[EditorMergePart]
    init(base:String,local:String,external:String) {
        self.base = base;self.local = local;self.external = external
        let a = EditorDiff.hunks(old:base,new:local),b = EditorDiff.hunks(old:base,new:external)
        let all = (a+b).sorted { $0.previous.location < $1.previous.location }
        var regions:[NSRange] = []
        for h in all {
            if let last = regions.last,(h.previous.location < NSMaxRange(last) || (h.previous.length == 0 && h.previous.location == NSMaxRange(last)) || (last.length == 0 && h.previous.location == last.location)) { regions[regions.count-1] = NSUnionRange(last,h.previous) }
            else { regions.append(h.previous) }
        }
        func transformed(_ r:NSRange,_ hunks:[EditorDiffHunk])->String {
            let value = NSMutableString(string:(base as NSString).substring(with:r))
            for h in hunks.reversed() where h.previous.location >= r.location && NSMaxRange(h.previous) <= NSMaxRange(r) {
                value.replaceCharacters(in:NSRange(location:h.previous.location-r.location,length:h.previous.length),with:h.after)
            };return value as String
        }
        parts = regions.enumerated().map { i,r in EditorMergePart(id:i,range:r,base:(base as NSString).substring(with:r),local:transformed(r,a),external:transformed(r,b)) }
    }
    func result(choices:[Int:Bool]) throws -> String {
        guard parts.filter(\.conflict).allSatisfy({choices[$0.id] != nil}) else { throw FolioError(message:"请逐项选择采用我的修改或外部修改") }
        let value = NSMutableString(string:base)
        for part in parts.reversed() { value.replaceCharacters(in:part.range,with:part.conflict ? (choices[part.id] == true ? part.local : part.external) : part.automatic) };return value as String
    }
}

/// Explicit jumps honor the selected phrase; automatic following uses the whole paragraph.
enum EditorNavigation {
    static func scope(_ source:String,selection:NSRange,explicit:Bool)->NSRange {
        let ns = source as NSString,selected = MarkdownNote.clamp(selection,to:ns.length)
        return explicit && selected.length > 0 ? selected : ns.paragraphRange(for:selected)
    }
}
