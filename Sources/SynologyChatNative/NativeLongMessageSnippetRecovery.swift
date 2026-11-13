import Foundation
import CryptoKit

/// A local copy for review, not a send request. Keep both the message draft
/// and any independent snippet draft until delivery has been verified.
struct NativeLongMessageSnippetRecovery:Identifiable {
    let id = UUID()
    let accountGeneration:Int
    let channelID:Int64
    let rootID:Int64?
    let sourceText:String
    var attemptKey:String? = nil
    var deliveryNeedsReview:Bool { attemptKey.map { NativeSnippetRecoveryAttempts.needsReview($0) } ?? false }
    var restoredDraft:NativeSnippetDraft? = nil
    var storageKey:String { attemptKey ?? id.uuidString }
    var initialDraft:NativeSnippetDraft { restoredDraft ?? NativeSnippetDraft(content:sourceText) }

    init?(text:String,accountGeneration:Int,channelID:Int64,rootID:Int64?) {
        guard !ChatMessageText.isAllowed(text) else { return nil }
        self.sourceText = text;self.accountGeneration = accountGeneration
        self.channelID = channelID;self.rootID = rootID
    }

    func matches(currentText:String,accountGeneration:Int,channelID:Int64,rootID:Int64?) -> Bool {
        self.accountGeneration == accountGeneration && self.channelID == channelID && self.rootID == rootID
            && sourceText.utf8.elementsEqual(currentText.utf8)
    }
}

@MainActor extension NativeChatPreviewModel {
    func prepareLongMessageSnippet(inThread:Bool = false)->NativeLongMessageSnippetRecovery? {
        guard !isEditingMessage,canCreateSnippet(inThread:inThread),let channelID = selection else { return nil }
        guard var recovery = NativeLongMessageSnippetRecovery(text:inThread ? replyDraft : draft,accountGeneration:accountGeneration,
                     channelID:channelID,rootID:inThread ? threadRoot?.id : nil) else { return nil }
        if let scope = snippetRecoveryAccountScope { recovery.attemptKey = NativeSnippetRecoveryAttempts.key(scope:scope,channel:channelID,root:recovery.rootID,text:recovery.sourceText) }
        recovery.restoredDraft = longMessageSnippetDrafts[recovery.storageKey]
        return recovery
    }

    func retainLongMessageSnippet(_ recovery:NativeLongMessageSnippetRecovery,draft:NativeSnippetDraft) { longMessageSnippetDrafts[recovery.storageKey] = draft }
    func discardLongMessageSnippet(_ recovery:NativeLongMessageSnippetRecovery) { longMessageSnippetDrafts[recovery.storageKey] = nil }

    /// Called only after createSnippet has checked the uploaded snippet bytes.
    /// A newer edit, a replacement account or a different thread is untouched.
    func finishLongMessageSnippet(_ recovery:NativeLongMessageSnippetRecovery,created post:ChatPost) {
        guard connected,accountGeneration == recovery.accountGeneration,post.channel_id == recovery.channelID,
              post.creator_id == userID,post.file_props?.is_snippet == true,
              recovery.rootID.map({ post.isReply && post.thread_id == $0 }) ?? !post.isReply else { return }
        discardLongMessageSnippet(recovery)
        if let rootID = recovery.rootID {
            guard recovery.matches(currentText:threadDrafts[rootID] ?? "",accountGeneration:accountGeneration,
                                   channelID:post.channel_id,rootID:rootID) else { return }
            threadDrafts[rootID] = nil
        } else {
            guard recovery.matches(currentText:drafts[recovery.channelID] ?? "",accountGeneration:accountGeneration,
                                   channelID:post.channel_id,rootID:nil) else { return }
            drafts[recovery.channelID] = nil
        }
    }
}

/// Only a digest and a boolean are persisted, never message text or credentials.
/// A stopped/ambiguous upload stays guarded across closing and reopening the app.
enum NativeSnippetRecoveryAttempts {
    static func key(scope:String,channel:Int64,root:Int64?,text:String)->String {
        let bytes = try! JSONEncoder().encode([scope,String(channel),String(root ?? 0),text])
        return "nativeSnippetRecovery.dispatched." + SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined()
    }
    static func needsReview(_ key:String,defaults:UserDefaults = .standard)->Bool { defaults.bool(forKey:key) }
    static func markDispatched(_ key:String,defaults:UserDefaults = .standard) { defaults.set(true,forKey:key) }
    static func clearAfterReviewOrSuccess(_ key:String,defaults:UserDefaults = .standard) { defaults.removeObject(forKey:key) }
}
