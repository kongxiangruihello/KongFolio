import AppKit

/// The chooser returns cloud placeholders promptly; CloudFilePreparation owns download progress and cancellation.
/// Conflicting cloud versions still use the system conflict resolver.
@MainActor enum DocumentOpenPanel {
    static func configure(_ panel:NSOpenPanel) {
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canDownloadUbiquitousContents = false
        panel.message = "可多选文献；尚未下载的 iCloud 文件将在应用内后台准备，可取消并切换阅读其他文件。"
    }
}
