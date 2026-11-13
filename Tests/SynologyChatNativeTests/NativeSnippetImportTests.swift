import XCTest
import Darwin
@testable import SynologyChatNative

@MainActor final class NativeSnippetImportTests:XCTestCase {
    private func folder() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-snippet-import-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at:directory) };return directory
    }
    private func write(_ data:Data,name:String = "example.swift",in directory:URL) throws -> URL {
        let file = directory.appendingPathComponent(name);try data.write(to:file);return file
    }
    private func utf16(_ text:String,little:Bool) -> Data {
        var bytes = Data(little ? [0xff,0xfe] : [0xfe,0xff])
        for unit in text.utf16 { let low = UInt8(unit & 255),high = UInt8(unit >> 8);bytes.append(contentsOf:little ? [low,high] : [high,low]) };return bytes
    }
    private func settled(_ controller:NativeSnippetImportController) async throws {
        for _ in 0..<200 { if !controller.busy { return };try await Task.sleep(nanoseconds:5_000_000) };XCTFail("Import did not settle")
    }
    func testUTF8BOMAndBothUTF16OrdersPreserveUnicodeWhitespaceAndSourceBytes() throws {
        let directory = try folder(),text = "\tlet cafe = \"e\u{301} 😀\"\r\n\r\n"
        let cases = [Data(text.utf8),Data([0xef,0xbb,0xbf])+Data(text.utf8),utf16(text,little:true),utf16(text,little:false)]
        for (index,bytes) in cases.enumerated() {
            let file = try write(bytes,name:index == 0 ? "Dockerfile" : "source-\(index).swift",in:directory)
            let draft = try NativeSnippetFileReader.load(file)
            XCTAssertEqual(Data(draft.content.utf8),Data(text.utf8));XCTAssertEqual(draft.filename,file.lastPathComponent);XCTAssertEqual(draft.caption,"")
            XCTAssertEqual(try Data(contentsOf:file),bytes)
            if index == 0 { XCTAssertEqual(NativeSnippetLanguage.forFilename(draft.filename).id,"dockerfile") }
        }
    }
    func testCRLFAndCRCountAsOneLineBreakWhileFullDraftKeepsOriginalBytes() throws {
        let code = "first\r\nsecond\rthird\n",draft = NativeSnippetDraft(content:code)
        XCTAssertEqual(draft.lineCount,4);XCTAssertEqual(NativeSnippetDraft.preview(code,lines:2),"first\nsecond")
        XCTAssertEqual(Data(draft.content.utf8),Data(code.utf8))
        XCTAssertEqual(NativeSnippetDraft(content:String(repeating:"line\r\n",count:4000)).lineCount,4001)
        XCTAssertFalse(NativeSnippetDraft.previewIsTruncated("short\r\ncode"))
        XCTAssertTrue(NativeSnippetDraft.previewIsTruncated(String(repeating:"line\r\n",count:20)))
        XCTAssertTrue(NativeSnippetDraft.previewIsTruncated(String(repeating:"x",count:12001)))
    }
    func testInvalidBinaryEmptyAndMalformedUnicodeNeverProduceDraft() throws {
        let directory = try folder()
        for (index,bytes) in [Data(),Data([0xff]),Data([65,0,66]),Data([0xff,0xfe]),Data([0xff,0xfe,0x41]),Data([0xff,0xfe,0,0xd8]),Data([0xff,0xfe,0,0,0,0])].enumerated() {
            let file = try write(bytes,name:"invalid-\(index).txt",in:directory)
            XCTAssertThrowsError(try NativeSnippetFileReader.load(file));XCTAssertEqual(try Data(contentsOf:file),bytes)
        }
    }
    func testInputAndConvertedUTF8AreBothBoundedToExistingSnippetLimit() throws {
        let directory = try folder(),boundary = Data(repeating:65,count:NativeSnippetDraft.maximumBytes)
        let valid = try write(boundary,name:"boundary.txt",in:directory)
        XCTAssertEqual(try NativeSnippetFileReader.load(valid).content.utf8.count,NativeSnippetDraft.maximumBytes)
        XCTAssertThrowsError(try NativeSnippetFileReader.load(write(boundary+Data([65]),name:"large.txt",in:directory)))
        let expanding = try write(utf16(String(repeating:"漢",count:400000),little:true),name:"utf16.txt",in:directory)
        XCTAssertLessThan(try Data(contentsOf:expanding).count,NativeSnippetDraft.maximumBytes)
        XCTAssertThrowsError(try NativeSnippetFileReader.load(expanding))
    }
    func testOnlyRegularLocalFilesAreReadAndCancellationStopsBeforeAdoption() async throws {
        let directory = try folder(),source = try write(Data("Synthetic source\n".utf8),in:directory),link = directory.appendingPathComponent("link.swift"),pipe = directory.appendingPathComponent("pipe.txt")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:source);XCTAssertEqual(mkfifo(pipe.path,0o600),0)
        for file in [directory,link,pipe,directory.appendingPathComponent("missing.txt"),URL(string:"https://example.invalid/source.swift")!] { XCTAssertThrowsError(try NativeSnippetFileReader.load(file)) }
        let operation = Task { try NativeSnippetFileReader.load(source) };operation.cancel()
        do { _ = try await operation.value;XCTFail() } catch is CancellationError { }
        XCTAssertEqual(try Data(contentsOf:source),Data("Synthetic source\n".utf8))
    }
    func testReviewAdoptionPreservesDescriptionAndRejectsChangedDraftBytes() throws {
        let original = NativeSnippetDraft(filename:"old.swift",caption:"Keep these notes",content:"Existing code\n")
        let imported = NativeSnippetDraft(filename:"new.py",caption:"Ignored incoming caption",content:"print(\"Imported\")\r\n")
        let proposal = NativeSnippetImportProposal(original:original,imported:imported),next = try proposal.applying(to:original)
        XCTAssertTrue(proposal.replacesCurrentCode);XCTAssertEqual(next.filename,"new.py");XCTAssertEqual(next.caption,original.caption);XCTAssertEqual(Data(next.content.utf8),Data(imported.content.utf8));XCTAssertEqual(original.content,"Existing code\n")
        XCTAssertThrowsError(try proposal.applying(to:.init(filename:original.filename,caption:original.caption,content:"Changed while reading\n")))
        let unicode = NativeSnippetDraft(content:"e\u{301}"),sameLooking = NativeSnippetDraft(content:"é")
        XCTAssertThrowsError(try NativeSnippetImportProposal(original:unicode,imported:imported).applying(to:sameLooking))
        XCTAssertFalse(NativeSnippetImportProposal(original:.init(),imported:imported).replacesCurrentCode)
    }
    func testControllerRequiresExplicitReviewAndLeavesOriginalUntouchedOnCancelOrFailure() async throws {
        let directory = try folder(),file = try write(Data("Imported code\n".utf8),in:directory),original = NativeSnippetDraft(caption:"Retained notes",content:"Old draft\n"),controller = NativeSnippetImportController()
        controller.prepare(file,original:original,isCurrent:{ true });try await settled(controller)
        XCTAssertNotNil(controller.pending);XCTAssertEqual(original.content,"Old draft\n");XCTAssertNil(controller.failure)
        controller.dismissReview();XCTAssertNil(controller.pending);XCTAssertEqual(original.content,"Old draft\n")
        controller.prepare(file,original:original,isCurrent:{ true });try await settled(controller)
        let acceptedID = try XCTUnwrap(controller.pending?.id)
        let adopted = try controller.adopt(acceptedID,to:original,isCurrent:{ true });XCTAssertEqual(adopted.caption,original.caption);XCTAssertEqual(adopted.content,"Imported code\n");XCTAssertNil(controller.pending)
        let invalid = try write(Data([0xff]),name:"bad.txt",in:directory)
        controller.prepare(invalid,original:original,isCurrent:{ true });try await settled(controller)
        XCTAssertNil(controller.pending);XCTAssertNotNil(controller.failure);XCTAssertEqual(original.content,"Old draft\n")
        controller.report(CocoaError(.userCancelled));XCTAssertNil(controller.failure)
    }
    func testLateCancelledReadCannotReplaceNewImportAndChangedContextPublishesNothing() async throws {
        let gate = ImportReadGate(),controller = NativeSnippetImportController(read:{ file in
            if file.lastPathComponent == "first.swift" { await gate.wait() }
            return .init(filename:file.lastPathComponent,content:"Imported \(file.lastPathComponent)\n")
        }),original = NativeSnippetDraft(content:"Original draft")
        controller.prepare(URL(fileURLWithPath:"/private/tmp/first.swift"),original:original,isCurrent:{ true })
        for _ in 0..<100 { if await gate.started { break };await Task.yield() }
        let began = await gate.hasStarted();XCTAssertTrue(began)
        controller.cancel();controller.prepare(URL(fileURLWithPath:"/private/tmp/second.swift"),original:original,isCurrent:{ true });try await settled(controller)
        XCTAssertEqual(controller.pending?.imported.filename,"second.swift")
        await gate.release();try await Task.sleep(nanoseconds:20_000_000)
        XCTAssertEqual(controller.pending?.imported.filename,"second.swift")
        let secondGate = ImportReadGate(),stale = NativeSnippetImportController(read:{ _ in await secondGate.wait();return .init(filename:"stale.swift",content:"Old-account text") })
        var current = true
        stale.prepare(URL(fileURLWithPath:"/private/tmp/stale.swift"),original:original,isCurrent:{ current })
        for _ in 0..<100 { if await secondGate.started { break };await Task.yield() }
        current = false;await secondGate.release();try await settled(stale)
        XCTAssertNil(stale.pending);XCTAssertNil(stale.failure)
    }
    func testOldReviewCannotAdoptANewerUnreviewedFile() async throws {
        let controller = NativeSnippetImportController(read:{ file in .init(filename:file.lastPathComponent,content:file.lastPathComponent) }),original = NativeSnippetDraft(content:"Retained original")
        controller.prepare(URL(fileURLWithPath:"/private/tmp/first.swift"),original:original,isCurrent:{ true });try await settled(controller)
        let old = try XCTUnwrap(controller.pending)
        controller.prepare(URL(fileURLWithPath:"/private/tmp/second.py"),original:original,isCurrent:{ true });try await settled(controller)
        let fresh = try XCTUnwrap(controller.pending)
        XCTAssertThrowsError(try controller.adopt(old.id,to:original,isCurrent:{ true }))
        XCTAssertEqual(controller.pending?.id,fresh.id);XCTAssertEqual(original.content,"Retained original")
        let next = try controller.adopt(fresh.id,to:original,isCurrent:{ true });XCTAssertEqual(next.filename,"second.py");XCTAssertNil(controller.failure)
    }
    func testChangedEditorOrAccountAtFinalAdoptionCannotOverwriteDraft() async throws {
        let controller = NativeSnippetImportController(read:{ _ in .init(filename:"imported.swift",content:"Imported code") }),original = NativeSnippetDraft(content:"Original")
        controller.prepare(URL(fileURLWithPath:"/private/tmp/synthetic.swift"),original:original,isCurrent:{ true });try await settled(controller)
        let changed = NativeSnippetDraft(content:"Changed in editor"),firstID = try XCTUnwrap(controller.pending?.id)
        XCTAssertThrowsError(try controller.adopt(firstID,to:changed,isCurrent:{ true }));XCTAssertNil(controller.pending);XCTAssertNotNil(controller.failure);XCTAssertEqual(changed.content,"Changed in editor")
        controller.prepare(URL(fileURLWithPath:"/private/tmp/synthetic.swift"),original:original,isCurrent:{ true });try await settled(controller)
        let secondID = try XCTUnwrap(controller.pending?.id)
        XCTAssertThrowsError(try controller.adopt(secondID,to:original,isCurrent:{ false }));XCTAssertNil(controller.pending);XCTAssertEqual(original.content,"Original")
    }
}
private actor ImportReadGate {
    var started = false
    private var continuation:CheckedContinuation<Void,Never>?
    func wait() async { started = true;await withCheckedContinuation { continuation = $0 } }
    func hasStarted() -> Bool { started }
    func release() { continuation?.resume();continuation = nil }
}
