import Foundation

@MainActor extension WorkspaceStore {
    /// Follow the focused PDF pane; an unsaved PDF needs a stable location before shelving.
    var currentPDFForShelf:URL? {
        guard let workspace=commandWorkspace,workspace.count>0,!workspace.busy,
              let url=workspace.projectURL ?? workspace.sourceURL,
              ["pdf","kongfolio"].contains(url.pathExtension.lowercased()) else { return nil }
        return url
    }
}
