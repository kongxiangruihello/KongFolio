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

/// Interface timing that is not the system default.
enum AppInterface {
    /// How long the pointer rests on something before its tooltip appears, in milliseconds (the system waits about a second).
    static let tooltipDelayKey = "NSInitialToolTipDelay"
    static let tooltipDelay = 150

    /// Registered, not stored: a value the reader set themselves still wins.
    static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [tooltipDelayKey: tooltipDelay])
    }
}
