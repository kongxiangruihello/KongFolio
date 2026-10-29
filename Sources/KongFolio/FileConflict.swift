import SwiftUI
import PDFKit

/// The bytes actually read, rather than a modification date which can be preserved by sync tools.
struct FileBaseline: Codable, Equatable {
    var path: String
    var digest: String?
    static func capture(_ url: URL, data: Data? = nil) throws -> Self {
        let bytes = try data ?? (FileManager.default.fileExists(atPath: url.path) ? Data(contentsOf: url, options: .mappedIfSafe) : nil)
        return Self(path: url.standardizedFileURL.path, digest: bytes.map(OCRPageCache.digest))
    }
    func verify(_ url: URL) throws {
        guard path == url.standardizedFileURL.path, try Self.capture(url).digest == digest else { throw FileConflict() }
    }
    /// Coordinate with other document apps, and check again inside the write accessor.
    @discardableResult func writing(_ url: URL, action: (URL) throws -> Void) throws -> FileBaseline {
        var coordinationError: NSError?, failure: Error?
        var saved: FileBaseline?
        NSFileCoordinator().coordinate(writingItemAt: url, options: digest == nil ? [] : .forReplacing, error: &coordinationError) { coordinated in
            do { try verify(url); try action(coordinated); saved = try Self.capture(url) } catch { failure = error }
        }
        if let failure { throw failure }; if let coordinationError { throw coordinationError }
        return try saved.unwrap("文档未完成保存")
    }
}
struct FileConflict: LocalizedError { var errorDescription: String? { "原文件已被其他软件修改或移走，已暂停覆盖；当前修改仍保留。" } }

extension Workspace {
    func baseline(for url: URL) throws -> FileBaseline {
        if let fileBaseline, fileBaseline.path == url.standardizedFileURL.path { return fileBaseline }
        // A recovered legacy workspace has no trustworthy baseline. Never assume its old bytes are current.
        if historySource?.standardizedFileURL == url.standardizedFileURL, FileManager.default.fileExists(atPath: url.path) { throw FileConflict() }
        return try FileBaseline.capture(url)
    }
    func handleSaveError(_ failure: Error) {
        if failure is FileConflict { saveConflict = true; status = failure.localizedDescription; _ = flushRecovery() }
        else { error = "保存失败，修改已保留在恢复副本：\(failure.localizedDescription)" }
    }
    func saveConflictCopy(to destination: URL) throws {
        guard let original = historySource, destination.standardizedFileURL != original.standardizedFileURL else { throw FolioError(message: "请使用与原文件不同的位置") }
        let target = try FileBaseline.capture(destination)
        let saved: FileBaseline
        if destination.pathExtension.lowercased() == "kongfolio" {
            var archive = try snapshot(); archive.projectPath = destination.path; archive.dirty = false; archive.fileBaseline = nil
            saved = try target.writing(destination) { try archive.write($0) }; projectURL = destination
        } else {
            saved = try target.writing(destination) { try writePDFCopy(to: $0) }
            try SignaturePersistence.write(signatureEditArchives, pdf: destination, storage: storage)
            projectURL = nil; sourceURL = destination
        }
        fileBaseline = saved; saveConflict = false; dirty = false
        try persistWordDraft(); try persistTableDrafts(); remember([destination]); scheduleRecovery(); status = "已另存副本，原文件保留"
    }
    func chooseConflictCopy() {
        guard let original = historySource else { return }
        guard let destination = saveURL(type: original.pathExtension == "kongfolio" ? .data : .pdf, suffix: original.pathExtension, name: original.deletingPathExtension().lastPathComponent + "-我的修改") else { return }
        do { try saveConflictCopy(to: destination) } catch { handleSaveError(error) }
    }
    func reloadAfterConflict() {
        guard let original = historySource else { return }
        do {
            // Keep a complete, independent recovery archive before replacing the in-memory document.
            let folder = storage.appendingPathComponent("Conflicts", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try snapshot().write(folder.appendingPathComponent(UUID().uuidString + ".kongfolio"))
            let payload = try ImportServices.read([original])
            let loadedBaseline: FileBaseline?
            if case .project(let archive) = payload {
                loadedBaseline = archive.fileBaseline
                try restore(archive); projectURL = original; sourceURL = nil
            } else if case .documents(let bytes) = payload {
                loadedBaseline = try FileBaseline.capture(original, data: bytes[0])
                try restore(ProjectArchive(sourcePath: original.path, pdf: bytes[0], title: title, selection: 0, selectedPages: [0], mode: .document, recipes: [:], drafts: [:], dirty: false, projectPath: nil))
            } else { loadedBaseline = nil }
            fileBaseline = loadedBaseline; dirty = false; saveConflict = false
            history.removeAll(); future.removeAll(); annotationResourceDocuments.removeAll(); loadWordDraft(); scheduleRecovery()
            status = "已重新载入原文件；此前修改保存在应用的 Conflicts 文件夹"
        } catch { self.error = error.localizedDescription }
    }
}

