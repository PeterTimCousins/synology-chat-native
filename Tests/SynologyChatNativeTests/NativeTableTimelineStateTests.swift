#if DEBUG
import XCTest
@testable import SynologyChatNative

final class NativeTableTimelineStateTests:XCTestCase {
    private let scope = NativeTableTimelineState.Scope(account:1,channel:23,token:UUID())
    private func state(ids:[Int64] = [10,11,12])->NativeTableTimelineState {
        var state = NativeTableTimelineState()
        state.replace(scope:scope,postIDs:ids,older:true,newer:false,empty:false)
        _ = state.setWidth(600,scale:2)
        return state
    }
    func testExplicitRowsMapStableIDsAndDoNotDuplicatePaddingOrPosts() {
        var value = state(ids:[10,10,-1,11])
        XCTAssertEqual(value.rows,[.top,.older,.post(10),.post(11),.bottom])
        XCTAssertEqual(value.index(of:10),2);XCTAssertNil(value.index(of:99))
        value.replace(scope:scope,postIDs:[],older:false,newer:true,empty:true)
        XCTAssertEqual(value.rows,[.top,.empty,.newer,.bottom])
        XCTAssertEqual(value.height(of:.top),20);XCTAssertEqual(value.height(of:.bottom),21)
    }
    func testPrependAndRemovalRetainOnlyScalarMeasurementsForRemainingIDs() throws {
        var value = state()
        let ticket = try XCTUnwrap(value.ticket)
        XCTAssertTrue(value.commit(height:150,for:.post(11),ticket:ticket,scale:2))
        value.replace(scope:scope,postIDs:[8,9,10,11,12],older:true,newer:false,empty:false)
        XCTAssertEqual(value.height(of:.post(11)),150);XCTAssertEqual(value.index(of:11),5)
        value.replace(scope:scope,postIDs:[8,10],older:false,newer:false,empty:false)
        XCTAssertNil(value.heights[.post(11)]);XCTAssertEqual(value.rows,[.top,.post(8),.post(10),.bottom])
    }
    func testReaderScopeReplacementCannotReuseGeometryOrInputTicket() throws {
        var value = state();let old = try XCTUnwrap(value.ticket)
        XCTAssertTrue(value.commit(height:200,for:.post(10),ticket:old,scale:1))
        for replacement in [NativeTableTimelineState.Scope(account:2,channel:23,token:scope.token),.init(account:1,channel:24,token:scope.token),.init(account:1,channel:23,token:UUID())] {
            value.replace(scope:replacement,postIDs:[10],older:false,newer:false,empty:false)
            XCTAssertNil(value.heights[.post(10)]);XCTAssertFalse(value.accepts(old))
            XCTAssertFalse(value.commit(height:400,for:.post(10),ticket:old,scale:1))
        }
    }
    func testWidthUsesBackingPixelsRejectsInvalidAndInvalidatesOldMeasurement() throws {
        var value = state();let old = try XCTUnwrap(value.ticket)
        _ = value.commit(height:100,for:.post(10),ticket:old,scale:2)
        XCTAssertFalse(value.setWidth(600.1,scale:2));XCTAssertEqual(value.height(of:.post(10)),100)
        XCTAssertTrue(value.setWidth(601,scale:2));XCTAssertEqual(value.widthPixels,1202)
        XCTAssertNil(value.heights[.post(10)]);XCTAssertFalse(value.commit(height:100,for:.post(10),ticket:old,scale:2))
        for invalid in [Double.nan,.infinity,0,-1,Double.greatestFiniteMagnitude] { XCTAssertFalse(value.setWidth(invalid,scale:2)) }
        XCTAssertFalse(value.setWidth(600,scale:.nan));XCTAssertEqual(value.widthPixels,1202)
    }
    func testPresentationRevisionInvalidatesOnlyChangedRowAndRejectsQueuedOldTicket() throws {
        var value = state();let old = try XCTUnwrap(value.ticket)
        _ = value.commit(height:200,for:.post(10),ticket:old,scale:2)
        _ = value.commit(height:300,for:.post(11),ticket:old,scale:2)
        value.replace(scope:scope,postIDs:[10,11,12],older:true,newer:false,empty:false,presentations:[10:1])
        XCTAssertNil(value.heights[.post(10)]);XCTAssertEqual(value.heights[.post(11)],300)
        XCTAssertFalse(value.accepts(old))
    }
    func testInputCancellationRejectsQueuedHeightAndNavigationTicket() throws {
        var value = state();let old = try XCTUnwrap(value.ticket)
        value.userInput();XCTAssertFalse(value.accepts(old))
        XCTAssertFalse(value.commit(height:500,for:.post(10),ticket:old,scale:1))
        XCTAssertTrue(value.commit(height:500,for:.post(10),ticket:try XCTUnwrap(value.ticket),scale:1))
    }
    func testFiniteMeasuredHeightsRoundToBackingPixelAndRejectMissingOrStaleRows() throws {
        var value = state();let ticket = try XCTUnwrap(value.ticket)
        XCTAssertTrue(value.commit(height:100.1,for:.post(10),ticket:ticket,scale:2));XCTAssertEqual(value.height(of:.post(10)),100.5)
        XCTAssertFalse(value.commit(height:100.2,for:.post(10),ticket:ticket,scale:2))
        for invalid in [Double.nan,.infinity,0,-1] { XCTAssertFalse(value.commit(height:invalid,for:.post(10),ticket:ticket,scale:1)) }
        XCTAssertFalse(value.commit(height:100,for:.post(99),ticket:ticket,scale:1))
        XCTAssertFalse(value.commit(height:100,for:.post(10),ticket:ticket,scale:0))
    }
    func testFirstVisibleIDOffsetSurvivesPrependAndHeightChangesAheadOfIt() {
        let rows:[NativeTableTimelineState.Row] = [.top,.post(1),.post(2),.post(3),.bottom]
        let anchor = NativeTableTimelineState.Anchor.post(2,offset:-17.5)
        XCTAssertEqual(NativeTableTimelineState.target(for:anchor,rows:rows,origins:[0,20,120,220,320],viewport:100,document:341),137.5)
        let prepended:[NativeTableTimelineState.Row] = [.top,.post(9),.post(1),.post(2),.post(3),.bottom]
        XCTAssertEqual(NativeTableTimelineState.target(for:anchor,rows:prepended,origins:[0,20,220,520,620,720],viewport:100,document:741),537.5)
        XCTAssertEqual(NativeTableTimelineState.target(for:.bottom,rows:rows,origins:[],viewport:100,document:341),241)
    }
    func testInvalidAnchorGeometryNeverProducesNonfiniteScrollTarget() {
        let rows:[NativeTableTimelineState.Row] = [.post(1)]
        XCTAssertNil(NativeTableTimelineState.target(for:.post(2,offset:0),rows:rows,origins:[0],viewport:100,document:200))
        XCTAssertNil(NativeTableTimelineState.target(for:.post(1,offset:.nan),rows:rows,origins:[0],viewport:100,document:200))
        XCTAssertNil(NativeTableTimelineState.target(for:.post(1,offset:0),rows:rows,origins:[.infinity],viewport:100,document:200))
        XCTAssertNil(NativeTableTimelineState.target(for:.bottom,rows:rows,origins:[],viewport:.nan,document:200))
        XCTAssertEqual(NativeTableTimelineState.target(for:.bottom,rows:rows,origins:[],viewport:500,document:100),0)
        XCTAssertEqual(NativeTableTimelineState.target(for:.post(1,offset:100),rows:rows,origins:[0],viewport:100,document:200),0)
    }
    func testInvalidMeasurementKeepsNativeHeightUntilCurrentReplacementIsMeasured() throws {
        var value = state();let old = try XCTUnwrap(value.ticket)
        XCTAssertTrue(value.commit(height:147,for:.post(10),ticket:old,scale:1))
        value.replace(scope:scope,postIDs:[9,10,11,12],older:true,newer:false,empty:false,presentations:[10:2])
        XCTAssertNil(value.heights[.post(10)])
        XCTAssertEqual(value.height(of:.post(10)),147,"Invalidation alone must not silently change the native height provider")
        XCTAssertFalse(value.commit(height:71,for:.post(10),ticket:old,scale:1))
        XCTAssertEqual(value.height(of:.post(10)),147)
        XCTAssertTrue(value.commit(height:71,for:.post(10),ticket:try XCTUnwrap(value.ticket),scale:1))
        XCTAssertEqual(value.height(of:.post(10)),71)
        XCTAssertTrue(value.setWidth(700,scale:1));XCTAssertNil(value.heights[.post(10)])
        XCTAssertEqual(value.height(of:.post(10)),71)
        value.replace(scope:.init(account:2,channel:23,token:UUID()),postIDs:[10],older:false,newer:false,empty:false)
        XCTAssertEqual(value.height(of:.post(10)),90,"A different account must not inherit the former native geometry")
    }
    func testEqualEstimateMeasurementBecomesValidWithoutUnnecessaryNativeRetile() throws {
        var value = state()
        XCTAssertFalse(value.commit(height:90,for:.post(10),ticket:try XCTUnwrap(value.ticket),scale:1))
        XCTAssertEqual(value.heights[.post(10)],90,"Read visibility needs a real measurement even when it equals the estimate")
    }
    func testThreadHeaderRolesExcludeRootFromRepliesAndResolveRootAnchor() {
        var value = NativeTableTimelineState()
        let thread = NativeTableTimelineState.Scope(account:1,channel:23,token:UUID(),rootID:7000)
        value.replace(scope:thread,postIDs:[7000,7001,7001,-1,7002],older:true,newer:false,empty:false,threadRootID:7000,threadLatest:true)
        XCTAssertEqual(value.rows,[.top,.threadRoot(7000),.threadDivider,.threadLatest,.older,.post(7001),.post(7002),.bottom])
        XCTAssertEqual(value.index(of:7000),1)
        XCTAssertEqual(NativeTableTimelineState.target(for:.post(7000,offset:-5),rows:value.rows,origins:[0,20,120,129,169,209,309,409],viewport:100,document:430),25)
    }
    func testThreadRootScopeAndPresentationCannotInheritPriorRootGeometry() throws {
        var value = NativeTableTimelineState()
        let first = NativeTableTimelineState.Scope(account:1,channel:23,token:UUID(),rootID:7000)
        value.replace(scope:first,postIDs:[7001],older:false,newer:false,empty:false,presentations:[7000:1],threadRootID:7000)
        let ticket = try XCTUnwrap(value.ticket)
        XCTAssertTrue(value.commit(height:201,for:.threadRoot(7000),ticket:ticket,scale:2))
        value.replace(scope:first,postIDs:[7001],older:false,newer:false,empty:false,presentations:[7000:2],threadRootID:7000)
        XCTAssertNil(value.heights[.threadRoot(7000)]);XCTAssertEqual(value.height(of:.threadRoot(7000)),201)
        value.replace(scope:.init(account:1,channel:23,token:first.token,rootID:8000),postIDs:[8001],older:false,newer:false,empty:false,threadRootID:8000)
        XCTAssertFalse(value.accepts(ticket));XCTAssertNil(value.heights[.threadRoot(7000)])
        XCTAssertEqual(value.height(of:.threadRoot(8000)),90);XCTAssertNil(value.index(of:7000))
    }
}
#endif
