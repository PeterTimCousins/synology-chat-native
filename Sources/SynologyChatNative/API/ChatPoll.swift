import Foundation

struct ChatPollChoice:Decodable,Identifiable,Equatable {
    let id:String
    let text:String
    let count:Int
    let voters:[Int64]?
    init(id:String,text:String,count:Int = 0,voters:[Int64]? = nil) { self.id = id;self.text = text;self.count = count;self.voters = voters }
}
struct ChatPollOptions:Decodable,Equatable {
    var multiple:Bool
    var anonymous:Bool
    var add_option:Bool
    var expire_at:Double
}
struct ChatPoll:Decodable,Equatable {
    let state:String
    let options:ChatPollOptions
    let choices:[ChatPollChoice]
    var totalSelections:Int { choices.reduce(0) { $0 + $1.count } }
    var totalLabel:String { "\(totalSelections) " + (options.multiple ? (totalSelections == 1 ? "selection" : "selections") : (totalSelections == 1 ? "vote" : "votes")) }
    func isOpen(at now:Date = Date())->Bool { state == "open" && (options.expire_at == 0 || options.expire_at > now.timeIntervalSince1970*1000) }
    func selected(by user:Int64)->[String] { choices.filter { $0.voters?.contains(user) == true }.map(\.id) }
    var sortedResults:[ChatPollChoice] { state == "open" ? choices : choices.enumerated().sorted { $0.element.count == $1.element.count ? $0.offset < $1.offset : $0.element.count > $1.element.count }.map(\.element) }
    func replacingChoices(_ choices:[ChatPollChoice]) throws -> ChatPoll {
        guard choices.count <= 10000,Set(choices.map(\.id)).count == choices.count,
              choices.allSatisfy({ !$0.id.isEmpty && $0.id.utf16.count <= 256 && $0.count >= 0 && $0.count <= 1_000_000 && ($0.voters ?? []).allSatisfy { $0 > 0 } }) else { throw ChatAPIError.invalidResponse }
        return ChatPoll(state:state,options:options,choices:choices)
    }
}
struct ChatPollDetails { let post:ChatPost;let poll:ChatPoll }
struct ChatPollDraftChoice:Identifiable,Equatable {
    let id = UUID()
    var serverID:String?
    var text:String
}
struct ChatPollDraft:Equatable {
    var question = ""
    var choices = [ChatPollDraftChoice(text:""),ChatPollDraftChoice(text:"")]
    var multiple = false
    var anonymous = false
    var allowAdd = false
    var expires = false
    var expiry = Date().addingTimeInterval(86400)
    init() { }
    init(details:ChatPollDetails) {
        question = details.post.message;choices = details.poll.choices.map { .init(serverID:$0.id,text:$0.text) }
        multiple = details.poll.options.multiple;anonymous = details.poll.options.anonymous;allowAdd = details.poll.options.add_option
        expires = details.poll.options.expire_at > 0
        expiry = expires ? Date(timeIntervalSince1970:details.poll.options.expire_at/1000) : Date().addingTimeInterval(86400)
    }
    func validated(at now:Date = Date()) throws -> ChatPollDraft {
        var value = self;value.question = question.trimmingCharacters(in:.whitespacesAndNewlines)
        value.choices = choices.map { .init(serverID:$0.serverID,text:$0.text.trimmingCharacters(in:.whitespacesAndNewlines)) }.filter { !$0.text.isEmpty }
        guard !value.question.isEmpty,value.question.utf16.count <= 120 else { throw ChatPollError("Enter a question of up to 120 characters.") }
        guard value.choices.count >= 2,value.choices.allSatisfy({ $0.text.utf16.count <= 120 }) else { throw ChatPollError("Add at least two options, each up to 120 characters.") }
        guard Set(value.choices.map(\.text)).count == value.choices.count else { throw ChatPollError("Each option must be different.") }
        guard !expires || (expiry.timeIntervalSince1970.isFinite && expiry > now && expiry < Date.distantFuture) else { throw ChatPollError("Choose a future closing time.") }
        return value
    }
    var options:ChatPollOptions { .init(multiple:multiple,anonymous:anonymous,add_option:allowAdd,expire_at:expires ? (expiry.timeIntervalSince1970*1000).rounded(.down) : 0) }
}
struct ChatPollError:LocalizedError {
    let message:String
    init(_ message:String) { self.message = message }
    var errorDescription:String? { message }
}
enum ChatPollAction { case vote([String]),addOption(String),close,edit(ChatPollDraft) }
