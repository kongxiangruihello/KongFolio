import AppKit
import UniformTypeIdentifiers

/// The chooser returns cloud placeholders promptly; CloudFilePreparation owns download progress and cancellation.
@MainActor enum DocumentOpenPanel {
    static let coordinator = DocumentChooserCoordinator()

    static func configure(_ panel:NSOpenPanel) {
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canDownloadUbiquitousContents = false
        panel.message = "可多选文献；尚未下载的 iCloud 文件将在应用内后台准备，可取消并切换阅读其他文件。"
    }

    static func files(imagesOnly:Bool = false, offersFinder:Bool = false) -> NSOpenPanel {
        let panel = NSOpenPanel()
        configure(panel)
        panel.allowsMultipleSelection = true
        if imagesOnly {
            panel.allowedContentTypes = [.image]
            panel.message = "所选图片将作为新页面插入当前页之后，可多选并调整顺序。"
        } else {
            panel.allowedContentTypes = [ReadingShortcut.fileType,.pdf,.image,.html,.plainText,UTType(exportedAs:"com.kongfolio.project")]
                + TextImport.markdownExtensions.compactMap { UTType(filenameExtension:$0) }
        }
        if offersFinder {
            panel.message = "双击文件夹进入，或选中后按 ⌘↓。所选 iCloud 文件将在应用内后台下载。"
            coordinator.installFinderButton(on:panel)
        }
        return panel
    }
}

/// Keep a single chooser. Ordinary open commands use a modeless window so an idle
/// file-provider panel cannot disable the reader. Editing operations can use a sheet.
@MainActor final class DocumentChooserCoordinator {
    enum Presentation { case separate, sheet }
    private(set) var panel:NSOpenPanel?
    private var closeObserver:NSObjectProtocol?

    func installFinderButton(on panel:NSOpenPanel) {
        let button = NSButton(title:"在访达中浏览当前文件夹",target:self,action:#selector(browseInFinder(_:)))
        button.toolTip = "在访达选中文献，可拖入 KongFolio 窗口"
        button.sizeToFit()
        panel.accessoryView = button
        panel.isAccessoryViewDisclosed = true
    }

    @objc private func browseInFinder(_ sender:NSButton) {
        guard let panel else { return }
        let directory = panel.directoryURL ?? FileManager.default.homeDirectoryForCurrentUser
        panel.cancel(nil)
        DispatchQueue.main.async { NSWorkspace.shared.open(directory) }
    }

    @discardableResult func revealExisting() -> Bool {
        guard let panel else { return false }
        if NSApp?.isActive == false { NSApp.activate(ignoringOtherApps:true) }
        panel.makeKeyAndOrderFront(nil)
        return true
    }

    func present(_ panel:NSOpenPanel,preferred:NSWindow? = nil,presentation:Presentation = .sheet,
                 completion:@escaping(NSApplication.ModalResponse,[URL])->Void) {
        guard !revealExisting() else { return }
        let candidates = [preferred,NSApp?.keyWindow,NSApp?.mainWindow]
        let window = presentation == .sheet ? candidates.compactMap{$0}.first {
            $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) && $0.attachedSheet == nil
        } : nil
        self.panel = panel
        if let window {
            closeObserver = NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:window,queue:.main) { [weak self,weak panel] _ in
                Task { @MainActor in
                    guard let panel, self?.panel === panel else { return }
                    panel.cancel(nil)
                }
            }
        }
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self,weak panel] response in
            guard let self,let panel,self.panel === panel else { return }
            let urls = response == .OK ? panel.urls : []
            if let observer = self.closeObserver { NotificationCenter.default.removeObserver(observer) }
            self.closeObserver = nil
            self.panel = nil
            if presentation == .sheet { panel.orderOut(nil) }
            // Process the selection after AppKit returns from the panel completion callback.
            DispatchQueue.main.async { completion(response,urls) }
        }
        if let window { panel.beginSheetModal(for:window,completionHandler:finish) }
        else { panel.begin(completionHandler:finish) }
    }
}
