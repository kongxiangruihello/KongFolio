import Foundation

extension Workspace {
    func validateWordDraft() throws {
        guard !(wordOptions.editedText ?? [:]).isEmpty else { return }
        guard wordOptions.editedFromRevision == revision else { throw FolioError(message: "PDF 已变化，请先拷贝需要保留的预览文字，再清除本次文字修改并重新预览") }
    }
    func setWordDraft(_ text: String, page: Int) throws {
        try validateWordDraft()
        guard (0..<count).contains(page) else { throw FolioError(message: "预览页面已不存在") }
        wordOptions.editedFromRevision = revision
        if wordOptions.editedText == nil { wordOptions.editedText = [:] }
        wordOptions.editedText?[page] = text
    }
    func clearWordDraft(page: Int? = nil) {
        if let page { wordOptions.editedText?[page] = nil } else { wordOptions.editedText = nil }
        if (wordOptions.editedText ?? [:]).isEmpty { wordOptions.editedFromRevision = nil }
    }
}
