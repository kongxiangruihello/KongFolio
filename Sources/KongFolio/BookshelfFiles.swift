import AppKit
import PDFKit
import UniformTypeIdentifiers

struct ShelfRelinkReview: Identifiable {
    let id = UUID()
    let book: LibraryBook
    let url: URL
    let digest: String?
    let previousDigest: String?

    var verified: Bool { digest != nil && digest == previousDigest }
    var message: String {
        if previousDigest != nil { return "文件内容与原记录不同。请核对是否是同一文献的更新版本；页序变化可能影响既有摘录。也可以取消后作为新书添加。" }
        return "这条旧书架记录缺少可比对的文件指纹。请核对书名、版本和页序，再决定是否关联。"
    }

    static func inspect(_ book:LibraryBook, url:URL) throws -> Self {
        guard BookLibrary.supports(url), ShelfFileStatus.read(url) == .available,
              url.pathExtension.caseInsensitiveCompare(URL(fileURLWithPath:book.path).pathExtension) == .orderedSame else {
            throw FolioError(message:"请选择同类型、已下载到本机的文献文件")
        }
        if book.isPDF {
            guard let pdf = PDFDocument(url:url), !pdf.isLocked, pdf.pageCount > 0 else {
                throw FolioError(message:"这份 PDF 无法读取或仍处于锁定状态")
            }
        }
        let chosen = try ShelfFileStatus.digest(url)
        let old = URL(fileURLWithPath:book.path)
        let actual = try? ShelfFileStatus.digest(old)
        var bookmarkMatches = false
        if actual == nil, let bookmark = book.bookmark {
            var stale = false
            if let relocated = try? URL(resolvingBookmarkData:bookmark,options:[.withoutUI,.withoutMounting],relativeTo:nil,bookmarkDataIsStale:&stale) {
                bookmarkMatches = !stale && ReadingProgress.canonicalPath(relocated.path) == ReadingProgress.canonicalPath(url.path)
            }
        }
        return Self(book:book,url:url,digest:chosen,previousDigest:actual ?? (bookmarkMatches ? chosen : book.shelfDigest))
    }
}

@MainActor enum ShelfChooser {
    static func open(title:String, multiple:Bool, action:@escaping ([URL])->Void) {
        let panel = NSOpenPanel()
        DocumentOpenPanel.configure(panel)
        panel.title = title
        panel.message = multiple ? "所选文献将加入书架，原件保留在原位置。" : "选择这份文献现在所在的位置。"
        panel.allowsMultipleSelection = multiple
        panel.allowedContentTypes = [.pdf,.html,.plainText,UTType(exportedAs:"com.kongfolio.project")]
            + TextImport.markdownExtensions.compactMap { UTType(filenameExtension:$0) }
        DocumentOpenPanel.coordinator.present(panel,presentation:.separate) { _,urls in
            if !urls.isEmpty { action(urls) }
        }
    }

    static func saveShortcut(_ shortcut:ReadingShortcut, library:BookLibrary, status:@escaping (String)->Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [ReadingShortcut.fileType]
        panel.canCreateDirectories = true
        let name = shortcut.title.replacingOccurrences(of:"/",with:"-").replacingOccurrences(of:":",with:"-")
        let suffix = shortcut.mode == .resume ? "-继续阅读" : "-第\(shortcut.position.selection+1)页"
        panel.nameFieldStringValue = String(name.prefix(80))+suffix+"."+ReadingShortcut.fileExtension
        panel.message = "保存后将快捷方式拖到 Dock 右侧分隔线后。"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try shortcut.write(to:url)
                try library.register(shortcut,file:url)
                status("已保存，可把快捷方式拖到 Dock 右侧。")
            } catch { status(error.localizedDescription) }
        }
    }
}
