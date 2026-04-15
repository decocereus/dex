import XCTest
@testable import Litter

final class DexRoutingTests: XCTestCase {
    func testServerIDUsesDexDesktopPrefix() {
        XCTAssertEqual(
            DexDesktopRouting.serverId(for: "env-1", projectId: "project-1"),
            "dex-desktop:env-1::project-1"
        )
        XCTAssertEqual(
            DexDesktopRouting.serverId(for: "env-1"),
            "dex-desktop:env-1"
        )
    }

    func testEnvironmentIDParsesPrimaryAndLegacyPrefixes() {
        XCTAssertEqual(
            DexDesktopRouting.environmentId(fromServerId: "dex-desktop:env-1::project-1"),
            "env-1"
        )
        XCTAssertEqual(
            DexDesktopRouting.environmentId(fromServerId: "dex-companion:env-1::project-1"),
            "env-1"
        )
    }

    func testProjectIDParsesPrimaryAndLegacyPrefixes() {
        XCTAssertEqual(
            DexDesktopRouting.projectId(fromServerId: "dex-desktop:env-1::project-1"),
            "project-1"
        )
        XCTAssertEqual(
            DexDesktopRouting.projectId(fromServerId: "dex-companion:env-1::project-1"),
            "project-1"
        )
    }
}
