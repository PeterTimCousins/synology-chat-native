import Foundation

/// A selected local file holds its picker grant until removed, sent or signed out.
final class ChatPollLocalFile {
    let url:URL
    let size:Int64
    private let modified:Date
    private let inode:UInt64
    private let scoped:Bool
    init(_ url:URL) throws {
        self.url = url;scoped = url.startAccessingSecurityScopedResource()
        do {
            _ = try ChatAttachmentSelection.localFiles([url]);try ChatAttachmentSelection.requireAvailable([url])
            let attributes = try FileManager.default.attributesOfItem(atPath:url.path)
            guard let size = attributes[.size] as? NSNumber,let modified = attributes[.modificationDate] as? Date,let inode = attributes[.systemFileNumber] as? NSNumber else { throw ChatAPIError.invalidResponse }
            self.size = size.int64Value;self.modified = modified;self.inode = inode.uint64Value
        } catch { if scoped { url.stopAccessingSecurityScopedResource() };throw error }
    }
    deinit { if scoped { url.stopAccessingSecurityScopedResource() } }
    func requireUnchanged() throws {
        try ChatAttachmentSelection.requireAvailable([url])
        let attributes = try FileManager.default.attributesOfItem(atPath:url.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == size,attributes[.modificationDate] as? Date == modified,
              (attributes[.systemFileNumber] as? NSNumber)?.uint64Value == inode else { throw ChatPollError("The selected file changed. Remove it and choose it again before creating the poll.") }
    }
}
enum ChatPollAttachment {
    case local(ChatPollLocalFile),nas(ChatNASFile)
    var name:String { switch self { case .local(let file):return file.url.lastPathComponent;case .nas(let file):return file.name } }
    var size:Int64 { switch self { case .local(let file):return file.size;case .nas(let file):return file.additional.size } }
    var sourceLabel:String { if case .nas = self { return "NAS file" };return "Local file" }
}
struct ChatPollCreationFailure:LocalizedError {
    let knownUnsent:Bool
    let message:String
    var errorDescription:String? { message }
    static func unsent(_ error:Error)->Self { .init(knownUnsent:true,message:(error as? LocalizedError)?.errorDescription ?? "Could not prepare this poll. Nothing was sent.") }
    static let uncertain = Self(knownUnsent:false,message:"Poll delivery could not be confirmed. Check the conversation before creating another poll. Your draft and selected file are kept.")
}
extension ChatPollDraft {
    func createParameters(channelID:Int64) throws -> [String:ChatParameter] {
        let value = try validated();guard channelID > 0 else { throw ChatAPIError.invalidResponse }
        return ["channel_id":.integer(channelID),"message":.string(value.question),"choices":.array(value.choices.map { .object(["text":.string($0.text)]) }),"options":.object(["multiple":.bool(value.multiple),"anonymous":.bool(value.anonymous),"add_option":.bool(value.allowAdd),"expire_at":.integer(Int64(value.options.expire_at))])]
    }
    func multipartFields(channelID:Int64) throws -> [String:String] {
        let parameters = try createParameters(channelID:channelID),encoder = JSONEncoder()
        var fields = ["api":"SYNO.Chat.Post.Vote","method":"create","version":"1","channel_id":String(channelID),"message":try validated().question]
        for key in ["choices","options"] { fields[key] = String(decoding:try encoder.encode(parameters[key]!),as:UTF8.self) };return fields
    }
    func requireCreated(_ post:ChatPost,channelID:Int64,attachment:ChatPollAttachment? = nil) throws {
        let value = try validated(at:.distantPast),poll = post.props?.vote
        guard post.type == "vote",post.id > 0,post.channel_id == channelID,!post.isReply,(post.delete_at ?? 0) == 0,
              post.message.utf8.elementsEqual(value.question.utf8),["open","close"].contains(poll?.state ?? ""),poll?.choices.map(\.text) == value.choices.map(\.text),
              poll?.options.multiple == value.multiple,poll?.options.anonymous == value.anonymous,poll?.options.add_option == value.allowAdd,
              let expiry = poll?.options.expire_at,expiry.isFinite,abs(expiry-value.options.expire_at) < 1000 else { throw ChatAPIError.invalidResponse }
        if let attachment {
            let name:String
            if case .local = attachment { name = ChatMultipartBody.safeFilename(attachment.name) } else { name = attachment.name }
            guard let props = post.file_props,props.name?.utf8.elementsEqual(name.utf8) == true,
                  props.size == attachment.size else { throw ChatAPIError.invalidResponse }
        }
    }
}
