import Foundation

/// The app is written in Chinese; its standard menus (文件、编辑、视图、窗口、帮助) follow the app's language, which on a
/// system set to another language would be that language. Putting Chinese first makes them Chinese from the next launch.
enum AppLanguage {
    static let key = "AppleLanguages"

    /// `current` with Chinese in front (other languages stay behind it as fallbacks).
    static func preferred(from current: [String]) -> [String] {
        if current.first?.hasPrefix("zh") == true { return current }
        return ["zh-Hans"] + current.filter { !$0.hasPrefix("zh-Hans") }
    }

    static func apply(to defaults: UserDefaults = .standard) {
        let current = defaults.stringArray(forKey: key) ?? []
        let wanted = preferred(from: current)
        if wanted != current { defaults.set(wanted, forKey: key) }
    }
}
