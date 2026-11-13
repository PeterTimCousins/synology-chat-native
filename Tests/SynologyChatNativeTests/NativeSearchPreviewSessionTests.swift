import AppKit
import PDFKit
import XCTest
@testable import SynologyChatNative

@MainActor final class NativeSearchPreviewSessionTests:XCTestCase {
    func testSidebarCheckerMovesUnreadRowsAndRetainsSelectedAnchorAndDraftWithoutAuthentication() async throws {
        let session = try await NativeSearchResultsUIFixture.makeInteractiveSession();defer { session.cleanup() }
        let model = session.model,original = model.draft
        _ = try await model.loadSidebarSettings()
        XCTAssertNil(model.userID)
        try session.setSidebarUnreadForChecks(1)
        XCTAssertEqual(model.sidebarSections(query:"").first?.group,.unread)
        XCTAssertEqual(model.sidebarSections(query:"").first?.channels.map(\.id),[24])
        model.selection = 24
        try session.setSidebarUnreadForChecks(0)
        XCTAssertEqual(model.sidebarSections(query:"").first?.group,.unread)
        model.selection = 23
        XCTAssertEqual(model.draft,original)
        XCTAssertFalse(model.sidebarSections(query:"").contains { $0.group == .unread })
        XCTAssertFalse(NativeChatAppConfiguration.automaticallyRestoresSavedSession(bundleID:NativeSearchPreviewChecks.sidebarBundleID))
    }
    func testInteractiveFixtureLoadsAllTypesWithoutAWindowOrChangingSelectedDraft() async throws {
        let visibleWindows = NSApplication.shared.windows.filter(\.isVisible).count
        let session = try await NativeSearchResultsUIFixture.makeInteractiveSession();defer { session.cleanup() }
        let model = session.model,original = model.draft,owner = UUID();var textBytes = Data()
        XCTAssertEqual(NSApplication.shared.windows.filter(\.isVisible).count,visibleWindows)
        XCTAssertEqual(session.documents.count,4);XCTAssertEqual(model.selection,23);XCTAssertNil(model.userID)
        for (index,post) in session.documents.enumerated() {
            model.openSearchDocument(post,owner:owner);await model.documentPreviewTask?.value
            XCTAssertNil(model.documentPreviewError);XCTAssertEqual(model.selection,23);XCTAssertEqual(model.draft,original)
            switch (index,model.documentPreviewContent) {
            case (0,.text(let text)):XCTAssertTrue(text.contains("No sign-in or real NAS data"));textBytes = Data(text.utf8)
            case (1,.pdf(let pdf)):XCTAssertEqual(pdf.pageCount,2)
            case (2,.media(let media)),(3,.media(let media)):XCTAssertEqual(media.player.rate,0);XCTAssertNil(media.file)
            default:XCTFail("Synthetic preview type did not load")
            }
            model.closeDocumentPreview()
        }
        let destination = session.sourceDirectory.appendingPathComponent("saved-synthetic.txt");var opened:[URL] = []
        await model.saveAttachment(session.documents[0],chooseDestination:{ _ in destination },openAfterSaving:{ opened.append($0);return true },confirmOpening:{ _ in .open })
        XCTAssertEqual(try Data(contentsOf:destination),textBytes);XCTAssertEqual(opened,[destination]);XCTAssertEqual(model.downloadHistory.first?.state,.saved)
        XCTAssertEqual(NSApplication.shared.windows.filter(\.isVisible).count,visibleWindows)
        let directory = session.sourceDirectory;XCTAssertTrue(FileManager.default.fileExists(atPath:directory.path));session.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath:directory.path));XCTAssertFalse(model.connected);XCTAssertNil(model.searchDocumentOwner)
    }
}
