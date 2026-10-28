import Foundation

struct WordDraftArchive: Codable {
    var digest: String
    var options: WordExportOptions
    var sourcePath: String? = nil
    var sourceTitle: String? = nil
    var modified: Date? = nil
}

extension Workspace {
    var wordDraftArchive: WordDraftArchive? {
        guard wordOptions.hasDraft, let digest = wordDraftDigest else { return nil }
        return WordDraftArchive(digest: digest, options: wordOptions, sourcePath: (projectURL ?? sourceURL)?.path, sourceTitle: displayName, modified: Date())
    }
    var wordDraftURL: URL {
        let identity = (projectURL ?? sourceURL)?.standardizedFileURL.path ?? "unsaved-\(slot)"
        return storage.appendingPathComponent("WordDrafts", isDirectory: true).appendingPathComponent(OCRPageCache.digest(Data(identity.utf8)) + ".json")
    }
    func persistWordDraft() throws {
        guard let archive = wordDraftArchive else { return }
        try FileManager.default.createDirectory(at: wordDraftURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(archive).write(to: wordDraftURL, options: .atomic)
    }
    func restoreWordDraft(_ archive: WordDraftArchive?, sourceDigest: String? = nil) {
        wordOptions.editedText = nil; wordOptions.editedBlocks = nil; wordOptions.blockBaselines = nil; wordOptions.editedSourceDigest = nil; wordOptions.editedFromRevision = nil; wordDraftDigest = nil
        guard let archive else { return }
        wordOptions = archive.options; wordDraftDigest = archive.digest
        wordOptions.editedFromRevision = (sourceDigest ?? (try? pdfData()).map(OCRPageCache.digest)) == archive.digest ? revision : nil
    }
    func loadWordDraft() {
        guard FileManager.default.fileExists(atPath: wordDraftURL.path) else { return }
        do { restoreWordDraft(try JSONDecoder().decode(WordDraftArchive.self, from: Data(contentsOf: wordDraftURL))) }
        catch { status = "Word 草稿无法读取，原稿仍保留：\(error.localizedDescription)" }
    }
    var wordDraftText: String {
        wordOptions.draftText
    }
    func validateWordDraft() throws {
        guard wordOptions.hasDraft else { return }
        guard wordOptions.editedFromRevision == revision else { throw FolioError(message: "PDF 已变化，请先拷贝需要保留的预览文字，再清除本次文字修改并重新预览") }
    }
    func setWordDraft(_ text: String, page: Int) throws {
        try validateWordDraft()
        guard (0..<count).contains(page) else { throw FolioError(message: "预览页面已不存在") }
        if !wordOptions.hasDraft { wordDraftDigest = OCRPageCache.digest(try pdfData()) }
        wordOptions.editedFromRevision = revision
        if wordOptions.editedText == nil { wordOptions.editedText = [:] }
        wordOptions.editedText?[page] = text
        try persistWordDraft()
        scheduleRecovery()
    }
    func clearWordDraft(page: Int? = nil) {
        if let page { wordOptions.editedText?[page] = nil; wordOptions.editedBlocks?[page] = nil; wordOptions.blockBaselines?[page] = nil } else { wordOptions.editedText = nil; wordOptions.editedBlocks = nil; wordOptions.blockBaselines = nil }
        if !wordOptions.hasDraft {
            wordOptions.editedFromRevision = nil; wordOptions.editedSourceDigest = nil; wordDraftDigest = nil
            do { if FileManager.default.fileExists(atPath: wordDraftURL.path) { try FileManager.default.removeItem(at: wordDraftURL) } }
            catch { self.error = "无法清除已保存的 Word 草稿：\(error.localizedDescription)" }
        } else { do { try persistWordDraft() } catch { self.error = error.localizedDescription } }
        scheduleRecovery()
    }
}
