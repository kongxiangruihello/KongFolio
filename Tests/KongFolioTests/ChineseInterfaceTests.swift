import XCTest
@testable import KongFolio

final class ChineseInterfaceTests: XCTestCase {
    func testChineseGoesFirstAndOtherLanguagesStayAsFallbacks() {
        XCTAssertEqual(AppLanguage.preferred(from: ["en-US", "fr-FR"]), ["zh-Hans", "en-US", "fr-FR"])
        XCTAssertEqual(AppLanguage.preferred(from: []), ["zh-Hans"])
        XCTAssertEqual(AppLanguage.preferred(from: ["zh-Hans-CN", "en-US"]), ["zh-Hans-CN", "en-US"])
        // A Chinese entry further down is folded into the one put in front.
        XCTAssertEqual(AppLanguage.preferred(from: ["en-US", "zh-Hans-CN"]), ["zh-Hans", "en-US"])
    }

    func testTheSettingIsWrittenOnceAndLeftAloneAfterwards() throws {
        let defaults = try UserDefaults(suiteName: "kongfolio-lang-" + UUID().uuidString).unwrap("无法创建设置")
        defaults.set(["en-US"], forKey: AppLanguage.key)
        AppLanguage.apply(to: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: AppLanguage.key) ?? [], ["zh-Hans", "en-US"])
        AppLanguage.apply(to: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: AppLanguage.key) ?? [], ["zh-Hans", "en-US"])
    }

    /// Without these keys (and the localization folders the build script adds) the standard menus stay English.
    func testTheBundleDeclaresChinese() throws {
        let candidates = [
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Info.plist"),
        ]
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return }
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any] ?? [:]
        XCTAssertEqual(plist["CFBundleDevelopmentRegion"] as? String, "zh-Hans")
        XCTAssertTrue((plist["CFBundleLocalizations"] as? [String] ?? []).contains("zh-Hans"))
    }

    func testTooltipsComeUpQuicklyUnlessTheReaderChoseOtherwise() throws {
        let fresh = try UserDefaults(suiteName: "kongfolio-tip-" + UUID().uuidString).unwrap("无法创建设置")
        AppInterface.registerDefaults(in: fresh)
        XCTAssertEqual(fresh.integer(forKey: AppInterface.tooltipDelayKey), AppInterface.tooltipDelay)
        XCTAssertTrue(AppInterface.tooltipDelay < 500)
        let chosen = try UserDefaults(suiteName: "kongfolio-tip-" + UUID().uuidString).unwrap("无法创建设置")
        chosen.set(900, forKey: AppInterface.tooltipDelayKey)
        AppInterface.registerDefaults(in: chosen)
        XCTAssertEqual(chosen.integer(forKey: AppInterface.tooltipDelayKey), 900)
    }
}
