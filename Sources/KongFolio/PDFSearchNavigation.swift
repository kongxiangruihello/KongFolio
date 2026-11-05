import Foundation

@MainActor extension WorkspaceStore {
    var canSearchPDF:Bool {
        guard let workspace=commandWorkspace else { return false }
        return workspace.count>0 && !workspace.busy
    }

    /// The reader magnifier never opens the reading-record library or a text-file editor.
    @discardableResult func openPDFSearch()->Bool {
        guard canSearchPDF,let workspace=commandWorkspace else { return false }
        workspace.pageEditing053=false
        workspace.sidebarTab = .search
        workspace.requestedSidebar053=true
        workspace.pdfSearchFocusRequest=UUID()
        return true
    }
}
