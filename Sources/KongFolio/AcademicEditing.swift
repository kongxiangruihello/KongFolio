import Foundation

enum AcademicInsertion: String, CaseIterable, Identifiable {
    case footnote = "脚注", endnote = "尾注", caption = "题注", page = "分页与原页码", chapter = "章节标题"
    var id: String { rawValue }
    func appending(to source: String) -> String {
        switch self {
        case .footnote, .endnote:
            let marker = self == .footnote ? "^" : "~"
            var number = 1; while source.contains("["+marker+String(number)+"]") { number += 1 }
            let ref = "["+marker+String(number)+"]"
            return source + ref + "\n\n" + ref + ": 请填写注释内容\n"
        case .caption: return source + "\n\n:::caption 请填写题注\n"
        case .page: return source + "\n\n:::page 请填写原页码\n"
        case .chapter: return source + "\n\n# 请填写章节标题\n"
        }
    }
}

extension AcademicInsertion {
    func edit(_ source: String, selection: NSRange) -> TextEdit {
        let text = source as NSString
        let location = min(max(0,selection.location),text.length), length = min(max(0,selection.length),text.length-location)
        let chosen = text.substring(with:NSRange(location:location,length:length))
        switch self {
        case .footnote, .endnote:
            let marker = self == .footnote ? "^" : "~"
            var number = 1; while source.contains("["+marker+String(number)+"]") { number += 1 }
            let ref = "["+marker+String(number)+"]"
            let replaced = text.replacingCharacters(in:NSRange(location:location,length:length),with:chosen+ref) + "\n\n"+ref+": 请填写注释内容\n"
            return TextEdit(range:NSRange(location:0,length:text.length),replacement:replaced,selection:NSRange(location:location+(chosen as NSString).length+(ref as NSString).length,length:0))
        default:
            let insertion: String
            switch self { case .caption: insertion = "\n\n:::caption 请填写题注\n"; case .page: insertion = "\n\n:::page 请填写原页码\n"; default: insertion = "\n\n# 请填写章节标题\n" }
            return TextEdit(range:NSRange(location:location,length:length),replacement:insertion,selection:NSRange(location:location+(insertion as NSString).length,length:0))
        }
    }
}
