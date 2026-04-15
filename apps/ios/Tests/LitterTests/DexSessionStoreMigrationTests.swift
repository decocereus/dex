import XCTest
@testable import Litter

@MainActor
final class DexSessionStoreMigrationTests: XCTestCase {
    private let newKey = "dex.desktop.sessions"
    private let legacyKey = "dex.companion.sessions"

    override func tearDown() {
        super.tearDown()
        UserDefaults.standard.removeObject(forKey: newKey)
        UserDefaults.standard.removeObject(forKey: legacyKey)
    }

    func testLoadReadsLegacyKeyAndMigratesToNewKey() throws {
        let session = DexDesktopSavedSession(
            environmentId: "env-1",
            serverLabel: "Dex Desktop",
            httpBaseUrl: "http://localhost:8080",
            wsBaseUrl: "ws://localhost:8080",
            sessionCookieName: "dex-session",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let data = try JSONEncoder().encode([session])
        UserDefaults.standard.set(data, forKey: legacyKey)
        UserDefaults.standard.removeObject(forKey: newKey)

        let loaded = DexDesktopSessionStore.load()
        let migrated = UserDefaults.standard.data(forKey: newKey)

        XCTAssertEqual(loaded, [session])
        XCTAssertEqual(migrated, data)
    }
}
