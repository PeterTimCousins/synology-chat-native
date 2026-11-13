import XCTest
@testable import SynologyChatNative

final class ChatSearchSuggestionParityTests:XCTestCase {
    private struct Fixture:Decodable {
        struct Case:Decodable { let text,query:String;let caseSensitive:Bool;let score:Double }
        let cases:[Case]
    }
    func testMatcherMatchesIndependentlyExecutedVendorUTF16Scores() throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource:"SearchFuzzyContract",withExtension:"json",subdirectory:"Fixtures"))
        let fixture = try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:file));XCTAssertEqual(fixture.cases.count,32)
        for item in fixture.cases { XCTAssertEqual(ChatSearchMatch.score(item.text,query:item.query,caseSensitive:item.caseSensitive),item.score,accuracy:0.00000001,"\(item.text) / \(item.query)") }
    }
    func testEmptyAndWhitespaceSlotsOfferAllOperatorsWithoutTouchingAdjacentWords() throws {
        let ids = ["in:","has:","before:","from:","after:","filetype:","@","#"]
        for (text,location) in [("",0),("words ",6),("😀  trailing",3)] {
            let range = NSRange(location:location,length:0),trigger = try XCTUnwrap(ChatSearchCompletion.trigger(text:text,selection:range))
            XCTAssertEqual(trigger.prefix,"");XCTAssertEqual(trigger.range,range)
            let choices = ChatSearchQuery.suggestions(token:trigger.prefix,users:[],channels:[]);XCTAssertEqual(choices.map(\.id),ids)
            let after = try XCTUnwrap(choices.first { $0.id == "after:" }),edit = try XCTUnwrap(ChatSearchCompletion.applying(after,trigger:trigger,text:text,selection:range))
            XCTAssertEqual(edit.text,(text as NSString).replacingCharacters(in:range,with:"after:"));XCTAssertEqual(edit.selection.location,location+6)
        }
        XCTAssertEqual(ChatSearchQuery.suggestions("words ",users:[],channels:[]).map(\.id),ids)
        XCTAssertTrue(ChatSearchQuery.suggestions("\"literal ",users:[],channels:[]).isEmpty)
        XCTAssertNil(ChatSearchCompletion.trigger(text:"word",selection:NSRange(location:0,length:0)))
    }
    func testMentionAndHashtagOperatorLeaveCaretReadyForValueEntry() throws {
        for op in ["@","#"] {
            let trigger = try XCTUnwrap(ChatSearchCompletion.trigger(text:"",selection:NSRange(location:0,length:0)))
            let choice = try XCTUnwrap(ChatSearchQuery.suggestions(token:"",users:[],channels:[]).first { $0.id == op })
            let edit = try XCTUnwrap(ChatSearchCompletion.applying(choice,trigger:trigger,text:"",selection:trigger.selection))
            XCTAssertEqual(edit.text,op);XCTAssertEqual(edit.selection.location,1)
            XCTAssertEqual(ChatComposerEdit.insert("Peter",into:edit.text,selection:edit.selection).text,op+"Peter")
        }
    }
    func testFuzzyRankingFindsNoncontiguousNamesAndUsesStableScoreTies() {
        let users:[ChatSearchEntity] = [.init(id:1,label:"Other Peter",aliases:["Other Peter"]),.init(id:2,label:"Peter Cousins",aliases:["Peter Cousins"]),.init(id:3,label:"Peter Colleague",aliases:["Peter Colleague"])]
        XCTAssertEqual(ChatSearchQuery.suggestions(token:"from:pc",users:users,channels:[]).map(\.id),["from:u:2","from:u:3"])
        XCTAssertEqual(ChatSearchQuery.suggestions(token:"from:pe",users:users,channels:[]).map(\.id),["from:u:2","from:u:3","from:u:1"])
        XCTAssertTrue(ChatSearchQuery.suggestions(token:"fo",users:[],channels:[]).contains { $0.id == "from:" })
        XCTAssertEqual(ChatSearchQuery.suggestions(token:"has:bm",users:[],channels:[]).map(\.replacement),["has:bookmark"])
    }
    func testHundredPerGroupLimitAppliedAfterRankingAndInvalidDuplicateIDsCannotCreateRows() {
        var users = (1...150).map { ChatSearchEntity(id:Int64($0),label:"Long prefix target",aliases:["Long prefix target"]) }
        users.append(.init(id:151,label:"Target",aliases:["Target"]));users.append(users[0]);users.append(.init(id:0,label:"Target",aliases:["Target"]))
        let choices = ChatSearchQuery.suggestions(token:"target",users:users,channels:users)
        XCTAssertEqual(choices.filter { $0.group == "People" }.count,100);XCTAssertEqual(choices.filter { $0.group == "Conversations" }.count,100)
        XCTAssertEqual(Set(choices.map(\.id)).count,choices.count);XCTAssertEqual(choices.first?.id,"from:u:151")
        XCTAssertFalse(choices.contains { $0.id == "from:u:0" });XCTAssertTrue(choices.contains { $0.id == "in:@c:151" })
        let unnamed = ChatSearchEntity(id:900,label:"Unnamed account",aliases:[])
        XCTAssertEqual(ChatSearchQuery.suggestions(token:"from:",users:[unnamed],channels:[]).first?.replacement,"from:u:900")
    }
    func testAmbiguousCaseFoldedAndReservedAliasesStillResolveOnlyChosenIdentity() throws {
        let users:[ChatSearchEntity] = [.init(id:1,label:"Straße",aliases:["Straße"]),.init(id:2,label:"STRASSE",aliases:["STRASSE"]),.init(id:3,label:"u:2",aliases:["u:2"])]
        let choices = ChatSearchQuery.suggestions(token:"from:",users:users,channels:[])
        for choice in choices {
            let result = try ChatSearchQuery.parse(choice.replacement,users:users,channels:[])
            XCTAssertEqual(result.filters.authorIDs,[Int64(try XCTUnwrap(choice.id.split(separator:":").last))!])
        }
        XCTAssertEqual(choices.first { $0.id == "from:u:3" }?.replacement,"from:u:3")
    }
    func testEmptyTriggerCannotApplyAfterCaretOrSourceChangesAndQuotedSlotsStayLiteral() throws {
        let text = "words ",selection = NSRange(location:6,length:0),trigger = try XCTUnwrap(ChatSearchCompletion.trigger(text:text,selection:selection))
        let choice = try XCTUnwrap(ChatSearchQuery.suggestions(token:"",users:[],channels:[]).first)
        XCTAssertNil(ChatSearchCompletion.applying(choice,trigger:trigger,text:"other ",selection:selection))
        XCTAssertNil(ChatSearchCompletion.applying(choice,trigger:trigger,text:text,selection:NSRange(location:5,length:0)))
        XCTAssertNil(ChatSearchCompletion.trigger(text:"\"two words\"",selection:NSRange(location:5,length:0)))
        XCTAssertNil(ChatSearchCompletion.trigger(text:"from:\"two words\"",selection:NSRange(location:5,length:3)))
    }
    func testSearchSuggestionScopesExcludeEncryptedHiddenClosedUnjoinedAndInvalidChannels() throws {
        func channel(_ changes:[String:Any]) throws -> ChatChannel {
            var value:[String:Any] = ["channel_id":93,"name":"Synthetic scope","type":"private","encrypted":false,"unread":0,"is_joined":true]
            value.merge(changes,uniquingKeysWith:{ _,new in new });return try JSONDecoder().decode(ChatChannel.self,from:JSONSerialization.data(withJSONObject:value))
        }
        XCTAssertTrue(try channel([:]).supportsSearchSuggestion)
        XCTAssertTrue(try channel(["is_joined":NSNull()]).supportsSearchSuggestion)
        for change:[String:Any] in [["encrypted":true],["hide_global_at":1000],["is_closed":true],["is_joined":false],["channel_id":0]] { XCTAssertFalse(try channel(change).supportsSearchSuggestion) }
    }
}
