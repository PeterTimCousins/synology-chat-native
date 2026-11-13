import XCTest
@testable import SynologyChatNative

@MainActor final class NativeInterfaceZoomTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let name = "native-interface-zoom-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }; return defaults
    }
    func testCorruptStoredZoomCannotProduceInvalidLayout() throws {
        let defaults = try defaults()
        for value: Any in ["invalid", -1.0, 0.0, 0.49, 2.01, Double.nan, Double.infinity] {
            defaults.set(value,forKey:NativeInterfaceZoom.key)
            let zoom = NativeInterfaceZoom(defaults:defaults); zoom.fit(contentSize:.init(width:1600,height:1120))
            XCTAssertEqual(zoom.requested,1); XCTAssertEqual(zoom.effective,1)
        }
    }
    func testPersistedZoomFitsDisplayWithoutDestroyingUserPreference() throws {
        let defaults = try defaults(), zoom = NativeInterfaceZoom(defaults:defaults)
        zoom.set(2); zoom.fit(contentSize:.init(width:1000,height:700))
        XCTAssertEqual(zoom.effective,1.25); XCTAssertEqual(zoom.requested,2)
        XCTAssertEqual(NativeInterfaceZoom(defaults:defaults).requested,2)
        zoom.fit(contentSize:.init(width:1600,height:1120)); XCTAssertEqual(zoom.effective,2)
    }
    func testUntrustedNonfiniteRequestedZoomDoesNotOverwriteCurrentValue() throws {
        let defaults = try defaults(), zoom = NativeInterfaceZoom(defaults:defaults)
        zoom.set(1.25)
        for value in [-1,0,Double.nan,Double.infinity,4] { zoom.set(value) }
        XCTAssertEqual(zoom.requested,1.25); XCTAssertEqual(NativeInterfaceZoom(defaults:defaults).requested,1.25)
    }
    func testSteppingCannotExceedDisplayCapacityAndReachesResetExactly() {
        let zoom = NativeInterfaceZoom(); zoom.fit(contentSize:.init(width:1000,height:700))
        XCTAssertEqual(zoom.next(1,maximum:1.25),1.1)
        zoom.set(1.25); zoom.fit(contentSize:.init(width:1000,height:700))
        XCTAssertNil(zoom.next(1,maximum:1.25)); XCTAssertEqual(zoom.next(-1,maximum:1.25),1.1)
        zoom.set(1.1); zoom.fit(contentSize:.init(width:1000,height:700))
        XCTAssertEqual(zoom.next(-1,maximum:1.25),1)
        zoom.set(0.5); zoom.fit(contentSize:.init(width:1000,height:700)); XCTAssertNil(zoom.next(-1,maximum:1.25))
    }
    func testResetRemovesOnlyOwnPreference() throws {
        let defaults = try defaults(), zoom = NativeInterfaceZoom(defaults:defaults)
        defaults.set(true,forKey:NativeDesktopPreferences.menuBarKey)
        zoom.set(1.5); zoom.set(1)
        XCTAssertNil(defaults.object(forKey:NativeInterfaceZoom.key)); XCTAssertTrue(defaults.bool(forKey:NativeDesktopPreferences.menuBarKey))
        XCTAssertEqual(NativeInterfaceZoom(defaults:defaults).requested,1)
    }
    func testUnavailableOrTinyDisplayCannotGenerateZeroOrInfiniteScale() {
        for size in [CGSize.zero, .init(width:-1,height:600),.init(width:CGFloat.infinity,height:600)] {
            XCTAssertEqual(NativeInterfaceZoom.capacity(contentSize:size),1)
        }
        XCTAssertEqual(NativeInterfaceZoom.capacity(contentSize:.init(width:200,height:140)),0.5)
        let zoom = NativeInterfaceZoom(); zoom.fit(contentSize:.init(width:200,height:140)); XCTAssertEqual(zoom.effective,0.5)
        XCTAssertNil(zoom.next(1,maximum:Double.nan)); XCTAssertNil(zoom.next(1,maximum:0))
    }
}
