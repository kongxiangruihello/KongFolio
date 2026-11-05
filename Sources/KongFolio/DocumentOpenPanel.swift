import AppKit

/// The chooser returns cloud placeholders promptly; CloudFilePreparation owns download progress and cancellation.
/// Conflicting cloud versions still use the system conflict resolver.
@MainActor enum DocumentOpenPanel {
    static let coordinator = DocumentChooserCoordinator()
    static func configure(_ panel:NSOpenPanel) {
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canDownloadUbiquitousContents = false
        panel.message = "可多选文献；尚未下载的 iCloud 文件将在应用内后台准备，可取消并切换阅读其他文件。"
    }
}

/// One chooser for the application. Repeated Open commands reveal the pending chooser,
/// rather than attaching another sheet to a different (possibly hidden) document view.
@MainActor final class DocumentChooserCoordinator {
    private(set) var panel:NSOpenPanel?
    private weak var parent:NSWindow?
    private var closeObserver:NSObjectProtocol?
    @discardableResult func revealExisting() -> Bool {
        guard let panel else { return false }
        NSApp?.activate(ignoringOtherApps:true)
        parent?.makeKeyAndOrderFront(nil)
        panel.makeKeyAndOrderFront(nil)
        return true
    }
    func present(_ panel:NSOpenPanel,preferred:NSWindow?,completion:@escaping(NSApplication.ModalResponse)->Void) {
        guard !revealExisting() else { return }
        let candidates=[NSApp?.keyWindow,NSApp?.mainWindow,preferred]
        let window=candidates.compactMap{$0}.first{ $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) && $0.attachedSheet == nil }
        self.panel=panel;parent=window
        if let window {
            closeObserver=NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:window,queue:.main) { [weak self] _ in
                Task { @MainActor in self?.panel?.cancel(nil) }
            }
        }
        let finish:(NSApplication.ModalResponse)->Void = { [weak self,weak panel,weak window] response in
            guard let self,self.panel === panel else { return }
            if let observer=self.closeObserver { NotificationCenter.default.removeObserver(observer) };self.closeObserver=nil
            self.panel=nil;self.parent=nil
            panel?.orderOut(nil)
            if window?.isVisible == true { window?.makeKeyAndOrderFront(nil) }
            completion(response)
        }
        NSApp?.activate(ignoringOtherApps:true)
        if let window { window.makeKeyAndOrderFront(nil);panel.beginSheetModal(for:window,completionHandler:finish) }
        else { panel.begin(completionHandler:finish) }
    }
}
