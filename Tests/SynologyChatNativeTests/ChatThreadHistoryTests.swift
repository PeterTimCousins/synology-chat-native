import XCTest
@testable import SynologyChatNative

@MainActor
final class ChatThreadHistoryTests: XCTestCase {
    private func post(_ id: Int64) -> [String: Any] {
        ["post_id": id, "channel_id": 23, "creator_id": 20, "message": "Synthetic", "type": "normal",
         "create_at": Double(id), "thread_id": 1]
    }
    private func setup(pages: [([Int64], TimeInterval)]) async throws -> (NativeChatPreviewModel, ChatPost) {
        ThreadHistoryStub.configure(pages.map { ids, delay in
            (try! JSONSerialization.data(withJSONObject: ["success": true, "data": ["posts": ids.map { self.post($0) }]]), delay)
        })
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ThreadHistoryStub.self]
        let api = try ChatAPIClient(session: .init(baseURL: URL(string: "https://synthetic.test")!, sid: "s", synoToken: "t"),
                                    network: URLSession(configuration: config))
        try await api.discover()
        let model = NativeChatPreviewModel(client: api)
        model.notificationRouting.activate(scope: String(repeating: "a", count: 64))
        model.selection = 23
        model.channels = [try JSONDecoder().decode(ChatChannel.self, from: Data(#"{"channel_id":23,"name":"Synthetic","type":"anonymous","encrypted":false,"unread":0}"#.utf8))]
        let root = try JSONDecoder().decode(ChatPost.self, from: JSONSerialization.data(withJSONObject: post(1)))
        return (model, root)
    }

    func testNotificationWaitsForAuthenticatedLiveStateThenLoadsExactContext() async throws {
        let (model, _) = try await setup(pages: [([500, 501, 502], 0)])
        model.selection = nil
        model.receiveNotification(try XCTUnwrap(ChatNotificationDestination(userInfo: ["nativeAccountScope": String(repeating: "a", count: 64), "nativeChannelID": "23", "nativePostID": "501"])))
        XCTAssertNil(model.selection)
        model.connected = true
        XCTAssertFalse(model.openPendingNotification(), "Initial history must not consume the destination before the handshake")
        model.liveStatus = .live
        XCTAssertTrue(model.openPendingNotification())
        XCTAssertEqual(model.selection, 23)
        model.loadSelection()
        for _ in 0..<200 where model.loadingHistory { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(model.scrollPostID, 501)
        XCTAssertTrue(model.viewingMessageContext)
        XCTAssertEqual(model.posts.map(\.id), [500, 501, 502])
        XCTAssertFalse(model.openPendingNotification(), "The click is consumed once")
    }
#if DEBUG
    func testNativeThreadViewportScopeChangesForContextLatestAndCloseButNotOlderPage() async throws {
        let (model,root) = try await setup(pages:[(Array(61...90),0),(Array(31...61),0),(Array(81...90),0),(Array(61...90),0)])
        let initial = model.nativeThreadViewportToken
        await model.openThread(root)
        let first = model.nativeThreadViewportToken
        XCTAssertNotEqual(first,initial);XCTAssertNil(model.nativeThreadScrollPostID)
        await model.loadOlderReplies()
        XCTAssertEqual(model.nativeThreadViewportToken,first);XCTAssertEqual(model.replies.map(\.id),Array(31...90))
        await model.openThread(root,around:85)
        let context = model.nativeThreadViewportToken
        XCTAssertNotEqual(context,first);XCTAssertEqual(model.nativeThreadScrollPostID,85);XCTAssertTrue(model.threadViewingContext)
        await model.openThread(root)
        let latest = model.nativeThreadViewportToken
        XCTAssertNotEqual(latest,context);XCTAssertNil(model.nativeThreadScrollPostID);XCTAssertFalse(model.threadViewingContext)
        model.replyDraft = "Synthetic retained reply draft"
        model.closeThread()
        XCTAssertNotEqual(model.nativeThreadViewportToken,latest);XCTAssertNil(model.nativeThreadScrollPostID)
        XCTAssertNil(model.threadRoot);XCTAssertTrue(model.replies.isEmpty)
        XCTAssertEqual(model.threadDrafts[root.id],"Synthetic retained reply draft")
    }
    func testRejectedThreadOpenCannotReplaceCurrentViewportIntent() async throws {
        let (model,root) = try await setup(pages:[([80,81,82],0)])
        await model.openThread(root,around:81)
        let token = model.nativeThreadViewportToken
        let foreign = try JSONDecoder().decode(ChatPost.self,from:Data(#"{"post_id":2,"channel_id":999,"creator_id":20,"message":"Synthetic inaccessible","type":"normal","create_at":2}"#.utf8))
        await model.openThread(foreign,around:99)
        XCTAssertEqual(model.nativeThreadViewportToken,token);XCTAssertEqual(model.nativeThreadScrollPostID,81)
        XCTAssertEqual(model.threadRoot?.id,root.id);XCTAssertEqual(model.replies.map(\.id),[80,81,82])
    }
#endif

    func testNotificationForInaccessibleConversationDoesNotChangeSelection() async throws {
        let (model, _) = try await setup(pages: [])
        model.connected = true
        model.liveStatus = .live
        model.receiveNotification(try XCTUnwrap(ChatNotificationDestination(userInfo: ["nativeAccountScope": String(repeating: "a", count: 64), "nativeChannelID": "999", "nativePostID": "1"])))
        XCTAssertEqual(model.selection, 23)
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.openPendingNotification())
    }

    func testReconnectHistoryRefreshRetainsOpenThreadAndDrafts() async throws {
        let (model, root) = try await setup(pages: [([100], 0), ([900], 0.01), ([1], 0), ([101], 0)])
        await model.openThread(root)
        model.draft = "Unsent main draft"
        model.replyDraft = "Unsent reply draft"
        model.loadSelection(preservingThread: true)
        XCTAssertEqual(model.threadRoot?.id, root.id)
        XCTAssertEqual(model.replies.map(\.id), [100])
        for _ in 0..<200 where model.loadingHistory { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertFalse(model.loadingHistory)
        XCTAssertEqual(model.posts.map(\.id), [900])
        XCTAssertEqual(model.threadRoot?.id, root.id)
        XCTAssertEqual(model.replies.map(\.id), [101])
        XCTAssertEqual(model.draft, "Unsent main draft")
        XCTAssertEqual(model.replyDraft, "Unsent reply draft")
    }

    func testClosingThreadDuringReconnectRefreshDoesNotReopenIt() async throws {
        let (model, root) = try await setup(pages: [([100], 0), ([900], 0.05)])
        await model.openThread(root)
        let started = expectation(description: "Reconnect history requested")
        ThreadHistoryStub.whenFirstPageRequested { started.fulfill() }
        model.loadSelection(preservingThread: true)
        await fulfillment(of: [started], timeout: 1)
        model.closeThread()
        for _ in 0..<200 where model.loadingHistory { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertFalse(model.loadingHistory)
        XCTAssertEqual(model.posts.map(\.id), [900])
        XCTAssertNil(model.threadRoot)
        XCTAssertTrue(model.replies.isEmpty)
    }

    func testReconnectRetainsLoadedOlderRepliesAndThreadTicketWhileRefreshingBothWindows() async throws {
        let (model,root) = try await setup(pages:[(Array(61...90),0),(Array(31...61),0),
            ([900],0),([1],0),(Array(45...55).filter { $0 != 49 },0),(Array(62...91),0)])
        await model.openThread(root);await model.loadOlderReplies()
        let token = model.nativeThreadViewportToken
        model.noteThreadViewport(postID:50,atBottom:false,token:token,account:model.accountGeneration,channelID:23,rootID:1)
        model.draft = "Unsent main";model.replyDraft = "Unsent thread"
        model.loadSelection(preservingThread:true,preservingViewport:true)
        for _ in 0..<500 where model.loadingHistory { try await Task.sleep(nanoseconds:1_000_000) }
        XCTAssertFalse(model.loadingHistory);XCTAssertFalse(model.loadingThread)
        XCTAssertEqual(model.nativeThreadViewportToken,token)
        XCTAssertEqual(model.replies.map(\.id),Array(31...91).filter { $0 != 49 })
        XCTAssertTrue(model.canLoadOlderReplies);XCTAssertFalse(model.threadViewingContext)
        XCTAssertEqual(model.draft,"Unsent main");XCTAssertEqual(model.replyDraft,"Unsent thread")
        XCTAssertEqual(ThreadHistoryStub.remainingPages,0)
    }

    func testContextRefreshReconcilesOnlyReturnedCoverageWithoutJumpingToLatest() async throws {
        let (model,root) = try await setup(pages:[(Array(46...75),0),(Array(55...65).filter { $0 != 60 },0),([999],0)])
        await model.openThread(root,around:60)
        let token = model.nativeThreadViewportToken
        model.noteThreadViewport(postID:60,atBottom:false,token:token,account:model.accountGeneration,channelID:23,rootID:1)
        await model.refreshOpenThreadPreservingReader()
        XCTAssertTrue(model.threadViewingContext);XCTAssertEqual(model.nativeThreadViewportToken,token)
        XCTAssertEqual(model.nativeThreadScrollPostID,60)
        XCTAssertEqual(model.replies.map(\.id),Array(46...75).filter { $0 != 60 })
        XCTAssertTrue(model.canLoadOlderReplies);XCTAssertEqual(ThreadHistoryStub.remainingPages,1)
    }

    func testRefreshAtLatestRetainsCachedOlderPagesWhenRecentWindowIsFull() async throws {
        let (model,root) = try await setup(pages:[(Array(61...90),0),(Array(31...61),0),(Array(62...91),0)])
        await model.openThread(root);await model.loadOlderReplies()
        let token = model.nativeThreadViewportToken
        model.noteThreadViewport(postID:88,atBottom:true,token:token,account:model.accountGeneration,channelID:23,rootID:1)
        await model.refreshOpenThreadPreservingReader()
        XCTAssertEqual(model.replies.map(\.id),Array(31...91));XCTAssertEqual(model.nativeThreadViewportToken,token)
        XCTAssertTrue(model.canLoadOlderReplies)
    }

    func testShortLatestRefreshRemovesDeletedBoundaryRepliesAndEstablishesExhaustion() async throws {
        let (model,root) = try await setup(pages:[(Array(61...90),0),([70,71],0)])
        await model.openThread(root)
        await model.refreshOpenThreadPreservingReader()
        XCTAssertEqual(model.replies.map(\.id),[70,71]);XCTAssertFalse(model.canLoadOlderReplies)
    }

    func testReconnectBridgesMoreThanOneMissedPageBeforePublishingTheNewTail() async throws {
        let (model,root) = try await setup(pages:[(Array(61...90),0),(Array(162...191),0),
            (Array(132...162),0),(Array(102...132),0),(Array(72...102),0)])
        await model.openThread(root);let token = model.nativeThreadViewportToken
        await model.refreshOpenThreadPreservingReader()
        XCTAssertEqual(model.replies.map(\.id),Array(61...191));XCTAssertEqual(model.nativeThreadViewportToken,token)
        XCTAssertTrue(model.canLoadOlderReplies);XCTAssertEqual(ThreadHistoryStub.remainingPages,0)
    }

    func testShortBridgeEstablishesEntireThreadAndRemovesDeletedCachedPrefix() async throws {
        let (model,root) = try await setup(pages:[([10],0),(Array(100...129),0),([20,100],0)])
        await model.openThread(root);await model.refreshOpenThreadPreservingReader()
        XCTAssertEqual(model.replies.map(\.id),[20]+Array(100...129));XCTAssertFalse(model.canLoadOlderReplies)
    }

    func testBridgeRequestBoundLeavesExistingHistoryIntactInsteadOfPublishingAHole() async throws {
        var pages:[([Int64],TimeInterval)] = [(Array(11...40),0),(Array(1000...1029),0)]
        for step in 0..<10 {
            let start = Int64(970-step*30),end = Int64(1000-step*30)
            pages.append((Array(start...end),0))
        }
        pages.append(([9999],0))
        let (model,root) = try await setup(pages:pages)
        await model.openThread(root);await model.refreshOpenThreadPreservingReader()
        XCTAssertEqual(model.replies.map(\.id),Array(11...40));XCTAssertNotNil(model.error)
        XCTAssertEqual(ThreadHistoryStub.remainingPages,1);XCTAssertFalse(model.loadingThread)
    }

    func testRefreshOfPreviouslyEmptyThreadCanDiscoverEarlierPages() async throws {
        let (model,root) = try await setup(pages:[([],0),(Array(61...90),0)])
        await model.openThread(root);XCTAssertFalse(model.canLoadOlderReplies)
        await model.refreshOpenThreadPreservingReader()
        XCTAssertEqual(model.replies.map(\.id),Array(61...90));XCTAssertTrue(model.canLoadOlderReplies)
    }

    func testSecondRefreshSupersedesDelayedSameThreadResponseWithoutChangingViewportTicket() async throws {
        let (model,root) = try await setup(pages:[([100],0),([101],0.06),([102],0)])
        await model.openThread(root);let token = model.nativeThreadViewportToken
        let started = expectation(description:"First refresh requested")
        ThreadHistoryStub.whenFirstPageRequested { started.fulfill() }
        let first = Task { await model.refreshOpenThreadPreservingReader() }
        await fulfillment(of:[started],timeout:1)
        await model.refreshOpenThreadPreservingReader();await first.value
        XCTAssertEqual(model.replies.map(\.id),[102]);XCTAssertEqual(model.nativeThreadViewportToken,token)
        XCTAssertFalse(model.loadingThread)
    }

    func testExplicitReopenAndCloseRejectDelayedPreservingRefresh() async throws {
        for close in [false,true] {
            let (model,root) = try await setup(pages:[([100],0),([101],0.04),([200],0)])
            await model.openThread(root)
            let started = expectation(description:"Preserving refresh started")
            ThreadHistoryStub.whenFirstPageRequested { started.fulfill() }
            let old = Task { await model.refreshOpenThreadPreservingReader() }
            await fulfillment(of:[started],timeout:1)
            if close { model.closeThread() } else { await model.openThread(root) }
            await old.value
            XCTAssertEqual(model.replies.map(\.id),close ? [] : [200]);XCTAssertFalse(model.loadingThread)
            XCTAssertEqual(model.threadRoot?.id,close ? nil : 1)
        }
    }

    func testPermissionLossAndAccountResetRejectDelayedRefresh() async throws {
        for reset in [false,true] {
            let (model,root) = try await setup(pages:[([100],0),([101],0.04)])
            await model.openThread(root)
            let started = expectation(description:"Refresh before scope loss")
            ThreadHistoryStub.whenFirstPageRequested { started.fulfill() }
            let old = Task { await model.refreshOpenThreadPreservingReader() }
            await fulfillment(of:[started],timeout:1)
            if reset { model.signOutLocally() } else { model.channels = [] }
            await old.value
            XCTAssertFalse(model.replies.contains(where:{ $0.id == 101 }))
            XCTAssertFalse(model.loadingThread)
        }
    }

    func testLateOlderPageCannotLandAfterPreservingRefreshHasFinished() async throws {
        let (model,root) = try await setup(pages:[(Array(61...90),0),(Array(31...61),0.06),(Array(62...91),0)])
        await model.openThread(root)
        let started = expectation(description:"Older page in flight")
        ThreadHistoryStub.whenFirstPageRequested { started.fulfill() }
        let old = Task { await model.loadOlderReplies() }
        await fulfillment(of:[started],timeout:1)
        await model.refreshOpenThreadPreservingReader();await old.value
        XCTAssertEqual(model.replies.map(\.id),Array(61...91));XCTAssertFalse(model.loadingThread)
    }

    func testInvalidLateLatestWindowDoesNotDiscardExistingReplies() async throws {
        let (model,root) = try await setup(pages:[([100],0),([101,101],0)])
        await model.openThread(root);let token = model.nativeThreadViewportToken
        await model.refreshOpenThreadPreservingReader()
        XCTAssertEqual(model.replies.map(\.id),[100]);XCTAssertEqual(model.nativeThreadViewportToken,token)
        XCTAssertNotNil(model.error);XCTAssertFalse(model.loadingThread)
    }

    func testThreadViewportRejectsOldTicketAndForeignScopeWithoutChangingRefreshAnchor() async throws {
        let (model,root) = try await setup(pages:[(Array(61...90),0),(Array(70...80),0),([999],0)])
        let old = model.nativeThreadViewportToken;await model.openThread(root,around:75)
        for (token,account,channel,rootID,id) in [
            (old,model.accountGeneration,Int64(23),Int64(1),Int64(80)),
            (model.nativeThreadViewportToken,model.accountGeneration+1,23,1,80),
            (model.nativeThreadViewportToken,model.accountGeneration,24,1,80),
            (model.nativeThreadViewportToken,model.accountGeneration,23,2,80),
            (model.nativeThreadViewportToken,model.accountGeneration,23,1,999)] {
            model.noteThreadViewport(postID:id,atBottom:true,token:token,account:account,channelID:channel,rootID:rootID)
        }
        await model.refreshOpenThreadPreservingReader()
        XCTAssertTrue(model.threadViewingContext);XCTAssertEqual(ThreadHistoryStub.remainingPages,1)
        XCTAssertEqual(model.replies.map(\.id),Array(61...90))
    }

    func testEarlierPagesPreserveCurrentRepliesAndExcludeRootAndOverlappingCursor() async throws {
        let (model, root) = try await setup(pages: [
            (Array(61...90), 0), ([1] + Array(31...61), 0), ([1, 29, 30, 31], 0)
        ])
        await model.openThread(root)
        XCTAssertTrue(model.canLoadOlderReplies)
        await model.loadOlderReplies()
        XCTAssertEqual(model.replies.map(\.id), Array(31...90))
        await model.loadOlderReplies()
        XCTAssertEqual(model.replies.map(\.id), Array(29...90))
        XCTAssertFalse(model.canLoadOlderReplies)
        XCTAssertFalse(model.loadingThread)
    }

    func testContextNewerPagesUseLastReplyCursorAndRetainReaderScopeUntilExplicitLatest() async throws {
        let (model,root) = try await setup(pages:[(Array(61...90),0),(Array(90...120),0),([120,121],0),([500],0)])
        await model.openThread(root,around:90);let token = model.nativeThreadViewportToken
        model.noteThreadViewport(postID:70,atBottom:false,token:token,account:model.accountGeneration,channelID:23,rootID:1)
        model.draft = "Unsent main forward paging";model.replyDraft = "Unsent reply forward paging"
        XCTAssertTrue(model.canLoadNewerReplies)
        await model.loadNewerReplies()
        XCTAssertEqual(model.replies.map(\.id),Array(61...120));XCTAssertTrue(model.canLoadNewerReplies)
        let first = try XCTUnwrap(ThreadHistoryStub.requests.last)
        XCTAssertEqual(first["post_id"],"90");XCTAssertEqual(first["thread_id"],"1")
        XCTAssertEqual(first["prev_count"],"0");XCTAssertEqual(first["next_count"],"30")
        await model.loadNewerReplies()
        XCTAssertEqual(model.replies.map(\.id),Array(61...121));XCTAssertFalse(model.canLoadNewerReplies)
        XCTAssertEqual(ThreadHistoryStub.requests.last?["post_id"],"120")
        XCTAssertTrue(model.threadViewingContext);XCTAssertEqual(model.nativeThreadViewportToken,token)
        XCTAssertEqual(model.draft,"Unsent main forward paging");XCTAssertEqual(model.replyDraft,"Unsent reply forward paging")
        await model.openThread(root)
        XCTAssertFalse(model.canLoadNewerReplies);XCTAssertFalse(model.threadViewingContext)
        XCTAssertNotEqual(model.nativeThreadViewportToken,token);XCTAssertEqual(model.replies.map(\.id),[500])
    }

    func testNewerBoundaryOnlyPageExhaustsWithoutRepeatingOrAddingTheCursor() async throws {
        let (model,root) = try await setup(pages:[([89,90],0),([90],0),([999],0)])
        await model.openThread(root,around:90);await model.loadNewerReplies()
        XCTAssertEqual(model.replies.map(\.id),[89,90]);XCTAssertFalse(model.canLoadNewerReplies)
        await model.loadNewerReplies();XCTAssertEqual(ThreadHistoryStub.remainingPages,1)
        model.closeThread();XCTAssertFalse(model.canLoadNewerReplies)
    }

    func testLateNewerPageCannotPublishAfterCloseReopenOrPermissionLoss() async throws {
        for change in 0..<3 {
            let (model,root) = try await setup(pages:[([89,90],0),([90,91],0.04),([200],0)])
            await model.openThread(root,around:90)
            let began = expectation(description:"Newer replies held")
            ThreadHistoryStub.whenFirstPageRequested { began.fulfill() }
            let pending = Task { await model.loadNewerReplies() };await fulfillment(of:[began],timeout:1)
            if change == 0 { model.closeThread() }
            else if change == 1 { await model.openThread(root) }
            else { model.channels = [] }
            await pending.value
            XCTAssertFalse(model.replies.contains(where:{ $0.id == 91 }));XCTAssertFalse(model.loadingThread)
            if change == 1 { XCTAssertEqual(model.replies.map(\.id),[200]) }
        }
    }

    func testPreservingRefreshRetiresInFlightForwardPageWithoutChangingContextTicket() async throws {
        let (model,root) = try await setup(pages:[([89,90],0),([90,1000],0.05),(Array(80...100),0)])
        await model.openThread(root,around:90);let token = model.nativeThreadViewportToken
        let began = expectation(description:"Forward page before reconnect")
        ThreadHistoryStub.whenFirstPageRequested { began.fulfill() }
        let pending = Task { await model.loadNewerReplies() };await fulfillment(of:[began],timeout:1)
        await model.refreshOpenThreadPreservingReader();await pending.value
        XCTAssertEqual(model.replies.map(\.id),Array(80...100));XCTAssertFalse(model.replies.contains(where:{ $0.id == 1000 }))
        XCTAssertEqual(model.nativeThreadViewportToken,token);XCTAssertTrue(model.threadViewingContext)
        XCTAssertTrue(model.canLoadNewerReplies);XCTAssertFalse(model.loadingThread)
    }

    func testInvalidForwardThreadMembershipLeavesContextAndRetryAvailable() async throws {
        let (model,root) = try await setup(pages:[([89,90],0)])
        await model.openThread(root,around:90)
        var invalid = post(91);invalid["thread_id"] = 999
        ThreadHistoryStub.configure([(try JSONSerialization.data(withJSONObject:["success":true,"data":["posts":[invalid]]]),0)])
        await model.loadNewerReplies()
        XCTAssertEqual(model.replies.map(\.id),[89,90]);XCTAssertTrue(model.canLoadNewerReplies)
        XCTAssertTrue(model.threadViewingContext);XCTAssertNotNil(model.error);XCTAssertFalse(model.loadingThread)
    }

    func testSlowOldRequestCannotOverwriteReopenedSameThread() async throws {
        let (model, root) = try await setup(pages: [([100], 0.08), ([900], 0)])
        let started = expectation(description: "First thread request has reached the server")
        ThreadHistoryStub.whenFirstPageRequested { started.fulfill() }
        let old = Task { await model.openThread(root) }
        await fulfillment(of: [started], timeout: 1)
        await model.openThread(root)
        await old.value
        XCTAssertEqual(model.replies.map(\.id), [900])
        XCTAssertFalse(model.loadingThread)
    }

    func testClosingThreadRejectsItsLateHistoryResponse() async throws {
        let (model, root) = try await setup(pages: [([100], 0.05)])
        let started = expectation(description: "Thread request has reached the server")
        ThreadHistoryStub.whenFirstPageRequested { started.fulfill() }
        let pending = Task { await model.openThread(root) }
        await fulfillment(of: [started], timeout: 1)
        model.closeThread()
        await pending.value
        XCTAssertNil(model.threadRoot)
        XCTAssertTrue(model.replies.isEmpty)
        XCTAssertFalse(model.loadingThread)
    }
}

private final class ThreadHistoryStub: URLProtocol {
    private static let lock = NSLock()
    private static var pages: [(Data, TimeInterval)] = []
    private static var onFirstPage: (() -> Void)?
    private static var capturedRequests:[[String:String]] = []
    static var requests:[[String:String]] { lock.lock();defer { lock.unlock() };return capturedRequests }
    static func configure(_ values: [(Data, TimeInterval)]) {
        lock.lock(); defer { lock.unlock() }; pages = values; onFirstPage = nil;capturedRequests = []
    }
    static func whenFirstPageRequested(_ callback: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }; onFirstPage = callback
    }
    static var remainingPages:Int { lock.lock();defer { lock.unlock() };return pages.count }
    private static func next() -> (Data, TimeInterval) {
        lock.lock()
        let callback = onFirstPage; onFirstPage = nil
        let result = pages.isEmpty ? (Data(#"{"success":true,"data":{"posts":[]}}"#.utf8), 0) : pages.removeFirst()
        lock.unlock()
        callback?()
        return result
    }
    private var delivery: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let value: (Data, TimeInterval)
        if request.url!.path.contains("SYNO.API.Info") {
            value = (Data(#"{"success":true,"data":{"SYNO.Chat.Post":{"path":"entry.cgi","minVersion":1,"maxVersion":8,"requestFormat":"JSON"}}}"#.utf8), 0)
        } else {
            var data = request.httpBody ?? Data()
            if data.isEmpty,let stream = request.httpBodyStream {
                stream.open();defer { stream.close() };var buffer = [UInt8](repeating:0,count:2048)
                while stream.hasBytesAvailable { let count = stream.read(&buffer,maxLength:buffer.count);if count <= 0 { break };data.append(contentsOf:buffer.prefix(count)) }
            }
            var parts = URLComponents();parts.percentEncodedQuery = String(decoding:data,as:UTF8.self)
            let fields = Dictionary((parts.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last })
            Self.lock.lock();Self.capturedRequests.append(fields);Self.lock.unlock()
            value = Self.next()
        }
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: self.request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: value.0)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        delivery = task
        DispatchQueue.global().asyncAfter(deadline: .now() + value.1, execute: task)
    }
    override func stopLoading() { delivery?.cancel() }
}
