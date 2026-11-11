import Foundation

@MainActor extension WorkspaceStore {
    var canSearchPDF:Bool {
        guard let workspace=commandWorkspace else { return false }
        return workspace.count>0 && !workspace.busy
    }

    var rightPDFSearchWorkspace: Workspace? {
        guard let active = activeWorkspace, let id = pdfSearchWorkspaceID else { return nil }
        if active.id == id { return active.count > 0 ? active : nil }
        guard let partner = active.splitPartner, partner.id == id, partner.count > 0 else { return nil }
        return partner
    }

    func closeRightReadingPanel() {
        showReadingDesk = false
        pdfSearchWorkspaceID = nil
    }

    /// The reader magnifier never opens the reading-record library or a text-file editor.
    @discardableResult func openPDFSearch()->Bool {
        guard canSearchPDF,let workspace=commandWorkspace else { return false }
        showReadingDesk = false
        pdfSearchWorkspaceID = workspace.id
        workspace.pdfSearchFocusRequest=UUID()
        return true
    }
}
