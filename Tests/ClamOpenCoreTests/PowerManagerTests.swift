import XCTest
@testable import ClamOpenCore

final class PowerManagerTests: XCTestCase {

    /// Apple Silicon 上 `pmset -g` 的典型输出
    private let appleSiliconOutput = """
    System-wide power settings:
    Currently in use:
     standby              1
     Sleep On Power Button 1
     hibernatefile        /var/vm/sleepimage
     powernap             1
     networkoversleep     0
     disksleep            10
     sleep                1 (sleep prevented by coreaudiod)
     hibernatemode        3
     ttyskeepawake        1
     displaysleep         10
     tcpkeepalive         1
     lowpowermode         0
     womp                 1
     proximitywake        1
     standbydelay         10800
    """

    /// Intel 机型：只有 standbydelayhigh / standbydelaylow，没有 standbydelay；Tab 分隔
    private let intelOutput = "Currently in use:\n standbydelaylow\t10800\n standbydelayhigh\t86400\n tcpkeepalive\t0\n womp\t0\n"

    func testParsesValuesWithMultipleSpaces() {
        XCTAssertEqual(PowerManager.parseValue(forKey: "tcpkeepalive", in: appleSiliconOutput), "1")
        XCTAssertEqual(PowerManager.parseValue(forKey: "womp", in: appleSiliconOutput), "1")
        XCTAssertEqual(PowerManager.parseValue(forKey: "standbydelay", in: appleSiliconOutput), "10800")
        XCTAssertEqual(PowerManager.parseValue(forKey: "sleep", in: appleSiliconOutput), "1")
    }

    func testParsesTabSeparatedValues() {
        XCTAssertEqual(PowerManager.parseValue(forKey: "tcpkeepalive", in: intelOutput), "0")
    }

    func testKeyMustMatchWholeWord() {
        // 回归：hasPrefix 会让 standbydelay 误匹配 standbydelaylow
        XCTAssertNil(PowerManager.parseValue(forKey: "standbydelay", in: intelOutput))
        XCTAssertEqual(PowerManager.parseValue(forKey: "standbydelayhigh", in: intelOutput), "86400")
        // "standby" 不应匹配 "standbydelay"
        XCTAssertEqual(PowerManager.parseValue(forKey: "standby", in: appleSiliconOutput), "1")
    }

    func testMissingKeyAndEmptyOutput() {
        XCTAssertNil(PowerManager.parseValue(forKey: "proximitywake", in: intelOutput))
        XCTAssertNil(PowerManager.parseValue(forKey: "tcpkeepalive", in: ""))
        XCTAssertNil(PowerManager.parseValue(forKey: "tcpkeepalive", in: " tcpkeepalive\n"))
    }

    func testNeedsOptimization() {
        XCTAssertTrue(PowerManager(readPmset: { self.appleSiliconOutput }).needsOptimization())

        let optimized = appleSiliconOutput
            .replacingOccurrences(of: "tcpkeepalive         1", with: "tcpkeepalive         0")
            .replacingOccurrences(of: "womp                 1", with: "womp                 0")
        XCTAssertFalse(PowerManager(readPmset: { optimized }).needsOptimization())

        // 只有 womp 启用也需要优化
        let wompOnly = optimized.replacingOccurrences(of: "womp                 0", with: "womp                 1")
        XCTAssertTrue(PowerManager(readPmset: { wompOnly }).needsOptimization())
    }

    func testUnreadableSettingsAreTreatedAsEnabled() {
        let pm = PowerManager(readPmset: { nil })
        XCTAssertNil(pm.getCurrentValue(.tcpKeepAlive))
        XCTAssertTrue(pm.isTCPKeepAliveEnabled())
        XCTAssertTrue(pm.needsOptimization())
    }

    func testSummaryIncludesCurrentValues() {
        let summary = PowerManager(readPmset: { self.appleSiliconOutput }).getPowerSettingsSummary()
        XCTAssertTrue(summary.contains("10800"))
        XCTAssertEqual(summary.components(separatedBy: "\n").count, 6)

        let unknown = PowerManager(readPmset: { nil }).getPowerSettingsSummary()
        XCTAssertTrue(unknown.contains("?"))
    }
}
