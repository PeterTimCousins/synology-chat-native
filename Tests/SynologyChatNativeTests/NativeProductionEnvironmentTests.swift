import AppKit
import SwiftUI
import XCTest
@testable import SynologyChatNative

@MainActor final class NativeProductionEnvironmentTests:XCTestCase {
    private final class Settings:ObservableObject {
        @Published var disabled = false
        @Published var rtl = false
    }
    private struct Content:View {
        @ObservedObject var settings:Settings
        let model:NativeChatPreviewModel
        var body:some View {
            NativeVirtualTimeline(model:model,onBottomChanged:{ _ in })
                .environment(\.nativeChatStyle,ChatAppearanceStyle.dark)
                .environment(\.layoutDirection,settings.rtl ? .rightToLeft : .leftToRight)
                .disabled(settings.disabled)
        }
    }
    private struct Harness {
        let settings:Settings
        let model:NativeChatPreviewModel
        let root:NSHostingView<Content>
        let window:NSWindow
        let document:NativeVirtualTimeline.Document
    }
    private func scrolls(_ view:NSView)->[NativeTimelineScrollView] {
        (view as? NativeTimelineScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls)
    }
    private func popups(_ view:NSView)->[NSPopUpButton] {
        (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap(popups)
    }
    private func settle(_ value:Harness) async throws {
        for _ in 0..<12 { try await Task.sleep(nanoseconds:15_000_000);value.root.layoutSubtreeIfNeeded() }
        XCTAssertFalse(value.window.isVisible)
    }
    private func make() async throws -> Harness {
        _ = NSApplication.shared
        let model = NativeChatPreviewModel(restoreNotificationPreference:false,notificationDefaults:nil)
        model.channels = [try JSONDecoder().decode(ChatChannel.self,from:Data(#"{"channel_id":23,"name":"Synthetic environment","type":"channel","encrypted":false,"unread":0}"#.utf8))]
        model.selection = 23;model.connected = true;model.liveStatus = .live
        model.posts = try (100..<130).map { id in
            try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:["post_id":id,"channel_id":23,"creator_id":id%2+10,"type":"normal","create_at":1000+id,"message":"Synthetic inherited environment \(id)"]))
        }
        model.scrollPostID = 120;model.draft = "Synthetic untouched environment draft"
        let settings = Settings(),root = NSHostingView(rootView:Content(settings:settings,model:model))
        let window = NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:680,height:520),styleMask:[],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false;window.contentView = root
        addTeardownBlock { @MainActor in window.contentView = nil;window.close() }
        var document:NativeVirtualTimeline.Document?
        for _ in 0..<60 {
            try await Task.sleep(nanoseconds:15_000_000);root.layoutSubtreeIfNeeded()
            document = scrolls(root).compactMap { $0.documentView as? NativeVirtualTimeline.Document }.first
            if document != nil { break }
        }
        let value = Harness(settings:settings,model:model,root:root,window:window,document:try XCTUnwrap(document))
        try await settle(value);model.scrollPostID = nil;try await settle(value)
        return value
    }
    private func control(_ value:Harness) throws -> (NativeVirtualTimeline.Cell,NSPopUpButton) {
        let index = try XCTUnwrap(value.document.canonicalRows.firstIndex(of:.post(120)))
        let cell = try XCTUnwrap(value.document.hostedView(forRow:index) as? NativeVirtualTimeline.Cell)
        let buttons = popups(cell);XCTAssertEqual(buttons.count,1)
        return (cell,try XCTUnwrap(buttons.first))
    }
    func testInheritedDisabledStateReachesNativeRowControlAndReenablesIt() async throws {
        let value = try await make(),(cell,button) = try control(value),host = try XCTUnwrap(cell.host)
        XCTAssertTrue(button.isEnabled)
        value.settings.disabled = true;try await settle(value)
        XCTAssertFalse(try control(value).1.isEnabled,"A row host must not reenable a disabled parent")
        XCTAssertTrue(try control(value).0.host === host)
        value.settings.disabled = false;try await settle(value)
        XCTAssertTrue(try control(value).1.isEnabled);XCTAssertTrue(try control(value).0.host === host)
        XCTAssertEqual(value.model.draft,"Synthetic untouched environment draft")
    }
    func testInheritedLayoutDirectionMovesNativeActionsWithoutReplacingHost() async throws {
        let value = try await make(),(cell,button) = try control(value),host = try XCTUnwrap(cell.host)
        let before = button.convert(button.bounds,to:cell)
        XCTAssertGreaterThan(before.midX,cell.bounds.midX)
        value.settings.rtl = true;try await settle(value)
        let (rtlCell,rtlButton) = try control(value),after = rtlButton.convert(rtlButton.bounds,to:rtlCell)
        XCTAssertLessThan(after.midX,rtlCell.bounds.midX,"Row must inherit the parent's RTL layout")
        XCTAssertTrue(rtlCell.host === host)
        value.settings.rtl = false;try await settle(value)
        let (restoredCell,restoredButton) = try control(value)
        XCTAssertEqual(restoredButton.convert(restoredButton.bounds,to:restoredCell).midX,before.midX,accuracy:1/value.window.backingScaleFactor)
        XCTAssertTrue(restoredCell.host === host);XCTAssertEqual(value.model.posts.map(\.id),Array(Int64(100)..<130))
    }
}
