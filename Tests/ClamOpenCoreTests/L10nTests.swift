import XCTest
@testable import ClamOpenCore

final class L10nTests: XCTestCase {

    func testChineseVariantsSelectChinese() {
        for lang in ["zh", "zh-Hans", "zh-Hans-CN", "zh-Hant-TW", "ZH-HANS"] {
            XCTAssertTrue(L10n.isChinese(preferredLanguages: [lang]), lang)
        }
    }

    func testOtherLanguagesFallBackToEnglish() {
        for lang in ["en", "en-US", "tr-TR", "de", "ja-JP"] {
            XCTAssertFalse(L10n.isChinese(preferredLanguages: [lang]), lang)
        }
    }

    func testOnlyFirstPreferredLanguageCounts() {
        XCTAssertFalse(L10n.isChinese(preferredLanguages: ["tr-TR", "zh-Hans"]))
        XCTAssertTrue(L10n.isChinese(preferredLanguages: ["zh-Hans", "en"]))
    }

    func testEmptyPreferredLanguagesFallsBackToEnglish() {
        XCTAssertFalse(L10n.isChinese(preferredLanguages: []))
    }

    func testTrReturnsStringForCurrentLanguage() {
        XCTAssertEqual(tr("en", "zh"), L10n.isChinese ? "zh" : "en")
    }
}
