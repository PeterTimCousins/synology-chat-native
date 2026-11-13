import AppKit
import SwiftUI
import XCTest
@testable import SynologyChatNative

@MainActor final class NativeSnippetTests:XCTestCase {
    private func network()->URLSession { let c = URLSessionConfiguration.ephemeral;c.protocolClasses = [SnippetProtocol.self];return URLSession(configuration:c) }
    private func client() async throws -> ChatAPIClient {
        let api = try ChatAPIClient(session:.init(baseURL:URL(string:"https://snippet-fixture.invalid")!,sid:"synthetic",synoToken:"synthetic"),network:network(),makeAttachmentNetwork:network)
        try await api.discover();return api
    }
    private func post() throws -> ChatPost { try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:SnippetProtocol.post)) }
    private func model() async throws -> NativeChatPreviewModel {
        let model = NativeChatPreviewModel(restoreNotificationPreference:false,makeClient:{ session in
            func make()->URLSession { let c = URLSessionConfiguration.ephemeral;c.protocolClasses = [SnippetProtocol.self];return URLSession(configuration:c) }
            return try ChatAPIClient(session:session,network:make(),makeAttachmentNetwork:make)
        })
        await model.connect(using:.init(session:.init(baseURL:URL(string:"https://snippet-fixture.invalid")!,sid:"synthetic",synoToken:"synthetic"),username:"synthetic",importedFromOfficialApp:false))
        model.suspendLiveForProbe();model.liveStatus = .live;model.selection = 93;model.posts = [try post()]
        addTeardownBlock { @MainActor in model.signOutLocally() };return model
    }
    override func setUp() { super.setUp();SnippetProtocol.reset() }
    override func tearDown() { SnippetProtocol.observer = nil;SnippetProtocol.held = nil;super.tearDown() }
    func testSnippetMetadataAndExtensionlessPreviewAreRecoveredWithoutChangingCaption() async throws {
        SnippetProtocol.filename = "Dockerfile"
        let target = try post();XCTAssertEqual(target.file_props?.is_snippet,true);XCTAssertEqual(target.file_props?.snippet_lines,3)
        XCTAssertEqual(target.file_props?.snippet_preview,SnippetProtocol.text)
        let model = try await model();XCTAssertEqual(model.documentKind(target),.text);XCTAssertTrue(model.canReadSnippet(target));XCTAssertTrue(model.canPreviewDocument(target))
        XCTAssertEqual(model.messageText(target),"Synthetic snippet caption")
    }
    func testDraftCountsUTF8BytesRejectsUnsafeNamesAndPreservesWhitespace() throws {
        for filename in ["../private.swift","a/b.txt",".lease","","bad\nname"] { XCTAssertThrowsError(try NativeSnippetDraft(filename:filename,content:"x").validated()) }
        let value = NativeSnippetDraft(filename:"example.swift",caption:"",content:"  let x = 1\n\n")
        XCTAssertEqual(try value.validated().content,value.content);XCTAssertEqual(value.lineCount,3)
        XCTAssertThrowsError(try NativeSnippetDraft(content:"").validated())
        XCTAssertThrowsError(try NativeSnippetDraft(content:"bad\0text").validated())
        var boundary = NativeSnippetDraft(content:String(repeating:"x",count:NativeSnippetDraft.maximumBytes));XCTAssertNoThrow(try boundary.validated());boundary.content += "é";XCTAssertThrowsError(try boundary.validated())
        XCTAssertThrowsError(try NativeSnippetDraft(caption:String(repeating:"😀",count:1001),content:"x").validated())
    }
    func testLanguageCatalogueMapsStaticNamesAndKeepsSafeExtensions() throws {
        XCTAssertGreaterThanOrEqual(NativeSnippetLanguage.all.count,135);XCTAssertEqual(Set(NativeSnippetLanguage.all.map(\.id)).count,NativeSnippetLanguage.all.count)
        XCTAssertEqual(NativeSnippetLanguage.forFilename("EXAMPLE.SWIFT").id,"swift")
        XCTAssertEqual(NativeSnippetLanguage.forFilename("Dockerfile").id,"dockerfile")
        XCTAssertEqual(NativeSnippetLanguage.all.first(where:{ $0.id == "python" })?.filename(from:"example.js"),"example.py")
        XCTAssertEqual(NativeSnippetLanguage.all.first(where:{ $0.id == "dockerfile" })?.filename(from:"example.js"),"Dockerfile")
    }
    func testSyntaxLexerIsLiteralUnicodeSafeAndDoesNotHighlightKeywordsInsideStringsOrComments() throws {
        let text = "// let false 👋\nlet name = \"return 😀\"\nlet n = 42\n"
        let tokens = try NativeSnippetSyntax.tokens(text,language:"swift")
        XCTAssertEqual(tokens.filter { $0.kind == .keyword }.count,2)
        XCTAssertEqual(tokens.filter { $0.kind == .comment }.count,1)
        XCTAssertEqual(tokens.filter { $0.kind == .string }.count,1)
        XCTAssertEqual(tokens.filter { $0.kind == .number }.count,1)
        for token in tokens { XCTAssertNotNil(Range(token.range,in:text)) }
        XCTAssertTrue(try NativeSnippetSyntax.tokens(text,language:"plain_text").isEmpty)
        XCTAssertEqual(text,"// let false 👋\nlet name = \"return 😀\"\nlet n = 42\n")
    }
    func testSnippetStagingIsPrivateByteExactAndLeaseCleanupRemovesOnlyOwnedFile() throws {
        let draft = NativeSnippetDraft(filename:"example.swift",content:"let text = \"👋\"\n")
        let file = try draft.writeTemporary();defer { NativeSnippetTemporaryFiles.shared.remove(file) }
        XCTAssertEqual(try Data(contentsOf:file),Data(draft.content.utf8));XCTAssertEqual(file.lastPathComponent,draft.filename)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? Int,0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath:file.deletingLastPathComponent().path)[.posixPermissions] as? Int,0o700)
        NativeSnippetTemporaryFiles.shared.remove(file);XCTAssertFalse(FileManager.default.fileExists(atPath:file.deletingLastPathComponent().path))
    }
    func testCodeViewportStartsAtFirstColumnAndPreservesUserScrollDuringRemeasurement() {
        let scroll = NativeCodeEditor.CodeScrollView(frame:NSRect(x:0,y:0,width:500,height:100))
        let view = NativeCodeEditor.CodeTextView(frame:.zero)
        view.font = .monospacedSystemFont(ofSize:13,weight:.regular);view.textContainerInset = .init(width:16,height:14)
        view.isHorizontallyResizable = true;view.isVerticallyResizable = true;view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = .init(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        view.string = "Synthetic " + String(repeating:"long-line-",count:40)+"\n";view.setSelectedRange(.init(location:0,length:0))
        scroll.documentView = view;scroll.hasHorizontalScroller = true;scroll.hasVerticalRuler = true;scroll.verticalRulerView = CodeLineRuler(scroll:scroll,textView:view);scroll.rulersVisible = true
        NativeCodeEditor.sizeDocument(scroll);scroll.contentView.scroll(to:.zero)
        NativeCodeEditor.sizeDocument(scroll)
        XCTAssertEqual(scroll.contentView.bounds.origin.x,0,accuracy:0.1)
        XCTAssertGreaterThan(view.frame.width,scroll.contentSize.width)
        scroll.contentView.scroll(to:NSPoint(x:100,y:0));NativeCodeEditor.sizeDocument(scroll)
        XCTAssertEqual(scroll.contentView.bounds.origin.x,100,accuracy:0.1)
    }
    func testHostedReadOnlySnippetKeepsFirstColumnAfterSwiftUILayout() async throws {
        _ = NSApplication.shared
        let text = "Synthetic native multi-file thread-context b fixture. No private data.\n"
        let host = NSHostingView(rootView:NativeCodeEditor(text:.constant(text),filename:"synthetic.txt",editable:false,label:"Synthetic snippet viewport").frame(width:535,height:76))
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:535,height:76),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        window.contentView = host;host.layoutSubtreeIfNeeded()
        for _ in 0..<10 { try await Task.sleep(nanoseconds:20_000_000);host.layoutSubtreeIfNeeded() }
        @MainActor func find(_ view:NSView)->NativeCodeEditor.CodeScrollView? { if let scroll = view as? NativeCodeEditor.CodeScrollView { return scroll };for child in view.subviews { if let found = find(child) { return found } };return nil }
        let scroll = try XCTUnwrap(find(host)),view = try XCTUnwrap(scroll.documentView as? NSTextView)
        XCTAssertEqual(scroll.contentView.bounds.origin.x,0,accuracy:0.1,"scroll \(scroll.frame), clip \(scroll.contentView.frame) bounds \(scroll.contentView.bounds), text \(view.frame), glyph origin \(view.textContainerOrigin)")
        scroll.scrollerStyle = .legacy;scroll.tile();host.layoutSubtreeIfNeeded()
        let firstColumn = view.convert(view.textContainerOrigin,to:scroll).x
        let rulerEdge = scroll.verticalRulerView?.frame.maxX ?? 0
        XCTAssertGreaterThanOrEqual(firstColumn,rulerEdge,"The line-number ruler must not cover the first source characters. clip=\(scroll.contentView.frame), ruler=\(scroll.verticalRulerView?.frame ?? .zero), firstColumn=\(firstColumn)")
        window.contentView = nil;window.close()
    }
    func testUploadCacheLeasePreservesActiveFilesAndRecoversAbandonedBodies() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-snippet-lease-test-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false);defer { try? FileManager.default.removeItem(at:root) }
        let first = NativeMediaTemporaryFiles(root:root,namespace:"synthetic",purpose:"upload",acceptsFilename:{ $0 != ".lease" && ChatMultipartBody.safeFilename($0) == $0 })
        let live = try first.create(filename:"My source.py");try Data("synthetic live source".utf8).write(to:live)
        let second = NativeMediaTemporaryFiles(root:root,namespace:"synthetic",purpose:"upload",acceptsFilename:{ $0 != ".lease" && ChatMultipartBody.safeFilename($0) == $0 })
        XCTAssertTrue(FileManager.default.fileExists(atPath:live.path))
        let orphan = root.appendingPathComponent("native-chat-upload-v1-synthetic-abandoned")
        try FileManager.default.createDirectory(at:orphan,withIntermediateDirectories:false)
        try Data("SynologyChatNative upload cache v1\n".utf8).write(to:orphan.appendingPathComponent(".lease"))
        try Data("synthetic multipart bytes".utf8).write(to:orphan.appendingPathComponent("multipart.body"))
        let foreign = root.appendingPathComponent("native-chat-media-v1-synthetic-foreign")
        try FileManager.default.createDirectory(at:foreign,withIntermediateDirectories:false)
        second.cleanAbandoned();XCTAssertFalse(FileManager.default.fileExists(atPath:orphan.path));XCTAssertTrue(FileManager.default.fileExists(atPath:live.path));XCTAssertTrue(FileManager.default.fileExists(atPath:foreign.path))
        first.removeAll();XCTAssertFalse(FileManager.default.fileExists(atPath:live.path));XCTAssertTrue(FileManager.default.fileExists(atPath:foreign.path))
    }
    func testRawSnippetEndpointRejectsJSONBinaryAndOversizedResponses() async throws {
        let api = try await client();let original = SnippetProtocol.text
        let text = try await api.snippetText(postID:1);XCTAssertEqual(text,original)
        SnippetProtocol.mime = "application/json"
        do { _ = try await api.snippetText(postID:1);XCTFail("API JSON accepted as snippet text") } catch { }
        SnippetProtocol.mime = "text/plain";SnippetProtocol.raw = Data([0xff,0xfe])
        do { _ = try await api.snippetText(postID:1);XCTFail("Invalid UTF8 accepted") } catch { }
        SnippetProtocol.raw = Data(repeating:65,count:NativeSnippetDraft.maximumBytes+1)
        do { _ = try await api.snippetText(postID:1);XCTFail("Oversized text accepted") } catch { }
    }
    func testSnippetSetWireAndCanonicalEditPreserveCodeExactly() async throws {
        let model = try await model(),target = try post();var fields:[String:String] = [:]
        SnippetProtocol.observer = { api,value in if api == "SYNO.Chat.Post.Snippet",value["method"] == "set" { fields = value } }
        let value = NativeSnippetDraft(filename:"updated.py",caption:"Updated synthetic caption",content:"# literal <script>\nprint(\"Hello 😀\")\n")
        try await model.editSnippet(target,draft:value)
        XCTAssertEqual(fields["version"],"2");XCTAssertEqual(fields["post_id"],"1");XCTAssertNotNil(fields["snippet"]);XCTAssertNotNil(fields["file_name"]);XCTAssertNil(fields["channel_id"])
        XCTAssertEqual(model.posts[0].file_props?.name,value.filename);XCTAssertEqual(model.posts[0].message,value.caption);XCTAssertEqual(SnippetProtocol.text,value.content);XCTAssertTrue(model.pendingMessageActions.isEmpty)
    }
    func testUnchangedSuccessAndWrongAuthorCannotPublishAnEdit() async throws {
        let model = try await model(),target = try post();let value = NativeSnippetDraft(filename:"changed.swift",content:"let changed = true\n")
        SnippetProtocol.ignoreSet = true
        do { try await model.editSnippet(target,draft:value);XCTFail("Unconfirmed edit accepted") } catch { }
        XCTAssertEqual(model.posts[0].file_props?.name,"synthetic.swift");XCTAssertTrue(model.pendingMessageActions.isEmpty)
        SnippetProtocol.creator = 11;var sets = 0;SnippetProtocol.observer = { _,f in if f["method"] == "set" { sets += 1 } }
        do { try await model.editSnippet(target,draft:value);XCTFail("Other author edit accepted") } catch { }
        XCTAssertEqual(sets,0)
    }
    func testLateSnippetResponseCannotEscapeAfterSignOutAndDraftsAreCleared() async throws {
        let model = try await model(),target = try post(),started = expectation(description:"Snippet reading")
        SnippetProtocol.hold = true;SnippetProtocol.observer = { api,f in if api == "SYNO.Chat.Post.Snippet",f["method"] == "get" { started.fulfill() } }
        model.snippetDrafts["93:0"] = NativeSnippetDraft(content:"Private draft")
        let task = Task { try await model.snippetText(target) }
        await fulfillment(of:[started],timeout:2);model.signOutLocally();SnippetProtocol.held?.finishRaw();SnippetProtocol.held = nil
        do { _ = try await task.value;XCTFail("Stale snippet published after sign-out") } catch is CancellationError { }
        XCTAssertTrue(model.snippetDrafts.isEmpty)
    }
    func testCopyUsesCanonicalSnapshotAndWritesPrivateClipboardExactlyOnce() async throws {
        SnippetProtocol.text = "let cafe = \"e\u{301} 😀\"\r\n\t// Preserve Unicode and line endings\r\n"
        let model = try await model(),target = try post(),pasteboard = NSPasteboard(name:.init("native-snippet-private-"+UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Existing private clipboard",forType:.string);var writes = 0
        let selection = model.selection;model.draft = "Synthetic unsent text"
        try await model.copySnippet(target) { text in writes += 1;pasteboard.clearContents();return pasteboard.setString(text,forType:.string) }
        XCTAssertEqual(pasteboard.string(forType:.string),SnippetProtocol.text);XCTAssertEqual(Data(try XCTUnwrap(pasteboard.string(forType:.string)).utf8),Data(SnippetProtocol.text.utf8));XCTAssertEqual(writes,1)
        XCTAssertGreaterThanOrEqual(SnippetProtocol.postReads,2);XCTAssertGreaterThanOrEqual(SnippetProtocol.channelReads,2)
        XCTAssertEqual(model.selection,selection);XCTAssertEqual(model.draft,"Synthetic unsent text");XCTAssertEqual(SnippetProtocol.sets,0)
    }
    func testStaleLocalOrCanonicalSnippetMetadataNeverReachesClipboard() async throws {
        for change in ["local","remote-name","remote-caption","remote-author","deleted","duplicate","thread"] {
            SnippetProtocol.reset();let model = try await model(),target = try post();var writes = 0
            switch change {
            case "local":SnippetProtocol.filename = "changed.swift";model.posts = [try post()];SnippetProtocol.filename = "synthetic.swift"
            case "remote-name":SnippetProtocol.filename = "changed.swift"
            case "remote-caption":SnippetProtocol.caption = "Changed elsewhere"
            case "remote-author":SnippetProtocol.creator = 20
            case "deleted":SnippetProtocol.postOverrides["delete_at"] = 1000
            case "duplicate":SnippetProtocol.duplicatePost = true
            default:SnippetProtocol.postOverrides["thread_id"] = 99
            }
            do { try await model.copySnippet(target) { _ in writes += 1;return true };XCTFail(change) } catch { }
            XCTAssertEqual(writes,0,change);XCTAssertEqual(SnippetProtocol.rawReads,0,change);XCTAssertEqual(SnippetProtocol.sets,0);model.signOutLocally()
        }
    }
    func testChangedChannelScopeBeforeOrAfterRawReadPreventsCopy() async throws {
        for late in [false,true] {
            for change:[String:Any] in [["encrypted":true],["hide_global_at":1000],["is_closed":true],["is_joined":false],["type":"private"]] {
                SnippetProtocol.reset();let model = try await model(),target = try post();var writes = 0
                if late { SnippetProtocol.afterRaw = { SnippetProtocol.channelOverrides = change } } else { SnippetProtocol.channelOverrides = change }
                do { try await model.copySnippet(target) { _ in writes += 1;return true };XCTFail() } catch { }
                XCTAssertEqual(writes,0);XCTAssertEqual(SnippetProtocol.rawReads,late ? 1 : 0);model.signOutLocally()
            }
        }
    }
    func testMetadataChangeAfterRawResponseAndFailedClipboardHaveNoSuccessfulHandoff() async throws {
        let model = try await model(),target = try post();var writes = 0
        SnippetProtocol.afterRaw = { SnippetProtocol.filename = "new-version.swift" }
        do { try await model.copySnippet(target) { _ in writes += 1;return true };XCTFail() } catch { }
        XCTAssertEqual(writes,0)
        SnippetProtocol.filename = "synthetic.swift";SnippetProtocol.afterRaw = nil
        do { try await model.copySnippet(target) { _ in writes += 1;return false };XCTFail("Failed clipboard write must be reported") } catch { }
        XCTAssertEqual(writes,1)
    }
    func testHeldCopyAfterSelectionOrAccountChangeCannotWriteOrFollowUp() async throws {
        for signout in [false,true] {
            SnippetProtocol.reset();let model = try await model(),target = try post(),started = expectation(description:"Held copy raw response");var writes = 0
            SnippetProtocol.hold = true;SnippetProtocol.observer = { api,fields in if api == "SYNO.Chat.Post.Snippet",fields["method"] == "get" { started.fulfill() } }
            let operation = Task { try await model.copySnippet(target) { _ in writes += 1;return true } }
            await fulfillment(of:[started],timeout:2)
            if signout { model.signOutLocally() } else { model.selection = nil }
            let reads = SnippetProtocol.postReads,channels = SnippetProtocol.channelReads
            SnippetProtocol.held?.finishRaw();SnippetProtocol.held = nil
            do { try await operation.value;XCTFail() } catch { }
            XCTAssertEqual(writes,0);XCTAssertEqual(SnippetProtocol.postReads,reads);XCTAssertEqual(SnippetProtocol.channelReads,channels);model.signOutLocally()
        }
    }
    func testReviewedFullContentConflictBeyondPreviewStopsBeforeEdit() async throws {
        SnippetProtocol.previewOverride = "Unchanged preview\n";SnippetProtocol.text = "First unseen code\n";SnippetProtocol.sizeOverride = SnippetProtocol.text.utf8.count
        let model = try await model(),target = try post(),snapshot = try await model.snippetSnapshot(target)
        SnippetProtocol.text = "Other unseen code\n" // Same byte count and line count; metadata alone cannot detect this.
        XCTAssertEqual(SnippetProtocol.text.utf8.count,snapshot.content.utf8.count)
        let draft = NativeSnippetDraft(filename:"synthetic.swift",content:"My unsaved change\n")
        do { try await model.editSnippet(target,draft:draft,review:snapshot.review);XCTFail("Unreviewed remote content overwritten") }
        catch let failure as ChatSnippetEditFailure { XCTAssertFalse(failure.uncertain) }
        XCTAssertEqual(SnippetProtocol.sets,0);XCTAssertEqual(SnippetProtocol.text,"Other unseen code\n");XCTAssertTrue(model.pendingMessageActions.isEmpty)
    }
    func testReviewedEditConfirmsExactBytesAndDoesNotAcceptUnicodeNormalizedReplacement() async throws {
        let model = try await model(),target = try post(),snapshot = try await model.snippetSnapshot(target)
        let draft = NativeSnippetDraft(filename:"changed.swift",caption:"Synthetic changed caption",content:"let cafe = \"e\u{301}\"\n")
        SnippetProtocol.normalizeSet = { $0.precomposedStringWithCanonicalMapping }
        do { try await model.editSnippet(target,draft:draft,review:snapshot.review);XCTFail("Different UTF8 bytes reported saved") }
        catch let failure as ChatSnippetEditFailure { XCTAssertTrue(failure.uncertain) }
        XCTAssertEqual(SnippetProtocol.sets,1);XCTAssertEqual(model.posts.first?.file_props?.name,"synthetic.swift");XCTAssertTrue(model.pendingMessageActions.isEmpty)
    }
    func testLateEditAcknowledgementAfterSignoutSendsNoReadbackRequests() async throws {
        let model = try await model(),target = try post(),snapshot = try await model.snippetSnapshot(target),started = expectation(description:"Held edit response")
        SnippetProtocol.holdSet = true;SnippetProtocol.observer = { api,fields in if api == "SYNO.Chat.Post.Snippet",fields["method"] == "set" { started.fulfill() } }
        let operation = Task { try await model.editSnippet(target,draft:.init(filename:"new.swift",content:"Synthetic changed code\n"),review:snapshot.review) }
        await fulfillment(of:[started],timeout:2);model.signOutLocally()
        let reads = SnippetProtocol.postReads,raw = SnippetProtocol.rawReads,channels = SnippetProtocol.channelReads
        SnippetProtocol.heldSet?.finishJSON(["success":true,"data":[:]]);SnippetProtocol.heldSet = nil
        do { try await operation.value;XCTFail() } catch is CancellationError { }
        XCTAssertEqual(SnippetProtocol.postReads,reads);XCTAssertEqual(SnippetProtocol.rawReads,raw);XCTAssertEqual(SnippetProtocol.channelReads,channels);XCTAssertTrue(model.pendingMessageActions.isEmpty)
    }
    func testReviewedSuccessfulEditAllowsUnrelatedReactionChangesAndRejectsOldReview() async throws {
        let model = try await model(),target = try post(),snapshot = try await model.snippetSnapshot(target)
        SnippetProtocol.postOverrides["reactions"] = [["sticker_name":"1f44d","user_ids":[20]]]
        let draft = NativeSnippetDraft(filename:"new.swift",caption:"Reviewed synthetic edit",content:"let reviewed = true\n")
        try await model.editSnippet(target,draft:draft,review:snapshot.review)
        XCTAssertEqual(SnippetProtocol.sets,1);XCTAssertEqual(model.posts.first?.file_props?.name,"new.swift");XCTAssertEqual(SnippetProtocol.text,draft.content)
        do { try await model.editSnippet(target,draft:draft,review:snapshot.review);XCTFail("Old editor review may not save again") } catch { }
        XCTAssertEqual(SnippetProtocol.sets,1)
    }
    func testMetadataConflictIsKnownUnsentAndRequiresFreshEditorReview() async throws {
        let model = try await model(),target = try post(),snapshot = try await model.snippetSnapshot(target)
        SnippetProtocol.filename = "Changed-elsewhere.swift"
        do { try await model.editSnippet(target,draft:.init(filename:"My-edit.swift",content:"My retained draft\n"),review:snapshot.review);XCTFail() }
        catch let failure as ChatSnippetEditFailure { XCTAssertFalse(failure.uncertain) }
        XCTAssertEqual(SnippetProtocol.sets,0);XCTAssertEqual(model.posts.first?.file_props?.name,"synthetic.swift")
    }
    func testDefiniteSetRejectionPreservesReviewForSeparateCorrectedSave() async throws {
        let model = try await model(),target = try post(),snapshot = try await model.snippetSnapshot(target)
        SnippetProtocol.rejectSet = true
        do { try await model.editSnippet(target,draft:.init(filename:"new.swift",content:"Synthetic rejected edit\n"),review:snapshot.review);XCTFail() }
        catch ChatAPIError.server(let code) { XCTAssertEqual(code,117) }
        XCTAssertEqual(SnippetProtocol.text,snapshot.content);XCTAssertEqual(SnippetProtocol.sets,1)
        SnippetProtocol.rejectSet = false
        try await model.editSnippet(target,draft:.init(filename:"new.swift",content:"Synthetic corrected edit\n"),review:snapshot.review)
        XCTAssertEqual(SnippetProtocol.sets,2);XCTAssertEqual(model.posts.first?.file_props?.name,"new.swift")
    }
    func testSnippetWithoutFilenameMetadataStillUsesCanonicalReadAndCopy() async throws {
        SnippetProtocol.postOverrides["file_props"] = ["is_snippet":true,"snippet_preview":SnippetProtocol.text,"size":SnippetProtocol.text.utf8.count]
        let model = try await model(),target = try post();var copied:String?
        XCTAssertNil(target.file_props?.name);XCTAssertTrue(model.canReadSnippet(target))
        try await model.copySnippet(target) { copied = $0;return true }
        XCTAssertEqual(copied,SnippetProtocol.text);XCTAssertEqual(SnippetProtocol.sets,0)
    }
    func testDraftAndRevisionTrackUTF8ChangesWithoutTreatingReactionsAsEdits() throws {
        let first = NativeSnippetDraft(content:"e\u{301}"),second = NativeSnippetDraft(content:"é")
        XCTAssertNotEqual(first,second);XCTAssertFalse(first.hasSameBytes(as:second))
        SnippetProtocol.text = first.content;let before = try XCTUnwrap(ChatSnippetRevision(post()))
        SnippetProtocol.text = second.content;let after = try XCTUnwrap(ChatSnippetRevision(post()));XCTAssertNotEqual(before,after)
        SnippetProtocol.text = first.content;SnippetProtocol.postOverrides["reactions"] = [["sticker_name":"1f44d","user_ids":[10]]]
        XCTAssertEqual(before,try ChatSnippetRevision(post()))
    }

}

private final class SnippetProtocol:URLProtocol {
    static var text = "let number = 42\n// synthetic fixture\n"
    static var filename = "synthetic.swift"
    static var caption = "Synthetic snippet caption"
    static var creator = 10
    static var mime = "text/plain"
    static var raw:Data?
    static var ignoreSet = false
    static var hold = false
    static var held:SnippetProtocol?
    static var observer:((String,[String:String])->Void)?
    static var afterRaw:(()->Void)?
    static var channelOverrides:[String:Any] = [:],postOverrides:[String:Any] = [:]
    static var previewOverride:String?,sizeOverride:Int?
    static var duplicatePost = false,holdSet = false,rejectSet = false
    static var heldSet:SnippetProtocol?
    static var normalizeSet:((String)->String)?
    static var rawReads = 0,sets = 0,postReads = 0,channelReads = 0
    static var post:[String:Any] {
        var value:[String:Any] = ["post_id":1,"channel_id":93,"creator_id":creator,"type":"file","message":caption,"create_at":1000,"file_props":["name":filename,"size":sizeOverride ?? text.utf8.count,"is_image":false,"is_snippet":true,"snippet_lines":text.split(separator:"\n",omittingEmptySubsequences:false).count,"snippet_preview":previewOverride ?? text,"snippet_preview_more":false]]
        value.merge(postOverrides,uniquingKeysWith:{ _,new in new });return value
    }
    static var channel:[String:Any] {
        var value:[String:Any] = ["channel_id":93,"name":"Peter","type":"public","encrypted":false,"unread":0,"is_joined":true]
        value.merge(channelOverrides,uniquingKeysWith:{ _,new in new });return value
    }
    static func reset() { text = "let number = 42\n// synthetic fixture\n";filename = "synthetic.swift";caption = "Synthetic snippet caption";creator = 10;mime = "text/plain";raw = nil;ignoreSet = false;hold = false;held = nil;observer = nil;afterRaw = nil;channelOverrides = [:];postOverrides = [:];previewOverride = nil;sizeOverride = nil;duplicatePost = false;holdSet = false;rejectSet = false;heldSet = nil;normalizeSet = nil;rawReads = 0;sets = 0;postReads = 0;channelReads = 0 }
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        guard request.url?.scheme == "https",request.url?.host == "snippet-fixture.invalid" else { client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL));return }
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty,let stream = request.httpBodyStream { stream.open();defer { stream.close() };var b = [UInt8](repeating:0,count:4096);while stream.hasBytesAvailable { let n = stream.read(&b,maxLength:b.count);if n <= 0 { break };bytes.append(contentsOf:b.prefix(n)) } }
        var query = URLComponents();query.percentEncodedQuery = String(decoding:bytes,as:UTF8.self)
        let fields = Dictionary((query.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ _,last in last })
        let api = request.url!.lastPathComponent
        DispatchQueue.main.async { self.route(api:api,fields:fields) }
    }
    @MainActor private func route(api:String,fields:[String:String]) {
        let method = fields["method"] ?? ""
        Self.observer?(api,fields)
        if request.url!.path.contains("SYNO.API.Info") { finishJSON(["success":true,"data":Dictionary(uniqueKeysWithValues:["SYNO.Chat.Post.Snippet","SYNO.Chat.Post","SYNO.Chat.User","SYNO.Chat.Channel","SYNO.Chat.Misc","SYNO.Chat.Admin.Setting"].map { ($0,["path":"entry.cgi","minVersion":1,"maxVersion":8,"requestFormat":"JSON"] as [String:Any]) })]);return }
        switch (api,method) {
        case ("SYNO.Chat.Post.Snippet","get"):Self.rawReads += 1;if Self.hold { Self.held = self } else { finishRaw() }
        case ("SYNO.Chat.Post.Snippet","set"):
            Self.sets += 1
            if Self.rejectSet { finishJSON(["success":false,"error":["code":117]]);return }
            if !Self.ignoreSet {
                func string(_ key:String)->String { (try? JSONSerialization.jsonObject(with:Data(fields[key]!.utf8),options:.fragmentsAllowed)) as? String ?? "" }
                Self.filename = string("file_name");Self.caption = string("message");Self.text = Self.normalizeSet?(string("snippet")) ?? string("snippet")
            };if Self.holdSet { Self.heldSet = self } else { finishJSON(["success":true,"data":[:]]) }
        case ("SYNO.Chat.User","list"):finishJSON(["success":true,"data":["users":[["user_id":10,"username":"synthetic","nickname":"Peter"]]]])
        case ("SYNO.Chat.Channel","list"):Self.channelReads += 1;finishJSON(["success":true,"data":["channels":[Self.channel]]])
        case ("SYNO.Chat.Misc",_):finishJSON(["success":true,"data":["acls":[]]])
        case ("SYNO.Chat.Admin.Setting",_):finishJSON(["success":true,"data":["hide_post_url_preview":true,"file_size_limit":0]])
        case ("SYNO.Chat.Post","list"):Self.postReads += 1;finishJSON(["success":true,"data":["posts":Self.duplicatePost ? [Self.post,Self.post] : [Self.post]]])
        default:finishJSON(["success":false,"error":["code":400]])
        }
    }
    func finishRaw() { let bytes = Self.raw ?? Data(Self.text.utf8);Self.afterRaw?();finish(bytes,mime:Self.mime) }
    func finishJSON(_ data:[String:Any]) { finish(try! JSONSerialization.data(withJSONObject:data),mime:"application/json") }
    private func finish(_ data:Data,mime:String) { client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":mime])!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self) }
    override func stopLoading() { }
}
