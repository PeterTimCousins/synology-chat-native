import AppKit
import SwiftUI
import XCTest
@testable import SynologyChatNative

@MainActor final class NativeCodeEditorTextTests:XCTestCase {
    private final class Draft:ObservableObject {
        @Published var text:String
        init(_ text:String) { self.text = text }
    }
    private struct Editor:View {
        @ObservedObject var draft:Draft
        var body:some View { NativeCodeEditor(text:$draft.text,filename:"example.swift",label:"Synthetic code editor").frame(width:540,height:180) }
    }
    private func find(_ view:NSView)->NativeCodeEditor.CodeTextView? {
        if let editor = view as? NativeCodeEditor.CodeTextView { return editor }
        for child in view.subviews { if let editor = find(child) { return editor } };return nil
    }
    private func settle(_ host:NSView) async throws {
        for _ in 0..<12 { host.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:15_000_000) }
    }
    func testDraftEqualityDistinguishesEncodingChangesInEveryRetainedField() {
        let original = NativeSnippetDraft(filename:"café.swift",caption:"café",content:"let café = 1\n")
        var filename = original;filename.filename = "cafe\u{301}.swift"
        var caption = original;caption.caption = "cafe\u{301}"
        var content = original;content.content = "let cafe\u{301} = 1\n"
        for changed in [filename,caption,content] { XCTAssertNotEqual(changed,original);XCTAssertFalse(changed.hasSameBytes(as:original)) }
        XCTAssertEqual(original,original)
    }
    func testHostedEditorAdoptsByteDifferentCanonicallyEqualImportBothDirections() async throws {
        _ = NSApplication.shared
        let composed = "let café = \"é 😀\"\r\n",decomposed = "let cafe\u{301} = \"e\u{301} 😀\"\r\n"
        XCTAssertEqual(composed,decomposed);XCTAssertNotEqual(Data(composed.utf8),Data(decomposed.utf8))
        let draft = Draft(composed),host = NSHostingView(rootView:Editor(draft:draft))
        host.frame = NSRect(x:0,y:0,width:540,height:180);try await settle(host)
        let editor = try XCTUnwrap(find(host));XCTAssertEqual(Data(editor.string.utf8),Data(composed.utf8))
        draft.text = decomposed;try await settle(host)
        XCTAssertTrue(find(host) === editor);XCTAssertEqual(Data(editor.string.utf8),Data(decomposed.utf8))
        draft.text = composed;try await settle(host)
        XCTAssertTrue(find(host) === editor);XCTAssertEqual(Data(editor.string.utf8),Data(composed.utf8))
    }
    func testUTF16FileImportReachesHostedEditorWithoutChangingUnicodeOrLineEndings() async throws {
        _ = NSApplication.shared
        let text = "\tlet cafe = \"e\u{301} 😀\"\r\n\r\n"
        var bytes = Data([0xff,0xfe]);for unit in text.utf16 { bytes.append(UInt8(unit & 255));bytes.append(UInt8(unit >> 8)) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-code-import-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer { try? FileManager.default.removeItem(at:directory) }
        let file = directory.appendingPathComponent("example.swift");try bytes.write(to:file)
        let imported = try NativeSnippetFileReader.load(file),draft = Draft("Old editor text\n"),host = NSHostingView(rootView:Editor(draft:draft))
        host.frame = NSRect(x:0,y:0,width:540,height:180);try await settle(host)
        draft.text = imported.content;try await settle(host)
        XCTAssertEqual(Data(try XCTUnwrap(find(host)).string.utf8),Data(text.utf8));XCTAssertEqual(Data(draft.text.utf8),Data(text.utf8));XCTAssertEqual(try Data(contentsOf:file),bytes)
    }
    func testIdenticalTextRefreshPreservesSelectionAndSyntaxRangesStayInBounds() async throws {
        _ = NSApplication.shared
        let text = "let café = \"e\u{301} 😀\"\r\n",draft = Draft(text),host = NSHostingView(rootView:Editor(draft:draft))
        host.frame = NSRect(x:0,y:0,width:540,height:180);try await settle(host)
        let editor = try XCTUnwrap(find(host)),selection = NSRange(location:4,length:4)
        editor.setSelectedRange(selection);draft.text = text;try await settle(host)
        XCTAssertTrue(find(host) === editor);XCTAssertEqual(editor.selectedRange(),selection);XCTAssertEqual(Data(editor.string.utf8),Data(text.utf8))
        for token in try NativeSnippetSyntax.tokens(editor.string,language:"swift") { XCTAssertLessThanOrEqual(NSMaxRange(token.range),editor.string.utf16.count) }
    }
}
