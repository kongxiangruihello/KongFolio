import Foundation

struct AcademicMarkup {
    var text: String
    var footnotes: [String: String]
    var endnotes: [String: String]
    var warnings: [String]
    static func parse(_ source: String) throws -> Self {
        var text: [String] = [], footnotes: [String: String] = [:], endnotes: [String: String] = [:]
        let definition = try NSRegularExpression(pattern: #"^\[([\^~])([A-Za-z0-9_-]+)\]:\s*(.*)$"#)
        for line in source.components(separatedBy: "\n") {
            let value = line as NSString
            if let hit = definition.firstMatch(in: line, range: NSRange(location: 0, length: value.length)) {
                let type = value.substring(with: hit.range(at: 1)), id = value.substring(with: hit.range(at: 2)), body = value.substring(with: hit.range(at: 3))
                if type == "^" { guard footnotes[id] == nil else { throw FolioError(message: "脚注编号重复：" + id) }; footnotes[id] = body }
                else { guard endnotes[id] == nil else { throw FolioError(message: "尾注编号重复：" + id) }; endnotes[id] = body }
            } else { text.append(line) }
        }
        let body = text.joined(separator: "\n"), refs = try NSRegularExpression(pattern: #"\[([\^~])([A-Za-z0-9_-]+)\]"#), ns = body as NSString
        for hit in refs.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            let type = ns.substring(with: hit.range(at: 1)), id = ns.substring(with: hit.range(at: 2))
            guard (type == "^" ? footnotes[id] : endnotes[id]) != nil else { throw FolioError(message: "缺少注释定义：" + id) }
        }
        let warnings = source.components(separatedBy: "\n").enumerated().compactMap { index,line -> String? in
            line.contains("□") || line.contains("�") || line.contains("[待核]") ? "第 \(index+1) 行有待核文字" : nil
        }
        return Self(text: body, footnotes: footnotes, endnotes: endnotes, warnings: warnings)
    }
    func runs(_ value: String) -> String {
        let regex = try! NSRegularExpression(pattern: #"\[([\^~])([A-Za-z0-9_-]+)\]"#), ns = value as NSString
        var result = "", position = 0
        for hit in regex.matches(in: value, range: NSRange(location: 0, length: ns.length)) {
            result += "<w:r><w:t xml:space=\"preserve\">" + WordExport.escape(ns.substring(with: NSRange(location: position,length:hit.range.location-position))) + "</w:t></w:r>"
            let type = ns.substring(with: hit.range(at: 1)), key = ns.substring(with: hit.range(at: 2)), keys = (type == "^" ? footnotes : endnotes).keys.sorted()
            if let index = keys.firstIndex(of: key) { result += "<w:r><w:rPr><w:vertAlign w:val=\"superscript\"/></w:rPr><w:\(type == "^" ? "footnoteReference" : "endnoteReference") w:id=\"\(index+1)\"/></w:r>" }
            position = NSMaxRange(hit.range)
        }
        result += "<w:r><w:t xml:space=\"preserve\">" + WordExport.escape(ns.substring(from: position)) + "</w:t></w:r>"
        return result
    }
    func notesXML(end: Bool) -> String {
        let name = end ? "endnote" : "footnote", values = end ? endnotes : footnotes
        let notes = values.keys.sorted().enumerated().map { index,key in
            "<w:\(name) w:id=\"\(index+1)\"><w:p><w:pPr><w:pStyle w:val=\"\(end ? "EndnoteText" : "FootnoteText")\"/></w:pPr><w:r><w:rPr><w:vertAlign w:val=\"superscript\"/></w:rPr><w:\(name)Ref/></w:r><w:r><w:t xml:space=\"preserve\"> " + WordExport.escape(values[key]!) + "</w:t></w:r></w:p></w:\(name)>"
        }.joined()
        return WordExport.header + "<w:\(name)s xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:\(name) w:type=\"separator\" w:id=\"-1\"><w:p><w:r><w:separator/></w:r></w:p></w:\(name)><w:\(name) w:type=\"continuationSeparator\" w:id=\"0\"><w:p><w:r><w:continuationSeparator/></w:r></w:p></w:\(name)>" + notes + "</w:\(name)s>"
    }
}
