import XCTest
@testable import SynologyChatNative

@MainActor final class ChatSavedFileOpeningTests: XCTestCase {
    private func folder() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/saved-file-opening-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func file(_ folder: URL, name: String = "synthetic.txt") throws -> URL {
        let url = folder.appendingPathComponent(name); try Data("Synthetic completed download".utf8).write(to: url); return url
    }
    func testOneExplicitReviewPreservesOriginalURLAndOpensExactlyOnce() async throws {
        let url = try file(folder()), coordinator = ChatSavedFileOpening(); var confirmations = 0, opens = 0, reveals = 0
        let result = try await coordinator.request(url: url, checkCurrent: {}, confirm: { review in
            confirmations += 1; XCTAssertEqual(review.localURL, url); XCTAssertEqual(review.displayName, "synthetic.txt")
            return .open
        }, open: { opened in XCTAssertEqual(opened, url); opens += 1; return true }, reveal: { _ in reveals += 1 })
        XCTAssertEqual(result, .opened); XCTAssertEqual(confirmations, 1); XCTAssertEqual(opens, 1); XCTAssertEqual(reveals, 0); XCTAssertFalse(coordinator.busy)
    }
    func testCancelAndRevealNeverOpenAndDirectRevealDoesNotNeedAnAlert() async throws {
        let url = try file(folder()), coordinator = ChatSavedFileOpening(); var opens = 0, reveals = 0
        for decision in [ChatSavedFileOpening.Decision.cancel, .reveal] {
            let result = try await coordinator.request(url: url, checkCurrent: {}, confirm: { _ in decision }, open: { _ in opens += 1; return true }, reveal: { shown in XCTAssertEqual(shown, url); reveals += 1 })
            XCTAssertEqual(result, decision == .cancel ? .cancelled : .revealed)
        }
        let direct = try await coordinator.reveal(url: url, checkCurrent: {}, reveal: { _ in reveals += 1 })
        XCTAssertEqual(direct, .revealed); XCTAssertEqual(opens, 0); XCTAssertEqual(reveals, 2)
    }
    func testConcurrentPendingWorkflowIsBusyAndDoesNotCreateSecondReview() async throws {
        let url = try file(folder()), coordinator = ChatSavedFileOpening(), gate = SavedFileReviewGate()
        var opens = 0, secondConfirmations = 0
        let first = Task { try await coordinator.request(url: url, checkCurrent: {}, confirm: gate.confirm, open: { _ in opens += 1; return true }, reveal: { _ in }) }
        await fulfillment(of: [gate.started], timeout: 2)
        let second = try await coordinator.request(url: url, checkCurrent: {}, confirm: { _ in secondConfirmations += 1; return .open }, open: { _ in opens += 1; return true }, reveal: { _ in })
        XCTAssertEqual(second, .busy); XCTAssertEqual(secondConfirmations, 0)
        gate.finish(.open); let firstResult = try await first.value; XCTAssertEqual(firstResult, .opened); XCTAssertEqual(opens, 1)
    }
    func testDirectRevealBypassesHeldOpenReviewWithoutChangingBusyAndRetirementStopsLateOpen() async throws {
        let url = try file(folder()), coordinator = ChatSavedFileOpening(), gate = SavedFileReviewGate()
        var opens = 0, reveals = 0
        let pending = Task { try await coordinator.request(url: url, checkCurrent: {}, confirm: gate.confirm,
            open: { _ in opens += 1; return true }, reveal: { _ in reveals += 1 }) }
        await fulfillment(of: [gate.started], timeout: 2)
        let result = try await coordinator.reveal(url: url, checkCurrent: {}, reveal: { original in
            XCTAssertEqual(original, url); reveals += 1
        })
        XCTAssertEqual(result, .revealed); XCTAssertTrue(coordinator.busy)
        XCTAssertEqual(reveals, 1); XCTAssertEqual(opens, 0)
        coordinator.retire(); gate.finish(.open)
        do { _ = try await pending.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(opens, 0); XCTAssertFalse(coordinator.busy)
    }
    func testDirectRevealRetiredDuringMetadataAwaitCannotReachEffect() async throws {
        let url = try file(folder()), coordinator = ChatSavedFileOpening(); var checks = 0, effects = 0
        do {
            _ = try await coordinator.reveal(url: url, checkCurrent: {
                checks += 1
                // The second check runs after the first off-main metadata read.
                if checks == 2 { coordinator.retire() }
            }, reveal: { _ in effects += 1 })
            XCTFail()
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(effects, 0); XCTAssertFalse(coordinator.busy)
    }
    func testRetirementAllowsNewWorkflowWhileOldPromptCannotPublishOrResetNewBusyState() async throws {
        let url = try file(folder()), coordinator = ChatSavedFileOpening(), oldGate = SavedFileReviewGate(), newGate = SavedFileReviewGate()
        var opens = 0
        let old = Task { try await coordinator.request(url: url, checkCurrent: {}, confirm: oldGate.confirm, open: { _ in opens += 1; return true }, reveal: { _ in }) }
        await fulfillment(of: [oldGate.started], timeout: 2)
        coordinator.retire(); XCTAssertFalse(coordinator.busy)
        let new = Task { try await coordinator.request(url: url, checkCurrent: {}, confirm: newGate.confirm, open: { _ in opens += 1; return true }, reveal: { _ in }) }
        await fulfillment(of: [newGate.started], timeout: 2)
        oldGate.finish(.open)
        do { _ = try await old.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(coordinator.busy, "Retired workflow must not clear its successor's pending state")
        newGate.finish(.open); let newResult = try await new.value; XCTAssertEqual(newResult, .opened)
        XCTAssertFalse(coordinator.busy); XCTAssertEqual(opens, 1)
    }
    func testCancellationAfterReviewStartedPreventsAnyLateEffect() async throws {
        let url = try file(folder()), coordinator = ChatSavedFileOpening(), gate = SavedFileReviewGate(); var effects = 0
        let task = Task { try await coordinator.request(url: url, checkCurrent: {}, confirm: gate.confirm, open: { _ in effects += 1; return true }, reveal: { _ in effects += 1 }) }
        await fulfillment(of: [gate.started], timeout: 2); task.cancel(); gate.finish(.open)
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(effects, 0); XCTAssertFalse(coordinator.busy)
    }
    func testOwnerGenerationOrDownloadIdentityChangeDuringReviewBlocksBothEffects() async throws {
        let url = try file(folder())
        for decision in [ChatSavedFileOpening.Decision.open, .reveal] {
            let coordinator = ChatSavedFileOpening(); var generation = 4, effects = 0
            do {
                _ = try await coordinator.request(url: url, checkCurrent: { guard generation == 4 else { throw CancellationError() } }, confirm: { _ in generation = 5; return decision }, open: { _ in effects += 1; return true }, reveal: { _ in effects += 1 })
                XCTFail()
            } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(effects, 0); XCTAssertFalse(coordinator.busy)
        }
    }
    func testRemovedReplacedOrModifiedFileCannotBeOpenedAfterReview() async throws {
        for mutation in 0..<3 {
            let url = try file(folder()), coordinator = ChatSavedFileOpening(); var opens = 0
            do {
                _ = try await coordinator.request(url: url, checkCurrent: {}, confirm: { _ in
                    switch mutation {
                    case 0: try! FileManager.default.removeItem(at: url)
                    case 1: try! Data("Synthetic completed download".utf8).write(to: url, options: .atomic)
                    default: try! Data("A different and longer local file".utf8).write(to: url)
                    }
                    return .open
                }, open: { _ in opens += 1; return true }, reveal: { _ in XCTFail("Unexpected reveal") })
                XCTFail("Changed local identity accepted")
            } catch { XCTAssertNotNil(error as? ChatSavedFileOpeningError) }
            XCTAssertEqual(opens, 0); XCTAssertFalse(coordinator.busy)
        }
    }
    func testDirectoryMissingLeafAndSymlinkLeafAreRejectedBeforeReview() async throws {
        let root = try folder(), regular = try file(root), link = root.appendingPathComponent("symlink.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
        let missing = root.appendingPathComponent("missing.txt")
        for url in [root, link, missing] {
            let coordinator = ChatSavedFileOpening(); var reviewed = false
            do { _ = try await coordinator.request(url: url, checkCurrent: {}, confirm: { _ in reviewed = true; return .open }, open: { _ in XCTFail(); return true }, reveal: { _ in XCTFail() }); XCTFail() }
            catch { XCTAssertEqual(error as? ChatSavedFileOpeningError, .unavailable) }
            XCTAssertFalse(reviewed)
        }
    }
    func testParentSymlinkRetargetingCannotRedirectReviewedOpenAndTmpAliasRemainsValid() async throws {
        let root = try folder(), first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second"), parent = root.appendingPathComponent("parent")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
        _ = try file(first); _ = try file(second)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: first)
        let target = parent.appendingPathComponent("synthetic.txt"), coordinator = ChatSavedFileOpening(); var opens = 0
        do {
            _ = try await coordinator.request(url: target, checkCurrent: {}, confirm: { _ in
                try! FileManager.default.removeItem(at: parent)
                try! FileManager.default.createSymbolicLink(at: parent, withDestinationURL: second)
                return .open
            }, open: { _ in opens += 1; return true }, reveal: { _ in }); XCTFail()
        } catch { XCTAssertEqual(error as? ChatSavedFileOpeningError, .changed) }
        XCTAssertEqual(opens, 0)
        let alias = URL(fileURLWithPath: "/tmp/" + root.lastPathComponent + "/first/synthetic.txt")
        let result = try await coordinator.request(url: alias, checkCurrent: {}, confirm: { _ in .open }, open: { original in XCTAssertEqual(original, alias); opens += 1; return true }, reveal: { _ in })
        XCTAssertEqual(result, .opened); XCTAssertEqual(opens, 1)
    }
    func testUnicodeDisplayLabelIsSanitizedWhileOriginalSavedURLIsKept() async throws {
        let name = "report\u{202E}\u{200D}\u{2028}\u{2029}\u{0001}.txt", url = try file(folder(), name: name), coordinator = ChatSavedFileOpening()
        let result = try await coordinator.request(url: url, checkCurrent: {}, confirm: { review in
            XCTAssertEqual(review.displayName, "report.txt"); XCTAssertEqual(review.localURL, url); return .open
        }, open: { original in XCTAssertEqual(original.lastPathComponent, name); return true }, reveal: { _ in })
        XCTAssertEqual(result, .opened)
        XCTAssertEqual(ChatSavedFileOpening.displayName("\u{202E}\u{0001}"), "Downloaded file")
    }
    func testWorkspaceRefusalIsReportedOnceWithoutAutomaticRetry() async throws {
        let url = try file(folder()), coordinator = ChatSavedFileOpening(); var opens = 0
        do { _ = try await coordinator.request(url: url, checkCurrent: {}, confirm: { _ in .open }, open: { _ in opens += 1; return false }, reveal: { _ in }); XCTFail() }
        catch { XCTAssertEqual(error as? ChatSavedFileOpeningError, .couldNotOpen) }
        XCTAssertEqual(opens, 1); XCTAssertFalse(coordinator.busy)
    }
    func testPrecancelledWorkflowDoesNotReadOrReviewAndInvalidURLNeverReachesEffects() async throws {
        let coordinator = ChatSavedFileOpening(); var confirmations = 0
        let task = Task { () throws -> ChatSavedFileOpening.Result in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await coordinator.request(url: URL(fileURLWithPath: "/private/tmp/not-needed"), checkCurrent: {}, confirm: { _ in confirmations += 1; return .open }, open: { _ in XCTFail(); return true }, reveal: { _ in XCTFail() })
        }
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(confirmations, 0); XCTAssertFalse(coordinator.busy)
        for url in [URL(string: "https://example.invalid/file")!, URL(string: "file://foreign.invalid/private/tmp/file")!, URL(string: "file:///private/tmp/file?session=forbidden")!] {
            do { _ = try await coordinator.request(url: url, checkCurrent: {}, confirm: { _ in XCTFail(); return .open }, open: { _ in XCTFail(); return true }, reveal: { _ in XCTFail() }); XCTFail() }
            catch { XCTAssertEqual(error as? ChatSavedFileOpeningError, .unavailable) }
        }
    }
}

@MainActor private final class SavedFileReviewGate {
    let started = XCTestExpectation(description: "File review presented")
    private var continuation: CheckedContinuation<ChatSavedFileOpening.Decision, Never>?
    private var resolvedDecision: ChatSavedFileOpening.Decision?
    private var watchdog: Task<Void, Never>?
    func confirm(_ review: ChatSavedFileOpening.Review) async -> ChatSavedFileOpening.Decision {
        if let resolvedDecision { return resolvedDecision }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation; started.fulfill()
            watchdog = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                self?.finish(.cancel)
            }
        }
    }
    func finish(_ decision: ChatSavedFileOpening.Decision) {
        guard resolvedDecision == nil else { return }; resolvedDecision = decision
        watchdog?.cancel(); watchdog = nil
        let saved = continuation; continuation = nil; saved?.resume(returning: decision)
    }
}
