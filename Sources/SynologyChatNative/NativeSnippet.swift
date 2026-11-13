import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NativeSnippetCard:View {
    let post:ChatPost
    @ObservedObject var model:NativeChatPreviewModel
    @State private var full:String?
    @State private var expanded = false
    @State private var working = false
    @State private var failure:String?
    @State private var editing = false
    @State private var task:Task<Void,Never>?
#if DEBUG
    static func renderFixture(post:ChatPost,model:NativeChatPreviewModel,full:String? = nil,failure:String? = nil) -> Self {
        var view = Self(post:post,model:model);view._full = State(initialValue:full);view._expanded = State(initialValue:full != nil);view._failure = State(initialValue:failure);return view
    }
#endif
    private var preview:String { NativeSnippetDraft.preview(post.file_props?.snippet_preview ?? "") }
    private var displayed:String { expanded ? full ?? preview : preview }
    private var hasMore:Bool { post.file_props?.snippet_preview == nil || post.file_props?.snippet_preview_more == true || (post.file_props?.snippet_lines ?? 0) > 12 || NativeSnippetDraft.previewIsTruncated(post.file_props?.snippet_preview ?? "") }
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:10) {
                Image(systemName:"chevron.left.forwardslash.chevron.right").foregroundColor(NativeChatColors.green)
                Text(model.attachmentName(post)).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength:8)
                if working { ProgressView().controlSize(.small) }
                Button("Copy") { copy() }.disabled(working).accessibilityLabel("Copy full snippet")
                if model.canEditSnippet(post) { Button("Edit") { editing = true }.accessibilityLabel("Edit snippet") }
            }.buttonStyle(NativeToolbarButtonStyle()).padding(12)
            Divider().overlay(NativeChatColors.separator)
            if !displayed.isEmpty {
                NativeCodeEditor(text:.constant(displayed),filename:model.attachmentName(post),editable:false,label:"Snippet preview")
                    .frame(height:expanded ? 360 : CGFloat(min(12,max(2,NativeSnippetDraft(content:displayed).lineCount)))*19+28)
            }
            HStack(spacing:12) {
                Text(NativeLocalizedStrings.count("%lld lines",Int64(post.file_props?.snippet_lines ?? NativeSnippetDraft(content:displayed).lineCount))).font(.caption).foregroundColor(NativeChatColors.muted)
                if hasMore || expanded { Button(expanded ? "Collapse" : "Expand") { toggleExpanded() }.disabled(working) }
                Spacer()
                Button("Open") { model.openDocumentPreview(post) }.accessibilityLabel("Open full snippet")
                Button("Save…") { Task { await model.saveAttachment(post) } }.disabled(model.downloading.contains(post.id))
            }.buttonStyle(NativeToolbarButtonStyle()).padding(12)
            if let failure { Text(failure).font(.caption).foregroundColor(.orange).padding(12) }
        }.background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:10))
            .sheet(isPresented:$editing) { NativeSnippetComposer(model:model,channelID:post.channel_id,rootID:post.isReply ? post.thread_id : nil,editing:post) }
            .onChange(of:ChatSnippetRevision(post)) { _ in clear() }
            .onChange(of:model.canReadSnippet(post)) { if !$0 { editing = false;clear() } }
            .onDisappear { editing = false;clear() }
    }
    private func clear() { task?.cancel();task = nil;full = nil;expanded = false;working = false;failure = nil }
    private func toggleExpanded() {
        if expanded { expanded = false;return }
        if full != nil { expanded = true;return }
        working = true;failure = nil
        task = Task { @MainActor in
            do { let value = try await model.snippetSnapshot(post);guard !Task.isCancelled,model.isCurrentSnippetReview(value.review,post:post) else { return };full = value.content;expanded = true }
            catch { if !Task.isCancelled { failure = error.localizedDescription } }
            if !Task.isCancelled { working = false;task = nil }
        }
    }
    private func copy() {
        working = true;failure = nil
        task = Task { @MainActor in
            do {
                try await model.copySnippet(post);try Task.checkCancellation()
            } catch { if !Task.isCancelled { failure = error.localizedDescription } }
            if !Task.isCancelled { working = false;task = nil }
        }
    }
}

struct NativeSnippetComposer:View {
    @ObservedObject var model:NativeChatPreviewModel
    let channelID:Int64
    let rootID:Int64?
    let editing:ChatPost?
    let recovery:NativeLongMessageSnippetRecovery?
    @State private var session:Int
    @State private var draft:NativeSnippetDraft
    @State private var busy = false
    @State private var loaded:Bool
    @State private var needsReview = false
    @State private var failure:String?
    @State private var task:Task<Void,Never>?
    @State private var showLanguages = false
    @State private var confirmLong = false
    @State private var confirmRetry = false
    @State private var review:ChatSnippetReview?
    @State private var loadedDraft:NativeSnippetDraft?
    @State private var confirmDiscard = false
    @StateObject private var fileImport = NativeSnippetImportController()
    @State private var chooseImport = false
    @State private var importBaseline:NativeSnippetDraft?
    @State private var findRequest = 0
    @Environment(\.dismiss) private var dismiss
    init(model:NativeChatPreviewModel,channelID:Int64,rootID:Int64? = nil,editing:ChatPost? = nil,recovery:NativeLongMessageSnippetRecovery? = nil) {
        self.model = model;self.channelID = channelID;self.rootID = rootID;self.editing = editing;self.recovery = recovery;_session = State(initialValue:model.pollSessionGeneration)
        _draft = State(initialValue:editing.map { NativeSnippetDraft(filename:model.attachmentName($0),caption:model.messageText($0),content:"") } ?? recovery?.initialDraft ?? model.snippetDrafts[model.snippetDraftKey(channelID:channelID,rootID:rootID)] ?? NativeSnippetDraft())
        _loaded = State(initialValue:editing == nil)
        _needsReview = State(initialValue:recovery?.deliveryNeedsReview ?? false)
    }
#if DEBUG
    private var renderingFixture = false
    static func renderNewFixture(model:NativeChatPreviewModel,draft:NativeSnippetDraft) -> Self {
        var view = Self(model:model,channelID:model.selection ?? 23);view._draft = State(initialValue:draft);view.renderingFixture = true;return view
    }
    static func renderFixture(model:NativeChatPreviewModel,post:ChatPost,original:NativeSnippetDraft,draft:NativeSnippetDraft,uncertain:Bool,failure:String?,importFailure:String? = nil) throws -> Self {
        guard let revision = ChatSnippetRevision(post) else { throw ChatAPIError.invalidResponse }
        var view = Self(model:model,channelID:post.channel_id,editing:post)
        view._draft = State(initialValue:draft);view._loaded = State(initialValue:true);view._loadedDraft = State(initialValue:original)
        view._review = State(initialValue:.init(revision:revision,contentDigest:ChatSnippetRevision.digest(original.content),channelType:model.selectedChannel?.type ?? "private",accountGeneration:model.accountGeneration))
        view._needsReview = State(initialValue:uncertain);view._failure = State(initialValue:failure)
        if let importFailure { let flow = NativeSnippetImportController();flow.report(ChatTransferError(message:importFailure));view._fileImport = StateObject(wrappedValue:flow) }
        view.renderingFixture = true;return view
    }
#endif
    private var importContextIsCurrent:Bool {
        model.connected && model.pollSessionGeneration == session && model.selection == channelID
            && model.selectedChannel?.supportsSnippetReading == true && model.canRead(channelID)
            && (editing != nil || rootID == nil || model.threadRoot?.id == rootID)
    }
    private var importReview:Binding<NativeSnippetImportProposal?> { Binding(get:{ fileImport.pending },set:{ if $0 == nil { fileImport.dismissReview() } }) }
    private var needsDiscardConfirmation:Bool {
        if let recovery { return !draft.hasSameBytes(as:NativeSnippetDraft(content:recovery.sourceText)) }
        return editing != nil && loadedDraft.map { !draft.hasSameBytes(as:$0) } == true
    }
    private func requestClose() { if needsDiscardConfirmation { confirmDiscard = true } else { dismiss() } }
    private var language:NativeSnippetLanguage { .forFilename(draft.filename) }
    private var valid:Bool { (try? draft.validated()) != nil }
    var body:some View {
        VStack(spacing:0) {
            HStack {
                Label(editing == nil ? "Create a snippet" : "Edit snippet",systemImage:"chevron.left.forwardslash.chevron.right").font(.system(size:20,weight:.bold));Spacer()
                Button { findRequest += 1 } label: { Image(systemName:"magnifyingglass") }.accessibilityLabel("Find in snippet").keyboardShortcut("f",modifiers:.command)
                Button { requestClose() } label: { Image(systemName:"xmark") }.accessibilityLabel("Close snippet editor").disabled(busy).keyboardShortcut(.cancelAction)
            }.buttonStyle(NativeToolbarButtonStyle()).padding(20)
            if recovery != nil {
                Text("Your full message is copied below. The original stays in the conversation composer until this snippet is sent.")
                    .font(.callout).foregroundColor(NativeChatColors.muted).frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,20).padding(.bottom,16)
            }
            if recovery != nil,!importContextIsCurrent { Text("This conversation or sign-in changed. Your copied text remains here; copy it before closing, or return to the original conversation to continue.").font(.callout).foregroundColor(.orange).padding(.horizontal,20) }
            HStack(spacing:14) {
                TextField("Filename",text:$draft.filename).textFieldStyle(.roundedBorder).accessibilityLabel("Snippet filename")
                Button { showLanguages = true } label: { HStack { Text(language.title);Image(systemName:"chevron.down") } }.buttonStyle(NativeToolbarButtonStyle()).accessibilityLabel("Snippet language").popover(isPresented:$showLanguages) {
                    NativeSnippetLanguagePicker(selected:language) { value in draft.filename = value.filename(from:draft.filename);showLanguages = false }
                }
            }.padding(.horizontal,20).padding(.bottom,16).disabled(busy || fileImport.busy || fileImport.pending != nil || !loaded)
            Divider().overlay(NativeChatColors.separator)
            ZStack {
                NativeCodeEditor(text:$draft.content,filename:draft.filename,findRequest:findRequest,label:"Snippet code").disabled(busy || fileImport.busy || fileImport.pending != nil || !loaded)
                if !loaded { ProgressView("Loading snippet…").padding(20).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:12)) }
            }.frame(minHeight:260,maxHeight:.infinity)
            Divider().overlay(NativeChatColors.separator)
            HStack { Text(NativeLocalizedStrings.count("%lld lines",Int64(draft.lineCount)));Spacer();Text("\(draft.content.utf8.count.formatted()) / 1,048,576 bytes") }.font(.caption).foregroundColor(NativeChatColors.muted).padding(.horizontal,20).padding(.vertical,8)
            TextField("Add a description",text:$draft.caption,axis:.vertical).textFieldStyle(.roundedBorder).lineLimit(2...4).accessibilityLabel("Snippet description").disabled(busy || fileImport.busy || fileImport.pending != nil || !loaded).padding(.horizontal,20)
            if let error = fileImport.failure { Text(error).font(.callout).foregroundColor(.orange).frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,20).padding(.top,10) }
            if let failure { Text(failure).font(.callout).foregroundColor(.orange).frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,20).padding(.top,10) }
            HStack {
                if busy { ProgressView().controlSize(.small);Button("Stop waiting") { task?.cancel();task = nil;busy = false;needsReview = true;failure = "Stopped waiting. Check the conversation before submitting again. Your draft stays in this editor." }.buttonStyle(NativeToolbarButtonStyle()) }
                if fileImport.busy { ProgressView("Reading text file…").controlSize(.small);Button("Cancel import") { fileImport.cancel() }.buttonStyle(NativeToolbarButtonStyle()) }
                else if loaded,!busy { Button { importBaseline = draft;chooseImport = true } label: { Label("Import text file…",systemImage:"doc.badge.plus") }.buttonStyle(NativeToolbarButtonStyle()).disabled(needsReview || !importContextIsCurrent || fileImport.pending != nil) }
                if !loaded,!busy { Button("Try again") { load() }.buttonStyle(NativeToolbarButtonStyle()) }
                Spacer()
                if needsReview {
                    if recovery != nil { Button("I checked; allow retry…") { confirmRetry = true }.buttonStyle(NativeToolbarButtonStyle()).disabled(!importContextIsCurrent) }
                    Button("Check conversation") { requestClose() }.buttonStyle(NativeSendButtonStyle())
                }
                else { Button(editing == nil ? "Send snippet" : "Save snippet") { if draft.lineCount > 4000 { confirmLong = true } else { submit() } }.buttonStyle(NativeSendButtonStyle()).keyboardShortcut(.return,modifiers:.command).disabled(!valid || busy || fileImport.busy || fileImport.pending != nil || !loaded || !model.canInteract || !importContextIsCurrent) }
            }.padding(20)
        }.frame(minWidth:700,idealWidth:900,maxWidth:1200,minHeight:560,idealHeight:720,maxHeight:950)
            .foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance().tint(NativeChatColors.green).interactiveDismissDisabled(busy || fileImport.busy || fileImport.pending != nil || needsDiscardConfirmation)
            .onAppear {
#if DEBUG
                if renderingFixture { return }
#endif
                model.conversationLibraryVisible = true;if !loaded { load() }
            }
            .onDisappear { task?.cancel();task = nil;fileImport.cancel();chooseImport = false;model.conversationLibraryVisible = false }
            .onChange(of:draft) { value in
                if let recovery { model.retainLongMessageSnippet(recovery,draft:value) }
                else if editing == nil,model.connected,model.pollSessionGeneration == session { model.snippetDrafts[model.snippetDraftKey(channelID:channelID,rootID:rootID)] = value }
            }
            .onChange(of:model.pollSessionGeneration) { if $0 != session { task?.cancel();task = nil;busy = false;if recovery != nil { needsReview = recovery?.deliveryNeedsReview ?? false } else { dismiss() } } }
            .onChange(of:model.connected) { if !$0,recovery == nil { dismiss() } }
            .onChange(of:model.selection) { if $0 != channelID,recovery == nil { dismiss() } }
            .onChange(of:model.selectedChannel?.encrypted) { if $0 != false,recovery == nil { dismiss() } }
            .onChange(of:model.threadRoot?.id) { if let rootID,$0 != rootID,recovery == nil { dismiss() } }
            .fileImporter(isPresented:$chooseImport,allowedContentTypes:[.data]) { [original = importBaseline] result in
                guard importContextIsCurrent,let original else { return }
                do { let file = try result.get();fileImport.prepare(file,original:original,isCurrent:{ importContextIsCurrent }) }
                catch { fileImport.report(error) }
            }
            .sheet(item:importReview) { proposal in
                NativeSnippetImportReview(proposal:proposal,accept:{ do { draft = try fileImport.adopt(proposal.id,to:draft,isCurrent:{ importContextIsCurrent });failure = nil } catch { if !(error is CancellationError),fileImport.failure == nil { failure = error.localizedDescription } } },cancel:{ fileImport.dismissReview() })
            }
            .alert("Discard unsaved snippet changes?",isPresented:$confirmDiscard) { Button("Keep editing",role:.cancel) { };Button("Discard changes",role:.destructive) { if let recovery { model.discardLongMessageSnippet(recovery) };dismiss() } } message: { Text("Your unsaved code and description will be discarded. The server snippet will not change.") }
            .alert("Allow another send?",isPresented:$confirmRetry) { Button("Cancel",role:.cancel) {};Button("Allow retry") { if let key = recovery?.attemptKey { NativeSnippetRecoveryAttempts.clearAfterReviewOrSuccess(key) };needsReview = false;failure = nil } } message: { Text("Check the conversation for the earlier snippet first. Sending again could create a duplicate if that upload succeeded.") }
            .alert("More than4,000 lines",isPresented:$confirmLong) { Button("Cancel",role:.cancel) { };Button("Continue") { submit() } } message: { Text("Continue submitting this long snippet?") }
    }
    private func load() {
        guard let editing,!busy else { return };busy = true;failure = nil
        task = Task { @MainActor in
            do { let snapshot = try await model.snippetSnapshot(editing);guard !Task.isCancelled,model.pollSessionGeneration == session,model.isCurrentSnippetReview(snapshot.review,post:editing) else { return };draft.content = snapshot.content;review = snapshot.review;loadedDraft = draft;loaded = true }
            catch { if !Task.isCancelled { failure = error.localizedDescription } }
            if !Task.isCancelled { busy = false;task = nil }
        }
    }
    private func submit() {
        guard valid,!busy,!fileImport.busy,fileImport.pending == nil,!needsReview,(editing == nil || review != nil),importContextIsCurrent,
              recovery.map({ $0.accountGeneration == model.accountGeneration && $0.channelID == channelID && $0.rootID == rootID }) ?? true else { return };busy = true;failure = nil
        task = Task { @MainActor in
            do {
                if let editing { try await model.editSnippet(editing,draft:draft,review:review) }
                else {
                    if let key = recovery?.attemptKey { NativeSnippetRecoveryAttempts.markDispatched(key) }
                    let post = try await model.createSnippet(draft,inThread:rootID != nil,preservingStoredDraft:recovery != nil)
                    if let recovery { model.finishLongMessageSnippet(recovery,created:post);if let key = recovery.attemptKey { NativeSnippetRecoveryAttempts.clearAfterReviewOrSuccess(key) } }
                }
                guard !Task.isCancelled,model.pollSessionGeneration == session else { return };busy = false;task = nil;dismiss()
            } catch {
                guard !Task.isCancelled,model.pollSessionGeneration == session else { return };busy = false;task = nil
                if let recovery { needsReview = recovery.deliveryNeedsReview;failure = "Delivery could not be confirmed. Check the conversation before trying again. Your message and snippet draft are kept." }
                else if let value = error as? ChatSnippetEditFailure { failure = value.message;needsReview = true }
                else if let value = error as? ChatTransferError { failure = value.message;needsReview = editing == nil && value.deliveryNeedsReview }
                else if case ChatAPIError.server(let code) = error { failure = "The server rejected this snippet change (\(code)). Your draft is kept." }
                else { needsReview = editing == nil;failure = "Delivery could not be confirmed. Check the conversation before sending again; your draft is kept." }
            }
        }
    }
}

private struct NativeSnippetLanguagePicker:View {
    let selected:NativeSnippetLanguage
    let choose:(NativeSnippetLanguage)->Void
    @State private var query = ""
    private var values:[NativeSnippetLanguage] { query.isEmpty ? NativeSnippetLanguage.all : NativeSnippetLanguage.all.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.extensions.contains(where:{ $0.localizedCaseInsensitiveContains(query) }) } }
    var body:some View {
        VStack(spacing:12) {
            TextField("Find a language",text:$query).textFieldStyle(.roundedBorder).accessibilityLabel("Find snippet language")
            ScrollView {
                LazyVStack(alignment:.leading,spacing:0) {
                    ForEach(values) { value in Button { choose(value) } label: { HStack { Text(value.title);Spacer();if value.id == selected.id { Image(systemName:"checkmark") } }.padding(9).frame(maxWidth:.infinity,alignment:.leading) }.buttonStyle(.plain) }
                }
            }
        }.padding(14).frame(width:300,height:360).foregroundColor(NativeChatColors.text).background(NativeChatColors.surface)
    }
}
