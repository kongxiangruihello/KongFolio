import AppKit
import Foundation

struct EditorTable {
    var source:String;var range:NSRange;var rows:[[String]]
    static func capture(_ source:String,selection:NSRange,format:TextDocumentFormat) throws -> Self {
        let ns = source as NSString,caret = min(selection.location,ns.length)
        if format == .html {
            let regex = try NSRegularExpression(pattern:#"(?is)<table\b[^>]*>.*?</table>"#)
            if let hit = regex.matches(in:source,range:NSRange(location:0,length:ns.length)).first(where:{NSLocationInRange(caret,$0.range)}) {
                let html = ns.substring(with:hit.range)
                guard html.range(of:#"(?i)\b(rowspan|colspan)\s*="# ,options:.regularExpression) == nil else { throw FolioError(message:"这个表格含合并单元格，请在源码中编辑，避免丢失结构") }
                let tr = try NSRegularExpression(pattern:#"(?is)<tr\b[^>]*>(.*?)</tr>"#),td = try NSRegularExpression(pattern:#"(?is)<t[dh]\b[^>]*>(.*?)</t[dh]>"#),hs = html as NSString
                let rows = tr.matches(in:html,range:NSRange(location:0,length:hs.length)).map { row -> [String] in
                    let s = hs.substring(with:row.range(at:1)),n = s as NSString
                    return td.matches(in:s,range:NSRange(location:0,length:n.length)).map { TextTableEntities.decode(n.substring(with:$0.range(at:1)).replacingOccurrences(of:#"(?is)<[^>]+>"#,with:"",options:.regularExpression)) }
                }
                guard !rows.isEmpty,rows.count <= 200,(rows.map(\.count).max() ?? 0) <= 30 else { throw FolioError(message:"表格过大或结构不支持；可分拆后编辑") }
                return Self(source:source,range:hit.range,rows:rectangular(rows))
            }
        } else if format == .markdown {
            var lines:[NSRange] = [],p = 0
            while p < ns.length { let r = ns.lineRange(for:NSRange(location:p,length:0));lines.append(r);p = NSMaxRange(r) }
            if let index = lines.firstIndex(where:{NSLocationInRange(caret,$0) || caret == ns.length && NSMaxRange($0) == caret}),ns.substring(with:lines[index]).contains("|") {
                var lo = index,hi = index
                while lo > 0,ns.substring(with:lines[lo-1]).contains("|") { lo-=1 }
                while hi+1 < lines.count,ns.substring(with:lines[hi+1]).contains("|") { hi+=1 }
                let r = NSUnionRange(lines[lo],lines[hi]),raw = ns.substring(with:r).components(separatedBy:"\n").filter{!$0.isEmpty}
                if raw.count >= 2, raw[1].range(of:#"^[\s|:\-]+$"#,options:.regularExpression) != nil {
                    let rows = raw.enumerated().filter{$0.offset != 1}.map{RichTextDocument.tableCells($0.element)}
                    guard rows.count <= 200,(rows.map(\.count).max() ?? 0) <= 30 else { throw FolioError(message:"表格过大，请分拆后编辑") }
                    return Self(source:source,range:r,rows:rectangular(rows))
                }
            }
        }
        return Self(source:source,range:MarkdownNote.clamp(selection,to:ns.length),rows:[["列 1","列 2"],["",""]])
    }
    static func rectangular(_ input:[[String]]) -> [[String]] { let width = max(1,input.map(\.count).max() ?? 1);return input.map{$0+Array(repeating:"",count:width-$0.count)} }
    mutating func pasteTSV(_ value:String) throws {
        var rows = value.replacingOccurrences(of:"\r\n",with:"\n").components(separatedBy:"\n");if rows.last == "" { rows.removeLast() }
        let cells = rows.map{$0.components(separatedBy:"\t")}
        guard !cells.isEmpty,cells.count <= 200,(cells.map(\.count).max() ?? 0) <= 30 else { throw FolioError(message:"每次最多导入 200 行、30 列") };self.rows = Self.rectangular(cells)
    }
    func edit(format:TextDocumentFormat) -> TextEdit {
        let value:String
        if format == .html {
            var output = "<table>\n"
            for (index,row) in rows.enumerated() {
                let tag:String = index == 0 ? "th" : "td"
                output += "<tr>"
                for cell in row { output += "<"+tag+">"+TextTableEntities.escape(cell)+"</"+tag+">" }
                output += "</tr>\n"
            }
            output += "</table>\n"
            value = output
        }
        else {
            var lines = rows.map { "| "+$0.map{$0.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"|",with:"\\|").replacingOccurrences(of:"\n",with:" ")}.joined(separator:" | ")+" |" }
            lines.insert("| "+Array(repeating:"---",count:rows.first?.count ?? 1).joined(separator:" | ")+" |",at:min(1,lines.count));value = lines.joined(separator:"\n")+"\n"
        }
        let prefix = range.location > 0 && !(source as NSString).substring(to:range.location).hasSuffix("\n") ? "\n" : ""
        return TextEdit(range:range,replacement:prefix+value,selection:NSRange(location:range.location+prefix.utf16.count,length:value.utf16.count))
    }
}
enum TextTableEntities {
    static func escape(_ value:String)->String { value.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;") }
    static func decode(_ value:String)->String { value.replacingOccurrences(of:"&lt;",with:"<").replacingOccurrences(of:"&gt;",with:">").replacingOccurrences(of:"&quot;",with:"\"").replacingOccurrences(of:"&nbsp;",with:" ").replacingOccurrences(of:"&amp;",with:"&") }
}
struct EditorFootnote: Identifiable {
    var id:String;var body:String;var definition:NSRange;var references:[NSRange]
}
enum EditorFootnotes {
    static func list(_ text:String) -> [EditorFootnote] {
        let ns = text as NSString,definition = try! NSRegularExpression(pattern:#"(?m)^\[\^([A-Za-z0-9_-]+)\]:[ \t]*([^\n]*)"#)
        let notes = definition.matches(in:text,range:NSRange(location:0,length:ns.length)).map { hit in
            let id = ns.substring(with:hit.range(at:1)),regex = try! NSRegularExpression(pattern:NSRegularExpression.escapedPattern(for:"[^"+id+"]")+"(?!:)")
            return EditorFootnote(id:id,body:ns.substring(with:hit.range(at:2)),definition:hit.range,references:regex.matches(in:text,range:NSRange(location:0,length:ns.length)).map(\.range))
        }
        return notes.sorted { ($0.references.first?.location ?? Int.max,$0.id) < ($1.references.first?.location ?? Int.max,$1.id) }
    }
    static func insertion(_ source:String,selection:NSRange,body:String) throws -> TextEdit {
        guard !body.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw FolioError(message:"请填写注释正文") }
        let ids = Set(list(source).map(\.id));var number = 1;while ids.contains(String(format:"note%06d",number)) { number+=1 }
        let id = String(format:"note%06d",number),ns = source as NSString,p = NSMaxRange(MarkdownNote.clamp(selection,to:ns.length))
        let result = NSMutableString(string:source);result.insert("[^\(id)]",at:p);result.append("\n\n[^\(id)]: "+body.replacingOccurrences(of:"\n",with:" ")+"\n")
        return TextEdit(range:NSRange(location:0,length:ns.length),replacement:result as String,selection:NSRange(location:p,length:id.utf16.count+3))
    }
    static func rendered(_ source:String) throws -> String {
        let academic = try AcademicMarkup.parse(source);var body = academic.text
        let order = academic.orderedKeys()
        for (i,id) in order.enumerated() { body = body.replacingOccurrences(of:"[^\(id)]",with:"[\(i+1)]") }
        if !order.isEmpty { body += "\n\n## 注释\n"+order.enumerated().map{"[\($0.offset+1)] "+(academic.footnotes[$0.element] ?? "")}.joined(separator:"\n\n") }
        return body
    }
}
struct EditorCorrection: Codable, Identifiable {
    var id:String = UUID().uuidString;var original:String;var replacement:String;var kind:String;var reason:String
    var marker:String { "<!--kongfolio-correction:"+((try? JSONEncoder().encode(self)) ?? Data()).base64EncodedString()+"-->" }
}
enum EditorCorrections {
    static let pattern = #"<!--kongfolio-correction:([A-Za-z0-9+/=]+)-->"#
    static func list(_ text:String)->[EditorCorrection] {
        let ns = text as NSString,regex = try! NSRegularExpression(pattern:pattern)
        return regex.matches(in:text,range:NSRange(location:0,length:ns.length)).compactMap { hit in guard let data = Data(base64Encoded:ns.substring(with:hit.range(at:1))) else { return nil };return try? JSONDecoder().decode(EditorCorrection.self,from:data) }
    }
    static func export(_ text:String,include:Bool,html:Bool = false)->String {
        let regex = try! NSRegularExpression(pattern:pattern),clean = regex.stringByReplacingMatches(in:text,range:NSRange(location:0,length:text.utf16.count),withTemplate:"")
        guard include else { return clean };let notes = list(text);guard !notes.isEmpty else { return clean }
        let lines = notes.enumerated().map { i,n in "\(i+1). 【\(n.kind)】\(n.original.isEmpty ? "∅" : n.original) → \(n.replacement)；理由：\(n.reason)" }
        return clean+(html ? "<h2>校勘记</h2>"+lines.map{"<p>"+TextTableEntities.escape($0)+"</p>"}.joined() : "\n\n## 校勘记\n\n"+lines.joined(separator:"\n\n"))
    }
}
enum EditorEncoding:String,CaseIterable,Identifiable {
    case utf8 = "UTF-8",utf16 = "UTF-16",utf16LE = "UTF-16 LE",utf16BE = "UTF-16 BE",gb = "GB18030",big5 = "Big5"
    var id:String { rawValue }
    var encoding:String.Encoding { switch self { case .utf8:return .utf8;case .utf16:return .utf16;case .utf16LE:return .utf16LittleEndian;case .utf16BE:return .utf16BigEndian;case .gb:return TextImport.gb18030;case .big5:return TextImport.big5 } }
    func decode(_ data:Data) throws -> String { guard let s = String(data:data,encoding:encoding) else { throw FolioError(message:"这些字节无法按 \(rawValue) 解码，请选择其他编码") };return s }
}
struct EditorCharacter:Identifiable { var id:Int { range.location };var range:NSRange;var name:String;var unicode:String }
enum EditorCharacters {
    static func inspect(_ source:String,all:Bool = false)->[EditorCharacter] {
        var result:[EditorCharacter] = [],p = 0
        for s in source.unicodeScalars {
            let n = String(s).utf16.count;defer { p+=n }
            let name:String?
            switch s.value { case 9:name = "制表符 ⇥";case 10:name = "换行 ↵";case 13:name = "回车";case 32:name = all ? "空格 ·" : nil;case 0xA0:name = "不换行空格";case 0x200B:name = "零宽空格";case 0xFEFF:name = "字节序标记 / 零宽空格";case 0xFFFD:name = "无法识别的替代字符";case 0x202A...0x202E,0x2066...0x2069:name = "文字方向控制符";default:name = CharacterSet.controlCharacters.contains(s) ? "控制字符" : nil }
            if let name { result.append(EditorCharacter(range:NSRange(location:p,length:n),name:name,unicode:String(format:"U+%04X",s.value))) }
            if result.count >= 1000 { break }
        };return result
    }
}
