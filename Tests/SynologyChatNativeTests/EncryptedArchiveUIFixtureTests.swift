import XCTest
@testable import SynologyChatNative

@MainActor final class EncryptedArchiveUIFixtureTests:XCTestCase {
    func testIsolatedArchiveFixtureBootstrapsLockedAndExercisesActualUnlockReadAndRelock() async throws {
        let m = try await NativeEncryptedArchiveUIFixture.makeModel()
        defer { m.signOutLocally() }
        XCTAssertTrue(m.connected);XCTAssertFalse(m.encryptionUnlocked)
        XCTAssertTrue(m.channels.isEmpty);XCTAssertEqual(m.userID,10)
        let names = try await m.loadArchiveNames(kind:.private)
        XCTAssertEqual(names,["Synthetic encrypted archive"])
        let archives = try await m.loadArchives(kind:.private,name:names[0])
        let archive = try XCTUnwrap(archives.first)
        XCTAssertFalse(m.canReadArchive(archive))
        try m.unlockEncryption(password:NativeEncryptedArchiveUIFixture.syntheticPassword)
        XCTAssertTrue(m.canReadArchive(archive))
        let posts = try await m.loadArchivePosts(kind:.private,name:names[0],archive:archive)
        XCTAssertEqual(posts.map(\.id),[1,10,11,12,13,14])
        XCTAssertEqual(m.archiveMessageText(posts[0],archive:archive),"Synthetic archived root — café 👋")
        let file = try XCTUnwrap(posts.first { $0.id == 10 })
        XCTAssertEqual(m.archiveFilename(file,archive:archive),"Synthetic encrypted note.txt")
        let data = try await m.archivedAttachmentPreview(kind:.private,name:names[0],archive:archive,post:file,maximumBytes:1024,expectedAccount:m.accountGeneration)
        XCTAssertEqual(String(decoding:data,as:UTF8.self),"Synthetic encrypted archive text.\nNo private data.\n")
        let replies = try await m.loadArchivePosts(kind:.private,name:names[0],archive:archive,threadID:1)
        XCTAssertEqual(replies.map(\.id),[2])
        let result = try await m.searchArchivedMessages(kind:.private,name:names[0],scopes:[archive],query:"",collection:.files)
        XCTAssertEqual(result.matches.count,5)
        m.lockEncryption(reload:false)
        XCTAssertFalse(m.canReadArchive(archive));XCTAssertFalse(m.canOpenArchiveAttachment(file,archive:archive))
    }
}
