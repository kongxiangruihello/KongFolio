import Foundation

/// A draft's suggested file name, not part of the document body.
enum DraftNoteName {
    static func normalized(_ value:String,extension suffix:String)throws->String {
        var name = value.trimmingCharacters(in:.whitespacesAndNewlines)
        if name.lowercased().hasSuffix("."+suffix.lowercased()) { name = String(name.dropLast(suffix.count+1)).trimmingCharacters(in:.whitespacesAndNewlines) }
        guard !name.isEmpty,name != ".",name != "..",name.utf8.count<=240,
              name.rangeOfCharacter(from:.controlCharacters) == nil,!name.contains("/"),!name.contains(":") else {
            throw FolioError(message:"请输入有效名称：不能留空、包含斜杠或冒号，名称也不能过长。")
        }
        return name
    }
}
