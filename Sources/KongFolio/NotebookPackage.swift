import Foundation

/// A ZIP with a portable Markdown note, relative image assets and optionally its original documents.
enum NotebookPackage {
    static func write(cards: [BoardCard], title: String, grouping: ExcerptNotebook.Grouping, outlines: [String: [OutlineEntry]] = [:], includeSources: Bool, to destination: URL) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("KongFolio-notebook-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true); defer { try? fm.removeItem(at: root) }
        var prepared = cards, copied: [String: String] = [:], contents: [String: String] = [:]
        for i in prepared.indices {
            try Task.checkCancellation()
            guard includeSources, var source = prepared[i].source else { continue }
            guard !source.path.isEmpty else { throw FolioError(message: "来源尚未保存，请先保存来源文档后打包") }
            if let relative = copied[source.path] { source.relativePath = relative; source.fingerprint = contents[source.path] }
            else {
                let bytes = try Data(contentsOf: URL(fileURLWithPath: source.path)), digest = OCRPageCache.digest(bytes)
                let name = String(digest.prefix(20)) + "-" + URL(fileURLWithPath: source.path).lastPathComponent
                let relative = "sources/" + name, url = root.appendingPathComponent(relative)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: url, options: .atomic)
                copied[source.path] = relative; contents[source.path] = digest
                source.relativePath = relative; source.fingerprint = digest
            }
            prepared[i].source = source
        }
        let note = root.appendingPathComponent("摘录笔记.md")
        let markdown = ExcerptNotebook.render(prepared, title: title, grouping: grouping, outlines: outlines)
        let portable = try TextAssets.saving(markdown, format: .markdown, oldBase: nil, destination: note)
        try portable.write(to: note, atomically: true, encoding: .utf8)
        try "解压整个资料包，用 KongFolio 打开“摘录笔记.md”，即可查看图片并返回原文。请保留 sources 和图片文件夹。\n".write(to: root.appendingPathComponent("使用说明.txt"), atomically: true, encoding: .utf8)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent("." + UUID().uuidString + ".zip")
        let writer = try ZipWriter(url: temporary)
        do {
            let paths = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
            for case let url as URL in paths where (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
                try Task.checkCancellation(); let path = url.resolvingSymlinksInPath().path
                guard path.hasPrefix(root.path + "/") else { throw FolioError(message: "资料包文件路径无效") }
                try writer.add(String(path.dropFirst(root.path.count + 1)), Data(contentsOf: url))
            }
            try writer.finish()
            if fm.fileExists(atPath: destination.path) { _ = try fm.replaceItemAt(destination, withItemAt: temporary) }
            else { try fm.moveItem(at: temporary, to: destination) }
        } catch { writer.abandon(); try? fm.removeItem(at: temporary); throw error }
    }
}
