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
        guard joinLines || dehyphenate || compactSpaces else { return source }
        var value = source.replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\r",with:"\n")
        if dehyphenate { value = value.replacingOccurrences(of:#"([A-Za-z])[-‐]\n([A-Za-z])"#,with:"$1$2",options:.regularExpression) }
        if compactSpaces { value = value.components(separatedBy:"\n").map { $0.replacingOccurrences(of:#"[ \t]+"#,with:" ",options:.regularExpression).trimmingCharacters(in:.whitespaces) }.joined(separator:"\n") }
        if joinLines {
            let lines = value.components(separatedBy:"\n")
            var result = ""
            for (index, raw) in lines.enumerated() {
                let line = raw.trimmingCharacters(in:.whitespaces)
                if index > 0 {
                    if line.isEmpty || lines[index-1].trimmingCharacters(in:.whitespaces).isEmpty {
                        result += "\n"
                    } else if let last = result.last, let first = line.first,
                              last.isASCII && first.isASCII && last.isLetter && first.isLetter {
                        result += " "
                    }
                }
                result += line.isEmpty ? raw : line
            }
            value = result
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
        let contentStart = line.location + NSMaxRange(match.range)
        let content = ns.substring(with:NSRange(location:contentStart,length:NSMaxRange(line)-contentStart))
        if content.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, NSMaxRange(r) <= NSMaxRange(line) {
            return TextEdit(range:NSRange(location:line.location,length:NSMaxRange(r)-line.location),replacement:"",selection:NSRange(location:line.location,length:0))
        }
        let indent = (before as NSString).substring(with:match.range(at:1))
        let marker = (before as NSString).substring(with:match.range(at:2))
        let number = Int(marker.dropLast())
        let next = number.flatMap { $0 < Int.max ? String($0+1)+marker.suffix(1) : nil } ?? marker
        let checkbox = match.range(at:3).location == NSNotFound ? "" : "[ ] "
        let newline = "\n"+indent+next+" "+checkbox
        let caret = NSRange(location:r.location+newline.utf16.count,length:0)
        guard var expected = number, expected < Int.max-1, NSMaxRange(r) <= NSMaxRange(line) else {
            return TextEdit(range:r,replacement:newline,selection:caret)
        }
        expected += 1
        let buffer = NSMutableString(string:"")
        var end = NSMaxRange(r)
        var position = NSMaxRange(line)
        while position < ns.length {
            let nextLine = ns.lineRange(for:NSRange(location:position,length:0))
            let value = ns.substring(with:nextLine)
            if value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { break }
            let leading = String(value.prefix { $0 == " " || $0 == "\t" })
            if leading == indent {
                guard expected < Int.max,
                      let match = regex.firstMatch(in:value,range:NSRange(location:0,length:value.utf16.count)),
                      match.range(at:1).length == indent.utf16.count else { break }
                let token = (value as NSString).substring(with:match.range(at:2))
                guard Int(token.dropLast()) != nil, token.last == marker.last else { break }
                expected += 1
                let tokenStart = nextLine.location + match.range(at:2).location
                buffer.append(ns.substring(with:NSRange(location:end,length:tokenStart-end)))
                buffer.append(String(expected)+marker.suffix(1))
                end = tokenStart+match.range(at:2).length
            } else if !leading.hasPrefix(indent) || leading.count <= indent.count { break }
            position = NSMaxRange(nextLine)
        }
        return TextEdit(range:NSRange(location:r.location,length:end-r.location),
                        replacement:newline+(buffer as String),selection:caret)
    }

    static func indent(_ text:String,selection:NSRange,outdent:Bool) -> TextEdit? {
        let ns = text as NSString,r = MarkdownNote.clamp(selection,to:ns.length)
        let scope = ns.lineRange(for:NSRange(location:r.location,length:max(0,r.length-(r.length>0 && ns.substring(with:NSRange(location:NSMaxRange(r)-1,length:1))=="\n" ? 1:0))))
        let block = ns.substring(with:scope),lines = block.components(separatedBy:"\n")
        guard lines.contains(where:{$0.range(of:#"^[ \t]*(?:[-+*]|[0-9]+[.)])[ \t]+"#,options:.regularExpression) != nil}) else { return nil }
        let changed = lines.enumerated().map { index,line in
            if index == lines.count-1 && line.isEmpty { return line }
            if outdent {
                if line.hasPrefix("\t") { return String(line.dropFirst()) }
                return String(line.dropFirst(line.prefix(2).prefix(while:{$0==" "}).count))
            }
            return "  "+line
        }
        let output = changed.joined(separator:"\n")
        let delta = (changed.first?.utf16.count ?? 0) - (lines.first?.utf16.count ?? 0)
        let result = r.length == 0 ? NSRange(location:max(scope.location,r.location+delta),length:0)
                                   : NSRange(location:scope.location,length:output.utf16.count)
        return TextEdit(range:scope,replacement:output,selection:result)
    }

    enum ParagraphAction: String, CaseIterable {
        case up = "上移段落", down = "下移段落", split = "从光标拆分段落", merge = "与下一段合并"
        var shortcut: String {
            switch self {
            case .up: "⌥⌘↑"
            case .down: "⌥⌘↓"
            case .split: "⌥⌘↩"
            case .merge: "⌥⌘J"
            }
        }
    }

    static func paragraph(_ action:ParagraphAction, text:String, selection:NSRange) -> TextEdit? {
        let ns = text as NSString
        let selection = MarkdownNote.clamp(selection,to:ns.length)
        if action == .split {
            return TextEdit(range:NSRange(location:selection.location,length:0),replacement:"\n\n",
                            selection:NSRange(location:selection.location+2,length:0))
        }
        let regex = try! NSRegularExpression(pattern:#"\r?\n(?:[ \t]*\r?\n)+"#)
        let separators = regex.matches(in:text,range:NSRange(location:0,length:ns.length)).map(\.range)
        let index = separators.firstIndex { $0.location >= selection.location } ?? separators.count
        let start = index == 0 ? 0 : NSMaxRange(separators[index-1])
        let end = index == separators.count ? ns.length : separators[index].location
        guard selection.location >= start, NSMaxRange(selection) <= end else { return nil }
        if action == .merge {
            guard index < separators.count else { return nil }
            return TextEdit(range:separators[index],replacement:" ",selection:selection)
        }
        let upper = action == .up ? index-1 : index
        guard separators.indices.contains(upper) else { return nil }
        let gap = separators[upper]
        let lowerStart = NSMaxRange(gap)
        let first = upper == 0 ? 0 : NSMaxRange(separators[upper-1])
        let last = upper+1 == separators.count ? ns.length : separators[upper+1].location
        let leading = ns.substring(with:NSRange(location:first,length:gap.location-first))
        let trailing = ns.substring(with:NSRange(location:lowerStart,length:last-lowerStart))
        let delta = action == .up ? first-lowerStart : trailing.utf16.count+gap.length
        return TextEdit(range:NSRange(location:first,length:last-first),
                        replacement:trailing+ns.substring(with:gap)+leading,
                        selection:NSRange(location:selection.location+delta,length:selection.length))
    }
}
@MainActor final class WritingSession:ObservableObject {
    weak var view:NSTextView?
    @Published var analysis = WritingAnalysis(characters:0,headings:[])
    @Published var message = ""
    @Published var findRequest = UUID()
    @Published var cleanupRequest = UUID()
    var cleanupFromClipboard = false
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
    var paragraphHandler: ((WritingEdit.ParagraphAction, NSRange) -> Bool)?

    func paragraph(_ action:WritingEdit.ParagraphAction) {
        guard let view, view.isEditable, !view.hasMarkedText() else { return }
        if paragraphHandler?(action, view.selectedRange()) == true { return }
        guard let edit = WritingEdit.paragraph(action,text:view.string,selection:view.selectedRange()) else { return }
        WritingEdit.apply(edit,to:view)
    }

    private var findOrigin: (selection:NSRange, scroll:CGPoint?, source:String)?
    @Published var searchSelectionOnly = false
    var canSearchSelection: Bool { (findOrigin?.selection.length ?? 0) > 0 }
    var capturedFindSelection: NSRange? { findOrigin?.selection }

    func beginFind() {
        guard findOrigin == nil, let view, !view.hasMarkedText() else { return }
        findOrigin = (view.selectedRange(),view.enclosingScrollView?.contentView.bounds.origin,view.string)
        searchSelectionOnly = false
    }

    func endFind() {
        defer { findOrigin = nil; searchSelectionOnly = false; message = "" }
        guard let view, !view.hasMarkedText() else { return }
        view.window?.makeFirstResponder(view)
        guard let origin = findOrigin, origin.source == view.string else { return }
        view.setSelectedRange(origin.selection)
        if let point = origin.scroll, let scroll = view.enclosingScrollView {
            scroll.contentView.scroll(to:point)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    func replacePlan(_ query:String) -> EditorReplacePlan? {
        guard let view else { return nil }
        let scope = searchSelectionOnly && findOrigin?.source == view.string ? findOrigin?.selection : nil
        if searchSelectionOnly && scope == nil { return nil }
        return try? EditorReplacePlan(source:view.string,query:query,scope:scope)
    }

    func find(_ query:String,backward:Bool = false) {
        guard let view,!query.isEmpty,!view.hasMarkedText(), let plan = replacePlan(query) else { return }
        lastQuery = query
        let r = view.selectedRange()
        let hit = backward
            ? plan.matches.last(where:{NSMaxRange($0.range) <= r.location}) ?? plan.matches.last
            : plan.matches.first(where:{$0.range.location >= NSMaxRange(r)}) ?? plan.matches.first
        guard let hit else { message = "没有找到匹配文字";return }
        view.setSelectedRange(hit.range);view.scrollRangeToVisible(hit.range);message = "已定位匹配文字"
    }

    func replace(_ query:String,with value:String,all:Bool) {
        guard let view,!query.isEmpty,!view.hasMarkedText(), let plan = replacePlan(query) else { return }
        let selected = view.selectedRange()
        let hits = all ? plan.matches : plan.matches.filter { $0.range == selected }
        guard let edit = plan.edit(selected:Set(hits.map(\.id)),replacement:value) else {
            find(query)
            return
        }
        applyReplacement(edit,hits:hits,replacement:value)
        if all { message = "已替换 \(hits.count) 处，可一次撤销" } else { find(query) }
    }

    func applyReplacement(_ edit:TextEdit,hits:[EditorMatch],replacement:String) {
        guard let view, view.isEditable, !view.hasMarkedText() else { return }
        func map(_ point:Int) -> Int {
            var shift = 0
            for hit in hits {
                if point <= hit.range.location { break }
                if point < NSMaxRange(hit.range) { return hit.range.location+shift+replacement.utf16.count }
                shift += replacement.utf16.count-hit.range.length
            }
            return point+shift
        }
        func mapped(_ range:NSRange) -> NSRange {
            let start = map(range.location)
            return NSRange(location:start,length:max(0,map(NSMaxRange(range))-start))
        }
        let origin = findOrigin?.source == view.string ? findOrigin : nil
        let selection = mapped(view.selectedRange())
        WritingEdit.apply(TextEdit(range:edit.range,replacement:edit.replacement,selection:selection),to:view)
        if let origin { findOrigin = (mapped(origin.selection),origin.scroll,view.string) }
    }
    func go(_ range:NSRange) { guard let view,!view.hasMarkedText() else { return };let r = MarkdownNote.clamp(range,to:view.string.utf16.count);view.setSelectedRange(r);view.scrollRangeToVisible(r);view.window?.makeFirstResponder(view) }
}
