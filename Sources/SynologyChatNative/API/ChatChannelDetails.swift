import Foundation

/// The official client sends only dirty fields, trimmed on submission. Keeping a
/// patch avoids overwriting another client's edits to an untouched field.
struct ChatChannelDetailsDraft:Equatable {
    var name:String
    var purpose:String
    init(channel:ChatChannel) { name = channel.name;purpose = channel.purpose ?? "" }
    func patch(relativeTo original:ChatChannel) throws -> ChatChannelDetailsPatch {
        let newName = name.trimmingCharacters(in:.whitespacesAndNewlines)
        let newPurpose = purpose.trimmingCharacters(in:.whitespacesAndNewlines)
        let patch = ChatChannelDetailsPatch(name:name == original.name || newName == original.name ? nil : newName,
                                          purpose:purpose == (original.purpose ?? "") || newPurpose == (original.purpose ?? "") ? nil : newPurpose)
        try patch.validate();return patch
    }
}

struct ChatChannelDetailsPatch:Equatable {
    let name:String?
    let purpose:String?
    var isEmpty:Bool { name == nil && purpose == nil }
    func validate() throws {
        if let name {
            guard name == name.trimmingCharacters(in:.whitespacesAndNewlines),ChatNamedChannelInput.validationError(name:name,purpose:"") == nil else { throw ChatTransferError(message:"Use a channel name of up to 64 characters without spaces or reserved punctuation.") }
        }
        if let purpose {
            guard purpose == purpose.trimmingCharacters(in:.whitespacesAndNewlines),purpose.utf16.count <= 256 else { throw ChatTransferError(message:"Keep the channel purpose within 256 characters.") }
        }
    }
    func originalMatches(_ current:ChatChannel,original:ChatChannel) -> Bool {
        (name == nil || current.name == original.name) && (purpose == nil || (current.purpose ?? "") == (original.purpose ?? ""))
    }
    func confirmed(by current:ChatChannel) -> Bool { (name == nil || current.name == name) && (purpose == nil || (current.purpose ?? "") == purpose) }
}

struct ChatChannelDetailsFailure:LocalizedError {
    let uncertain:Bool
    let message:String
    var errorDescription:String? { message }
}

extension ChatChannel {
    // Named-channel metadata is plaintext in the official client, including
    // encrypted private channels. Message-key availability is unrelated here.
    // System-channel authority is additionally verified by the account model.
    var supportsDetailsEditing:Bool {
        id > 0 && ["public", "private"].contains(type) && (!encrypted || type == "private")
            && (id > 2 || (type == "public" && !encrypted))
            && is_joined == true && is_closed != true && (hide_global_at ?? 0) == 0
    }
    func hasSameDetailsScope(as original: ChatChannel) -> Bool {
        id == original.id && type == original.type && encrypted == original.encrypted
            && (!encrypted || channel_key_enc == original.channel_key_enc)
    }
}
