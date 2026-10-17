import Foundation

/// UserDefaults keys for the collapsible side panels; the menu commands, the top bar buttons and every tab share them.
enum LayoutKeys {
    static let sidebar = "KongFolio.showSidebar"
    static let inspector = "KongFolio.showInspector"
    static let board = "KongFolio.showBoard"
    /// Colour the source text of an excerpt in the document (on by default).
    static let tintSources = "KongFolio.tintSources"
}

/// How the interface adapts to the window width. Panels the user switched on are hidden while the window is too
/// narrow for them (their preference is kept and they return when the window is wide enough again).
enum LayoutMetrics {
    enum TopBarStyle: Equatable { case full, icons, minimal }

    static let fullTopBar: CGFloat = 1100
    static let iconTopBar: CGFloat = 780
    static let sidebarMinimum: CGFloat = 640
    static let inspectorMinimum: CGFloat = 880
    static let boardMinimum: CGFloat = 780
    /// With the workspace pane open, the properties panel needs room for it as well.
    static let inspectorWithBoardMinimum: CGFloat = 1180
    static let previewMinimum: CGFloat = 640
    /// Two documents side by side need room for both pages.
    static let splitMinimum: CGFloat = 760
    static let inspectorWithSplitMinimum: CGFloat = 1280

    static func topBarStyle(width: CGFloat) -> TopBarStyle {
        width >= fullTopBar ? .full : (width >= iconTopBar ? .icons : .minimal)
    }
    static func showsSidebar(preferred: Bool, width: CGFloat) -> Bool { preferred && width >= sidebarMinimum }
    static func showsInspector(preferred: Bool, width: CGFloat, boardShown: Bool = false, splitShown: Bool = false) -> Bool {
        preferred && width >= max(boardShown ? inspectorWithBoardMinimum : inspectorMinimum, splitShown ? inspectorWithSplitMinimum : 0)
    }
    static func showsSplit(width: CGFloat) -> Bool { width >= splitMinimum }
    static func showsBoard(preferred: Bool, width: CGFloat) -> Bool { preferred && width >= boardMinimum }
    static func showsPreview(preferred: Bool, width: CGFloat) -> Bool { preferred && width >= previewMinimum }
}
