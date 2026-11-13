import XCTest
@testable import InjectionBundle

final class ReconnectTests: XCTestCase {
    func testWakeResetsFailuresAndDelay() {
        XCTAssertEqual(InjectionReconnectFailures(6, 4, 4), 6)
        let failures = InjectionReconnectFailures(6, 4, 5)
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(InjectionReconnectDelay(failures), 0.25)
        XCTAssertEqual(InjectionReconnectDelay(6), 16)
        XCTAssertEqual(InjectionReconnectDelay(100), 16)
    }

    func testDeveloperEnvironmentTools() {
        for value in ["app-default", "xs", "s", "m", "l", "xl", "xxl", "xxxl", "ax1", "ax2", "ax3", "ax4", "ax5"] {
            XCTAssertTrue(InjectionNext.validDeveloperTool("text-size", value: value))
        }
        for value in ["app-default", "ltr", "rtl"] {
            XCTAssertTrue(InjectionNext.validDeveloperTool("layout-direction", value: value))
        }
        XCTAssertFalse(InjectionNext.validDeveloperTool("text-size", value: "rtl"))
        XCTAssertFalse(InjectionNext.validDeveloperTool("layout-direction", value: nil))
        XCTAssertFalse(InjectionNext.validDeveloperTool("unknown", value: "app-default"))
        XCTAssertTrue(InjectionNext.validDeveloperTool("refresh", value: nil))
    }

    func testDeveloperEnvironmentCapability() {
        XCTAssertTrue(PreparedPatchEvidence.clientCapabilities.contains("developer-environment-v1"))
        XCTAssertLessThanOrEqual(PreparedPatchEvidence.clientCapabilities.count, 16)
    }
}
