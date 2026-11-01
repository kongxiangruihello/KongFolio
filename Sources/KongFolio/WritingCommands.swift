import AppKit
import Combine

struct WritingHeading:Identifiable { var id:Int { range.location }; var title:String; var level:Int; var range:NSRange }
struct WritingAnalysis { var characters:Int; var headings:[WritingHeading] }
actor WritingAnalysisWorker {
    static let shared = WritingAnalysisWorker()
    func analyze(_ text:String) -> WritingAnalysis {
        let ns = text as NSString, regex = try! NSRegularExpression(pattern:#"(?m)^(#{1,6})[ \t]+(.+)$"#)
        let headings = regex.matches(in:text,range:NSRange(location:0,length:ns.length)).map { WritingHeading(title:ns.substring(with:$0.range(at:2)),level:$0.range(at:1).length,range:$0.range) }
        return WritingAnalysis(characters:text.reduce(0){$0+($1.isWhitespace ? 0 : 1)},headings:headings)
    }
}
struct WritingCleanup:Equatable {
    var joinLines = false
    var dehyphenate = false
    var compactSpaces = false
    func apply(_ source:String) -> String {
        var value = source.replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\r",with:"\n")
        if dehyphenate { value = value.replacingOccurrences(of:#"([A-Za-z])[-‐]\n([A-Za-z])"#,with:"$1$2",options:.regularExpression) }
        if compactSpaces { value = value.components(separatedBy:"\n").map { $0.replacingOccurrences(of:#"[ \t]+"#,with:" ",options:.regularExpression).trimmingCharacters(in:.whitespaces) }.joined(separator:"\n") }
        if joinLines {
            value = value.components(separatedBy:"\n\n").map { paragraph in
                var result = ""
                for line in paragraph.components(separatedBy:"\n") {
                    let line = line.trimmingCharacters(in:.whitespaces)
                    if let last = result.last,let first = line.first, last.isASCII && first.isASCII && last.isLetter && first.isLetter { result += " " }
                    result += line
                }
                return result
            }.joined(separator:"\n\n")
        }
        return value
    }
}
enum WritingEdit {
    static func apply(_ edit:TextEdit,to view:NSTextView) {
        guard view.isEditable,!view.hasMarkedText(),NSMaxRange(edit.range)<=view.string.utf16.count else { return }
        view.breakUndoCoalescing(); view.undoManager?.beginUndoGrouping()
        view.insertText(edit.replacement,replacementRange:edit.range)
        view.setSelectedRange(MarkdownNote.clamp(edit.selection,to:view.string.utf16.count))
        view.undoManager?.endUndoGrouping();view.breakUndoCoalescing(); view.window?.makeFirstResponder(view)
    }
    static func newline(_ text:String,selection:NSRange) -> TextEdit? {
        let ns = text as NSString,r = MarkdownNote.clamp(selection,to:ns.length),line = ns.lineRange(for:NSRange(location:r.location,length:0))
        let before = ns.substring(with:NSRange(location:line.location,length:r.location-line.location))
        let regex = try! NSRegularExpression(pattern:#"^([ \t]*)([-+*]|[0-9]+[.)])[ \t]+(?:\[([ xX])\][ \t]+)?"#)
        guard let match = regex.firstMatch(in:before,range:NSRange(location:0,length:before.utf16.count)) else { return nil }
        let prefix = (before as NSString).substring(with:match.range),tail = String(before.dropFirst(prefix.count))
        if tail.trimmingCharacters(in:.whitespaces).isEmpty {
            return TextEdit(range:NSRange(location:line.location,length:NSMaxRange(r)-line.location),replacement:"",selection:NSRange(location:line.location,length:0))
        }
        let indent = (before as NSString).substring(with:match.range(at:1)), marker = (before as NSString).substring(with:match.range(at:2))
        var next = marker
        if let n = Int(marker.dropLast()),n<Int.max { next = String(n+1)+marker.suffix(1) }
        let checkbox = match.range(at:3).location == NSNotFound ? "" : "[ ] "
        let replacement = "\n"+indent+next+" "+checkbox
        return TextEdit(range:r,replacement:replacement,selection:NSRange(location:r.location+replacement.utf16.count,length:0))
    }
    static func indent(_ text:String,selection:NSRange,outdent:Bool) -> TextEdit? {
        let ns = text as NSString,r = MarkdownNote.clamp(selection,to:ns.length)
        let scope = ns.lineRange(for:NSRange(location:r.location,length:max(0,r.length-(r.length>0 && ns.substring(with:NSRange(location:NSMaxRange(r)-1,length:1))=="\n" ? 1:0))))
        let block = ns.substring(with:scope),lines = block.components(separatedBy:"\n")
        guard lines.contains(where:{$0.range(of:#"^[ \t]*(?:[-+*]|[0-9]+[.)])[ \t]+"#,options:.regularExpression) != nil}) else { return nil }
        var output = lines.enumerated().map { i,line in
            if i == lines.count-1 && line.isEmpty { return line }
            if outdent { if line.hasPrefix("\t") { return String(line.dropFirst()) };return String(line.dropFirst(line.prefix(2).prefix(while:{$0==" "}).count)) }
            return "  "+line
        }.joined(separator:"\n")
        if block.isEmpty { output = "" }
        return TextEdit(range:scope,replacement:output,selection:NSRange(location:scope.location,length:output.utf16.count))
    }
}
@MainActor final class WritingSession:ObservableObject {
    weak var view:NSTextView?
    @Published var analysis = WritingAnalysis(characters:0,headings:[])
    @Published var message = ""
    @Published var findRequest = UUID()
    @Published var cleanupRequest = UUID()
    private(set) var lastQuery = ""
    private var task:Task<Void,Never>?
    func analyze(_ text:String) {
        task?.cancel(); task = Task { [weak self] in
            do { try await Task.sleep(nanoseconds:350_000_000) } catch { return }
            let result = await WritingAnalysisWorker.shared.analyze(text)
            guard !Task.isCancelled else { return };self?.analysis = result
        }
    }
    func wrap(_ prefix:String,_ suffix:String,placeholder:String) { guard let view else { return };WritingEdit.apply(MarkdownNote.wrapEdit(in:view.string,selection:view.selectedRange(),prefix:prefix,suffix:suffix,placeholder:placeholder),to:view) }
    func prefix(_ prefix:String) { guard let view else { return };WritingEdit.apply(MarkdownNote.lineEdit(in:view.string,selection:view.selectedRange(),prefix:prefix),to:view) }
    func clearFormatting() {
        guard let view else { return };let ns = view.string as NSString,r = MarkdownNote.clamp(view.selectedRange(),to:ns.length);guard r.length>0 else { message = "先选择需要清除格式的文字";return }
        let value = ns.substring(with:r).replacingOccurrences(of:#"(?m)^\s{0,3}(?:#{1,6}\s+|>\s?)"#,with:"",options:.regularExpression).replacingOccurrences(of:#"(\*\*|__|`|\*)"#,with:"",options:.regularExpression)
        WritingEdit.apply(TextEdit(range:r,replacement:value,selection:NSRange(location:r.location,length:value.utf16.count)),to:view)
    }
    func find(_ query:String,backward:Bool = false) {
        guard let view,!query.isEmpty,!view.hasMarkedText() else { return }
        lastQuery = query
        let ns = view.string as NSString,r = view.selectedRange(),start = backward ? 0 : min(ns.length,NSMaxRange(r)),length = backward ? min(ns.length,r.location) : ns.length-start
        let options:NSString.CompareOptions = backward ? [.caseInsensitive,.backwards] : [.caseInsensitive]
        var hit = ns.range(of:query,options:options,range:NSRange(location:start,length:length))
        if hit.location == NSNotFound { hit = ns.range(of:query,options:options) }
        guard hit.location != NSNotFound else { message = "没有找到匹配文字";return }
        view.setSelectedRange(hit);view.scrollRangeToVisible(hit);message = "已定位匹配文字"
    }
    func replace(_ query:String,with value:String,all:Bool) {
        guard let view,!query.isEmpty,!view.hasMarkedText() else { return }
        let ns = view.string as NSString
        if all {
            let regex = try! NSRegularExpression(pattern:NSRegularExpression.escapedPattern(for:query),options:.caseInsensitive)
            let range = NSRange(location:0,length:ns.length),count = regex.numberOfMatches(in:view.string,range:range)
            guard count>0 else { message = "没有找到匹配文字";return }
            let replacement = view.string.replacingOccurrences(of:query,with:value,options:.caseInsensitive)
            WritingEdit.apply(TextEdit(range:range,replacement:replacement,selection:NSRange(location:0,length:0)),to:view);message = "已替换 \(count) 处，可一次撤销"
        } else {
            let r = MarkdownNote.clamp(view.selectedRange(),to:ns.length)
            guard ns.substring(with:r).caseInsensitiveCompare(query) == .orderedSame else { find(query);return }
            WritingEdit.apply(TextEdit(range:r,replacement:value,selection:NSRange(location:r.location,length:value.utf16.count)),to:view);find(query)
        }
    }
    func go(_ range:NSRange) { guard let view,!view.hasMarkedText() else { return };let r = MarkdownNote.clamp(range,to:view.string.utf16.count);view.setSelectedRange(r);view.scrollRangeToVisible(r);view.window?.makeFirstResponder(view) }
}
