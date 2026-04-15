import XCTest
@testable import Litter

final class DexRoutingTests: XCTestCase {
    func testServerIDUsesDexDesktopPrefix() {
        XCTAssertEqual(
            DexCompanionRouting.serverId(for: "env-1", projectId: "project-1"),
            "dex-desktop:env-1::project-1"
        )
        XCTAssertEqual(
            DexCompanionRouting.serverId(for: "env-1"),
            "dex-desktop:env-1"
        )
    }

    func testEnvironmentIDParsesPrimaryAndLegacyPrefixes() {
        XCTAssertEqual(
            DexCompanionRouting.environmentId(fromServerId: "dex-desktop:env-1::project-1"),
            "env-1"
        )
        XCTAssertEqual(
            DexCompanionRouting.environmentId(fromServerId: "dex-companion:env-1::project-1"),
            "env-1"
        )
    }

    func testProjectIDParsesPrimaryAndLegacyPrefixes() {
        XCTAssertEqual(
            DexCompanionRouting.projectId(fromServerId: "dex-desktop:env-1::project-1"),
            "project-1"
        )
        XCTAssertEqual(
            DexCompanionRouting.projectId(fromServerId: "dex-companion:env-1::project-1"),
            "project-1"
        )
    }
}
