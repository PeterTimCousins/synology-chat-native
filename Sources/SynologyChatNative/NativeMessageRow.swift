import AppKit
import SwiftUI

struct NativeMessageRow: View {
    let post: ChatPost
    @ObservedObject var model: NativeChatPreviewModel
    var showsReplyAction = true
    var isContinuation = false
#if DEBUG
    var fixtureShowActions = false
#endif
    @Environment(\.nativeContainedMessageActions) private var containedMessageActions
    @Environment(\.nativeMessageEditorHostingChanged) private var editorHostingChanged
    @State private var editorOwner = UUID()
    @FocusState private var editFocused: Bool
    private enum ActionFocus:Hashable { case more,reaction,reply,save }
    @FocusState private var focusedAction:ActionFocus?
    private var actionsFocused:Bool { focusedAction != nil }
    @State private var hovered = false
    private var editing: Bool { model.activeMessageEditor == editorOwner }
    @State private var editedText = ""
    @State private var working = false
    @State private var confirmDelete = false
    @State private var showingReactions = false
    @State private var addedHashtagDestination: NativeHashtagDestination?
    @State private var showingPostHashtags = false
    @State private var showingReactionDetails = false
    @State private var detailReaction: String?
    @State private var showingReadStatus = false
    @State private var showingForward = false
    @State private var showingReminder = false
    @State private var readStatusUnread = false
    @State private var showingAuthorProfile = false

    private var actionPending: Bool { model.pendingMessageActions.contains(post.id) }
    private var compact: Bool { isContinuation && !editing }
    private var compactActionSpace:CGFloat {
        // Per-message native hosts cannot route input outside their own bounds.
        // Reserve a stable lane, avoiding text reflow when the actions appear.
        if containedMessageActions { return 132 }
        return 40
    }
    private var actionToolbarOffset:CGFloat {
        if compact && containedMessageActions { return 0 }
        return compact && quickActionsVisible ? -34 : -6
    }
    private var authorName: String { model.names[post.displayAuthorID] ?? "User \(post.displayAuthorID)" }

#if DEBUG
    /// Seed the real editor's existing state for hidden integration checks.
    /// This does not invoke or verify the menu's edit-authorisation path.
    func fixtureEditor(_ fixture:NativeMessageEditorFixture)->Self {
        var value = self
        value._editorOwner = State(initialValue:fixture.owner)
        value._editedText = State(initialValue:fixture.text)
        return value
    }
#endif

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if compact {
                Text(model.formattedDate(post.date,timeOnly:true))
                    .font(.system(size:9)).foregroundColor(NativeChatColors.muted)
                    .lineLimit(1).minimumScaleFactor(0.7).frame(width:34,height:20)
                    .opacity(hovered || actionsFocused ? 1 : 0)
                    .accessibilityLabel(authorName + ", " + model.formattedDate(post.date))
            } else {
                NativeUserIdentity(model:model,userID:post.displayAuthorID)
            }
            VStack(alignment: .leading, spacing: 7) {
            if !compact {
                authorHeader

            }
            if (post.delete_at ?? 0) > 0 {
                Text("Message deleted").italic().foregroundColor(.secondary)
            } else if editing {
                TextEditor(text: $editedText).font(.system(size: 14)).frame(minHeight: 70, maxHeight: 140)
                    .disabled(working)
                    .accessibilityLabel("Edit message").focused($editFocused)
                    .onAppear { DispatchQueue.main.async { editFocused = true } }
                    .onExitCommand { if !working { model.endMessageEditing(owner: editorOwner) } }
                NativeMessageLengthNotice(text: editedText)
                HStack {
                    Button("Cancel") { model.endMessageEditing(owner: editorOwner) }.keyboardShortcut(.cancelAction).disabled(working)
                    Button(working ? "Saving…" : "Save changes") {
                        guard !working,let session = model.messageEditorSession(owner:editorOwner) else { return }
                        let text = editedText,target = post
                        working = true
                        Task {
                            if await model.edit(target,text:text,owner:editorOwner,session:session),model.messageEditorSession(owner:editorOwner) == session {
                                model.endMessageEditing(owner:editorOwner)
                            }
                            working = false
                        }
                    }.keyboardShortcut(.return, modifiers: .command)
                        .disabled(working || actionPending || !ChatMessageText.isAllowed(editedText) || editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                if let origin = post.props?.forward {
                    if origin.isReminder {
                        HStack {
                            Label("Reminder",systemImage:"bell.badge")
                            Button("Open original message") { model.openReminderSource(post) }.buttonStyle(.link).disabled(!model.canOpenReminderSource(post))
                        }.font(.caption).foregroundColor(NativeChatColors.muted)
                        HStack {
                            Text("Message from " + (model.names[origin.origin_user_id] ?? "a member"))
                            if let date = origin.originDate { Text("· " + model.formattedDate(date)) }
                        }.font(.caption).foregroundColor(NativeChatColors.muted)
                    } else {
                        Label("Forwarded from " + (model.names[origin.origin_user_id] ?? "a member"),systemImage:"arrowshape.turn.up.right")
                            .font(.caption).foregroundColor(NativeChatColors.muted)
                    }
                }
                if post.type == "system" {
                    Text(post.systemEventText(names:model.names)).foregroundColor(NativeChatColors.muted)
                } else if post.type == "vote" {
                    NativePollCard(post:post,model:model)
                } else if post.type == "sticker", let name = model.stickerName(post) {
                    NativeStickerImage(assets: model.stickers, name: name, size: 160)
                } else if !post.message.isEmpty {
                    NativeMessageText(post: post, model: model)
                }
                NativeBotAttachmentsView(post: post, model: model)
                ForEach(model.linkPreviews(for: post)) { preview in
                    NativeLinkPreviewCard(post: post, item: preview, model: model)
                }
                if post.type == "file", post.file_props?.is_image == true, model.canPreviewThumbnail(post) {
                    Button { model.openImage(post) } label: { NativeImageThumbnail(post: post, model: model) }
                        .buttonStyle(.plain).accessibilityLabel("Open image: " + model.attachmentName(post))
                        .background {
#if DEBUG
                            NativeMessageActionMarker(postID:post.id,kind:"image-open")
#endif
                        }
                }
                if model.canReadSnippet(post) { NativeSnippetCard(post:post,model:model) }
                if post.type == "file",!model.canReadSnippet(post) {
                    NativeFileAttachmentCard(post: post, model: model)
                } else if post.message.isEmpty, !["system", "vote", "sticker", "file"].contains(post.type), model.botAttachments(for: post).isEmpty {
                    Text("Conversation event").font(.callout).foregroundColor(.secondary)
                }
                if compact, post.isPinned || post.is_star == true || (post.update_at ?? 0) > post.create_at {
                    HStack(spacing: 8) {
                        if (post.update_at ?? 0) > post.create_at { Text("edited") }
                        if post.isPinned { Label("Pinned",systemImage:"pin.fill") }
                        if post.is_star == true { Label("Saved",systemImage:"bookmark.fill") }
                    }.font(.caption2).foregroundColor(NativeChatColors.muted)
                }
                if showsReplyAction, post.type != "system", post.props?.forward?.isReminder != true, (post.comment_count ?? 0) > 0 {
                    Button { Task { await model.openThread(post) } } label: {
                        Label(NativeLocalizedStrings.count("%lld replies",Int64(post.comment_count ?? 0)),systemImage:"bubble.right")
                            .font(.system(size:12,weight:.semibold)).foregroundColor(NativeChatColors.green)
                    }.buttonStyle(.plain).padding(.vertical,2)
                        .help("Open thread").accessibilityLabel(NativeLocalizedStrings.count("Open thread with %lld replies",Int64(post.comment_count ?? 0)))
                }
                if model.canViewPostHashtags(post), let tags = post.hashtags_additional, !tags.isEmpty {
                    NativeReactionFlow {
                        ForEach(tags.filter { ChatHashtags.valid($0.hashtag) }) { tag in
                            Button("#" + tag.hashtag) { addedHashtagDestination = .init(name: tag.hashtag) }
                                .buttonStyle(.plain).font(.caption).foregroundColor(NativeChatColors.green)
                                .help("Added by " + (tag.user_id.flatMap { model.names[$0] } ?? "Unknown user"))
                                .accessibilityLabel("Browse added hashtag " + tag.hashtag)
                                .contextMenu { Button("Manage hashtags…") { showingPostHashtags = true } }
                        }
                    }
                }
                if !(post.reactions ?? []).isEmpty { reactionChips }
            }
        }
        .padding(.trailing,compact ? compactActionSpace : 0)
        }
        .font(.system(size: 14))
        .padding(.horizontal,8).padding(.vertical,compact ? 3 : 6)
        .frame(maxWidth:.infinity,alignment:.leading)
        .background(hovered && !editing ? NativeChatColors.messageHover : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius:8))
        .overlay(alignment:.topTrailing) {
            if !editing {
                messageToolbar.background {
#if DEBUG
                    NativeMessageActionMarker(postID:post.id,kind:"toolbar")
#endif
                }.padding(.trailing,4).offset(y:actionToolbarOffset)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .popover(isPresented:$showingReactions) {
            NativeReactionPicker(preferences:model.emojiPreferences) { kind in
                showingReactions = false
                Task { await model.toggleReaction(post,kind:kind) }
            }
        }
        .accessibilityElement(children:.contain)
        .accessibilityLabel(authorName + ", " + model.formattedDate(post.date))
        .contextMenu { messageActions }
        .popover(isPresented:$showingAuthorProfile) { NativeUserProfileView(model:model,userID:post.displayAuthorID) }
        .sheet(item: $addedHashtagDestination) { tag in NativeMessageSearchView(model: model, hashtag: tag.name, fixedChannelID: post.channel_id) }
        .sheet(isPresented: $showingPostHashtags) { NativePostHashtagsView(model: model, post: post) }
        .sheet(isPresented: $showingReactionDetails) {
            NativeReactionDetailsView(model: model, post: post, initialReaction: detailReaction)
        }
        .sheet(isPresented:$showingReadStatus) {
            NativeMessageReadStatusView(model:model,post:post,initialUnread:readStatusUnread)
        }
        .sheet(isPresented:$showingReminder) { NativeReminderEditor(model:model,post:post) }
        .sheet(isPresented:$showingForward) { NativeForwardMessageView(model:model,post:post) }
        .onAppear { if editing { editorHostingChanged?(editorOwner,true) } }
        .onChange(of: editing) { active in
            guard editing == active else { return }
            if !active { editedText = "" }
            editorHostingChanged?(editorOwner,active)
        }
        .onChange(of: model.connected) { connected in if !connected { showingReactions = false; addedHashtagDestination = nil; showingAuthorProfile = false } }
        .onChange(of: model.accountGeneration) { _ in showingAuthorProfile = false }
        .onDisappear { showingAuthorProfile = false;showingReminder = false;showingForward = false;showingReadStatus = false; addedHashtagDestination = nil; showingPostHashtags = false; showingReactionDetails = false; showingReactions = false; editedText = ""; model.endMessageEditing(owner: editorOwner);editorHostingChanged?(editorOwner,false) }
        .alert("Delete this message?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) { Task { await model.delete(post) } }
        } message: { Text("This removes your message from the conversation.") }
    }

    private var authorHeader: some View {
        HStack(spacing: 10) {
            NativeUserIdentity(model:model,userID:post.displayAuthorID,showsName:true,showsAvatar:false)
            Text(model.formattedDate(post.date,timeOnly:true))
                .font(.system(size:11)).foregroundColor(NativeChatColors.muted)
                .help(model.formattedDate(post.date)).accessibilityLabel(model.formattedDate(post.date))
            if let update = post.update_at, update > post.create_at {
                Text("edited").font(.caption2).foregroundColor(.secondary)
            }
            if post.isPinned {
                Image(systemName:"pin.fill").font(.system(size:11)).foregroundColor(NativeChatColors.green)
                    .accessibilityLabel("Pinned message").help("Pinned in this conversation")
            }
            if post.is_star == true {
                Image(systemName:"bookmark.fill").font(.system(size:11)).foregroundColor(NativeChatColors.green)
                    .accessibilityLabel("Saved message").help("Saved in your collection")
            }
            Spacer(minLength: 0)
        }.padding(.trailing,132)
    }

    private var quickActionsVisible:Bool {
#if DEBUG
        if fixtureShowActions { return true }
#endif
        return hovered || actionsFocused || showingReactions
    }
    private var messageToolbar:some View {
        HStack(spacing:2) {
            if quickActionsVisible, post.type != "system",post.props?.forward?.isReminder != true {
                Button { showingReactions = true } label: { Image(systemName:"face.smiling") }
                    .buttonStyle(NativeMessageQuickActionStyle()).help("Add a reaction")
                    .focused($focusedAction,equals:.reaction)
                    .accessibilityLabel("React to message from " + authorName).disabled(!model.canAct(on:post))
                if showsReplyAction {
                    Button { Task { await model.openThread(post) } } label: { Image(systemName:"bubble.right") }
                        .buttonStyle(NativeMessageQuickActionStyle()).help("Reply in thread").accessibilityLabel("Reply in thread")
                        .focused($focusedAction,equals:.reply)
                }
                Button { Task { await model.setBookmark(post,enabled:post.is_star != true) } } label: {
                    Image(systemName:post.is_star == true ? "bookmark.fill" : "bookmark")
                }.buttonStyle(NativeMessageQuickActionStyle())
                    .focused($focusedAction,equals:.save)
                    .foregroundColor(post.is_star == true ? NativeChatColors.green : NativeChatColors.muted)
                    .help(post.is_star == true ? "Remove from saved messages" : "Save message")
                    .accessibilityLabel(post.is_star == true ? "Remove from saved messages" : "Save message")
                    .disabled(!model.canAct(on:post))
            }
            actionsMenu.frame(width:28,height:28)
                .background {
#if DEBUG
                    NativeMessageActionMarker(postID:post.id,kind:"more")
#endif
                }
        }.padding(3)
            .background(quickActionsVisible ? NativeChatColors.surface : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius:8))
            .overlay(RoundedRectangle(cornerRadius:8).stroke(quickActionsVisible ? NativeChatColors.separator : Color.clear))
            .shadow(color:.black.opacity(quickActionsVisible ? 0.12 : 0),radius:3,y:2)
    }

    private var reactionChips: some View {
        NativeReactionFlow {
            ForEach(post.reactions ?? []) { reaction in
                reactionChip(reaction)
            }
        }
    }

    private func reactionChip(_ reaction: ChatReaction) -> some View {
        let kind = ChatReactionKind(rawValue: reaction.sticker_name)
        let actors = reaction.user_ids.map { userID in
            userID == model.userID ? "You" : (model.names[userID] ?? "User \(userID)")
        }.joined(separator: ", ")
        return Button {
            if let kind { Task { await model.toggleReaction(post, kind: kind) } }
        } label: {
            HStack(spacing: 4) {
                if let kind { Text(kind.emoji) }
                else { NativeStickerImage(assets: model.stickers, name: reaction.sticker_name, size: 22) }
                Text("\(reaction.user_ids.count)")
            }
            .font(.system(size: 12, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 4)
            .background(reaction.user_ids.contains(model.userID ?? -1) ? NativeChatColors.selected : NativeChatColors.elevated)
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).disabled(!model.canAct(on: post) || kind == nil)
            .background {
#if DEBUG
                NativeMessageActionMarker(postID:post.id,kind:"reaction:"+reaction.sticker_name)
#endif
            }
            .help(actors + " reacted with " + (kind?.displayName ?? reaction.sticker_name))
            .accessibilityLabel((kind?.displayName ?? reaction.sticker_name) + ", \(reaction.user_ids.count) reactions")
            .accessibilityValue(actors)
            .contextMenu {
                Button("View reaction details…") { detailReaction = reaction.sticker_name; showingReactionDetails = true }
                    .disabled(!model.canViewReactionDetails(post))
            }
    }

    private var actionsMenu: some View {
        Menu { messageActions } label: { Image(systemName:"ellipsis").font(.system(size:13,weight:.semibold)).foregroundColor(NativeChatColors.muted) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .focused($focusedAction,equals:.more)
            .accessibilityLabel("Message actions for " + authorName + ", " + model.formattedDate(post.date))
    }

    @ViewBuilder private var messageActions: some View {
            Button("View author profile…") { showingAuthorProfile = true }
                .disabled(!model.connected || model.directory.first(where: { $0.user_id == post.displayAuthorID })?.canViewProfile != true)
            Button("Remind me…") { showingReminder = true }.disabled(!model.canRemind(post))
            Button("Forward message…") { showingForward = true }.disabled(!model.canForward(post))
            Button("Copy message") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.messageText(post), forType: .string)
            }
            if model.canViewReadStatus(post) {
                Button("Read by…") { readStatusUnread = false; showingReadStatus = true }
                Button("Not read by…") { readStatusUnread = true; showingReadStatus = true }
            }
            if showsReplyAction { Button("Reply in thread") { Task { await model.openThread(post) } } }
            if !post.isReply,model.channels.first(where:{ $0.id == post.channel_id })?.encrypted == false {
                Button(post.isPinned ? "Unpin message" : "Pin message") {
                    Task { await model.setPinned(post,enabled:!post.isPinned) }
                }.disabled(!model.canPin(post))
            }
            if model.pinStateNeedsRefresh.contains(post.id) {
                Button("Verify pin state") { Task { _ = await model.refreshPinState(post) } }
                    .disabled(model.pendingMessageActions.contains(post.id))
            }
            Button(post.is_star == true ? "Remove from saved messages" : "Save message") {
                Task { await model.setBookmark(post,enabled:post.is_star != true) }
            }.disabled(!model.canAct(on:post))
            if model.canViewPostHashtags(post) { Button("Manage hashtags…") { showingPostHashtags = true } }
            Button("Reaction details…") { detailReaction = nil; showingReactionDetails = true }
                .disabled(!model.canViewReactionDetails(post))
            Button("Add reaction…") { showingReactions = true }.disabled(!model.canAct(on:post))
            Button("Toggle 👍 reaction") { Task { await model.toggleThumbsUp(post) } }.disabled(!model.canAct(on: post))
            if post.creator_id == model.userID && post.type != "system" {
                Divider()
                Button("Edit message") {
                    editedText = model.messageText(post);model.beginMessageEditing(owner:editorOwner,post:post)
                    editorHostingChanged?(editorOwner,true)
                }.disabled(post.type == "sticker" || post.type == "vote" || post.file_props?.is_snippet == true || !model.canChangeOwnMessage(post))
                Button("Delete message", role: .destructive) { confirmDelete = true }.disabled(!model.canChangeOwnMessage(post))
            }
    }
}

#if DEBUG
struct NativeMessageEditorFixture {
    let owner:UUID
    let text:String
}
#endif

struct NativeMessageLengthNotice: View {
    let text: String
    var convertToSnippet:(()->Void)? = nil
    var body: some View {
        if let warning = ChatMessageText.warning(for: text) {
            HStack(alignment:.firstTextBaseline,spacing:12) {
                Text(convertToSnippet == nil ? warning : "Message is too long (\(text.utf16.count.formatted())/2,000 characters). Send the full text as a snippet.").font(.caption).foregroundColor(.orange)
                if let convertToSnippet { Button("Convert to snippet",action:convertToSnippet).buttonStyle(NativeToolbarButtonStyle()) }
            }
        }
    }
}

struct NativeUploadStatusView: View {
    @ObservedObject var model: NativeChatPreviewModel
    var body: some View {
        if model.capturingScreenshot {
            HStack {ProgressView().controlSize(.small);Text("Select an area or window. Press Escape to cancel.").font(.caption);Spacer();Button("Cancel capture") {model.cancelScreenshotCapture()}.font(.caption)}
        } else if model.preparingComposerAttachment {
            HStack { ProgressView().controlSize(.small);Text("Preparing attachments…").font(.caption);Spacer();Button("Cancel preparation") { model.cancelAttachmentPreparation() }.font(.caption) }
        } else if model.uploading {
            HStack(spacing: 10) {
                ProgressView(value: model.uploadProgress?.fraction).progressViewStyle(.linear)
                    .frame(width: 80).accessibilityLabel("Attachment upload progress")
                Text(model.uploadProgress?.label ?? "Preparing attachment…")
                    .font(.caption).foregroundColor(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Button("Cancel upload") { model.cancelUpload() }.font(.caption)
            }
        }
    }
}

struct NativeThreadView: View {
    @ObservedObject var appearancePreferences = NativeAppearancePreferences.shared
    @State private var showNASPicker = false
    @State private var showDrivePicker = false
    @State private var pendingNASSelection:ChatNASSelection?
    @ObservedObject var model: NativeChatPreviewModel
    @State private var windowActive = false
    @State private var atBottom = false
    @State private var initialScroll = true
    @State private var showStickers = false
    @State private var showMentions = false
    @State private var showSnippet = false
    @State private var snippetRecovery:NativeLongMessageSnippetRecovery?
    @State private var composerSelection = NSRange(location: NSNotFound, length: 0)
    @State private var replyFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Thread").font(.system(size:19,weight:.bold))
                Spacer()
                if model.loadingThread || model.preparingComposerAttachment { ProgressView().controlSize(.small) }
                if let root = model.threadRoot, let follows = model.followsThread(root) {
                    Button {
                        Task { await model.setThreadSubscription(root,enabled:!follows) }
                    } label: { Label(follows ? "Following" : "Follow",systemImage:follows ? "bell.badge.fill" : "bell") }
                        .buttonStyle(NativeToolbarButtonStyle()).disabled(!model.canAct(on:root))
                        .help(follows ? "Stop following this thread" : "Follow this thread in your collection")
                        .accessibilityLabel(follows ? "Unfollow thread" : "Follow thread")
                }
                Button { model.closeThread() } label: { Image(systemName:"xmark") }
                    .buttonStyle(NativeToolbarButtonStyle()).accessibilityLabel("Close thread").help("Close thread")
                    .keyboardShortcut(.cancelAction).disabled(model.isEditingMessage)
            }.padding(20)
            Divider()
            if let error = model.error { Text(error).foregroundColor(.orange).font(.callout).padding(16) }
            threadTimeline.background(NativeConversationWallpaper(model: model, settings: appearancePreferences.followsAccount ? model.appearanceSettings : nil, behindMessages: true)).nativeConversationScrollDrop(model:model)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                NativeFormattingToolbar(text: Binding(get: { model.replyDraft }, set: { model.replyDraft = $0 }), selection: $composerSelection, focused: $replyFocused)
                    .disabled(model.isEditingMessage || model.sending)
                NativeAutocompleteComposer(model: model, channelID: model.threadRoot?.channel_id ?? -1, rootID: model.threadRoot?.id, text: Binding(get: { model.replyDraft }, set: { model.replyDraft = $0 }), selection: $composerSelection, focused: $replyFocused, label: "Reply to thread", minimumHeight: 60, maximumHeight:automaticallySizesReplyComposer ? 180 : 100,automaticallySizes:automaticallySizesReplyComposer, onAttachmentInput:{ model.receiveComposerAttachment($0,inThread:true) })
                    .id(model.threadRoot?.id).disabled(model.isEditingMessage)
                    .font(.system(size: 14)).scrollContentBackground(.hidden)
                    .padding(.horizontal,2)
                    .accessibilityLabel("Reply to thread")
                NativeUploadStatusView(model: model)
                NativeSlashSuggestions(model: model, inThread: true)
            NativeMessageLengthNotice(text: model.replyDraft,convertToSnippet:model.prepareLongMessageSnippet(inThread:true) == nil ? nil : { snippetRecovery = model.prepareLongMessageSnippet(inThread:true) })
                HStack {
                    Menu {
                        Button("From this Mac…") {Task {await model.chooseAttachment(inThread:true)}}
                        Button("Capture screenshot…") {model.captureScreenshot(inThread:true)}.disabled(model.preparingComposerAttachment || model.attachmentBatch != nil)
                                    Button("From NAS…") {showNASPicker = true}.disabled(!model.canChooseNASFiles(inThread:true))
                                    Button("From Synology Drive…") {showDrivePicker = true}.disabled(!model.canChooseDriveFiles(inThread:true))
                    } label: {Image(systemName:"paperclip")}
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .frame(width: 30, height: 30)
                        .accessibilityLabel("Attach a file to thread").help("Attach a file to thread")
                        .disabled(!model.canComposeInThread || !ChatMessageText.isAllowed(model.replyDraft))
                    Button { showStickers = true } label: { Image(systemName: "face.smiling") }
                        .accessibilityLabel("Emoji and stickers for thread").disabled(!model.canComposeInThread)
                        .popover(isPresented: $showStickers) {
                            NativeComposerEmojiPicker(preferences: model.emojiPreferences, chooseEmoji: { kind in
                                let edit = ChatComposerEdit.insert(kind.emoji, into: model.replyDraft, selection: composerSelection)
                                model.replyDraft = edit.text; composerSelection = edit.selection
                                showStickers = false; replyFocused = true
                            }, chooseSticker: { name in
                                showStickers = false; Task { await model.sendSticker(name, inThread: true) }
                            }, assets: model.stickers)
                        }
                    Button { showMentions = true } label: { Image(systemName: "at") }
                        .accessibilityLabel("Mention a member in thread").disabled(!model.canComposeInThread)
                        .popover(isPresented: $showMentions) {
                            if let channelID = model.threadRoot?.channel_id {
                                NativeMentionPicker(model: model, channelID: channelID) { id in
                                    let edit = ChatComposerEdit.insert("@u:\(id)", into: model.replyDraft, selection: composerSelection, separated: true)
                                    model.replyDraft = edit.text; composerSelection = edit.selection
                                    showMentions = false; replyFocused = true
                                }
                            }
                        }
                    Button { snippetRecovery = nil;showSnippet = true } label: { Image(systemName:"chevron.left.forwardslash.chevron.right") }.accessibilityLabel("Create a snippet in thread").disabled(!model.canCreateSnippet(inThread:true))
                    Text("⌘ Return to reply").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button(model.sending ? "Sending…" : "Reply") { Task { await model.sendReply() } }
                        .keyboardShortcut(.return, modifiers: .command).buttonStyle(NativeSendButtonStyle())
                        .disabled(!model.canReply)
                }.buttonStyle(NativeToolbarButtonStyle())
            }.padding(14)
                .background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:12))
                .overlay(RoundedRectangle(cornerRadius:12).stroke(NativeChatColors.separator))
                .padding(16)
        }.frame(width:threadViewSize.width,height:threadViewSize.height).background(NativeChatColors.canvas)
            .foregroundColor(NativeChatColors.text).tint(NativeChatColors.green).nativeChatAppearance()
            .background(NativeWindowActivity { active in
                windowActive = active; updateReadVisibility()
            })
            .onChange(of: model.loadingThread) { loading in
                if loading && model.replies.isEmpty { initialScroll = true }
                updateReadVisibility()
            }
            .onChange(of: model.liveStatus) { _ in updateReadVisibility() }
            .onChange(of: model.imageViewerPost?.id) { _ in updateReadVisibility() }
            .onChange(of:model.documentPreviewPost?.id) { _ in updateReadVisibility() }
        .onChange(of:model.documentPreviewIsPresented) { _ in updateReadVisibility() }
            .onChange(of:model.attachmentBatch?.id) { _ in updateReadVisibility() }
            .onChange(of:model.preparingComposerAttachment) { _ in updateReadVisibility() }
            .onChange(of: model.isEditingMessage) { editing in
                replyFocused = !editing
                if editing { showMentions = false; showStickers = false }
            }
            .onChange(of: model.connected) { connected in if !connected { showMentions = false; showStickers = false } }
            .onChange(of: model.threadRoot?.id) { _ in
                showMentions = false; showStickers = false
                composerSelection = NSRange(location: NSNotFound, length: 0)
                atBottom = false; initialScroll = true
                model.updateThreadReadingVisibility(active:false,atBottom:false)
            }
            .sheet(isPresented:$showSnippet) { if let root = model.threadRoot { NativeSnippetComposer(model:model,channelID:root.channel_id,rootID:root.id) } }
            .sheet(item:$snippetRecovery) { recovery in NativeSnippetComposer(model:model,channelID:recovery.channelID,rootID:recovery.rootID,recovery:recovery) }
            .sheet(isPresented:Binding(get:{ model.pollAttachmentOwner == nil && model.searchDocumentOwner == nil && model.collectionDocumentOwner == nil && model.documentPreviewIsPresented },set:{ if !$0 && model.pollAttachmentOwner == nil && model.searchDocumentOwner == nil && model.collectionDocumentOwner == nil && model.documentPreviewIsPresented { model.closeDocumentPreview() } })) {
            NativeDocumentPreview(model:model)
        }
        .sheet(isPresented:$showDrivePicker) {NativeDriveFilePicker(model:model,inThread:true)}
        .sheet(isPresented:$showNASPicker,onDismiss:{if let pendingNASSelection {model.stageNASFiles(pendingNASSelection)};pendingNASSelection = nil}) {NativeNASFilePicker(model:model,inThread:true) {pendingNASSelection = $0}}
        .sheet(isPresented:Binding(get:{ model.attachmentBatch != nil && model.attachmentBatch?.rootID == model.threadRoot?.id },set:{ if !$0 { model.dismissAttachmentBatch() } })) {
            if let batch = model.attachmentBatch { NativeAttachmentBatchView(model:model,batch:batch) }
        }
        .sheet(isPresented: Binding(get: { model.pollAttachmentOwner == nil && model.searchImageOwner == nil && model.imageViewerPost != nil }, set: { if !$0,model.pollAttachmentOwner == nil,model.searchImageOwner == nil { model.closeImageViewer() } })) {
                NativeImageViewer(model: model)
            }
            .onDisappear { model.updateThreadReadingVisibility(active: false, atBottom: false) }
            .nativeConversationFileDrop(model:model,inThread:true)
    }
    var usesNativeVirtualTimeline = NativeChatAppConfiguration.usesNativeMessageViewport
    func usingNativeMessageViewport()->Self { var value = self;value.usesNativeVirtualTimeline = true;return value }
#if DEBUG
    var fixtureThreadEditors:[Int64:NativeMessageEditorFixture] = [:]
    var nativeVirtualFixtureSize:NSSize?
    var nativeVirtualAutomaticComposer = false
    func usingNativeVirtualTimeline(fixtureEditors:[Int64:NativeMessageEditorFixture] = [:],fixtureSize:NSSize? = nil,automaticallySizesComposer:Bool = false)->Self {
        var value = self;value.usesNativeVirtualTimeline = true;value.fixtureThreadEditors = fixtureEditors;value.nativeVirtualFixtureSize = fixtureSize;value.nativeVirtualAutomaticComposer = automaticallySizesComposer;return value
    }
#endif
    private var automaticallySizesReplyComposer:Bool {
#if DEBUG
        return usesNativeVirtualTimeline && nativeVirtualAutomaticComposer
#else
        return false
#endif
    }
    private var threadViewSize:NSSize {
#if DEBUG
        if usesNativeVirtualTimeline,let size = nativeVirtualFixtureSize,size.width.isFinite,size.height.isFinite,size.width > 0,size.height > 0 { return size }
#endif
        return NSSize(width:640,height:680)
    }
    @ViewBuilder private var threadTimeline:some View {
        if usesNativeVirtualTimeline {
#if DEBUG
            NativeVirtualTimeline(model:model,onBottomChanged:{ bottom in
                atBottom = bottom;updateReadVisibility()
            },fixtureEditors:fixtureThreadEditors,inThread:true,traceViewportGeometry:automaticallySizesReplyComposer)
#else
            NativeVirtualTimeline(model:model,onBottomChanged:{ bottom in
                atBottom = bottom;updateReadVisibility()
            },inThread:true)
#endif
        } else { standardThreadTimeline }
    }
    private var standardThreadTimeline:some View {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if let root = model.threadRoot {
                            NativeMessageRow(post: root, model: model, showsReplyAction: false)
                            Divider()
                        }
                        if model.threadViewingContext, let root = model.threadRoot {
                            Button("Back to latest replies") { Task { await model.openThread(root) } }
                                .buttonStyle(.link).disabled(model.loadingThread)
                        }
                        if model.canLoadOlderReplies {
                            Button(model.loadingThread ? "Loading…" : "Load earlier replies") {
                                Task { await model.loadOlderReplies() }
                            }.buttonStyle(.link).disabled(model.loadingThread)
                        }
                        if model.replies.isEmpty && !model.loadingThread { Text("No replies yet.").foregroundColor(.secondary) }
                        ForEach(Array(model.replies.enumerated()), id: \.element.id) { item in
                            let reply = item.element
                            let previous = item.offset > 0 ? model.replies[item.offset - 1] : nil
                            let continuation = model.selectedChannel?.encrypted == false && NativeTimelineGrouping.isContinuation(reply, after: previous, calendar: .current)
                            VStack(alignment: .leading, spacing: 0) {
                                if let priorDate = previous?.date ?? model.threadRoot?.date, !Calendar.current.isDate(priorDate, inSameDayAs: reply.date) {
                                    NativeTimelineDayDivider(label: model.formattedDate(reply.date, dateOnly: true))
                                }
                                NativeMessageRow(post: reply, model: model, showsReplyAction: false, isContinuation: continuation)
                                    .padding(.top, previous == nil || continuation ? 0 : 14)
                                    .id(reply.id)
                                    .background(NativeTimelineRowMarker(postID:reply.id,token:model.nativeThreadViewportToken).allowsHitTesting(false))
                            }
                        }
                        if model.threadViewingContext,model.canLoadNewerReplies {
                            Button(model.loadingThread ? "Loading…" : "Load newer replies") { Task { await model.loadNewerReplies() } }
                                .buttonStyle(.link).disabled(model.loadingThread)
                        }
                        Color.clear.frame(height: 1).id("thread-bottom")
                    }.padding(.horizontal,16).padding(.vertical,20).frame(maxWidth: .infinity, alignment: .leading)
                        .background(NativeTimelineViewport(token:model.nativeThreadViewportToken,changed:{ [token = model.nativeThreadViewportToken,account = model.accountGeneration,channel = model.threadRoot?.channel_id,root = model.threadRoot?.id] postID,bottom in
                            guard let channel,let root else { return }
                            model.noteThreadViewport(postID:postID,atBottom:bottom,token:token,account:account,channelID:channel,rootID:root)
                        }).allowsHitTesting(false))
                        .background(NativeScrollVisibility(readerContext: .init(account:model.accountGeneration,channelID:model.threadRoot?.channel_id,threadID:model.threadRoot?.id,viewportToken:model.nativeThreadViewportToken,isLoading:model.loadingThread),keepLatestAfterResize: { [account = model.accountGeneration,selection = model.selection,channel = model.threadRoot?.channel_id,root = model.threadRoot?.id,token = model.nativeThreadViewportToken] isCurrent in
                            DispatchQueue.main.async {
                                guard isCurrent(),root != nil,model.accountGeneration == account,model.selection == selection,
                                      model.threadRoot?.channel_id == channel,model.threadRoot?.id == root,
                                      model.nativeThreadViewportToken == token,!model.loadingThread,!model.threadViewingContext else { return }
                                proxy.scrollTo("thread-bottom",anchor:.bottom)
                                initialScroll = false
                            }
                        }) { bottom in atBottom = bottom; updateReadVisibility() })
                }
                    .onAppear { scrollInitialThreadIfNeeded(proxy) }
                    .onChange(of:model.loadingThread) { loading in if !loading { scrollInitialThreadIfNeeded(proxy) } }
                    .onChange(of: model.replies.last?.id) { id in
                        if id != nil, initialScroll || (atBottom && !model.threadViewingContext) {
                            let account = model.accountGeneration,selection = model.selection
                            let channel = model.threadRoot?.channel_id,root = model.threadRoot?.id,token = model.nativeThreadViewportToken
                            DispatchQueue.main.async {
                                guard root != nil,model.accountGeneration == account,model.selection == selection,
                                      model.threadRoot?.channel_id == channel,model.threadRoot?.id == root,
                                      model.nativeThreadViewportToken == token,model.replies.last?.id == id,
                                      !model.loadingThread,initialScroll || (atBottom && !model.threadViewingContext) else { return }
                                proxy.scrollTo("thread-bottom", anchor: .bottom)
                                initialScroll = false
                            }
                        }
                        updateReadVisibility()
                    }
            }
    }
    private func scrollInitialThreadIfNeeded(_ proxy:ScrollViewProxy) {
        guard initialScroll,!model.loadingThread,!model.replies.isEmpty,let root = model.threadRoot else { return }
        let account = model.accountGeneration,token = model.nativeThreadViewportToken
        DispatchQueue.main.async {
            guard initialScroll,!model.loadingThread,!model.replies.isEmpty,model.accountGeneration == account,
                  model.nativeThreadViewportToken == token,model.selection == root.channel_id,
                  model.threadRoot?.id == root.id else { return }
            proxy.scrollTo("thread-bottom",anchor:.bottom)
            initialScroll = false
        }
    }
    private func updateReadVisibility() { model.updateThreadReadingVisibility(active: windowActive, atBottom: atBottom) }
}

struct NativeImageThumbnail: View {
    let post: ChatPost
    @ObservedObject var model: NativeChatPreviewModel
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image {
                NativeInlineImageView(image:image,label:"Image attachment: " + model.attachmentName(post))
                    .frame(maxWidth: min(320, image.size.width), maxHeight: min(240, image.size.height), alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Image attachment: " + model.attachmentName(post))
            } else {
                Label("Image attachment", systemImage: "photo").font(.callout).foregroundColor(.secondary)
            }
        }
        // Reserve the preview footprint before the asynchronous image arrives.
        // Otherwise decoding moves the latest message below the visible viewport.
        .frame(width: 320, height: 240, alignment: .leading)
        .help("Open image")
        .task(id: post.id) { image = await model.thumbnail(for: post) }
        .onDisappear { image = nil }
    }
}
