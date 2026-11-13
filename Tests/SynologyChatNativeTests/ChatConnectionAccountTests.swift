import XCTest
@testable import SynologyChatNative

final class ChatConnectionAccountTests: XCTestCase {
    private func account(_ id: String, imported: Bool = false) -> ChatAccount {
        .init(session: .init(baseURL: URL(string: "https://synthetic.test")!, sid: id, synoToken: "synthetic"),
              username: id, importedFromOfficialApp: imported)
    }
    func testProductionNeverReadsOfficialProfileOrAcceptsImportedAccounts() throws {
        var reads = 0
        let borrowed = account("borrowed", imported: true)
        for (supplied, current): (ChatAccount?, ChatAccount?) in [(nil, nil), (borrowed, nil), (nil, borrowed)] {
            do {
                _ = try ChatConnectionAccount.select(supplied: supplied, current: current, allowOfficialImport: false,
                    loadOfficial: { reads += 1; return borrowed })
                XCTFail("Production must require a native-owned session")
            } catch ChatSignInError.sessionRequired { }
        }
        XCTAssertEqual(reads, 0, "Reject before touching the official profile or Keychain")
    }
    func testNativeSignInAndSavedSessionTakePrecedenceWithoutImport() throws {
        let signedIn = account("signed-in"), saved = account("saved")
        for allow in [false, true] {
            let fresh = try ChatConnectionAccount.select(supplied: signedIn, current: saved, allowOfficialImport: allow,
                loadOfficial: { XCTFail("Must not read official profile"); return self.account("unexpected", imported: true) })
            XCTAssertEqual(fresh.session.sid, signedIn.session.sid)
            let restored = try ChatConnectionAccount.select(supplied: nil, current: saved, allowOfficialImport: allow,
                loadOfficial: { XCTFail("Must not read official profile"); return self.account("unexpected", imported: true) })
            XCTAssertEqual(restored.session.sid, saved.session.sid)
        }
    }
    func testAuthorizedDevelopmentImportRemainsInMemoryAndReusesCurrentAccount() throws {
        var reads = 0
        let borrowed = account("borrowed", imported: true)
        let imported = try ChatConnectionAccount.select(supplied: nil, current: nil, allowOfficialImport: true,
            loadOfficial: { reads += 1; return borrowed })
        XCTAssertEqual(imported.session.sid, borrowed.session.sid)
        XCTAssertTrue(imported.importedFromOfficialApp)
        let reconnect = try ChatConnectionAccount.select(supplied: nil, current: imported, allowOfficialImport: true,
            loadOfficial: { reads += 1; return self.account("unexpected", imported: true) })
        XCTAssertEqual(reconnect.session.sid, borrowed.session.sid)
        XCTAssertEqual(reads, 1)
    }
}
