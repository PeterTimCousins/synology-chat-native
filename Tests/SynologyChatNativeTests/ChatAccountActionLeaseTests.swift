import CryptoKit
import Foundation
import XCTest
@testable import SynologyChatNative

final class ChatAccountActionLeaseTests:XCTestCase {
    private let scope = String(repeating:"a",count:64)
    private func folder()->URL {
        let value = URL(fileURLWithPath:"/private/tmp",isDirectory:true).appendingPathComponent("native-account-action-lease-test-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at:value) };return value
    }
    private func leaseFile(_ directory:URL,key:String)->URL {
        let digest = SHA256.hash(data:Data(key.utf8)).map { String(format:"%02x",$0) }.joined()
        return directory.appendingPathComponent(scope+"."+digest+".lease")
    }
    func testDiskLeaseExcludesAnotherInstanceButAllowsUnrelatedResourceAndAccount() throws {
        let directory = folder(),first = try ChatAccountActionLease(directory:directory,scope:scope,keys:["webhook:50"],memoryNamespace:"first")
        defer { first.release() }
        XCTAssertThrowsError(try ChatAccountActionLease(directory:directory,scope:scope,keys:["webhook:50"],memoryNamespace:"second"))
        let otherResource = try ChatAccountActionLease(directory:directory,scope:scope,keys:["webhook:51"],memoryNamespace:"second")
        let otherAccount = try ChatAccountActionLease(directory:directory,scope:String(repeating:"b",count:64),keys:["webhook:50"],memoryNamespace:"second")
        otherResource.release();otherAccount.release()
        first.release();first.release()
        let next = try ChatAccountActionLease(directory:directory,scope:scope,keys:["webhook:50","webhook:50"],memoryNamespace:"second")
        next.release()
    }
    func testFailedMultiKeyAcquisitionReleasesEarlierLocks() throws {
        let directory = folder(),occupied = try ChatAccountActionLease(directory:directory,scope:scope,keys:["z"],memoryNamespace:"one")
        defer { occupied.release() }
        XCTAssertThrowsError(try ChatAccountActionLease(directory:directory,scope:scope,keys:["z","a"],memoryNamespace:"two"))
        let free = try ChatAccountActionLease(directory:directory,scope:scope,keys:["a"],memoryNamespace:"three")
        free.release()
        XCTAssertThrowsError(try ChatAccountActionLease(directory:directory,scope:scope,keys:["z"],memoryNamespace:"four"))
    }
    func testSymlinkLeaseCannotFollowOrModifyItsTarget() throws {
        let directory = folder(),prime = try ChatAccountActionLease(directory:directory,scope:scope,keys:["prime"],memoryNamespace:"one")
        prime.release()
        let target = directory.appendingPathComponent("synthetic-target.txt"),bytes = Data("Synthetic target must remain untouched".utf8)
        try bytes.write(to:target)
        try FileManager.default.createSymbolicLink(at:leaseFile(directory,key:"blocked"),withDestinationURL:target)
        XCTAssertThrowsError(try ChatAccountActionLease(directory:directory,scope:scope,keys:["blocked"],memoryNamespace:"two"))
        XCTAssertEqual(try Data(contentsOf:target),bytes)
    }
    func testPrivateLeaseFilesContainNoDataOrRawKeys() throws {
        let directory = folder(),key = "synthetic-private-callback-https://example.invalid/never-persist"
        let lease = try ChatAccountActionLease(directory:directory,scope:scope,keys:[key],memoryNamespace:"one")
        defer { lease.release() }
        let file = leaseFile(directory,key:key)
        XCTAssertTrue(try Data(contentsOf:file).isEmpty)
        XCTAssertFalse(file.lastPathComponent.contains("callback"));XCTAssertFalse(file.lastPathComponent.contains("https"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:directory.path)[.posixPermissions] as? NSNumber)?.intValue,0o700)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
    }
    func testInMemoryRegistryIsNamespacedAtomicAndReleasedOnDeinit() throws {
        let namespace = UUID().uuidString
        var first:ChatAccountActionLease? = try ChatAccountActionLease(directory:nil,scope:scope,keys:["z"],memoryNamespace:namespace)
        try withExtendedLifetime(first) {
            XCTAssertThrowsError(try ChatAccountActionLease(directory:nil,scope:scope,keys:["a","z"],memoryNamespace:namespace))
        }
        let free = try ChatAccountActionLease(directory:nil,scope:scope,keys:["a"],memoryNamespace:namespace)
        let isolated = try ChatAccountActionLease(directory:nil,scope:scope,keys:["z"],memoryNamespace:namespace+"other")
        free.release();isolated.release();first = nil
        let next = try ChatAccountActionLease(directory:nil,scope:scope,keys:["z"],memoryNamespace:namespace)
        next.release();next.release()
    }
    func testDiskDeinitReleasesLocksAndInvalidRequestsCannotCreateFiles() throws {
        let directory = folder()
        for invalid in ["",String(repeating:"A",count:64),String(repeating:"a",count:63)] {
            XCTAssertThrowsError(try ChatAccountActionLease(directory:directory,scope:invalid,keys:["key"],memoryNamespace:"one"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath:directory.path))
        XCTAssertThrowsError(try ChatAccountActionLease(directory:nil,scope:scope,keys:[],memoryNamespace:"one"))
        XCTAssertThrowsError(try ChatAccountActionLease(directory:nil,scope:scope,keys:[""],memoryNamespace:"one"))
        XCTAssertThrowsError(try ChatAccountActionLease(directory:nil,scope:scope,keys:["key"],memoryNamespace:""))
        var first:ChatAccountActionLease? = try ChatAccountActionLease(directory:directory,scope:scope,keys:["key"],memoryNamespace:"one")
        try withExtendedLifetime(first) {
            XCTAssertThrowsError(try ChatAccountActionLease(directory:directory,scope:scope,keys:["key"],memoryNamespace:"two"))
        }
        first = nil
        let second = try ChatAccountActionLease(directory:directory,scope:scope,keys:["key"],memoryNamespace:"two")
        second.release()
    }
    func testKnownCreateReceiptLocksBothKindAndTargetResource() throws {
        let create = try ChatWebhookActionIntent(operation:.create,kind:.incoming),known = try create.withCreatedID(50)
        XCTAssertEqual(create.recoveryLockKeys,["create:incoming"])
        XCTAssertEqual(known.recoveryLockKeys,["create:incoming","webhook:50"])
        XCTAssertEqual(try ChatWebhookActionIntent(operation:.edit,kind:.incoming,webhookID:50).recoveryLockKeys,["webhook:50"])
    }
}
