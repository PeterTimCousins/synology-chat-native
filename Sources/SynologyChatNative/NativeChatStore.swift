import AppKit
import SwiftUI
import OSLog
import Combine

@MainActor
final class NativeChatPreviewModel: ObservableObject {
    @Published var channels: [ChatChannel] = [] {
        didSet {
            updateDockBadge()
            if draftStore?.scope != nil, oldValue.contains(where: { old in
                !old.encrypted && !channels.contains(where: { $0.id == old.id && !$0.encrypted && $0.is_closed != true })
            }) { flushRecoverableDrafts() }
            else { persistRecoverableDrafts() }
            if let id = selection, let old = oldValue.first(where: { $0.id == id }), let current = channels.first(where: { $0.id == id }),
               old.type != current.type || old.encrypted != current.encrypted || old.channel_key_enc != current.channel_key_enc { refreshSidebarAnchor() }
            if let context = composerAttachmentContext {
                let current = channels.first { $0.id == context.channelID }
                if current == nil || current?.encrypted != context.encrypted || current?.channel_key_enc != context.keyEnvelope { cancelComposerAttachmentPreparation() }
            }
            if let batch = attachmentBatch {
                let current = channels.first { $0.id == batch.channelID }
                if current == nil || current?.encrypted != batch.encrypted || current?.channel_key_enc != batch.keyEnvelope { dismissAttachmentBatch() }
            }
            if let context = savedFileOpenContext, context.encrypted {
                let current = channels.first { $0.id == context.channelID }
                if current == nil || current?.encrypted != true || current?.channel_key_enc != context.keyEnvelope {
                    cancelPendingSavedFileOpen()
                }
            }
            if let post = documentPreviewPost {
                let previous = oldValue.first { $0.id == post.channel_id }
                let current = channels.first { $0.id == post.channel_id }
                if previous == nil || current == nil || previous?.encrypted != current?.encrypted || previous?.channel_key_enc != current?.channel_key_enc { closeDocumentPreview() }
                else if searchDocumentOwner != nil,!canPreviewSearchDocument(post) { closeDocumentPreview() }
            }
            if let post = imageViewerPost {
                let previous = oldValue.first { $0.id == post.channel_id }
                let current = channels.first { $0.id == post.channel_id }
                if previous == nil || current == nil || previous?.encrypted != current?.encrypted
                    || previous?.channel_key_enc != current?.channel_key_enc { closeImageViewer() }
            }
            if searchImageOwner != nil {
                imageViewerPosts = imageViewerPosts.filter(canReadSearchImage)
                if let post = imageViewerPost,!imageViewerPosts.contains(where:{ $0.id == post.id }) { closeImageViewer() }
            }
        }
    }
    @Published private(set) var slashCommandRequest: NativeSlashCommandRequest?
    @Published private(set) var quickSwitcherBusy = false
    @Published private(set) var pendingConversationStarts: [String: ChatConversationStartIntent] = [:]
    @Published private(set) var conversationStartRecoveryError: String?
    private let conversationStartJournal: ChatConversationStartJournal
    @Published private(set) var pendingEncryptedConversationStarts:[UUID:ChatEncryptedConversationIntent] = [:]
    @Published private(set) var encryptedConversationRecoveryError:String?
    private let encryptedConversationJournal:ChatEncryptedConversationJournal
    private var encryptedConversationRecoveryScope:String?
    @Published private(set) var botBrowserBusy = false
    @Published private(set) var blockedBotIDs: Set<Int64> = []
    @Published private(set) var pendingBotSubscriptions: [Int64: ChatBotSubscriptionIntent] = [:]
    @Published private(set) var botSubscriptionRecoveryError: String?
    private let botSubscriptionJournal: ChatBotSubscriptionJournal
    @Published private(set) var webhookBusy = false
    @Published private(set) var uncertainWebhookIDs: Set<Int64> = []
    @Published private(set) var uncertainWebhookCreates: Set<ChatWebhookKind> = []
    private var uncertainWebhookRotations: [Int64: String] = [:]
    private let webhookActionJournal:ChatWebhookActionJournal
    private var webhookRecoveryScope:String?
    @Published private(set) var webhookRecoveryError:String?
    @Published private(set) var pendingWebhookActions:[String:ChatWebhookActionIntent] = [:]
    @Published private(set) var pendingEncryptedCreations:[UUID:ChatEncryptedCreationIntent] = [:]
    @Published private(set) var encryptedCreationRecoveryError:String?
    private let encryptedCreationJournal:ChatEncryptedCreationJournal
    private var encryptedCreationRecoveryScope:String?
    var canCreateEncryptedChannel:Bool {
        canCreateNamedChannel && !sending && encryptionUnlocked && encryptionKeyPair?.isInitialized == true
            && currentUserID != nil && encryptedCreationRecoveryError == nil && pendingEncryptedCreations.isEmpty
    }
    @Published private(set) var pendingInvitations:[Int64:ChatChannelInvitationIntent] = [:]
    @Published private(set) var invitationRecoveryError:String?
    private let invitationJournal:ChatChannelInvitationJournal
    private var invitationRecoveryScope:String?
    @Published private(set) var pendingForwards:[String:ChatForwardIntent] = [:]
    @Published private(set) var forwardRecoveryError:String?
    @Published private(set) var forwardRecoveryBusy = false
    private let forwardJournal:ChatForwardJournal
    private var forwardRecoveryScope:String?
    @Published private(set) var slashBusy = false
    @Published private(set) var uncertainSlashInvocations: Set<String> = []
    @Published private(set) var pendingSlashInvocations:[String:ChatSlashActionIntent] = [:]
    @Published private(set) var slashRecoveryError:String?
    private let slashActionJournal:ChatSlashActionJournal
    private var slashRecoveryScope:String?
    @Published private(set) var botActionsPending: Set<Int64> = []
    @Published private(set) var uncertainBotActions: [Int64: ChatBotActionSelection] = [:]
    @Published private(set) var botActionStatus: [Int64: String] = [:]
    @Published private(set) var pendingBotActionReceipts: [Int64: ChatBotActionIntent] = [:]
    @Published private(set) var botActionRecoveryError: String?
    private let botActionJournal: ChatBotActionJournal
    @Published private(set) var administratorStatus: ChatAdministratorStatus?
    private var administratorStatusGeneration: Int?
    private var administratorStatusUserID: Int64?
    private var administratorReadRevision = UUID()
    @Published private(set) var pendingPromotions: [Int64: ChatChannelPromotionAttempt] = [:]
    @Published private(set) var promotionRecoveryError:String?
    private let promotionJournal:ChatChannelPromotionJournal
    private var promotionRecoveryScope:String?
    @Published var calendarSettingsBusy = false
    @Published var calendarSettingsNeedRefresh = false
    private var calendarPreferenceReadRevision = UUID()
    @Published var calendarDetection: Bool?
    @Published var calendarBusy = false
    @Published var uncertainCalendarPosts: Set<Int64> = []
    private var calendarDetectionTask: Task<Bool?, Never>?
    @Published var posts: [ChatPost] = []
    @Published private(set) var historyViewportToken = UUID()
    @Published private(set) var historyScrollRevision = UUID()
    @Published private(set) var latestHistoryScrollRevision = UUID()
    @Published private(set) var scrollAnchorAtTop = false
    @Published var scrollPostID: Int64? { didSet { historyScrollRevision = UUID() } }
    private var timelineViewport: (postID:Int64, atBottom:Bool)?
    private var timelineRecoveryAnchor:Int64?
    @Published var viewingMessageContext = false
    private var pendingLocation: (channel: Int64, post: Int64, thread: Int64?)?
    var notificationRouting = ChatNotificationRouting()
    private var revealWindow: (() -> Void)?
    let avatars = NativeAvatarStore()
    @Published private(set) var channelMemberIDs:[Int64:[Int64]] = [:]
    private var profileRefreshTask:Task<Void,Never>?
    private var profileRefreshID = UUID()
    @Published private(set) var profileConversationRoute = UUID()
    @Published var directory: [ChatUser] = [] { didSet { rebuildDisplayNames() } }
    @Published var names: [Int64: String] = [:]
    @Published var channelNames: [Int64: String] = [:]
    @Published private(set) var channelPermissions: ChatChannelPermissions?
    @Published private(set) var channelManagementBusy = false
    @Published private(set) var unresolvedMembership:Set<Int64> = []
    @Published private(set) var unresolvedChannelDetails:Set<Int64> = []
    @Published private(set) var pendingChannelClosures:[Int64:ChatChannelClosePreparation] = [:]
    @Published private(set) var knownClosedChannelIDs:Set<Int64> = []
    @Published private(set) var channelActionRecoveryError:String?
    private let channelActionJournal:ChatChannelActionJournal
    let guestManagement: ChatGuestManagement
    let encryptionChanges: ChatEncryptionChangeCoordinator
    let archiveDeletions: ChatArchiveDeletionCoordinator
    private let managementConnectionIDProvider: (() -> String?)?
    private var channelActionScope:String?
    @Published private(set) var pendingHistoryArchives:[Int64:ChatHistoryArchivePreparation] = [:]
    var canCreateNamedChannel: Bool { canInteract && !channelManagementBusy && channelPermissions?.allows("channel_create") == true }
    var hasPendingActions:Bool {
        !pendingChannelClosures.isEmpty || !pendingHistoryArchives.isEmpty || channelActionRecoveryError != nil
            || !pendingPromotions.isEmpty || promotionRecoveryError != nil || !pendingForwards.isEmpty || forwardRecoveryError != nil
            || !pendingInvitations.isEmpty || invitationRecoveryError != nil
            || !pendingEncryptedCreations.isEmpty || encryptedCreationRecoveryError != nil
            || !pendingEncryptedConversationStarts.isEmpty || encryptedConversationRecoveryError != nil
    }
    func canInviteMembers(_ channel: ChatChannel) -> Bool {
        canInteract && currentUserID != nil && !channelManagementBusy && channel.id != 1
            && channel.supportsMemberInvitation && (!channel.encrypted || canRead(channel.id))
            && invitationRecoveryError == nil && pendingInvitations[channel.id] == nil && channelPermissions?.allows("channel_invite") == true
    }
    func canRemoveMember(_ user: ChatUser, channel: ChatChannel) -> Bool {
        canInteract && currentUserID != nil && !channelManagementBusy && channel.supportsMemberRemoval
            && user.type == "human" && user.human_type == "dsm" && channelPermissions?.allows("channel_kick") == true
            && user.user_id != currentUserID && user.user_id != channel.creator_id
    }
    @Published var selection: Int64? {
        didSet {
            if selection != oldValue { refreshSidebarAnchor();timelineViewport = nil;timelineRecoveryAnchor = nil;historyViewportToken = UUID() }
            if selection != oldValue,searchDocumentOwner != nil { closeDocumentPreview() }
            if let post = imageViewerPost,post.channel_id != selection { closeImageViewer() }
            if let post = documentPreviewPost,post.channel_id != selection { closeDocumentPreview() }
            if let batch = attachmentBatch,batch.channelID != selection { dismissAttachmentBatch() }
            if let context = composerAttachmentContext,context.channelID != selection { cancelComposerAttachmentPreparation() }
        }
    }
    private enum CollectionWatch { case all, channel(Int64) }
    private var collectionWatches: [UUID: CollectionWatch] = [:]
    func watchCollection(_ id: UUID, channelID: Int64?) {
        collectionWatches[id] = channelID.map(CollectionWatch.channel) ?? .all
    }
    func stopWatchingCollection(_ id: UUID) { collectionWatches[id] = nil }
    private func collectionWatchesChannel(_ channelID: Int64) -> Bool {
        collectionWatches.values.contains { scope in switch scope { case .all: return true; case .channel(let id): return id == channelID } }
    }
    let collectionChanges = PassthroughSubject<ChatCollectionChange,Never>()
    let collectionResyncs = PassthroughSubject<Int,Never>()
    var conversationLibraryVisible = false {
        didSet {
            if conversationLibraryVisible {
                updateReadingVisibility(active:false,atBottom:false)
                updateThreadReadingVisibility(active:false,atBottom:false)
            }
        }
    }
    @Published var connecting = false
    @Published private(set) var restoringSavedSession = false
    @Published var loadingHistory = false
    @Published var connected = false
    @Published var canLoadOlder = false
    @Published private(set) var canLoadNewer = false
    @Published var error: String?
    @Published var liveStatus: ChatLiveStatus = .offline
    @Published private(set) var pinStateNeedsRefresh: Set<Int64> = []
    @Published private(set) var postHashtagsNeedRefresh: Set<Int64> = []
    @Published private(set) var pendingMessageActions: Set<Int64> = []
    @Published private(set) var activeMessageEditor: UUID?
    private struct MessageEditorScope {
        let id:UUID
        let account:Int,encryption:Int,channel:Int64,post:Int64
        let encrypted:Bool,key:String?
        let thread:Int64?
        let baseline:ChatMessageEditBaseline
    }
    private var messageEditorScope:MessageEditorScope?
    var isEditingMessage: Bool { activeMessageEditor != nil }
    func beginMessageEditing(owner: UUID,post:ChatPost? = nil) {
        messageEditorScope = post.flatMap { post in
            guard let channel = selectedChannel,post.channel_id == channel.id,canRead(channel.id) else { return nil }
            return MessageEditorScope(id:UUID(),account:accountGeneration,encryption:encryptionGeneration,channel:channel.id,post:post.id,
                                      encrypted:channel.encrypted,key:channel.channel_key_enc,thread:post.isReply ? post.thread_id : nil,
                                      baseline:ChatMessageEditBaseline(post))
        }
        activeMessageEditor = owner
    }
    func endMessageEditing(owner: UUID) { if activeMessageEditor == owner { activeMessageEditor = nil;messageEditorScope = nil } }
    func messageEditorSession(owner:UUID)->UUID? { activeMessageEditor == owner ? messageEditorScope?.id : nil }
    var canComposeInThread: Bool {
        canInteract && !isEditingMessage && !sending
            && threadRoot.map { $0.channel_id == selection && canRead($0.channel_id) } == true
    }
    var canReply: Bool {
        !preparingComposerAttachment && attachmentBatch == nil && canComposeInThread && ChatMessageText.isAllowed(replyDraft) && !replyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    @Published var sending = false
    @Published var uploading = false
    @Published private(set) var uploadProgress: ChatUploadProgress?
    var notificationStatus:String { notifications.status }
    var notificationHasStatusNotice:Bool { notifications.hasStatusNotice }
    @Published var notificationsEnabled = false { didSet { updateDockBadge() } }
    @Published private var notificationDiagnosticState = NativeNotificationDiagnostic.noEvents
    var notificationDiagnostic:String { notifications.diagnosticText(notificationDiagnosticState) }
    private var notificationEventCount = 0
    private var incomingPostCount = 0
    private var notificationToggleID: UUID?
    private let notifications:NativeChatNotifications
    private let notificationDefaults:UserDefaults?
    private(set) var windowIsActive = false
    private var windowIsVisible = false
    private var visibleChannelID: Int64?
    private var visibleThreadTarget: ChatThreadReadState.Target?
    var notificationVisibleLocation: (channelID: Int64, threadID: Int64?)? {
        guard canInteract, imageViewerPost == nil,!documentPreviewIsPresented, !conversationLibraryVisible,attachmentBatch == nil,!preparingComposerAttachment,attachmentBatch == nil else { return nil }
        if let target = visibleThreadTarget, !loadingThread, !threadViewingContext,
           threadRoot?.id == target.rootID, selection == target.channelID, canRead(target.channelID) {
            return (target.channelID, target.rootID)
        }
        guard !viewingMessageContext, !loadingHistory, threadRoot == nil,
              let channel = visibleChannelID, selection == channel, canRead(channel) else { return nil }
        return (channel, nil)
    }
    @Published private(set) var hidesLinkPreviews = true {
        didSet { if hidesLinkPreviews { cancelLinkPreviewImages() } }
    }
    @Published private(set) var allowsReadStatus = false
    let stickers = NativeStickerAssets()
    private var displaySettingsRevision = UUID()
    private var linkPreviewGeneration = UUID()
    private var linkPreviewTasks: [UUID: Task<Data, Error>] = [:]
    #if DEBUG
    // Post/type counters only; never retain preview destinations or message data.
    private var debugLinkPreviewEvents:[String:[String:Int]] = [:]
    private var debugLinkPreviewEventOrder:[String] = []
    private static let debugLinkPreviewEventNames = ["cache_hit","start","transport_return","caller_cancelled","stale_scope","not_authorized","decode_failure","cache_admit","transfer_failure"]
    func debugLinkPreviewCounts(postID:Int64,asset:ChatLinkPreviewAsset)->[String:Int] {
        let stored = debugLinkPreviewEvents["\(postID):\(asset.rawValue)"] ?? [:]
        return Dictionary(uniqueKeysWithValues:Self.debugLinkPreviewEventNames.map { ($0,stored[$0] ?? 0) })
    }
    private func debugRecordLinkPreview(_ event:String,postID:Int64,asset:ChatLinkPreviewAsset,revision:UUID? = nil) {
        // A receipt from a cancelled old reader/account cannot repopulate the
        // freshly reset diagnostic namespace after cancellation/sign-out.
        guard revision == nil || revision == linkPreviewGeneration else { return }
        let key = "\(postID):\(asset.rawValue)"
        if debugLinkPreviewEvents[key] == nil {
            if debugLinkPreviewEventOrder.count >= 256 {
                debugLinkPreviewEvents[debugLinkPreviewEventOrder.removeFirst()] = nil
            }
            debugLinkPreviewEventOrder.append(key);debugLinkPreviewEvents[key] = [:]
        }
        debugLinkPreviewEvents[key,default:[:]][event,default:0] += 1
    }
    #endif
    @Published private(set) var documentPreviewPost:ChatPost?
    @Published private(set) var collectionDocumentOwner:UUID?
    @Published private(set) var searchDocumentOwner:UUID?
    private var searchDocumentSource:(postID:Int64,channelID:Int64)?
    @Published private(set) var documentPreviewInlineAudio = false
    @Published private(set) var inlineAudioOwnerID: UUID?
    var documentPreviewIsPresented: Bool { documentPreviewPost != nil && !documentPreviewInlineAudio }
    var inlineAudioPostID: Int64? { documentPreviewInlineAudio ? documentPreviewPost?.id : nil }
    @Published private(set) var documentPreviewContent:NativeDocumentContent?
    @Published private(set) var documentPreviewLoading = false
    @Published private(set) var documentPreviewError:String?
    private(set) var documentPreviewTask:Task<Void,Never>?
    private var documentPreviewRequestID:UUID?
    @Published private(set) var imageViewerPost: ChatPost?
    @Published private(set) var imageViewerImage: NSImage?
    @Published private(set) var imageViewerFrameCount = 1
    @Published private(set) var imageViewerOriginal = false
    @Published private(set) var imageViewerLoading = false
    @Published private(set) var imageViewerError: String?
    private(set) var imageViewerTask: Task<Void, Never>?
    private var imageViewerRequestID: UUID?
    private var imageViewerPosts: [ChatPost] = []
    @Published private(set) var searchImageOwner:UUID?
    @Published private(set) var imageHistoryLoading = false
    @Published private(set) var imageHistoryError: String?
    private(set) var imageHistoryTask: Task<Void,Never>?
    private var imageHistoryRequestID: UUID?
    private var imageHistoryChannelID: Int64?
    private var imageHistoryThreadID: Int64?
    private var imageHistoryHasOlder = false
    private var imageHistoryHasNewer = false
    private var imageHistoryRetryDirection = ChatImageHistoryDirection.around
    private var imageLibraryLoader: (() async throws -> ChatLibraryImagePage)?
    private var imageLibraryHasMore = false
    @Published var downloading: Set<Int64> = []
    @Published private(set) var checkingDownloadFiles = false
    @Published private(set) var downloadStateRevision = 0
    @Published var showDesktopSettings = false
    @Published private(set) var downloadHistory: [ChatDownloadRecord] = []
    let emojiPreferences: ChatEmojiPreferences
    private(set) lazy var emojiRecentSync = ChatEmojiRecentSync(preferences:emojiPreferences)
    let downloadPreferences: ChatDownloadPreferences
    let savedFileOpening = ChatSavedFileOpening()
    private let savedFileOpenPrompt = NativeSavedFileOpenPrompt()
    private struct SavedFileOpenContext {
        let id: UUID
        let channelID: Int64
        let encrypted: Bool
        let keyEnvelope: String?
    }
    private var savedFileOpenContext: SavedFileOpenContext?
    private enum DownloadSource { case current(ChatPost), archive(ChatArchiveKind, String, ChatArchive, ChatPost) }
    private var downloadSources: [UUID: DownloadSource] = [:]
    private var activeDownloadIDs: [Int64: UUID] = [:]
    private var downloadPanels: [Int64: NSSavePanel] = [:]
    private var downloadTasks: [Int64: (encrypted: Bool, task: Task<Void, Error>)] = [:]
    private struct ComposerAttachmentContext {
        let channelID:Int64;let rootID:Int64?;let encrypted:Bool;let keyEnvelope:String?
    }
    #if DEBUG
    @Published var conversationFileDropDiagnostic = "No drop event"
    #endif
    @Published private(set) var preparingComposerAttachment = false
    @Published private(set) var capturingScreenshot = false
    private(set) var composerAttachmentTask:Task<Void,Never>?
    private var composerAttachmentRequestID:UUID?
    private var composerAttachmentContext:ComposerAttachmentContext?
    private var composerImageFiles:Set<URL> = []
    @Published private(set) var attachmentBatch:NativeAttachmentBatch?
    private var attachmentBatchSession:Int?
    private var uploadTask: Task<Void, Never>?
    private var uploadIsEncrypted = false
    @Published var threadRoot: ChatPost? {
        didSet { if let root = threadRoot { threadDraftChannelIDs[root.id] = root.channel_id } }
    }
    @Published var replies: [ChatPost] = []
    @Published var loadingThread = false
    @Published var canLoadOlderReplies = false
    @Published var canLoadNewerReplies = false
    @Published var threadViewingContext = false
    private(set) var nativeThreadViewportToken = UUID()
    private var threadViewport:(postID:Int64,atBottom:Bool)?
    private var threadRecoveryAnchor:Int64?
    private var threadRefreshRequestID:UUID?
    private var threadReadRevision = UUID()
    var nativeThreadScrollPostID:Int64?
    private var threadGeneration = 0 {
        didSet { nativeThreadViewportToken = UUID() }
    }
    private var encryptedDraftChannels: Set<Int64> = []
    private var encryptedDraftThreads: Set<Int64> = []
    @Published var threadDrafts: [Int64: String] = [:] {
        didSet {
            if oldValue.contains(where: { !$0.value.isEmpty && (threadDrafts[$0.key] ?? "").isEmpty }) { flushRecoverableDrafts() }
            else { persistRecoverableDrafts() }
        }
    }
    var userID: Int64? { currentUserID }
    var canInteract: Bool { connected && liveStatus == .live && !selectedBotInteractionBlocked && !(selection.map { pendingChannelClosures[$0] != nil || knownClosedChannelIDs.contains($0) } ?? false) }
    var canRevokeSession: Bool { connected && account?.importedFromOfficialApp == false }
    var replyDraft: String {
        get { threadRoot.flatMap { threadDrafts[$0.id] } ?? "" }
        set { if let root = threadRoot {
            threadDrafts[root.id] = newValue
            if channels.first(where: { $0.id == root.channel_id })?.encrypted != false {
                encryptedDraftThreads.insert(root.id)
            }
        } }
    }
    @Published var drafts: [Int64: String] = [:] {
        didSet {
            if oldValue.contains(where: { !$0.value.isEmpty && (drafts[$0.key] ?? "").isEmpty }) { flushRecoverableDrafts() }
            else { persistRecoverableDrafts() }
        }
    }
    @Published private(set) var draftRecoveryNotice: String?
    private let draftStore: NativeDraftStore?
    private var draftSaveTask: Task<Void, Never>?
    private var restoringDrafts = false
    private var threadDraftChannelIDs: [Int64: Int64] = [:]
    @Published var pollDrafts:[Int64:ChatPollDraft] = [:]
    @Published var pollAttachments:[Int64:ChatPollAttachment] = [:]
    @Published var pollAttachmentOwner:UUID?
    @Published var snippetDrafts:[String:NativeSnippetDraft] = [:]
    var longMessageSnippetDrafts:[String:NativeSnippetDraft] = [:]
    @Published var scheduleDrafts:[Int64:ChatScheduleDraft] = [:]
    @Published private(set) var scheduleBusy = false
    @Published private(set) var pendingScheduledCreations:[Int64:ChatScheduledCreationIntent] = [:]
    @Published private(set) var scheduleCreationRecoveryError:String?
    private let scheduleCreationJournal:ChatScheduledCreationJournal
    private var scheduleCreationScope:String?
    @Published private(set) var reminderBusy = false
    @Published private(set) var hiddenConversationRoute = UUID()
    @Published private(set) var conversationOrganizationBusy = false
    @Published private(set) var unresolvedOrganization:Set<Int64> = []
    @Published private(set) var reminderRevision = UUID()
    var accountGeneration:Int { connectionGeneration }
    @Published private(set) var pollRevision = 0
    var pollSessionGeneration:Int { connectionGeneration }
    @Published var needsDeliveryCheck = false
    @Published private(set) var launcherBusy = false
    @Published private(set) var launcherNeedsRefresh = false
    @Published private(set) var regionalSettingsBusy = false
    @Published private(set) var regionalSettingsNeedRefresh = false
    @Published private(set) var regionalDisplay:ChatRegionalDisplay?
    @Published private(set) var pairedDevicesBusy = false
    @Published private(set) var pairedDevicesNeedRefresh = false
    @Published private(set) var profileEditingBusy = false
    @Published private(set) var profileEditingNeedsRefresh = false
    @Published private(set) var manualPresenceBusy = false
    @Published private(set) var manualPresenceNeedsRefresh = false
    var manualAway:Bool? { directory.first(where:{ $0.user_id == currentUserID })?.user_props?.is_always_offline }
    @Published private(set) var nameSettings: ChatNameSettings? { didSet { rebuildDisplayNames() } }
    @Published private(set) var nameSettingsBusy = false
    @Published private(set) var nameSettingsNeedRefresh = false
    private var nameReadRevision = UUID()
    @Published private(set) var sidebarSettings: ChatSidebarSettings? {
        didSet { if oldValue != sidebarSettings { refreshSidebarAnchor() } }
    }
    @Published private(set) var sidebarSettingsBusy = false
    @Published private(set) var sidebarSettingsNeedRefresh = false
    private var sidebarAnchor: ChatSidebarAnchor?
    private var sidebarReadRevision = UUID()
    @Published private(set) var appearanceSettings: ChatAppearanceSettings?
    @Published private(set) var appearanceSettingsBusy = false
    @Published private(set) var appearanceSettingsNeedRefresh = false
    private var appearanceReadRevision = UUID()
    @Published private(set) var channelAlertsBusy = false
    @Published private(set) var channelAlertsNeedRefresh: Set<Int64> = []
    @Published private(set) var notificationPreferencesBusy = false
    @Published private(set) var notificationPreferencesNeedRefresh = false
    private var live: ChatLiveConnection?
    private var readState: ChatReadState?
    private var threadReadState: ChatThreadReadState?
    private let readLog = Logger(subsystem: "com.costwisegroup.synology-chat-native.api-preview", category: "native-read")
    private let deliveryLog = Logger(subsystem: "com.costwisegroup.synology-chat-native.api", category: "native-delivery")
    private var deletedPostIDs: Set<Int64> = []
    private var sidebarRefreshTask: Task<Void, Never>?
    private var sidebarRefreshID: UUID?
    private(set) var eventTasks: [UUID: Task<Void, Never>] = [:]
    private var canonicalReadKeys: [Int64: UUID] = [:]
    private var historyReadUpdates: [UUID: [Int64: ChatPost]] = [:]
    private struct HistoryContentScope:Equatable {
        let account:Int,encryption:Int,channel:Int64
        let encrypted:Bool,key:String?,token:UUID
    }
    private var loadedHistoryContentScope:HistoryContentScope?
    private func historyContentScope(_ channel:ChatChannel)->HistoryContentScope {
        .init(account:accountGeneration,encryption:encryptionGeneration,channel:channel.id,
              encrypted:channel.encrypted,key:channel.channel_key_enc,token:historyViewportToken)
    }
    private var connectionGeneration = 0
    private var currentUserID: Int64?
    private var draftIdentity: String?
    var draft: String {
        get { selection.flatMap { drafts[$0] } ?? "" }
        set { if let selection {
            drafts[selection] = newValue
            if selectedChannel?.encrypted == true { encryptedDraftChannels.insert(selection) }
        } }
    }
    var canSend: Bool {
        canInteract && !slashBusy && slashCommandRequest == nil && attachmentBatch == nil && !preparingComposerAttachment && !isEditingMessage && !sending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && ChatMessageText.isAllowed(draft)
            && selectedChannel.map({ canRead($0.id) }) == true
    }
    private var encryptionGeneration = 0
    private var encryptedPreviewTasks: [UUID: Task<Data, Error>] = [:]
    private let thumbnailCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 96
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()
    private var client: ChatAPIClient?
    private var account: ChatAccount?
    @Published var accountDisplay = ""
    private(set) var historyTask: Task<Void, Never>?
    private var generation = 0

    private let restoreNotificationPreference: Bool
    private let makeClient: (ChatSession) throws -> ChatAPIClient
    private let encryption: ChatEncryptionSession
    @Published private(set) var encryptionUnlocked = false
    init(client: ChatAPIClient? = nil, restoreNotificationPreference: Bool = true, encryption: ChatEncryptionSession? = nil,
         makeClient: @escaping (ChatSession) throws -> ChatAPIClient = { try ChatAPIClient(session: $0) },
         channelActionJournal:ChatChannelActionJournal? = nil, botSubscriptionJournal: ChatBotSubscriptionJournal? = nil, conversationStartJournal: ChatConversationStartJournal? = nil, downloadPreferences: ChatDownloadPreferences? = nil, emojiPreferences: ChatEmojiPreferences? = nil, draftStore: NativeDraftStore? = nil, guestJournal: ChatGuestActionJournal? = nil, encryptionJournal: ChatEncryptionWriteJournal? = nil, archiveDeletionJournal: ChatArchiveDeletionJournal? = nil, managementConnectionID: (() -> String?)? = nil, botActionJournal: ChatBotActionJournal? = nil, slashActionJournal:ChatSlashActionJournal? = nil,promotionJournal:ChatChannelPromotionJournal? = nil,forwardJournal:ChatForwardJournal? = nil,invitationJournal:ChatChannelInvitationJournal? = nil,encryptedCreationJournal:ChatEncryptedCreationJournal? = nil,encryptedConversationJournal:ChatEncryptedConversationJournal? = nil,webhookActionJournal:ChatWebhookActionJournal? = nil,scheduleCreationJournal:ChatScheduledCreationJournal? = nil,notifications:NativeChatNotifications? = nil,notificationDefaults:UserDefaults? = .standard) {
        self.client = client
        self.notifications = notifications ?? NativeChatNotifications()
        self.notificationDefaults = notificationDefaults
        self.draftStore = draftStore
        self.channelActionJournal = channelActionJournal ?? .init()
        self.guestManagement = ChatGuestManagement(journal: guestJournal)
        self.encryptionChanges = ChatEncryptionChangeCoordinator(journal: encryptionJournal)
        self.archiveDeletions = ChatArchiveDeletionCoordinator(journal: archiveDeletionJournal)
        self.managementConnectionIDProvider = managementConnectionID
        self.botSubscriptionJournal = botSubscriptionJournal ?? .init()
        self.botActionJournal = botActionJournal ?? .init()
        self.slashActionJournal = slashActionJournal ?? .init()
        self.webhookActionJournal = webhookActionJournal ?? .init()
        self.scheduleCreationJournal = scheduleCreationJournal ?? .init()
        self.promotionJournal = promotionJournal ?? .init()
        self.forwardJournal = forwardJournal ?? .init()
        self.invitationJournal = invitationJournal ?? .init()
        self.encryptedCreationJournal = encryptedCreationJournal ?? .init()
        self.conversationStartJournal = conversationStartJournal ?? .init()
        self.encryptedConversationJournal = encryptedConversationJournal ?? .init()
        self.downloadPreferences = downloadPreferences ?? .init()
        self.emojiPreferences = emojiPreferences ?? .init()
        self.encryption = encryption ?? ChatEncryptionSession()
        self.encryptionUnlocked = self.encryption.isUnlocked
        self.restoreNotificationPreference = restoreNotificationPreference
        self.makeClient = makeClient
        stickers.attach(client);avatars.attach(client)
    }

    var mentionNames: [Int64: String] {
        Dictionary(directory.map { ($0.user_id, $0.type == "bot" ? ChatNameFormat.nickname.display($0) : ($0.username ?? ChatNameFormat.nickname.display($0))) }, uniquingKeysWith: { first, _ in first })
    }

    var selectedChannel: ChatChannel? { channels.first { $0.id == selection && !knownClosedChannelIDs.contains($0.id) && $0.is_closed != true } }
    func title(_ channel: ChatChannel) -> String {
        if let explicit = channel.defaultTitle { return explicit }
        if channel.type == "chatbot", let creator = channel.creator_id, let user = directory.first(where: { $0.user_id == creator }) { return displayName(user) }
        if channel.type == "anonymous", let ids = channelMemberIDs[channel.id] {
            let labels = ids.filter { $0 != currentUserID }.map { names[$0] ?? "User \($0)" }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            if !labels.isEmpty { return labels.joined(separator: ", ") }
        }
        return channelNames[channel.id] ?? "Conversation \(channel.id)"
    }

    var encryptionKeyPair: ChatEncryptionKeyPair? { directory.first { $0.user_id == currentUserID }?.user_props?.key_pair }
    var hasEncryptionKeyPair: Bool { encryptionKeyPair?.isInitialized == true }

    var encryptionChangeBlockReason: String? {
        if sending || isEditingMessage || uploadIsEncrypted || downloadTasks.values.contains(where: { $0.encrypted }) {
            return "Finish editing or transferring messages and encrypted files before changing encryption settings."
        }
        if preparingComposerAttachment || attachmentBatch?.encrypted == true {
            return "Finish or cancel the attachment review before changing encryption settings."
        }
        if encryptedDraftChannels.contains(where: { !(drafts[$0] ?? "").isEmpty }) ||
            encryptedDraftThreads.contains(where: { !(threadDrafts[$0] ?? "").isEmpty }) {
            return "Send or clear your encrypted drafts before changing encryption settings. Your drafts have been kept."
        }
        return nil
    }
    private var encryptionManagementConnectionID: String? {
        if let managementConnectionIDProvider { return managementConnectionIDProvider() }
        return live?.connectionID
    }
    func loadEncryptionManagement() async throws -> ChatEncryptionManagementSnapshot {
        guard connected, let api = client, let ownerID = currentUserID else { throw ChatAPIError.connection }
        if let reason = encryptionChangeBlockReason { throw ChatTransferError(message: reason) }
        let epoch = accountGeneration
        profileRefreshTask?.cancel(); profileRefreshTask = nil
        let revision = UUID(); profileRefreshID = revision
        let owner = try await api.encryptionOwnerState(userID: ownerID)
        try checkConversationSession(epoch)
        guard profileRefreshID == revision else { throw CancellationError() }
        if let reason = encryptionChangeBlockReason { throw ChatTransferError(message: reason) }
        guard directory.filter({ $0.user_id == ownerID }).count == 1,
              let index = directory.firstIndex(where: { $0.user_id == ownerID }) else { throw ChatAPIError.invalidResponse }
        let previous = encryptionKeyPair
        if previous?.public_key != owner.pair.public_key || previous?.private_key_enc != owner.pair.private_key_enc { lockEncryption(reload: false) }
        // A strict own-state read must not parse peers' private-key fields or
        // let an older in-flight profile request reinstall an obsolete pair.
        directory[index] = directory[index].replacingEncryptionPair(owner.pair)
        return .init(owner: owner, accountGeneration: epoch, connectionID: encryptionManagementConnectionID)
    }
    func changeEncryption(_ change: ChatEncryptionChange, original: ChatEncryptionManagementSnapshot) async throws -> ChatEncryptionManagementSnapshot {
        guard connected, original.accountGeneration == accountGeneration, original.owner.userID == currentUserID, let api = client else { throw ChatAPIError.connection }
        if let reason = encryptionChangeBlockReason { throw ChatTransferError(message: reason) }
        let epoch = accountGeneration, connection = encryptionManagementConnectionID
        var issuedWrite = false
        // Check discovered support before saving an uncertainty receipt. This
        // prepares no key request and never sends it.
        _ = try api.requestForCall(api: "SYNO.Chat.User", method: change.requiresConnection ? "change_password" : "set", version: change.requiresConnection ? 2 : 3)
        func current() throws {
            try checkConversationSession(epoch)
            if let reason = encryptionChangeBlockReason { throw ChatTransferError(message: reason) }
            if !issuedWrite {
                guard let pair = encryptionKeyPair,
                      pair.public_key.utf8.elementsEqual(original.owner.pair.public_key.utf8),
                      pair.private_key_enc.utf8.elementsEqual(original.owner.pair.private_key_enc.utf8) else {
                    throw ChatTransferError(message: "Encryption keys changed in another client. Refresh before continuing.")
                }
            }
            if change.requiresConnection, connection?.isEmpty != false || (connection?.utf8.count ?? 0) > 512 || connection != encryptionManagementConnectionID {
                throw ChatTransferError(message: "The live connection changed. Refresh encryption status before continuing.")
            }
        }
        return try await encryptionChanges.perform(change, original: original, read: { [self] in
            try await loadEncryptionManagement()
        }, dispatch: { [self] plan, connectionID in
            issuedWrite = true
            lockEncryption(reload: false)
            try await api.applyEncryptionManagementPlan(plan, connectionID: connectionID)
        }, check: current)
    }

    func unlockEncryption(password: String) throws {
        guard let pair = encryptionKeyPair else { throw ChatCryptoError.invalidKey }
        do { try encryption.unlock(pair, password: password) }
        catch { lockEncryption(); throw error }
        encryptionUnlocked = true
        encryptionGeneration += 1
        if selectedChannel?.encrypted == true { loadSelection() }
    }

    func lockEncryption(reload: Bool = true) {
        cancelPendingSavedFileOpen()
        closeImageViewer();closeDocumentPreview()
        cancelLinkPreviewImages()
        activeMessageEditor = nil
        messageEditorScope = nil
        loadedHistoryContentScope = nil
        encryptionGeneration += 1
        encryption.lock(); encryptionUnlocked = false
        for task in encryptedPreviewTasks.values { task.cancel() }
        encryptedPreviewTasks = [:]
        for record in downloadHistory where record.encrypted && record.state.active { cancelDownload(postID:record.postID) }
        if composerAttachmentContext?.encrypted == true { cancelComposerAttachmentPreparation() }
        if attachmentBatch?.encrypted == true { dismissAttachmentBatch() }
        if uploadIsEncrypted { uploadTask?.cancel() }
        thumbnailCache.removeAllObjects()
        for id in encryptedDraftChannels { drafts[id] = nil }
        for id in encryptedDraftThreads { threadDrafts[id] = nil }
        encryptedDraftChannels = []; encryptedDraftThreads = []
        let selectedIsEncrypted = selectedChannel?.encrypted == true
        let threadIsSensitive = threadRoot.map { root in
            channels.first(where: { $0.id == root.channel_id })?.encrypted != false
        } ?? false
        if threadIsSensitive, let root = threadRoot { threadDrafts[root.id] = nil }
        if selectedIsEncrypted || threadIsSensitive { closeThread() }
        if selectedIsEncrypted && reload { loadSelection() }
    }

    func canRead(_ channelID: Int64) -> Bool {
        guard !knownClosedChannelIDs.contains(channelID),let channel = channels.first(where: { $0.id == channelID }),channel.is_closed != true else { return false }
        if channel.type == "chatbot", let bot = channel.creator_id, blockedBotIDs.contains(bot) || pendingBotSubscriptions[bot] != nil || botSubscriptionRecoveryError != nil { return false }
        return !channel.encrypted || (try? encryption.key(for: channel)) != nil
    }
    func canAct(on post: ChatPost) -> Bool {
        canInteract && canRead(post.channel_id) && post.type != "system" && (post.delete_at ?? 0) == 0
            && !deletedPostIDs.contains(post.id) && !pendingMessageActions.contains(post.id)
    }
    func canChangeOwnMessage(_ post: ChatPost) -> Bool {
        canAct(on: post) && currentUserID != nil && post.creator_id == currentUserID
    }
    func canOpenReminderSource(_ post:ChatPost) -> Bool {
        guard let origin = post.props?.forward,origin.isReminder,
              canRead(post.channel_id),canRead(origin.origin_channel_id),
              (post.delete_at ?? 0) == 0,!deletedPostIDs.contains(post.id),!deletedPostIDs.contains(origin.origin_post_id) else { return false }
        return true
    }
    func openReminderSource(_ post:ChatPost) {
        guard canOpenReminderSource(post),let origin = post.props?.forward else { return }
        navigateToMessage(channelID:origin.origin_channel_id,postID:origin.origin_post_id,threadID:origin.navigationThreadID)
    }
    func wireMessage(_ text: String, channelID: Int64) throws -> String {
        guard let channel = channels.first(where: { $0.id == channelID }) else { throw ChatCryptoError.invalidKey }
        return try encryption.wireMessage(text, channel: channel)
    }
    func messageText(_ post: ChatPost) -> String {
        guard let channel = channels.first(where: { $0.id == post.channel_id }) else { return "Message unavailable" }
        if post.type == "system" { return post.systemEventText(names:names) }
        do { return try encryption.message(post.message, channel: channel) }
        catch { return encryptionUnlocked ? "Could not decrypt this message" : "Encrypted message" }
    }
    func attachmentName(_ post: ChatPost) -> String {
        guard let name = post.file_props?.name, let channel = channels.first(where: { $0.id == post.channel_id }) else { return "Attachment" }
        return (try? encryption.filename(name, channel: channel)) ?? "Encrypted attachment"
    }
    func canPreviewThumbnail(_ post: ChatPost) -> Bool { canRead(post.channel_id) }

    func restoreSavedSession(loadAccount: (() async throws -> ChatAccount?)? = nil) async {
        guard !connected, !connecting, !restoringSavedSession else { return }
        restoringSavedSession = true
        let expected = connectionGeneration
        defer { restoringSavedSession = false }
        do {
            let saved: ChatAccount?
            if let loadAccount { saved = try await loadAccount() }
            else { saved = try await ChatAccountKeychain.loadAsync() }
            guard !Task.isCancelled, !connected, !connecting, expected == connectionGeneration else { return }
            if let saved { await connect(using: saved) }
        } catch {
            guard !Task.isCancelled, !connected, !connecting, expected == connectionGeneration else { return }
            self.error = "Could not restore the saved sign-in. Sign in again or remove it from the sign-in window."
        }
    }

    func connect(using supplied: ChatAccount? = nil) async {
        guard !connecting else { return }
        flushRecoverableDrafts(); draftStore?.deactivate()
        emojiRecentSync.attach(nil)
        stickers.attach(nil);avatars.attach(nil);profileRefreshTask?.cancel();profileRefreshTask = nil;channelMemberIDs = [:]
        resetQuickSwitchState()
        pollAttachmentOwner = nil
        resetBotSubscriptionState()
        resetBotActionRecovery()
        resetSlashRecovery()
        resetScheduledCreationRecovery()
        resetPromotionRecovery()
        resetForwardRecovery()
        resetInvitationRecovery()
        resetEncryptedCreationRecovery()
        resetAdministratorStatus()
        guestManagement.deactivate()
        encryptionChanges.deactivate()
        archiveDeletions.deactivate()
        connecting = true
        hidesLinkPreviews = true; allowsReadStatus = false; displaySettingsRevision = UUID()
        lockEncryption(reload: false)
        disconnectLive()
        notifications.suspendAccount()
        connectionGeneration += 1
        pendingMessageActions.removeAll();postHashtagsNeedRefresh = [];pinStateNeedsRefresh = [];collectionWatches = [:];launcherBusy = false;launcherNeedsRefresh = false;regionalSettingsBusy = false;regionalSettingsNeedRefresh = false;regionalDisplay = nil;pairedDevicesBusy = false;pairedDevicesNeedRefresh = false;profileEditingBusy = false;profileEditingNeedsRefresh = false;manualPresenceBusy = false;manualPresenceNeedsRefresh = false;emojiPreferences.activate(scope: nil);nameSettings = nil;nameSettingsBusy = false;nameSettingsNeedRefresh = false;nameReadRevision = UUID();sidebarSettings = nil;sidebarSettingsBusy = false;sidebarSettingsNeedRefresh = false;sidebarAnchor = nil;sidebarReadRevision = UUID();appearanceSettings = nil;appearanceSettingsBusy = false;appearanceSettingsNeedRefresh = false;appearanceReadRevision = UUID();channelAlertsBusy = false;channelAlertsNeedRefresh = [];notificationPreferencesBusy = false;notificationPreferencesNeedRefresh = false;scheduleBusy = false;reminderBusy = false;conversationOrganizationBusy = false;unresolvedOrganization = [];unresolvedMembership = [];unresolvedChannelDetails = [];pendingHistoryArchives = [:];pendingChannelClosures = [:];knownClosedChannelIDs = [];channelActionRecoveryError = nil;channelActionScope = nil;channelActionJournal.deactivate();reminderRevision = UUID()
        let expected = connectionGeneration
        func checkCurrent() throws {
            try Task.checkCancellation()
            guard expected == connectionGeneration else { throw CancellationError() }
        }
        cancelTransfers()
        connected = false
        error = nil
        generation += 1
        historyTask?.cancel()
        closeThread()
        selection = nil
        channelPermissions = nil
        currentUserID = nil
        accountDisplay = ""
        directory = []
        channels = []; posts = []; names = [:]; channelNames = [:]
        client = nil
        thumbnailCache.removeAllObjects()
        defer { if expected == connectionGeneration { connecting = false } }
        do {
            let saved = try ChatConnectionAccount.select(supplied: supplied, current: account,
                allowOfficialImport: NativeChatAppConfiguration.allowsOfficialSessionImport)
            let imported: ChatAccount
            if let quick = saved.connectionAddress {
                guard let identity = saved.serverIdentity else { throw ChatSignInError.response }
                let resolved = try await ChatServerResolver().resolveServer(quick, expectedIdentity: identity)
                try checkCurrent()
                imported = ChatAccount(session: .init(baseURL: resolved.baseURL, sid: saved.session.sid, synoToken: saved.session.synoToken, tlsServerName: resolved.tlsServerName),
                    username: saved.username, importedFromOfficialApp: saved.importedFromOfficialApp,
                    connectionAddress: quick, serverIdentity: identity)
            } else { imported = saved }
            let api = try makeClient(imported.session)
            try await api.discover()
            try checkCurrent()
            let users = try await api.users()
            try checkCurrent()
            let loaded = try await api.channels()
            try checkCurrent()
            let permissions = try? await api.channelPermissions()
            try checkCurrent()
            let displaySettings = try? await api.displaySettings()
            try checkCurrent()
            let regional = try? await api.regionalDisplay()
            try checkCurrent()
            let sidebar = try? await api.sidebarSettings()
            try checkCurrent()
            let appearance = try? await api.appearanceSettings()
            try checkCurrent()
            let loadedNameSettings = try? await api.nameSettings()
            try checkCurrent()
            let loadedFormat = loadedNameSettings?.prefer_user_name_format ?? .nickname
            let loadedNames = Dictionary(users.map { ($0.user_id, loadedFormat.display($0)) }, uniquingKeysWith: { first, _ in first })
            let myID = users.first { $0.username?.caseInsensitiveCompare(imported.username) == .orderedSame }?.user_id
            let conversationNames = try await NativeConversationBootstrap.resolve(
                channels: loaded, names: loadedNames, currentUserID: myID,
                members: { try await api.members(channelID: $0) }, checkCurrent: checkCurrent)
            let loadedChannelNames = conversationNames.titles
            let loadedMemberIDs = conversationNames.memberIDs
            try checkCurrent()
            // Publish one coherent account snapshot only after all bootstrap reads finish.
            let verifiedDraftIdentity = ChatNotificationAccountScope.make(account: imported, userID: myID)
            if verifiedDraftIdentity == nil || draftIdentity != verifiedDraftIdentity {
                drafts = [:];pollDrafts = [:];pollAttachments = [:];pollAttachmentOwner = nil;snippetDrafts = [:];scheduleDrafts = [:]; threadDrafts = [:];threadDraftChannelIDs = [:];deletedPostIDs = []
            }
            draftIdentity = verifiedDraftIdentity
            account = imported
            accountDisplay = imported.username + " · " + (imported.session.baseURL.host ?? "Synology Chat")
            directory = users; names = loadedNames; channelNames = loadedChannelNames;channelMemberIDs = loadedMemberIDs
            currentUserID = myID; channelPermissions = permissions
            regionalDisplay = regional
            sidebarSettings = sidebar
            appearanceSettings = appearance
            nameSettings = loadedNameSettings
            hidesLinkPreviews = displaySettings?.hidesPreviews ?? true
            allowsReadStatus = displaySettings?.allow_read_status == true
            let notificationScope = verifiedDraftIdentity
            emojiPreferences.activate(scope: notificationScope)
            if notificationScope != nil { emojiRecentSync.attach(api) }
            notificationRouting.activate(scope: notificationScope)
            notifications.activateAccount(scope: notificationScope)
            restoreBotSubscriptions(scope: notificationScope)
            restoreBotActionRecovery(scope: notificationScope)
            restoreSlashRecovery(scope: notificationScope)
            restoreWebhookRecovery(scope:notificationScope)
            restoreScheduledCreationRecovery(scope:notificationScope)
            restorePromotionRecovery(scope:notificationScope)
            restoreForwardRecovery(scope:notificationScope)
            restoreInvitationRecovery(scope:notificationScope)
            restoreEncryptedCreationRecovery(scope:notificationScope)
            restoreConversationStarts(scope: notificationScope)
            restoreEncryptedConversationRecovery(scope:notificationScope)
            guestManagement.activate(scope: notificationScope)
            encryptionChanges.activate(scope: notificationScope, ownerID: myID)
            archiveDeletions.activate(scope: notificationScope, ownerID: myID)
            client = api
            if let notificationScope { restoreChannelActions(scope:notificationScope,loaded:loaded) }
            else { channelActionRecoveryError = "Could not identify this account for safe channel-action recovery. Archiving and closing are disabled." }
            stickers.attach(api);avatars.attach(api)
            channels = loaded.sorted { title($0).localizedCaseInsensitiveCompare(title($1)) == .orderedAscending }
            restoreRecoverableDrafts(scope: notificationScope)
            connected = true
            if restoreNotificationPreference, !notificationsEnabled, notificationDefaults?.bool(forKey: "nativePreviewNotificationsEnabled") == true {
                await toggleNotifications(restoreOnly: true)
                try checkCurrent()
            }
            do {
                let version = try await api.runtimeVersion()
                try checkCurrent()
                let connection = ChatLiveConnection(session: imported.session, version: version, sleepNotifications: NSWorkspace.shared.notificationCenter)
                live = connection
                connection.setUserActive(windowIsActive)
                connection.onStatus = { [weak self] status in
                    guard let self, self.connectionGeneration == expected else { return }
                    self.liveStatus = status
                }
                connection.onReady = { [weak self] in
                    guard let self, self.connectionGeneration == expected else { return }
                    self.resyncAfterConnection()
                }
                connection.onEvent = { [weak self] event in
                    guard let self, self.connectionGeneration == expected else { return }
                    self.handleLiveEvent(event)
                }
                connection.start()
            } catch is CancellationError { throw CancellationError() }
            catch {
                try checkCurrent()
                liveStatus = .offline
                self.error = "Conversations loaded, but live updates could not connect. Reconnect to try again."
            }
        } catch is CancellationError {
            if expected == connectionGeneration { signOutLocally() }
        } catch {
            guard expected == connectionGeneration, !Task.isCancelled else { return }
            self.error = (error as? LocalizedError)?.errorDescription ?? "Could not load conversations."
        }
    }

    private func cancelTransfers() {
        cancelPendingSavedFileOpen()
        closeDocumentPreview()
        cancelComposerAttachmentPreparation()
        dismissAttachmentBatch()
        uploadTask?.cancel(); uploadTask = nil; uploadIsEncrypted = false
        uploadProgress = nil
        for transfer in downloadTasks.values { transfer.task.cancel() }
        for panel in downloadPanels.values { panel.cancel(nil) }
        downloadPanels = [:]; activeDownloadIDs = [:]; downloadHistory = []; downloadSources = [:]; checkingDownloadFiles = false
        downloadTasks = [:]; downloading = []
        sending = false; uploading = false; channelManagementBusy = false
    }

    /// The viewport ticket prevents old layout callbacks from selecting an anchor
    /// in a replacement reader, even when account and channel are unchanged.
    func noteTimelineViewport(postID:Int64, atBottom:Bool, token:UUID, account:Int, channelID:Int64?) {
        guard token == historyViewportToken, account == accountGeneration, channelID == selection,
              posts.contains(where:{ $0.id == postID && $0.channel_id == channelID }) else { return }
        timelineViewport = (postID,atBottom)
        if viewingMessageContext || !atBottom { timelineRecoveryAnchor = postID }
    }

    /// Thread callbacks have their own scope: a main-history refresh must not
    /// invalidate a reader that is still looking at the same thread.
    func noteThreadViewport(postID:Int64,atBottom:Bool,token:UUID,account:Int,channelID:Int64?,rootID:Int64?) {
        guard token == nativeThreadViewportToken,account == accountGeneration,channelID == selection,
              let root = threadRoot,root.id == rootID,root.channel_id == channelID,
              replies.contains(where:{ $0.id == postID && $0.thread_id == root.id && $0.channel_id == channelID }) else { return }
        threadViewport = (postID,atBottom)
        if threadViewingContext || !atBottom { threadRecoveryAnchor = postID }
    }

    private func historyReadIsCurrent(_ expected:Int, epoch:Int, encryptionEpoch:Int, channel:ChatChannel) -> Bool {
        generation == expected && connectionGeneration == epoch && encryptionGeneration == encryptionEpoch
            && selection == channel.id && canRead(channel.id)
            && channels.contains(where:{ $0.id == channel.id && $0.encrypted == channel.encrypted && $0.channel_key_enc == channel.channel_key_enc })
    }

    func loadSelection(preservingThread: Bool = false, preservingViewport:Bool = false,returningToLatest:Bool = false) {
        // Only history actually loaded under this reader/account/key may be
        // refreshed in place. A matching channel ID alone is not ownership.
        let retainMain = preservingViewport && !returningToLatest && pendingLocation == nil && !posts.isEmpty
            && selectedChannel.map { channel in
                canRead(channel.id) && loadedHistoryContentScope == historyContentScope(channel)
                    && posts.allSatisfy { $0.channel_id == channel.id }
            } == true
        let retainedThread = preservingThread && pendingLocation == nil && !returningToLatest
            && threadRoot.map { $0.channel_id == selection && canRead($0.channel_id) } == true ? threadRoot : nil
        let retainEditor = messageEditorScope.map { scope in
            guard let channel = selectedChannel,scope.account == accountGeneration,scope.encryption == encryptionGeneration,
                  scope.channel == channel.id,scope.encrypted == channel.encrypted,scope.key == channel.channel_key_enc,canRead(channel.id) else { return false }
            return (retainMain && posts.contains { $0.id == scope.post })
                || (retainedThread?.channel_id == channel.id && (retainedThread?.id == scope.post
                    || replies.contains { $0.id == scope.post && $0.channel_id == channel.id && $0.thread_id == retainedThread?.id }))
        } == true
        let retainedAnchor:Int64? = retainMain && (viewingMessageContext || timelineViewport?.atBottom == false)
            ? timelineViewport?.postID ?? (viewingMessageContext ? timelineRecoveryAnchor ?? scrollPostID : nil) : nil
        let retainedContext = viewingMessageContext,retainedOlder = canLoadOlder,cachedLatest = posts.last?.id
        if !retainMain { historyViewportToken = UUID();timelineViewport = nil;loadedHistoryContentScope = nil }
        closeImageViewer()
        if !retainEditor { activeMessageEditor = nil;messageEditorScope = nil }
        canonicalReadKeys.removeAll()
        historyReadUpdates.removeAll()
        visibleChannelID = nil; visibleThreadTarget = nil
        let retainedThreadGeneration = threadGeneration
        // Retire a previous transport's loading ownership without discarding
        // the same thread's rows, pagination or viewport ticket.
        if retainedThread != nil { threadReadRevision = UUID();threadRefreshRequestID = nil;loadingThread = false }
        generation += 1
        let expected = generation
        historyTask?.cancel()
        if !retainMain { posts = [];scrollPostID = nil;viewingMessageContext = false }
        if retainedThread == nil { closeThread() }
        if !retainMain { canLoadOlder = false;canLoadNewer = false }
        error = nil
        loadingHistory = false
        guard let channel = selectedChannel, let api = client else { return }
        guard canRead(channel.id) else {
            error = "Unlock this encrypted conversation to read its messages."
            return
        }
        loadingHistory = true
        let explicitLocation = pendingLocation?.channel == channel.id ? pendingLocation : nil
        let location = explicitLocation
        if !retainMain { viewingMessageContext = location != nil;timelineRecoveryAnchor = location?.post }
        pendingLocation = nil
        let historyKey = beginHistoryRead()
        let epoch = connectionGeneration, encryptionEpoch = encryptionGeneration
        historyTask = Task {
            defer {
                historyReadUpdates[historyKey] = nil
                if generation == expected { loadingHistory = false }
            }
            do {
                if retainMain {
                    let windows = try await api.mainHistoryRefresh(channelID:channel.id,anchorID:retainedAnchor,
                                                                   context:retainedContext,cachedLatest:cachedLatest)
                    try Task.checkCancellation()
                    guard historyReadIsCurrent(expected,epoch:epoch,encryptionEpoch:encryptionEpoch,channel:channel) else { return }
                    let retainedIDs = Set(posts.map(\.id))
                    var merged = posts
                    for window in windows {
                        if window.complete { merged.removeAll() }
                        else if let lower = window.posts.first?.id,let upper = window.posts.last?.id {
                            merged.removeAll { $0.id >= lower && (window.latest || $0.id <= upper) }
                        } else if window.latest { merged.removeAll() }
                        merged = ChatTimeline.merge(merged,window.posts,excluding:deletedPostIDs)
                    }
                    posts = reconcileHistory(merged,key:historyKey,includeNew:!retainedContext,includeReplyUpdates:false,retainingUpdateIDs:retainedIDs)
                    canLoadOlder = !posts.isEmpty && !windows.contains { $0.complete }
                        && (retainedOlder || (cachedLatest == nil && windows.contains { $0.latest }))
                    if retainedContext { canLoadNewer = !posts.isEmpty }
                    // No new navigation intent: current input/geometry and any
                    // unsaved editor keep their existing reader ownership.
                } else {
                    let anchor = location.map { $0.thread ?? $0.post }
                    let result: [ChatPost]
                    if let anchor { result = try await api.context(channelID: channel.id, postID: anchor) }
                    else { result = try await api.posts(channelID: channel.id) }
                    try Task.checkCancellation()
                    guard historyReadIsCurrent(expected,epoch:epoch,encryptionEpoch:encryptionEpoch,channel:channel) else { return }
                    let snapshot = try ChatHistoryWindow.validated(result,channelID:channel.id)
                    posts = reconcileHistory(snapshot, key: historyKey, includeNew: location == nil, includeReplyUpdates: false)
                    canLoadOlder = anchor.map { ChatHistoryWindow.count(snapshot,before:$0) >= 15 } ?? (snapshot.count >= 30)
                    // Context alone cannot establish newer-side exhaustion.
                    canLoadNewer = location != nil
                    scrollAnchorAtTop = retainedAnchor != nil && explicitLocation == nil
                    scrollPostID = anchor
                    if returningToLatest,location == nil { latestHistoryScrollRevision = UUID() }
                }
                loadedHistoryContentScope = historyContentScope(channel)
                if let threadID = location?.thread, let root = posts.first(where: { $0.id == threadID }) {
                    await openThread(root, around: location?.post)
                } else if let retainedThread, threadGeneration == retainedThreadGeneration,
                          threadRoot?.id == retainedThread.id {
                    let readKey = UUID()
                    canonicalReadKeys[retainedThread.id] = readKey
                    let root = try await api.post(channelID: channel.id, postID: retainedThread.id)
                    guard historyReadIsCurrent(expected,epoch:epoch,encryptionEpoch:encryptionEpoch,channel:channel), threadGeneration == retainedThreadGeneration,
                          threadRoot?.id == retainedThread.id else { return }
                    guard !root.isReply else { throw ChatAPIError.invalidResponse }
                    if canonicalReadKeys[retainedThread.id] == readKey {
                        if posts.contains(where: { $0.id == root.id }) { applyCanonical(root, readKey: readKey) }
                        else { threadRoot = root }
                    }
                    await refreshOpenThreadPreservingReader()
                }
            } catch is CancellationError { }
            catch {
                guard generation == expected else { return }
                guard historyReadIsCurrent(expected,epoch:epoch,encryptionEpoch:encryptionEpoch,channel:channel) else { return }
                self.error = (error as? LocalizedError)?.errorDescription ?? "Could not load messages."
            }
        }
    }

    func navigateToMessage(channelID: Int64, postID: Int64, threadID: Int64? = nil) {
        guard channels.contains(where: { $0.id == channelID }) else { return }
        pendingLocation = (channelID, postID, threadID == postID ? nil : threadID)
        if selection == channelID { loadSelection() }
        else { selection = channelID }
    }

    func loadOlder() async { await loadHistoryPage(newer:false) }
    func loadNewer() async { await loadHistoryPage(newer:true) }

    private func loadHistoryPage(newer:Bool) async {
        guard !loadingHistory, (!newer || (viewingMessageContext && canLoadNewer)),
              let channel = selectedChannel,canRead(channel.id),let api = client,
              let boundary = newer ? posts.last?.id : posts.first?.id else { return }
        let expected = generation,epoch = connectionGeneration,encryptionEpoch = encryptionGeneration
        loadingHistory = true;error = nil
        let historyKey = beginHistoryRead()
        defer {
            historyReadUpdates[historyKey] = nil
            if generation == expected { loadingHistory = false }
        }
        do {
            let result:[ChatPost]
            if newer { result = try await api.newerPosts(channelID:channel.id,after:boundary) }
            else { result = try await api.posts(channelID:channel.id,before:boundary) }
            try Task.checkCancellation()
            guard historyReadIsCurrent(expected,epoch:epoch,encryptionEpoch:encryptionEpoch,channel:channel) else { return }
            let snapshot = try ChatHistoryWindow.validated(result,channelID:channel.id)
            let directional = snapshot.filter { newer ? $0.id > boundary : $0.id < boundary }
            // Preserve canonical changes received while the page was in flight;
            // never reintroduce the inclusive boundary or a confirmed deletion.
            let additions = reconcileHistory(directional,key:historyKey,includeNew:false,includeReplyUpdates:false)
            // Paging can take time. Preserve where the reader is now, rather
            // than undoing a scroll made while this request was in flight.
            let viewport = timelineViewport?.postID
            posts = ChatTimeline.merge(posts,additions,excluding:deletedPostIDs)
            if newer { canLoadNewer = directional.count >= 30 }
            else { canLoadOlder = directional.count >= 30 }
            if viewingMessageContext,let viewport,posts.contains(where:{ $0.id == viewport }) {
                scrollAnchorAtTop = true;scrollPostID = viewport
            }
        } catch is CancellationError {} catch {
            guard historyReadIsCurrent(expected,epoch:epoch,encryptionEpoch:encryptionEpoch,channel:channel) else { return }
            self.error = (error as? LocalizedError)?.errorDescription ?? "Could not load more messages."
        }
    }
    func signOutLocally() {
        guestManagement.deactivate()
        encryptionChanges.deactivate()
        archiveDeletions.deactivate()
        draftSaveTask?.cancel(); draftSaveTask = nil
        var draftClearFailed = false
        do { try draftStore?.clear() } catch { draftClearFailed = true }
        draftStore?.deactivate(); threadDraftChannelIDs = [:]
        draftRecoveryNotice = draftClearFailed ? "Signed out, but saved drafts could not be removed from this Mac. They may return when you sign in again." : nil
        emojiRecentSync.attach(nil)
        resetQuickSwitchState()
        resetBotSubscriptionState()
        resetBotActionRecovery()
        resetSlashRecovery()
        resetScheduledCreationRecovery()
        resetPromotionRecovery()
        resetForwardRecovery()
        resetInvitationRecovery()
        resetEncryptedCreationRecovery()
        resetAdministratorStatus()
        webhookBusy = false; uncertainWebhookIDs = []; uncertainWebhookCreates = []; uncertainWebhookRotations = [:]
        webhookActionJournal.deactivate();webhookRecoveryScope = nil;pendingWebhookActions = [:];webhookRecoveryError = nil
        slashCommandRequest = nil; slashBusy = false; uncertainSlashInvocations = []
        botActionsPending = []; uncertainBotActions = [:]; botActionStatus = [:]
        pendingPromotions = [:]
        calendarDetectionTask?.cancel(); calendarDetectionTask = nil; calendarDetection = nil; calendarSettingsBusy = false; calendarSettingsNeedRefresh = false; calendarPreferenceReadRevision = UUID(); calendarBusy = false; uncertainCalendarPosts = []
        stickers.attach(nil);avatars.attach(nil);profileRefreshTask?.cancel();profileRefreshTask = nil;channelMemberIDs = [:]
        hidesLinkPreviews = true; allowsReadStatus = false; displaySettingsRevision = UUID()
        lockEncryption(reload: false)
        disconnectLive()
        connectionGeneration += 1
        pendingMessageActions.removeAll();postHashtagsNeedRefresh = [];pinStateNeedsRefresh = [];collectionWatches = [:];launcherBusy = false;launcherNeedsRefresh = false;regionalSettingsBusy = false;regionalSettingsNeedRefresh = false;regionalDisplay = nil;pairedDevicesBusy = false;pairedDevicesNeedRefresh = false;profileEditingBusy = false;profileEditingNeedsRefresh = false;manualPresenceBusy = false;manualPresenceNeedsRefresh = false;emojiPreferences.activate(scope: nil);nameSettings = nil;nameSettingsBusy = false;nameSettingsNeedRefresh = false;nameReadRevision = UUID();sidebarSettings = nil;sidebarSettingsBusy = false;sidebarSettingsNeedRefresh = false;sidebarAnchor = nil;sidebarReadRevision = UUID();appearanceSettings = nil;appearanceSettingsBusy = false;appearanceSettingsNeedRefresh = false;appearanceReadRevision = UUID();channelAlertsBusy = false;channelAlertsNeedRefresh = [];notificationPreferencesBusy = false;notificationPreferencesNeedRefresh = false;scheduleBusy = false;reminderBusy = false;conversationOrganizationBusy = false;unresolvedOrganization = [];unresolvedMembership = [];unresolvedChannelDetails = [];pendingHistoryArchives = [:];pendingChannelClosures = [:];knownClosedChannelIDs = [];channelActionRecoveryError = nil;channelActionScope = nil;channelActionJournal.deactivate();reminderRevision = UUID()
        cancelTransfers()
        closeThread()
        connecting = false
        generation += 1
        historyTask?.cancel()
        client = nil
        loadingHistory = false
        account = nil
        currentUserID = nil
        connected = false
        selection = nil
        channels = []; posts = []; names = [:]; channelNames = [:]
        drafts = [:];pollDrafts = [:];pollAttachments = [:];pollAttachmentOwner = nil;snippetDrafts = [:];scheduleDrafts = [:]; threadDrafts = [:]; threadRoot = nil; replies = []
        accountDisplay = ""
        directory = []
        channelPermissions = nil
        notificationRouting.signOut()
        pendingLocation = nil
        error = nil
        notifications.reset()
    }

    func signOutNativeSession() async {
        guard canRevokeSession, !sending, !connecting, let api = client, let account else { return }
        connecting = true
        let expected = connectionGeneration
        defer { if expected == connectionGeneration { connecting = false } }
        do {
            do { try await api.revokeSession() }
            catch ChatAPIError.server(let code) where [105, 106, 107, 119].contains(code) {
                // An already expired session no longer needs revoking.
            }
            guard expected == connectionGeneration else { return }
            var warning: String?
            do { try await ChatAccountKeychain.removeAsync(ifMatching: account) }
            catch { warning = "Signed out, but the saved sign-in could not be removed. Remove it from the sign-in window." }
            guard expected == connectionGeneration else { return }
            signOutLocally()
            error = warning
        } catch {
            guard expected == connectionGeneration else { return }
            self.error = "Could not confirm sign-out. You are still connected; try again when the server is available."
        }
    }

    func prepareForTermination() { flushRecoverableDrafts(); draftStore?.deactivate(); cancelTransfers();lockEncryption(reload:false);disconnectLive() }

    private func restoreRecoverableDrafts(scope: String?) {
        guard let draftStore, let scope else { return }
        restoringDrafts = true
        defer { restoringDrafts = false }
        do {
            let saved = try draftStore.activate(scope: scope)
            let readable = Set(channels.filter { !$0.encrypted && $0.is_closed != true && !knownClosedChannelIDs.contains($0.id) }.map(\.id))
            for item in saved where readable.contains(item.channelID) {
                if let root = item.rootID {
                    if threadDrafts[root] == nil { threadDrafts[root] = item.text }
                    threadDraftChannelIDs[root] = item.channelID
                } else if drafts[item.channelID] == nil { drafts[item.channelID] = item.text }
            }
            try draftStore.replace(recoverableDraftEntries())
            draftRecoveryNotice = nil
        } catch {
            draftRecoveryNotice = "Saved drafts could not be restored. New drafts will stay in memory for this session."
        }
    }
    private func recoverableDraftEntries() -> [NativeDraftStore.Entry] {
        let allowed = Set(channels.filter { !$0.encrypted && $0.is_closed != true && !knownClosedChannelIDs.contains($0.id) }.map(\.id))
        let main = drafts.compactMap { id, text -> NativeDraftStore.Entry? in
            guard allowed.contains(id), !encryptedDraftChannels.contains(id), !text.isEmpty,
                  text.utf8.count <= NativeDraftStore.maximumTextBytes else { return nil }
            return .init(channelID: id, rootID: nil, text: text)
        }
        let replies = threadDrafts.compactMap { root, text -> NativeDraftStore.Entry? in
            guard let channel = threadDraftChannelIDs[root], allowed.contains(channel), !encryptedDraftThreads.contains(root),
                  !text.isEmpty, text.utf8.count <= NativeDraftStore.maximumTextBytes else { return nil }
            return .init(channelID: channel, rootID: root, text: text)
        }
        return Array((main + replies).sorted { $0.key < $1.key }.prefix(NativeDraftStore.maximumEntries))
    }
    private func persistRecoverableDrafts() {
        guard !restoringDrafts, draftStore?.scope != nil else { return }
        draftSaveTask?.cancel()
        draftSaveTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 350_000_000); try Task.checkCancellation() }
            catch { return }
            self?.flushRecoverableDrafts()
        }
    }
    /// Flush before quit/reconnect; observer persistence also removes acknowledged sent captions.
    func flushRecoverableDrafts() {
        draftSaveTask?.cancel(); draftSaveTask = nil
        guard !restoringDrafts, let draftStore, draftStore.scope != nil else { return }
        do { try draftStore.replace(recoverableDraftEntries()); draftRecoveryNotice = nil }
        catch { draftRecoveryNotice = "Drafts could not be saved on this Mac. Quitting may lose your latest changes." }
    }

    func previewDidDisappear() {
        updateWindowVisibility(false, applicationActive: false)
        updateReadingVisibility(active: false, atBottom: false)
        updateThreadReadingVisibility(active: false, atBottom: false)
        // Keep unread badges and live state current while the window is closed,
        // including when alert delivery is disabled.
    }

    func disconnectLive() {
        readState?.stop(); readState = nil
        threadReadState?.stop(); threadReadState = nil
        visibleChannelID = nil; visibleThreadTarget = nil
        live?.stop()
        live = nil
        sidebarRefreshTask?.cancel(); sidebarRefreshTask = nil; sidebarRefreshID = nil
        for task in eventTasks.values { task.cancel() }
        eventTasks = [:]
        canonicalReadKeys.removeAll()
        historyReadUpdates.removeAll()
    }

    func resyncAfterConnection() {
        guard connected, client != nil else { return }
        emojiRecentSync.refresh()
        // A replacement socket does not replay missed changes. Retire reads from
        // the previous transport before asking open collections for fresh pages.
        for task in eventTasks.values { task.cancel() }
        eventTasks = [:]; canonicalReadKeys.removeAll()
        refreshDisplaySettings()
        refreshSidebarSettingsInBackground()
        refreshAppearanceSettingsInBackground()
        refreshNameSettingsInBackground()
        readState?.stop()
        threadReadState?.stop(); threadReadState = nil
        // The canonical Peter read-state lifecycle has been verified against the live server.
        if !CommandLine.arguments.contains("--disable-native-read-state"), let api = client, let id = live?.connectionID {
            let state = ChatReadState(api: api, connectionID: id)
            state.onRead = { [weak self] _ in self?.refreshChannels() }
            readState = state
            let threadState = ChatThreadReadState(api: api)
            threadState.onRead = { [weak self] _ in self?.refreshChannels() }
            threadReadState = threadState
        }
        // Reload authoritative recent history on every connection; do not assume event replay exists.
        if !openPendingNotification() { loadSelection(preservingThread: true,preservingViewport:true) }
        refreshChannels()
        collectionResyncs.send(connectionGeneration)
    }

    #if DEBUG
    func suspendLiveForProbe() { live?.stop() }
    func resumeLiveForProbe() { live?.start() }
    #endif

    func updateWindowVisibility(_ visible: Bool, applicationActive: Bool, applicationHidden: Bool = false) {
        windowIsVisible = visible
        updateWindowActivity(applicationActive, applicationHidden: applicationHidden)
    }

    func updateWindowActivity(_ active: Bool, applicationHidden: Bool = false) {
        // AppKit can leave the app active after its last window closes. Late
        // focus observers must not advertise that closed window as an active user.
        windowIsActive = active && !applicationHidden && windowIsVisible
        live?.setUserActive(windowIsActive)
    }

    func updateReadingVisibility(active: Bool, atBottom: Bool) {
        readLog.notice("Read visibility active=\(active, privacy: .public) bottom=\(atBottom, privacy: .public) live=\(self.canInteract, privacy: .public) loading=\(self.loadingHistory, privacy: .public) context=\(self.viewingMessageContext, privacy: .public) thread=\(self.threadRoot != nil, privacy: .public) coordinator=\(self.readState != nil, privacy: .public)")
        visibleChannelID = active && atBottom && !loadingHistory && !viewingMessageContext && threadRoot == nil && imageViewerPost == nil && !documentPreviewIsPresented && !conversationLibraryVisible && attachmentBatch == nil && !preparingComposerAttachment ? selection : nil
        let target: ChatReadState.Target?
        if active, atBottom, canInteract, !loadingHistory, !viewingMessageContext, threadRoot == nil, imageViewerPost == nil,!documentPreviewIsPresented, !conversationLibraryVisible,attachmentBatch == nil,!preparingComposerAttachment,
           selectedChannel.map({ canRead($0.id) }) == true, let id = selection, let latest = posts.map(\.create_at).max(),
           latest.isFinite, latest >= 0, latest < Double(Int64.max) {
            let watermark = selectedChannel?.last_view_at ?? 0
            let timestamp = max(latest, watermark.isFinite && watermark >= 0 && watermark < Double(Int64.max) ? watermark : 0)
            target = .init(channelID: id, timestamp: Int64(timestamp))
        } else { target = nil }
        readState?.update(target)
    }

    func updateThreadReadingVisibility(active: Bool, atBottom: Bool) {
        let target: ChatThreadReadState.Target?
        if active, atBottom, canInteract, !loadingThread, !threadViewingContext, imageViewerPost == nil,!documentPreviewIsPresented, !conversationLibraryVisible,attachmentBatch == nil,!preparingComposerAttachment,
           let root = threadRoot, root.channel_id == selection, selectedChannel.map({ canRead($0.id) }) == true {
            target = .init(channelID: root.channel_id, rootID: root.id, lastPostID: replies.last?.id ?? root.id)
        } else { target = nil }
        visibleThreadTarget = target
        threadReadState?.update(target)
    }

    private func updateDockBadge() {
        // The normal wrapper owns its own Dock presentation. Only the standalone
        // API preview manages this label, including when its window is closed.
        guard NativeChatAppConfiguration.standalone else { return }
        let count = channels.reduce(0) { min(9999, $0 + $1.badgeUnreadCount) }
        notifications.updateBadge(count)
    }

    func testNotification() {
        guard notificationsEnabled else { return }
        notificationDiagnosticState = .submittingTest
        notifications.deliver(.init(channelID: selection ?? 0,
            postID: -Int64(Date().timeIntervalSince1970 * 1000), threadID: nil,
            title: "Synology Chat", body: notifications.testMessageBody, sound: true))
    }

    func toggleNotifications(restoreOnly: Bool = false) async {
        guard connected else { return }
        if restoreOnly && notificationsEnabled { return }
        let expected = connectionGeneration
        let attempt = UUID()
        notificationToggleID = attempt
        if notificationsEnabled { notifications.disable() }
        else {
            notifications.activateAccount(scope: notificationRouting.activeScope)
            await notifications.enable(requestPermission: !restoreOnly)
        }
        guard expected == connectionGeneration, notificationToggleID == attempt, !Task.isCancelled else { return }
        notificationsEnabled = notifications.isEnabled
        notificationDefaults?.set(notificationsEnabled, forKey: "nativePreviewNotificationsEnabled")
        configureNotificationCallbacks()
    }

    func prepareNotificationWindow(reveal: @escaping () -> Void) {
        revealWindow = reveal
        configureNotificationCallbacks()
        notifications.prepareForResponses()
    }

    private func configureNotificationCallbacks() {
        notifications.onDelivery = { [weak self] result in self?.notificationDiagnosticState = result }
        notifications.onOpen = { [weak self] destination in
            self?.receiveNotification(destination)
        }
    }

    func receiveNotification(_ destination: ChatNotificationDestination) {
        guard notificationRouting.receive(destination) else { return }
        revealWindow?()
        _ = openPendingNotification()
    }

    @discardableResult
    func openPendingNotification() -> Bool {
        guard connected, liveStatus == .live, let location = notificationRouting.takePending() else { return false }
        guard channels.contains(where: { $0.id == location.channelID }) else {
            error = "This notification's conversation is no longer available."
            return true
        }
        navigateToMessage(channelID: location.channelID, postID: location.postID, threadID: location.threadID)
        return true
    }

    private func refreshChannels() {
        guard let api = client else { return }
        sidebarRefreshTask?.cancel()
        let expected = connectionGeneration
        let key = UUID()
        sidebarRefreshID = key
        sidebarRefreshTask = Task { [weak self] in
            defer {
                if self?.sidebarRefreshID == key { self?.sidebarRefreshTask = nil; self?.sidebarRefreshID = nil }
            }
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
                let updated = try await api.channels()
                guard let self, self.connectionGeneration == expected, !Task.isCancelled else { return }
                self.channels = updated.filter { !self.knownClosedChannelIDs.contains($0.id) && $0.is_closed != true }.sorted { self.title($0).localizedCaseInsensitiveCompare(self.title($1)) == .orderedAscending }
                if let selected = self.selection, !updated.contains(where: { $0.id == selected }) {
                    self.selection = nil
                    self.generation += 1
                    self.historyTask?.cancel()
                    self.posts = []; self.threadRoot = nil; self.replies = []
                    self.error = "This conversation is no longer available."
                }
            } catch { /* Preserve existing data and connection status for transient sidebar refresh failures. */ }
        }
    }

    func handleLiveEvent(_ received: ChatLiveEvent) {
        let event = received.normalized
        if ["client.broadcast","client.user.update","client.user.create","client.user.delete","client.user.updatekey"].contains(event.name) { scheduleProfileRefresh() }
        if ["client.post.reminder.set","client.post.reminder.delete"].contains(event.name),connected { reminderRevision = UUID();return }
        if event.name == "client.setting.update" {
            guard connected else { return }
            displaySettingsRevision = UUID()
            if case .bool(let hidden)? = event.payload["hide_post_url_preview"] { hidesLinkPreviews = hidden }
            else { hidesLinkPreviews = true }
            if case .bool(let enabled)? = event.payload["allow_read_status"] { allowsReadStatus = enabled }
            else { allowsReadStatus = false }
            return
        }
        if event.name == "client.channel.close",connected,let channelID = event.channelID {
            invalidateClosedChannel(channelID)
            refreshChannels()
            return
        }
        if event.name == "client.channel.archive",connected,let channelID = event.channelID {
            // Old live rows may remain in a collection or an in-flight read. They
            // must not become actionable again after moving into read-only history.
            let cached = posts + replies + imageViewerPosts + [threadRoot,documentPreviewPost].compactMap { $0 }
            deletedPostIDs.formUnion(cached.filter { $0.channel_id == channelID }.map(\.id))
            if selection == channelID {
                closeDocumentPreview();pendingLocation = nil
                loadSelection()
            }
            refreshChannels()
            return
        }
        if event.name == "client.notification.create", let api = client {
            refreshChannels()
            notificationEventCount += 1
            deliveryLog.notice("Server notification event received; enabled=\(self.notificationsEnabled, privacy: .public)")
            notificationDiagnosticState = .serverEvents(notificationEventCount,enabled:notificationsEnabled)
            guard notificationsEnabled else { return }
            let expected = connectionGeneration
            let key = UUID()
            eventTasks[key] = Task { [weak self] in
                defer { self?.eventTasks[key] = nil }
                // Re-read privacy settings so a change made in another client takes effect.
                let preferences = try? await api.notificationPreferences()
                let clock = preferences?.hasSnoozeConfiguration == true ? try? await api.serverClock() : nil
                guard let self, expected == self.connectionGeneration, !Task.isCancelled else { return }
                if preferences?.hasSnoozeConfiguration == true && clock == nil {
                    self.deliveryLog.notice("Notification held: snooze clock unavailable")
                    self.notificationDiagnosticState = .snoozeClockUnavailable;return
                }
                let channelID = event.payload["post"]?["channel_id"]?.integer
                let channel = self.channels.first(where: { $0.id == channelID })
                let name = channel.map(self.title) ?? "Synology Chat"
                let personalReminderChannel = channel?.type == "synobot" && channel?.creator_id == self.currentUserID ? channelID : nil
                let visible = self.notificationVisibleLocation
                if let message = ChatNotificationMessage.make(event: event, preferences: preferences,
                    currentUserID: self.currentUserID, visibleChannelID: visible?.channelID,
                    visibleThreadID: visible?.threadID, channelTitle: name,
                    contentIsEncrypted: self.channels.first(where: { $0.id == channelID })?.encrypted ?? true,
                    now:clock?.date() ?? Date(),accountTimeZone:self.directory.first(where:{ $0.user_id == self.currentUserID })?.profileTimeZone,personalReminderChannelID:personalReminderChannel) {
                    self.notificationDiagnosticState = .submitting
                    self.deliveryLog.notice("Notification policy accepted; preferencesAvailable=\(preferences != nil, privacy: .public)")
                    self.notifications.deliver(message)
                } else {
                    self.notificationDiagnosticState = .filtered
                    self.deliveryLog.notice("Notification policy filtered event; preferencesAvailable=\(preferences != nil, privacy: .public)")
                }
            }
            return
        }
        if event.name == "client.post.create" {
            incomingPostCount += 1
            deliveryLog.notice("Post event received; serverNotificationSeen=\(self.notificationEventCount > 0, privacy: .public)")
            if notificationEventCount == 0 {
                notificationDiagnosticState = .postsWithoutNotification(incomingPostCount)
            }
        }
        guard event.name.hasPrefix("client.post.") else {
            if event.name == "client.broadcast" || event.name.hasPrefix("client.channel.") { refreshChannels() }
            return
        }
        refreshChannels()
        guard let channelID = event.channelID, let postID = event.postID else { return }
        if event.name == "client.post.delete" {
            collectionChanges.send(.init(accountGeneration:connectionGeneration,channelID:channelID,postID:postID,state:.deleted))
            pollRevision &+= 1
            let rootID = replies.first(where: { $0.id == postID })?.thread_id
                ?? event.payload["thread_id"]?.integer ?? event.payload["data"]?["thread_id"]?.integer
            canonicalReadKeys[postID] = UUID()
            if imageViewerPosts.contains(where: { $0.id == postID }) { closeImageViewer() }
            if documentPreviewPost?.id == postID { closeDocumentPreview() }
            deletedPostIDs.insert(postID)
            posts.removeAll { $0.id == postID }
            replies.removeAll { $0.id == postID }
            if threadRoot?.id == postID { threadRoot = nil }
            if let rootID, rootID != 0, rootID != postID { refreshThreadHeader(channelID: channelID, rootID: rootID) }
            return
        }
        guard channelID == selection || collectionWatchesChannel(channelID) && canRead(channelID), let api = client else { return }
        collectionChanges.send(.init(accountGeneration:connectionGeneration,channelID:channelID,postID:postID,state:.invalidated))
        let expected = generation, expectedAccount = connectionGeneration
        let key = UUID()
        canonicalReadKeys[postID] = key
        eventTasks[key] = Task { [weak self] in
            defer {
                self?.eventTasks[key] = nil
            }
            do {
                let threadID = event.payload["thread_id"]?.integer ?? event.payload["data"]?["thread_id"]?.integer
                let post = try await api.post(channelID: channelID, postID: postID, threadID: threadID)
                guard let self, self.connectionGeneration == expectedAccount, self.canonicalReadKeys[postID] == key, !Task.isCancelled else { return }
                if self.generation == expected { self.applyCanonical(post,readKey:key) }
                else if self.collectionWatchesChannel(channelID), self.canRead(channelID) { self.collectionChanges.send(.init(accountGeneration:expectedAccount,channelID:channelID,postID:postID,state:.updated(post))) }
                if post.isReply, let root = post.thread_id { self.refreshThreadHeader(channelID: channelID, rootID: root) }
            } catch {
                guard let self, self.connectionGeneration == expectedAccount, self.generation == expected, self.canonicalReadKeys[postID] == key, !Task.isCancelled else { return }
                self.error = "A message changed, but it could not be loaded. Refresh this conversation."
            }
        }
    }

    private func refreshThreadHeader(channelID: Int64, rootID: Int64) {
        guard channelID == selection, let api = client else { return }
        let expected = generation
        let key = UUID()
        canonicalReadKeys[rootID] = key
        eventTasks[key] = Task { [weak self] in
            defer {
                self?.eventTasks[key] = nil
            }
            do {
                let root = try await api.post(channelID: channelID, postID: rootID)
                guard let self, self.generation == expected, self.canonicalReadKeys[rootID] == key, !Task.isCancelled else { return }
                self.applyCanonical(root, readKey: key)
            } catch { /* The message operation is already confirmed. Reopening the thread retries this read. */ }
        }
    }

    private func beginHistoryRead() -> UUID {
        let key = UUID()
        historyReadUpdates[key] = [:]
        return key
    }

    private func reconcileHistory(_ snapshot: [ChatPost], key: UUID, includeNew: Bool, includeReplyUpdates: Bool = true, retainingUpdateIDs:Set<Int64> = []) -> [ChatPost] {
        let ids = Set(snapshot.map(\.id))
        let updates = (historyReadUpdates[key] ?? [:]).values.filter {
            (includeReplyUpdates || !$0.isReply) && (includeNew || ids.contains($0.id) || retainingUpdateIDs.contains($0.id))
        }
        return ChatTimeline.merge(snapshot, Array(updates), excluding: deletedPostIDs)
    }

    private func applyCanonical(_ post: ChatPost, readKey: UUID? = nil) {
        guard !deletedPostIDs.contains(post.id) else { return }
        // Keep the last read ticket after completion: an older write response can
        // arrive after the newer read has already published its canonical state.
        if let readKey { guard canonicalReadKeys[post.id] == readKey else { return } }
        else if canonicalReadKeys[post.id] != nil { return }
        if canRead(post.channel_id) { collectionChanges.send(.init(accountGeneration:connectionGeneration,channelID:post.channel_id,postID:post.id,state:.updated(post))) }
        guard post.channel_id == selection else { return }
        if post.type == "vote" { pollRevision &+= 1 }
        for key in Array(historyReadUpdates.keys) { historyReadUpdates[key]?[post.id] = post }
        if !post.isReply, !viewingMessageContext || posts.contains(where: { $0.id == post.id }) {
            posts = ChatTimeline.merge(posts, [post])
        }
        if threadRoot?.id == post.id { threadRoot = post }
        else if threadRoot?.id == post.thread_id, !threadViewingContext || replies.contains(where: { $0.id == post.id }) {
            replies = ChatTimeline.merge(replies, [post])
        }
    }

    func closeThread() {
        nativeThreadScrollPostID = nil
        if composerAttachmentContext?.rootID != nil { cancelComposerAttachmentPreparation() }
        if attachmentBatch?.rootID != nil { dismissAttachmentBatch() }
        closeImageViewer();closeDocumentPreview()
        visibleThreadTarget = nil
        threadReadState?.update(nil)
        threadGeneration += 1
        threadViewport = nil;threadRecoveryAnchor = nil;threadRefreshRequestID = nil;threadReadRevision = UUID()
        threadRoot = nil; replies = []
        loadingThread = false; canLoadOlderReplies = false;canLoadNewerReplies = false; threadViewingContext = false
    }

    func openThread(_ post: ChatPost, around replyID: Int64? = nil) async {
        guard let api = client, post.channel_id == selection, canRead(post.channel_id) else { return }
        nativeThreadScrollPostID = replyID
        cancelComposerAttachmentPreparation()
        if attachmentBatch != nil { dismissAttachmentBatch() }
        threadGeneration += 1
        threadViewport = nil;threadRecoveryAnchor = replyID;threadRefreshRequestID = nil;threadReadRevision = UUID()
        let expectedThread = threadGeneration
        let revision = threadReadRevision
        let expected = generation
        threadRoot = post
        replies = []
        canLoadOlderReplies = false
        canLoadNewerReplies = false
        threadViewingContext = replyID != nil
        loadingThread = true
        let historyKey = beginHistoryRead()
        defer {
            historyReadUpdates[historyKey] = nil
            if generation == expected, threadGeneration == expectedThread,threadReadRevision == revision { loadingThread = false }
        }
        do {
            let items = try await api.threadPosts(channelID: post.channel_id, rootID: post.id, before: replyID)
            guard generation == expected, threadGeneration == expectedThread,threadReadRevision == revision, threadRoot?.id == post.id else { return }
            replies = reconcileHistory(items, key: historyKey, includeNew: replyID == nil)
                .filter { $0.id != post.id && $0.thread_id == post.id }
            canLoadOlderReplies = items.count >= 30 && !replies.isEmpty
            // A context page ends at its target, not necessarily the live tail.
            // Only a forward read can establish exhaustion on that side.
            canLoadNewerReplies = replyID != nil && !replies.isEmpty
        } catch {
            guard generation == expected, threadGeneration == expectedThread,threadReadRevision == revision else { return }
            self.error = "Could not load this thread. Close it and try again."
        }
    }

    /// Refresh only authoritative windows while retaining the same reader.
    /// A recent page cannot stand in for all the older replies already loaded.
    func refreshOpenThreadPreservingReader() async {
        guard let root = threadRoot,let channel = selectedChannel,root.channel_id == channel.id,
              canRead(channel.id),let api = client else { return }
        let expected = generation,epoch = connectionGeneration,encryptionEpoch = encryptionGeneration,thread = threadGeneration
        let request = UUID(),historyKey = beginHistoryRead()
        let context = threadViewingContext
        let anchor = (context || threadViewport?.atBottom == false)
            ? threadViewport?.postID ?? threadRecoveryAnchor ?? replies.first?.id : nil
        let previousCanLoadOlder = canLoadOlderReplies
        let cachedLatest = replies.last?.id
        threadReadRevision = UUID();threadRefreshRequestID = request;loadingThread = true
        func isCurrent() -> Bool {
            !Task.isCancelled && historyReadIsCurrent(expected,epoch:epoch,encryptionEpoch:encryptionEpoch,channel:channel)
                && threadGeneration == thread && threadRoot?.id == root.id && threadRoot?.channel_id == channel.id
                && threadRefreshRequestID == request && threadViewingContext == context
        }
        defer {
            historyReadUpdates[historyKey] = nil
            if threadRefreshRequestID == request {
                threadRefreshRequestID = nil
                if generation == expected,threadGeneration == thread { loadingThread = false }
            }
        }
        do {
            var windows:[(posts:[ChatPost],latest:Bool,complete:Bool)] = []
            if let anchor {
                let items = try await api.threadWindow(channelID:channel.id,rootID:root.id,postID:anchor,previous:15,next:15)
                guard isCurrent() else { return }
                windows.append((items,false,false))
            }
            if !context || anchor == nil {
                let raw = try await api.threadPosts(channelID:channel.id,rootID:root.id)
                guard isCurrent() else { return }
                // Match the anchored API's strict identity/scope contract before
                // treating any returned range as authoritative.
                guard raw.count <= 31,Set(raw.map(\.id)).count == raw.count,
                      raw.allSatisfy({ $0.id > 0 && $0.channel_id == channel.id && ($0.id == root.id ? !$0.isReply : $0.thread_id == root.id) }) else { throw ChatAPIError.invalidResponse }
                var recent = ChatTimeline.merge([],raw.filter { $0.id != root.id })
                var complete = recent.count < 30
                // More than thirty missed replies can leave a hole between
                // cached history and the new tail. Bridge that interval before
                // publishing it, rather than silently presenting a partial list.
                var bridgeReads = 0
                while !complete,let cachedLatest,let oldest = recent.first?.id,oldest > cachedLatest {
                    guard bridgeReads < 10 else { throw ChatAPIError.invalidResponse }
                    let page = try await api.threadWindow(channelID:channel.id,rootID:root.id,postID:oldest,previous:30,next:0)
                    guard isCurrent() else { return }
                    let earlier = page.filter { $0.id < oldest }
                    complete = page.count < 30
                    guard complete || !earlier.isEmpty else { throw ChatAPIError.invalidResponse }
                    recent = ChatTimeline.merge(recent,page)
                    bridgeReads += 1
                }
                windows.append((recent,true,complete))
            }
            guard isCurrent() else { return }
            let retainedIDs = Set(replies.map(\.id))
            var merged = replies
            for window in windows {
                if window.complete {
                    // A short latest page, or a bridged walk to the earliest
                    // reply, establishes the entire thread's remaining rows.
                    merged.removeAll()
                } else if let lower = window.posts.map(\.id).min(),let upper = window.posts.map(\.id).max() {
                    // A latest page also establishes that no cached reply newer
                    // than its newest row remains. An anchored page establishes
                    // only the closed interval it actually returned.
                    merged.removeAll { $0.id >= lower && (window.latest || $0.id <= upper) }
                } else if window.latest { merged.removeAll() }
                merged = ChatTimeline.merge(merged,window.posts,excluding:deletedPostIDs)
            }
            replies = reconcileHistory(merged,key:historyKey,includeNew:!context,retainingUpdateIDs:retainedIDs)
                .filter { $0.id != root.id && $0.channel_id == channel.id && $0.thread_id == root.id }
            canLoadOlderReplies = replies.isEmpty || windows.contains(where:{ $0.complete }) ? false
                : previousCanLoadOlder || (cachedLatest == nil && windows.contains(where:{ $0.latest }))
            if context { canLoadNewerReplies = !replies.isEmpty }
        } catch is CancellationError { }
        catch {
            guard isCurrent() else { return }
            self.error = (error as? LocalizedError)?.errorDescription ?? "Could not load this thread. Close it and try again."
        }
    }

    func loadOlderReplies() async {
        guard !loadingThread, canLoadOlderReplies, let root = threadRoot,
              let oldest = replies.first?.id, let api = client else { return }
        let expected = generation
        let expectedThread = threadGeneration
        let revision = threadReadRevision
        loadingThread = true
        let historyKey = beginHistoryRead()
        defer {
            historyReadUpdates[historyKey] = nil
            if generation == expected, threadGeneration == expectedThread,threadReadRevision == revision { loadingThread = false }
        }
        do {
            let items = try await api.threadPosts(channelID: root.channel_id, rootID: root.id, before: oldest)
            guard generation == expected, threadGeneration == expectedThread,threadReadRevision == revision, threadRoot?.id == root.id else { return }
            let older = reconcileHistory(items, key: historyKey, includeNew: false)
                .filter { $0.id < oldest && $0.id != root.id && $0.thread_id == root.id }
            replies = ChatTimeline.merge(replies, older)
            canLoadOlderReplies = items.count >= 30 && !older.isEmpty
        } catch {
            guard generation == expected, threadGeneration == expectedThread,threadReadRevision == revision else { return }
            self.error = "Could not load earlier replies. Try again."
        }
    }

    func loadNewerReplies() async {
        guard !loadingThread,threadViewingContext,canLoadNewerReplies,let root = threadRoot,
              let channel = selectedChannel,root.channel_id == channel.id,canRead(channel.id),
              let newest = replies.last?.id,let api = client else { return }
        let expected = generation,epoch = connectionGeneration,encryptionEpoch = encryptionGeneration
        let thread = threadGeneration,revision = threadReadRevision
        let historyKey = beginHistoryRead()
        loadingThread = true
        func isCurrent()->Bool {
            !Task.isCancelled && historyReadIsCurrent(expected,epoch:epoch,encryptionEpoch:encryptionEpoch,channel:channel)
                && threadGeneration == thread && threadReadRevision == revision && threadRoot?.id == root.id && threadViewingContext
        }
        defer {
            historyReadUpdates[historyKey] = nil
            if generation == expected,threadGeneration == thread,threadReadRevision == revision { loadingThread = false }
        }
        do {
            let items = try await api.threadWindow(channelID:channel.id,rootID:root.id,postID:newest,previous:0,next:30)
            guard isCurrent() else { return }
            let later = reconcileHistory(items.filter { $0.id > newest },key:historyKey,includeNew:false)
                .filter { $0.id != root.id && $0.channel_id == channel.id && $0.thread_id == root.id }
            replies = ChatTimeline.merge(replies,later,excluding:deletedPostIDs)
            // An inclusive cursor can conservatively cost one extra read; it
            // must never be counted as a new reply or cause repeated paging.
            canLoadNewerReplies = items.count >= 30 && !later.isEmpty
        } catch is CancellationError { }
        catch {
            guard isCurrent() else { return }
            self.error = (error as? LocalizedError)?.errorDescription ?? "Could not load more messages."
        }
    }

    func sendReply() async {
        guard !slashBusy, slashCommandRequest == nil else { return }
        if canReply, ChatSlashSyntax.name(replyDraft) != nil {
            do { try await prepareSlashCommands(inThread: true, fromComposer: true) }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
            return
        }
        guard canReply, let root = threadRoot, let api = client,
              let connectionID = live?.connectionID, !replyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let text = replyDraft
        let expected = connectionGeneration
        sending = true
        error = nil
        defer { if expected == connectionGeneration { sending = false } }
        do {
            let wireText = try wireMessage(text, channelID: root.channel_id)
            let reply = try await api.sendText(channelID: root.channel_id, text: wireText, connectionID: connectionID, threadID: root.id)
            guard expected == connectionGeneration else { return }
            applyCanonical(reply)
            if threadDrafts[root.id] == text { threadDrafts[root.id] = "" }
            // Replying may turn a plain post into a thread root, and changes its reply count.
            do {
                let readKey = UUID()
                canonicalReadKeys[root.id] = readKey
                let updated = try await api.post(channelID: root.channel_id, postID: root.id)
                guard expected == connectionGeneration else { return }
                applyCanonical(updated, readKey: readKey)
            } catch {
                guard expected == connectionGeneration else { return }
                self.error = "Your reply was sent, but the thread header could not refresh."
            }
        } catch let error as ChatCryptoError {
            guard expected == connectionGeneration else { return }
            self.error = error.errorDescription
        } catch ChatAPIError.server(411) {
            guard expected == connectionGeneration else { return }
            self.error = "Messages are being sent too quickly. Wait a moment; your reply draft is kept."
        } catch {
            guard expected == connectionGeneration else { return }
            self.error = "Reply delivery could not be confirmed. Your draft is kept; check the thread before sending again."
        }
    }

    func edit(_ post: ChatPost, text: String,owner:UUID? = nil,session:UUID? = nil) async -> Bool {
        guard post.type != "sticker",post.type != "vote",canChangeOwnMessage(post),let api = client,
              let channel = selectedChannel,post.channel_id == channel.id else { return false }
        if let warning = ChatMessageText.warning(for: text) { error = warning; return false }
        let editor:MessageEditorScope?
        if let owner {
            guard activeMessageEditor == owner,let scope = messageEditorScope,scope.post == post.id,scope.channel == channel.id,
                  scope.account == accountGeneration,scope.encryption == encryptionGeneration,
                  scope.encrypted == channel.encrypted,scope.key == channel.channel_key_enc,
                  session == nil || scope.id == session else { return false }
            editor = scope
        } else {
            // Internal callers still get a preflight against their supplied
            // original post; they cannot bypass an active owned editor.
            guard activeMessageEditor == nil,session == nil else { return false }
            editor = nil
        }
        let baseline = editor?.baseline ?? ChatMessageEditBaseline(post)
        let threadID = editor?.thread ?? (post.isReply ? post.thread_id : nil)
        let expected = connectionGeneration,encryptionEpoch = encryptionGeneration
        func current()->Bool {
            guard !Task.isCancelled,expected == connectionGeneration,encryptionEpoch == encryptionGeneration,
                  selection == channel.id,canInteract,canRead(channel.id),currentUserID == post.creator_id,
                  !deletedPostIDs.contains(post.id),pendingMessageActions.contains(post.id),
                  channels.contains(where:{ $0.id == channel.id && $0.encrypted == channel.encrypted && $0.channel_key_enc == channel.channel_key_enc }) else { return false }
            if let owner,let editor { return activeMessageEditor == owner && messageEditorScope?.id == editor.id }
            return activeMessageEditor == nil
        }
        pendingMessageActions.insert(post.id)
        error = nil
        defer { if expected == connectionGeneration { pendingMessageActions.remove(post.id) } }
        var dispatched = false
        do {
            try Task.checkCancellation()
            let preflightKey = UUID();canonicalReadKeys[post.id] = preflightKey
            let fresh = try await api.post(channelID:channel.id,postID:post.id,threadID:threadID)
            guard current() else { return false }
            guard canonicalReadKeys[post.id] == preflightKey else {
                error = NativeLocalizedStrings.text("This message changed while it was being checked. Your draft is kept. Review it before saving again.")
                return false
            }
            guard baseline.matches(fresh) else {
                // Keep the original baseline and local TextEditor state. Do
                // not hide the editor behind a deleted/malformed response.
                if baseline.matchesIdentity(fresh),(fresh.delete_at ?? 0) <= 0 { applyCanonical(fresh,readKey:preflightKey) }
                error = NativeLocalizedStrings.text("This message changed since you started editing. Your draft is kept. Cancel this edit to review the latest version.")
                return false
            }
            let wire = try wireMessage(text,channelID:channel.id)
            guard current() else { return false }
            // No documented server compare-and-set is available. This read
            // refuses detected conflicts but cannot eliminate a later race.
            dispatched = true
            try await api.setPost(fresh,text:wire)
            guard current() else { return false }
            let readKey = UUID()
            canonicalReadKeys[post.id] = readKey
            let updated = try await api.post(channelID:channel.id,postID:post.id,threadID:threadID)
            guard current() else { return false }
            guard baseline.matchesIdentity(updated),(updated.delete_at ?? 0) <= 0 else { throw ChatAPIError.invalidResponse }
            applyCanonical(updated, readKey: readKey)
            guard updated.message.utf8.elementsEqual(wire.utf8) else { throw ChatAPIError.invalidResponse }
            return true
        } catch {
            guard current() else { return false }
            self.error = NativeLocalizedStrings.text(dispatched
                ? "The edit could not be confirmed. Your draft is kept. Check the message before saving again."
                : "Could not check the latest version of this message. Nothing was changed. Your draft is kept.")
            return false
        }
    }

    func delete(_ post: ChatPost) async {
        guard canChangeOwnMessage(post), let api = client else { return }
        let expected = connectionGeneration
        pendingMessageActions.insert(post.id)
        error = nil
        defer { if expected == connectionGeneration { pendingMessageActions.remove(post.id) } }
        do {
            try await api.deletePost(postID: post.id)
            guard expected == connectionGeneration else { return }
            canonicalReadKeys[post.id] = UUID()
            if imageViewerPosts.contains(where: { $0.id == post.id }) { closeImageViewer() }
            if documentPreviewPost?.id == post.id { closeDocumentPreview() }
            deletedPostIDs.insert(post.id)
            collectionChanges.send(.init(accountGeneration:connectionGeneration,channelID:post.channel_id,postID:post.id,state:.deleted))
            posts.removeAll { $0.id == post.id }
            replies.removeAll { $0.id == post.id }
            if threadRoot?.id == post.id { threadRoot = nil }
            if post.isReply, let root = post.thread_id { refreshThreadHeader(channelID: post.channel_id, rootID: root) }
        } catch {
            guard expected == connectionGeneration else { return }
            self.error = "Deletion could not be confirmed. Refresh the conversation before trying again."
        }
    }

    func canManageSchedules(channelID:Int64) -> Bool {
        connected && selection == channelID && channels.first(where:{ $0.id == channelID })?.encrypted == false
    }
    var canCreateSchedule:Bool { canInteract && !scheduleBusy && scheduleCreationRecoveryError == nil && selectedChannel.map { canManageSchedules(channelID:$0.id) && pendingScheduledCreations[$0.id] == nil } == true && threadRoot == nil }
    func scheduledMessages(channelID:Int64) async throws -> [ChatScheduledMessage] {
        guard canManageSchedules(channelID:channelID),let api = client else { throw ChatAPIError.connection }
        let expected = connectionGeneration
        if !scheduleBusy { restoreScheduledCreationRecovery(scope:scheduleCreationScope) }
        let result = try await api.scheduledMessages(channelID:channelID)
        try checkConversationSession(expected)
        guard canManageSchedules(channelID:channelID) else { throw CancellationError() };return result
    }
    private func resetScheduledCreationRecovery() {
        scheduleCreationJournal.deactivate();scheduleCreationScope = nil
        pendingScheduledCreations = [:];scheduleCreationRecoveryError = nil
    }
    private func restoreScheduledCreationRecovery(scope:String?) {
        scheduleCreationScope = scope
        guard let scope else {
            pendingScheduledCreations = [:]
            scheduleCreationRecoveryError = "This account could not be identified for scheduled-send recovery. New schedules are disabled."
            return
        }
        do {
            let records = try scheduleCreationJournal.activate(scope:scope)
            pendingScheduledCreations = Dictionary(uniqueKeysWithValues:records.map { ($0.channelID,$0) })
            scheduleCreationRecoveryError = nil
        } catch {
            scheduleCreationRecoveryError = "Saved scheduled-send protection could not be loaded. New schedules are disabled. Keep the recovery file and refresh after resolving the storage problem."
        }
    }
    func refreshScheduledCreationRecovery(channelID:Int64) throws {
        guard !scheduleBusy,canManageSchedules(channelID:channelID) else { throw ChatAPIError.connection }
        restoreScheduledCreationRecovery(scope:scheduleCreationScope)
        if let failure = scheduleCreationRecoveryError { throw ChatScheduleFailure(uncertain:true,message:failure) }
    }
    private func requireScheduledCreationRecovery(channelID:Int64) throws {
        if let failure = scheduleCreationRecoveryError { throw ChatScheduleFailure(uncertain:true,message:failure) }
        guard scheduleCreationScope != nil,scheduleCreationJournal.accountScope == scheduleCreationScope,
              pendingScheduledCreations[channelID] == nil else {
            throw ChatScheduleFailure(uncertain:true,message:"A previous scheduled-send attempt needs review. Open Scheduled messages to check it before scheduling another message in this conversation.")
        }
    }
    private func scheduledCreationReview(_ record:ChatScheduledCreationIntent,jobs:[ChatScheduledMessage],generation:Int)->NativeScheduledCreationReview {
        .init(accountGeneration:generation,record:record,matchingJobs:record.candidates(in:jobs),acknowledgedJob:record.acknowledgedID.flatMap { id in jobs.first { $0.id == id } })
    }
    func reviewScheduledCreation(channelID:Int64) async throws -> NativeScheduledCreationReview {
        guard !scheduleBusy,canManageSchedules(channelID:channelID),let api = client else { throw ChatAPIError.connection }
        restoreScheduledCreationRecovery(scope:scheduleCreationScope)
        guard scheduleCreationRecoveryError == nil,let record = pendingScheduledCreations[channelID] else { throw ChatAPIError.invalidResponse }
        let lease = try scheduleCreationJournal.acquireActionLease(for:record);defer { lease.release() }
        restoreScheduledCreationRecovery(scope:scheduleCreationScope)
        guard scheduleCreationRecoveryError == nil,pendingScheduledCreations[channelID] == record else { throw ChatAPIError.invalidResponse }
        let expected = accountGeneration;scheduleBusy = true
        defer { if accountGeneration == expected { scheduleBusy = false } }
        let jobs = try await api.scheduledMessages(channelID:channelID)
        try checkConversationSession(expected)
        guard canManageSchedules(channelID:channelID) else { throw CancellationError() }
        return scheduledCreationReview(record,jobs:jobs,generation:expected)
    }
    /// Only a captured, explicitly reviewed outcome may release local protection.
    /// A missing job may already have delivered; this never infers safe retry.
    func clearReviewedScheduledCreation(_ reviewed:NativeScheduledCreationReview) async throws {
        let channel = reviewed.record.channelID
        guard !scheduleBusy,accountGeneration == reviewed.accountGeneration,canManageSchedules(channelID:channel),let api = client else { throw ChatAPIError.connection }
        restoreScheduledCreationRecovery(scope:scheduleCreationScope)
        guard scheduleCreationRecoveryError == nil,pendingScheduledCreations[channel] == reviewed.record else { throw ChatAPIError.invalidResponse }
        let lease = try scheduleCreationJournal.acquireActionLease(for:reviewed.record);defer { lease.release() }
        restoreScheduledCreationRecovery(scope:scheduleCreationScope)
        guard scheduleCreationRecoveryError == nil,pendingScheduledCreations[channel] == reviewed.record else { throw ChatAPIError.invalidResponse }
        let expected = accountGeneration;scheduleBusy = true
        defer { if accountGeneration == expected { scheduleBusy = false } }
        let jobs = try await api.scheduledMessages(channelID:channel)
        try checkConversationSession(expected)
        guard canManageSchedules(channelID:channel),scheduledCreationReview(reviewed.record,jobs:jobs,generation:expected) == reviewed else {
            throw ChatScheduleFailure(uncertain:true,message:"The scheduled-send evidence changed. Review the latest result before clearing protection.")
        }
        do { try scheduleCreationJournal.remove(reviewed.record);pendingScheduledCreations[channel] = nil }
        catch {
            scheduleCreationRecoveryError = "Scheduled-send protection could not be cleared. No server action was sent; refresh recovery state before trying again."
            throw error
        }
    }
    @discardableResult func saveScheduledMessage(channelID:Int64,draft originalDraft:ChatScheduleDraft,editing:ChatScheduledMessage? = nil) async throws -> ChatScheduledMessage {
        let draft = try originalDraft.validated()
        guard canInteract,!scheduleBusy,canManageSchedules(channelID:channelID),let api = client else { throw ChatAPIError.connection }
        let expected = connectionGeneration
        var lease:ChatAccountActionLease?
        if editing == nil {
            restoreScheduledCreationRecovery(scope:scheduleCreationScope)
            try requireScheduledCreationRecovery(channelID:channelID)
            lease = try scheduleCreationJournal.acquireActionLease(keys:["create:\(channelID)"])
            restoreScheduledCreationRecovery(scope:scheduleCreationScope)
            try requireScheduledCreationRecovery(channelID:channelID)
        }
        defer { lease?.release() }
        let originalScope = scheduleCreationJournal.accountScope
        scheduleBusy = true
        defer { if expected == connectionGeneration { scheduleBusy = false } }
        var dispatched = false
        var receipt:ChatScheduledCreationIntent?
        do {
            let before = try await api.scheduledMessages(channelID:channelID)
            try checkConversationSession(expected)
            if let editing {
                guard before.first(where:{ $0.id == editing.id }) == editing,editing.date > Date() else { throw ChatScheduleFailure(uncertain:false,message:"This scheduled message changed or has already sent. Refresh the list before editing it.") }
            }
            guard canInteract,canManageSchedules(channelID:channelID) else { throw CancellationError() }
            _ = try draft.validated()
            if editing == nil {
                let record = try ChatScheduledCreationIntent(channelID:channelID,message:draft.message,sendAt:Int64(draft.milliseconds),before:before)
                do { try scheduleCreationJournal.remember(record) }
                catch {
                    restoreScheduledCreationRecovery(scope:originalScope)
                    throw ChatScheduleFailure(uncertain:false,message:"The schedule was not sent because its recovery record could not be saved. Refresh Scheduled messages before trying again.")
                }
                receipt = record;pendingScheduledCreations[channelID] = record
                try checkConversationSession(expected)
                guard canInteract,canManageSchedules(channelID:channelID) else { throw CancellationError() }
            }
            dispatched = true
            let id:Int64
            if let editing { try await api.setScheduledMessage(id:editing.id,draft:draft);id = editing.id }
            else {
                id = try await api.createScheduledMessage(channelID:channelID,draft:draft)
                if let record = receipt {
                    let known = try record.acknowledging(id)
                    // A late acknowledgement is checkpointed in its original account.
                    do {
                        try scheduleCreationJournal.replaceInScope(record,with:known,originalScope:originalScope)
                        receipt = known
                        if expected == connectionGeneration { pendingScheduledCreations[channelID] = known }
                    } catch {
                        if expected == connectionGeneration { scheduleCreationRecoveryError = "The server returned a scheduled-send ID, but its recovery checkpoint could not be saved. Check Scheduled messages before making another schedule." }
                    }
                }
            }
            try checkConversationSession(expected)
            let after = try await api.scheduledMessages(channelID:channelID)
            try checkConversationSession(expected)
            guard canManageSchedules(channelID:channelID),let confirmed = after.first(where:{ $0.id == id }),confirmed.message == draft.message,confirmed.send_at == draft.milliseconds,
                  editing != nil || !before.contains(where:{ $0.id == id }) else { throw ChatAPIError.invalidResponse }
            if editing == nil {
                if scheduleDrafts[channelID] == originalDraft { scheduleDrafts[channelID] = nil }
                if let source = draft.sourceComposerText,drafts[channelID] == source { drafts[channelID] = nil }
                if let receipt {
                    do {
                        try scheduleCreationJournal.remove(receipt)
                        pendingScheduledCreations[channelID] = nil;scheduleCreationRecoveryError = nil
                    } catch {
                        // Canonical success must remain success even if local cleanup fails.
                        scheduleCreationRecoveryError = "The message is scheduled, but its local protection could not be cleared. Review this outcome before scheduling another message."
                    }
                }
            }
            return confirmed
        } catch {
            if !dispatched,let receipt {
                do {
                    try scheduleCreationJournal.removeUndispatched(receipt,originalScope:originalScope)
                    if expected == connectionGeneration,pendingScheduledCreations[channelID] == receipt { pendingScheduledCreations[channelID] = nil }
                } catch { if expected == connectionGeneration { scheduleCreationRecoveryError = "The unsent schedule's local protection could not be cleared. Refresh recovery state before trying again." } }
            }
            guard expected == connectionGeneration else { throw CancellationError() }
            if dispatched { throw ChatScheduleFailure(uncertain:true,message:"The scheduled-send change could not be confirmed. Your draft is kept. Review the previous attempt in Scheduled messages before trying again.") }
            throw error
        }
    }
    func cancelScheduledMessage(_ job:ChatScheduledMessage,channelID:Int64) async throws {
        guard canInteract,!scheduleBusy,canManageSchedules(channelID:channelID),let api = client else { throw ChatAPIError.connection }
        let expected = connectionGeneration
        scheduleBusy = true
        defer { if expected == connectionGeneration { scheduleBusy = false } }
        var dispatched = false
        do {
            let before = try await api.scheduledMessages(channelID:channelID)
            try checkConversationSession(expected)
            guard before.first(where:{ $0.id == job.id }) == job,job.date > Date() else { throw ChatScheduleFailure(uncertain:false,message:"This message changed or is no longer pending. Refresh scheduled messages.") }
            guard canInteract,canManageSchedules(channelID:channelID) else { throw CancellationError() }
            dispatched = true;try await api.cancelScheduledMessage(id:job.id)
            try checkConversationSession(expected)
            let after = try await api.scheduledMessages(channelID:channelID)
            try checkConversationSession(expected)
            guard !after.contains(where:{ $0.id == job.id }) else { throw ChatAPIError.invalidResponse }
        } catch {
            guard expected == connectionGeneration else { throw CancellationError() }
            if dispatched { throw ChatScheduleFailure(uncertain:true,message:"Cancellation could not be confirmed. Refresh scheduled messages before trying again.") }
            throw error
        }
    }

    func canPin(_ post:ChatPost) -> Bool {
        canAct(on:post) && !pinStateNeedsRefresh.contains(post.id) && !post.isReply && channels.first(where:{ $0.id == post.channel_id })?.encrypted == false
    }
    func canForward(_ post:ChatPost) -> Bool {
        canAct(on:post) && post.channel_id == selection && currentUserID != nil
            && ChatForwardPolicy.supports(post,channel:channels.first(where:{ $0.id == post.channel_id }),users:directory)
    }
    /// Resolve new people without navigating away from the reviewed source.
    /// Initiation uses the shared durable receipt; forwarding remains a separate,
    /// single dispatch after every destination and the source have been rechecked.
    func forwardMessage(_ source:ChatPost,to entryIDs:Set<String>,reviewed:ChatQuickSwitchSnapshot) async throws -> [ChatPost] {
        guard canForward(source),!channelManagementBusy,!quickSwitcherBusy,!sending,!isEditingMessage,
              reviewed.accountGeneration == accountGeneration,reviewed.ownerID == currentUserID,
              !entryIDs.isEmpty,entryIDs.count <= 20,let api = client else { throw ChatAPIError.invalidResponse }
        try refreshForwardRecovery(expectedGeneration:accountGeneration)
        try requireForwardReviewCleared(sourceID:source.id,channelID:source.channel_id)
        let originals = reviewed.entries.filter { entryIDs.contains($0.id) }
        guard originals.count == entryIDs.count,originals.allSatisfy(ChatForwardPolicy.destination) else { throw ChatAPIError.invalidResponse }
        let epoch = accountGeneration,origin = selection,root = threadRoot?.id
        channelManagementBusy = true
        defer { if epoch == accountGeneration { channelManagementBusy = false } }
        var fresh = try await quickSwitchSnapshot()
        func checkSourceContext() throws {
            try checkConversationSession(epoch)
            guard origin == selection,root == threadRoot?.id,canForward(source),!isEditingMessage else { throw CancellationError() }
        }
        try checkSourceContext()
        // Validate the whole selection before the first possible initiation.
        for original in originals {
            if original.channel != nil {
                guard let current = fresh.entries.first(where:{ $0.id == original.id }),ChatForwardPolicy.sameDestination(original,current) else {
                    throw NativeForwardFailure(uncertain:false,message:"A destination changed or is no longer available. Refresh destinations and review the selection.")
                }
            } else {
                guard let person = original.person else { throw ChatAPIError.invalidResponse }
                let existing = try existingConversation(members:[reviewed.ownerID,person.user_id],snapshot:fresh)
                guard fresh.canStartConversations || existing != nil else { throw ChatAPIError.invalidResponse }
                try validateConversationPeople([reviewed.ownerID,person.user_id],reviewed:reviewed,fresh:fresh)
            }
        }
        let currentSource = try await api.post(channelID:source.channel_id,postID:source.id,threadID:source.isReply ? source.thread_id : nil)
        try checkSourceContext()
        guard ChatForwardPolicy.sameContent(source,currentSource),ChatForwardPolicy.supports(currentSource,channel:fresh.channels.first(where:{ $0.id == source.channel_id }),users:fresh.users) else {
            throw NativeForwardFailure(uncertain:false,message:"The source message changed. Reopen forwarding to review it.")
        }
        var resolved:[ChatQuickSwitchEntry] = []
        do {
            for original in originals {
                try checkSourceContext()
                if original.channel != nil { resolved.append(original);continue }
                guard let person = original.person else { throw ChatAPIError.invalidResponse }
                let result = try await resolveConversationStart(members:[reviewed.ownerID,person.user_id],reviewed:reviewed,fresh:fresh,
                    expectedExisting:nil,epoch:epoch,origin:origin,root:root)
                fresh = result.snapshot;resolved.append(result.entry)
            }
            // Other starts and external changes may have occurred during the loop.
            fresh = try await quickSwitchSnapshot();try checkSourceContext()
            for original in resolved {
                guard let current = fresh.entries.first(where:{ $0.id == original.id }),ChatForwardPolicy.sameDestination(original,current) else {
                    throw ChatTransferError(message:"A forwarding destination changed. Refresh and review it again.")
                }
            }
        } catch {
            try checkConversationSession(epoch)
            if error is CancellationError { throw error }
            throw NativeForwardFailure(uncertain:false,message:"No message was forwarded. A new conversation may have been created. \(error.localizedDescription)")
        }
        let targets = resolved.compactMap { $0.channel?.id }
        guard targets.count == entryIDs.count,Set(targets).count == targets.count else { throw ChatAPIError.invalidResponse }
        // Publish only current directory/channel metadata; selection, presence,
        // read state and main/thread drafts stay with the original conversation.
        directory = fresh.users;channels = fresh.channels
        for entry in resolved {
            if let id = entry.channel?.id { channelNames[id] = entry.title;channelMemberIDs[id] = entry.memberIDs.sorted() }
        }
        let members = Dictionary(uniqueKeysWithValues:resolved.filter { $0.channel?.type == "anonymous" || $0.channel?.type == "synobot" }.compactMap { entry in entry.channel.map { ($0.id,entry.memberIDs) } })
        return try await forwardMessage(source,to:targets,reviewedMembers:members)
    }
    func forwardMessage(_ source:ChatPost,to targets:[Int64],reviewedMembers:[Int64:Set<Int64>] = [:]) async throws -> [ChatPost] {
        guard canForward(source),let api = client,let me = currentUserID,!targets.isEmpty,targets.count <= 20,
              Set(targets).count == targets.count,targets.allSatisfy({ id in channels.contains { $0.id == id && ChatForwardPolicy.destination($0) } }) else {
            throw NativeForwardFailure(uncertain:false,message:"Choose available unencrypted conversations and a readable message.")
        }
        try refreshForwardRecovery(expectedGeneration:accountGeneration)
        try requireForwardReviewCleared(sourceID:source.id,channelID:source.channel_id)
        let expected = connectionGeneration
        pendingMessageActions.insert(source.id)
        defer { if expected == connectionGeneration { pendingMessageActions.remove(source.id) } }
        var dispatched = false
        var saved:ChatForwardIntent?
        let receiptScope = forwardJournal.accountScope
        do {
            let available = try await api.channels();try checkConversationSession(expected)
            guard targets.allSatisfy({ id in available.contains { $0.id == id && ChatForwardPolicy.destination($0) } }),
                  available.contains(where:{ $0.id == source.channel_id && ChatForwardPolicy.destination($0) }) else {
                throw NativeForwardFailure(uncertain:false,message:"A conversation is no longer available for forwarding. Refresh destinations.")
            }
            let current = try await api.post(channelID:source.channel_id,postID:source.id,threadID:source.isReply ? source.thread_id : nil)
            try checkConversationSession(expected)
            guard selection == source.channel_id,ChatForwardPolicy.supports(current,channel:channels.first(where:{ $0.id == current.channel_id }),users:directory),
                  ChatForwardPolicy.sameContent(current,source) else {
                throw NativeForwardFailure(uncertain:false,message:"The source message changed. Reopen forwarding to review it.")
            }
            var previous:[Int64:Set<Int64>] = [:]
            var newestAt:[Int64:Double] = [:]
            for id in targets {
                let page = try await api.posts(channelID:id)
                try checkConversationSession(expected)
                guard page.allSatisfy({ $0.create_at.isFinite && $0.create_at >= 0 && $0.create_at < 253402300800000 }) else { throw ChatAPIError.invalidResponse }
                previous[id] = Set(page.map(\.id));newestAt[id] = page.map(\.create_at).max() ?? 0
                if let wanted = reviewedMembers[id] {
                    let ids = try await api.members(channelID:id);try checkConversationSession(expected)
                    guard Set(ids) == wanted,ids.count == wanted.count else {
                        throw NativeForwardFailure(uncertain:false,message:"The people in a destination changed. Refresh and review it before forwarding.")
                    }
                }
            }
            guard canInteract,selection == source.channel_id,targets.allSatisfy({ id in channels.contains { $0.id == id && ChatForwardPolicy.destination($0) } }) else { throw CancellationError() }
            let receipt = try ChatForwardIntent(source:current,targets:targets,previous:previous,newestAt:newestAt)
            do { try forwardJournal.remember(receipt) }
            catch { forwardRecoveryError = "The forward was not sent because its recovery record could not be saved. Repair storage and refresh saved state.";throw error }
            saved = receipt;pendingForwards[receipt.id] = receipt
            try checkConversationSession(expected)
            dispatched = true
            try await api.forwardPost(postID:source.id,channelIDs:targets)
            try checkConversationSession(expected)
            var confirmed:[ChatPost] = []
            for id in targets {
                let page = try await api.posts(channelID:id)
                try checkConversationSession(expected)
                let matches = page.filter { receipt.newerThanBaseline($0) && ChatForwardPolicy.receipt($0,source:current,channelID:id,userID:me,previous:previous[id] ?? []) }
                guard matches.count == 1 else { throw ChatAPIError.invalidResponse }
                confirmed.append(matches[0])
            }
            if selection == source.channel_id,!viewingMessageContext {
                posts = ChatTimeline.merge(posts,confirmed.filter { $0.channel_id == selection })
            }
            if let saved {
                do { try forwardJournal.remove(saved);pendingForwards.removeValue(forKey:saved.id) }
                catch { forwardRecoveryError = "Forwarding was confirmed, but its saved record could not be cleared. Refresh saved state; do not resend automatically." }
            }
            return confirmed
        } catch {
            if !dispatched,let saved {
                do { try forwardJournal.removeUndispatched(saved,originalScope:receiptScope);if expected == connectionGeneration { pendingForwards.removeValue(forKey:saved.id) } }
                catch { if expected == connectionGeneration { forwardRecoveryError = "An unsent forward record could not be cleared. Repair storage and refresh saved state." } }
            }
            guard expected == connectionGeneration else { throw CancellationError() }
            if dispatched { throw NativeForwardFailure(uncertain:true,message:"Delivery could not be confirmed for every destination. It may have succeeded in some or all conversations. This is saved across restarts. Use Pending actions to check each destination before forwarding again.") }
            if error is CancellationError { throw error }
            throw NativeForwardFailure(uncertain:false,message:error.localizedDescription)
        }
    }
    private func resetEncryptedCreationRecovery() {
        encryptedConversationJournal.deactivate();encryptedConversationRecoveryScope = nil;pendingEncryptedConversationStarts = [:];encryptedConversationRecoveryError = nil
        encryptedCreationJournal.deactivate();encryptedCreationRecoveryScope = nil;pendingEncryptedCreations = [:];encryptedCreationRecoveryError = nil
    }
    private func restoreEncryptedCreationRecovery(scope:String?) {
        encryptedCreationRecoveryScope = scope;pendingEncryptedCreations = [:]
        guard let scope else { encryptedCreationRecoveryError = "This account could not be identified for encrypted channel recovery. Encrypted creation is disabled.";return }
        do { pendingEncryptedCreations = Dictionary(uniqueKeysWithValues:try encryptedCreationJournal.activate(scope:scope).map { ($0.id,$0) });encryptedCreationRecoveryError = nil }
        catch { encryptedCreationRecoveryError = "Saved encrypted channel creation state could not be loaded. Repair storage and refresh recovery before creating an encrypted channel." }
    }
    func refreshEncryptedCreationRecovery(expectedGeneration:Int) throws {
        try checkConversationSession(expectedGeneration)
        guard !channelManagementBusy else { throw ChatAPIError.connection }
        restoreEncryptedCreationRecovery(scope:encryptedCreationRecoveryScope)
        if let error = encryptedCreationRecoveryError { throw ChatTransferError(message:error) }
    }
    func acknowledgeEncryptedCreation(_ intent:ChatEncryptedCreationIntent,expectedGeneration:Int) throws {
        try checkConversationSession(expectedGeneration)
        guard !channelManagementBusy,encryptedCreationRecoveryError == nil,pendingEncryptedCreations[intent.id] == intent,intent.ownerID == currentUserID else { throw ChatAPIError.connection }
        do { try encryptedCreationJournal.remove(intent);pendingEncryptedCreations.removeValue(forKey:intent.id) }
        catch { encryptedCreationRecoveryError = "Saved encrypted channel creation state could not be updated. Repair storage and refresh recovery.";throw error }
    }
    private func checkEncryptedCreationContext(api:ChatAPIClient,expected:Int,keyEpoch:Int,ownerID:Int64,owner:ChatEncryptionKeyPair,permission:String = "channel_create") async throws {
        try checkConversationSession(expected)
        guard canInteract,!sending,encryptionUnlocked,keyEpoch == encryptionGeneration,currentUserID == ownerID else { throw CancellationError() }
        let permissions = try await api.channelPermissions();try checkConversationSession(expected)
        guard permissions.allows(permission) else { throw ChatTransferError(message:permission == "channel_join" ? "Your account cannot join channels." : "Your account cannot create channels.") }
        let fresh = try await api.encryptionOwnerState(userID:ownerID);try checkConversationSession(expected)
        guard canInteract,!sending,encryptionUnlocked,keyEpoch == encryptionGeneration,currentUserID == ownerID,
              let cached = encryptionKeyPair,fresh.isInitialized,
              fresh == ChatEncryptionOwnerState(userID:ownerID,pair:owner),fresh == ChatEncryptionOwnerState(userID:ownerID,pair:cached),
              encryption.matchesUnlockedPublicKey(fresh.pair.public_key) else { throw ChatTransferError(message:"Your encryption keys changed. Refresh your account and unlock encryption before creating a channel.") }
    }
    private func createEncryptedPrivateChannel(name:String,purpose:String) async throws {
        let expected = accountGeneration,keyEpoch = encryptionGeneration
        try refreshEncryptedCreationRecovery(expectedGeneration:expected)
        guard pendingEncryptedCreations.isEmpty else { throw ChatTransferError(message:"An encrypted channel creation needs review. Check Pending actions before creating another encrypted channel.") }
        guard canCreateEncryptedChannel,let api = client,let ownerID = currentUserID,let owner = encryptionKeyPair else { throw ChatAPIError.connection }
        let name = name.trimmingCharacters(in:.whitespacesAndNewlines)
        if let error = ChatNamedChannelInput.validationError(name:name,purpose:purpose) { throw ChatTransferError(message:error) }
        channelManagementBusy = true;defer { if expected == accountGeneration { channelManagementBusy = false } }
        try await checkEncryptedCreationContext(api:api,expected:expected,keyEpoch:keyEpoch,ownerID:ownerID,owner:owner)
        let plan = try ChatEncryptedChannelCreation(owner:owner,encryption:encryption)
        var saved = try ChatEncryptedCreationIntent(plan:plan,ownerID:ownerID,owner:owner,name:name,purpose:purpose)
        let scope = encryptedCreationJournal.accountScope
        var dispatched = false
        do {
            let channel = try await api.createEncryptedNamedChannel(name:name,purpose:purpose,plan:plan,owner:owner,encryption:encryption,
                onDispatch:{
                    try self.checkConversationSession(expected)
                    do { try self.encryptedCreationJournal.rememberAsOnlyPending(saved) }
                    catch { self.encryptedCreationRecoveryError = "The channel was not created because its recovery record could not be saved. Repair storage and refresh recovery.";throw error }
                    self.pendingEncryptedCreations[saved.id] = saved;dispatched = true
                },onCreated:{ id,envelope in
                    guard envelope == saved.creatorEnvelope else { throw ChatAPIError.invalidResponse }
                    let updated = try saved.withChannelID(id)
                    try self.encryptedCreationJournal.replaceInScope(saved,with:updated,originalScope:scope)
                    saved = updated
                    if expected == self.accountGeneration { self.pendingEncryptedCreations[saved.id] = saved }
                },onJoinDispatch:{
                    try self.checkConversationSession(expected)
                    let attempted = try saved.recordingJoinAttempt()
                    try self.encryptedCreationJournal.replace(saved,with:attempted)
                    saved = attempted;self.pendingEncryptedCreations[saved.id] = saved
                },checkContinuation:{
                    try await self.checkEncryptedCreationContext(api:api,expected:expected,keyEpoch:keyEpoch,ownerID:ownerID,owner:owner)
                })
            try checkConversationSession(expected)
            guard saved.matches(channel) else { throw ChatAPIError.invalidResponse }
            let members = try await api.members(channelID:channel.id);try checkConversationSession(expected)
            guard canInteract,encryptionUnlocked,keyEpoch == encryptionGeneration,members.allSatisfy({ $0 > 0 }),Set(members).count == members.count,members.contains(ownerID) else { throw ChatAPIError.invalidResponse }
            let current = try await api.channels();try checkConversationSession(expected)
            guard current.filter({ $0.id == channel.id }).count == 1,let confirmed = current.first(where:{ $0.id == channel.id }),saved.matches(confirmed),
                  canInteract,encryptionUnlocked,keyEpoch == encryptionGeneration else { throw ChatAPIError.invalidResponse }
            do { try encryptedCreationJournal.remove(saved);pendingEncryptedCreations.removeValue(forKey:saved.id) }
            catch { encryptedCreationRecoveryError = "The encrypted channel was created, but its saved warning could not be cleared. Repair storage and refresh recovery; do not repeat creation." }
            channels = (channels.filter { $0.id != confirmed.id } + [confirmed]).sorted { title($0).localizedCaseInsensitiveCompare(title($1)) == .orderedAscending }
            if selection == channel.id { loadSelection() } else { selection = channel.id }
        } catch {
            guard expected == accountGeneration else { throw CancellationError() }
            if dispatched { throw ChatTransferError(message:"Encrypted channel creation could not be fully confirmed. Its recovery record is saved. Use Pending actions to check status before creating another channel.") }
            throw error
        }
    }
    private func unjoinedEncryptedCreation(_ intent:ChatEncryptedCreationIntent,api:ChatAPIClient,expected:Int) async throws -> ChatChannel {
        let available = try await api.channels();try checkConversationSession(expected)
        guard available.allSatisfy({ $0.id > 0 }),Set(available.map(\.id)).count == available.count,
              let channel = available.first(where:{ $0.id == intent.channelID }),intent.matchesUnjoined(channel) else {
            throw ChatTransferError(message:"This channel is not confirmed unjoined with its original details. Check status first. No join was sent.")
        }
        return channel
    }
    func prepareEncryptedCreationJoin(_ intent:ChatEncryptedCreationIntent,expectedGeneration:Int) async throws -> ChatEncryptedCreationJoinReview {
        try refreshEncryptedCreationRecovery(expectedGeneration:expectedGeneration)
        guard pendingEncryptedCreations[intent.id] == intent,intent.ownerID == currentUserID,intent.channelID != nil,
              canInteract,!sending,encryptionUnlocked,let api = client,let owner = encryptionKeyPair else { throw ChatAPIError.connection }
        let keyEpoch = encryptionGeneration
        channelManagementBusy = true;defer { if expectedGeneration == accountGeneration { channelManagementBusy = false } }
        try await checkEncryptedCreationContext(api:api,expected:expectedGeneration,keyEpoch:keyEpoch,ownerID:intent.ownerID,owner:owner,permission:"channel_join")
        let channel = try await unjoinedEncryptedCreation(intent,api:api,expected:expectedGeneration)
        guard encryptionUnlocked,keyEpoch == encryptionGeneration,intent.matchesOwnerKey(owner),encryption.matchesUnlockedPublicKey(owner.public_key) else { throw ChatCryptoError.invalidKey }
        try encryption.validateChannelEnvelope(intent.creatorEnvelope)
        return .init(intent:intent,channel:channel,owner:owner,accountGeneration:expectedGeneration,keyGeneration:keyEpoch)
    }
    /// A new manual action after fresh review. One join attempt is persisted
    /// before dispatch, never retried automatically, and uses the original key.
    func finishEncryptedCreationJoin(_ review:ChatEncryptedCreationJoinReview) async throws {
        let expected = review.accountGeneration,keyEpoch = review.keyGeneration,intent = review.intent
        try refreshEncryptedCreationRecovery(expectedGeneration:expected)
        guard pendingEncryptedCreations[intent.id] == intent,intent.ownerID == currentUserID,intent.matchesUnjoined(review.channel),
              canInteract,!sending,encryptionUnlocked,keyEpoch == encryptionGeneration,let api = client else { throw ChatAPIError.connection }
        channelManagementBusy = true;defer { if expected == accountGeneration { channelManagementBusy = false } }
        try await checkEncryptedCreationContext(api:api,expected:expected,keyEpoch:keyEpoch,ownerID:intent.ownerID,owner:review.owner,permission:"channel_join")
        let channel = try await unjoinedEncryptedCreation(intent,api:api,expected:expected)
        try await checkEncryptedCreationContext(api:api,expected:expected,keyEpoch:keyEpoch,ownerID:intent.ownerID,owner:review.owner,permission:"channel_join")
        guard intent.matchesOwnerKey(review.owner),encryption.matchesUnlockedPublicKey(review.owner.public_key) else { throw ChatCryptoError.invalidKey }
        try encryption.validateChannelEnvelope(intent.creatorEnvelope)
        let attempted = try intent.recordingJoinAttempt()
        do { try encryptedCreationJournal.replace(intent,with:attempted) }
        catch { encryptedCreationRecoveryError = "No join was sent because its recovery record could not be updated. Repair storage and refresh recovery.";throw error }
        pendingEncryptedCreations[intent.id] = attempted
        do {
            try await api.joinEncryptedCreatedChannel(attempted,channel:channel)
            try checkConversationSession(expected)
            guard encryptionUnlocked,keyEpoch == encryptionGeneration else { throw CancellationError() }
            let before = try await api.channels();try checkConversationSession(expected)
            guard before.filter({ $0.id == intent.channelID }).count == 1,let joined = before.first(where:{ $0.id == intent.channelID }),attempted.matches(joined) else { throw ChatAPIError.invalidResponse }
            let members = try await api.members(channelID:joined.id);try checkConversationSession(expected)
            guard members.allSatisfy({ $0 > 0 }),Set(members).count == members.count,members.contains(intent.ownerID) else { throw ChatAPIError.invalidResponse }
            let after = try await api.channels();try checkConversationSession(expected)
            guard after.filter({ $0.id == joined.id }).count == 1,let confirmed = after.first(where:{ $0.id == joined.id }),attempted.matches(confirmed),
                  canInteract,encryptionUnlocked,keyEpoch == encryptionGeneration else { throw ChatAPIError.invalidResponse }
            try encryption.validateChannelEnvelope(attempted.creatorEnvelope)
            do { try encryptedCreationJournal.remove(attempted);pendingEncryptedCreations.removeValue(forKey:intent.id) }
            catch { encryptedCreationRecoveryError = "Joining was confirmed, but its saved warning could not be cleared. Repair storage and refresh recovery; do not repeat the join." }
            channels = (channels.filter { $0.id != confirmed.id } + [confirmed]).sorted { title($0).localizedCaseInsensitiveCompare(title($1)) == .orderedAscending }
        } catch {
            guard expected == accountGeneration else { throw CancellationError() }
            throw ChatTransferError(message:"Joining could not be fully confirmed. The original encrypted key and this attempt remain saved. Check status before reviewing another manual join; no automatic retry was made.")
        }
    }

    /// Read-only confirmation. Unknown IDs are never guessed from a matching name.
    /// No join, create, invite or key mutation is replayed, even while unlocked.
    func checkEncryptedCreationStatus(_ intent:ChatEncryptedCreationIntent,expectedGeneration:Int) async throws {
        try refreshEncryptedCreationRecovery(expectedGeneration:expectedGeneration)
        guard pendingEncryptedCreations[intent.id] == intent,intent.ownerID == currentUserID,let api = client else { throw ChatAPIError.connection }
        guard let id = intent.channelID else { throw ChatTransferError(message:"The server did not return a channel ID. Check your channels in the official app before clearing this warning. No channel was created or joined by this check.") }
        channelManagementBusy = true;defer { if expectedGeneration == accountGeneration { channelManagementBusy = false } }
        let before = try await api.channels();try checkConversationSession(expectedGeneration)
        let matches = before.filter { $0.id == id }
        guard matches.count == 1,let channel = matches.first,intent.matches(channel) else { throw ChatTransferError(message:"The encrypted channel is not confirmed joined with its original keys and details. If it is still unjoined, unlock encryption and review Finish joining. No creation or join was repeated.") }
        let members = try await api.members(channelID:id);try checkConversationSession(expectedGeneration)
        guard members.allSatisfy({ $0 > 0 }),Set(members).count == members.count,members.contains(intent.ownerID) else { throw ChatAPIError.invalidResponse }
        let after = try await api.channels();try checkConversationSession(expectedGeneration)
        guard after.filter({ $0.id == id }).count == 1,let current = after.first(where:{ $0.id == id }),intent.matches(current),pendingEncryptedCreations[intent.id] == intent else { throw ChatAPIError.invalidResponse }
        do { try encryptedCreationJournal.remove(intent);pendingEncryptedCreations.removeValue(forKey:intent.id) }
        catch { encryptedCreationRecoveryError = "The channel is confirmed joined, but its saved warning could not be cleared. Repair storage and refresh recovery." }
        // A status check deliberately preserves the user's conversation and drafts.
    }

    private func resetInvitationRecovery() {
        invitationJournal.deactivate();invitationRecoveryScope = nil;pendingInvitations = [:];invitationRecoveryError = nil
    }
    private func restoreInvitationRecovery(scope:String?) {
        invitationRecoveryScope = scope;pendingInvitations = [:]
        guard let scope else { invitationRecoveryError = "This account could not be identified for invitation recovery. Adding people is disabled.";return }
        do { pendingInvitations = Dictionary(uniqueKeysWithValues:try invitationJournal.activate(scope:scope).map { ($0.channelID,$0) });invitationRecoveryError = nil }
        catch { invitationRecoveryError = "Saved invitation state could not be loaded. Repair storage and refresh saved state before adding people." }
    }
    func refreshInvitationRecovery(expectedGeneration:Int) throws {
        try checkConversationSession(expectedGeneration)
        guard !channelManagementBusy else { throw ChatAPIError.connection }
        restoreInvitationRecovery(scope:invitationRecoveryScope)
        if let invitationRecoveryError { throw ChatTransferError(message:invitationRecoveryError) }
    }
    func acknowledgeInvitationOutcome(_ intent:ChatChannelInvitationIntent,expectedGeneration:Int) throws {
        try checkConversationSession(expectedGeneration)
        guard !channelManagementBusy,invitationRecoveryError == nil,pendingInvitations[intent.channelID] == intent else { throw ChatAPIError.connection }
        do { try invitationJournal.remove(intent);pendingInvitations.removeValue(forKey:intent.channelID) }
        catch { invitationRecoveryError = "Saved invitation state could not be updated. Repair storage and refresh saved state.";throw error }
    }
    func checkInvitationStatus(_ intent:ChatChannelInvitationIntent,expectedGeneration:Int) async throws {
        try refreshInvitationRecovery(expectedGeneration:expectedGeneration)
        guard pendingInvitations[intent.channelID] == intent,let api = client,let owner = currentUserID else { throw ChatAPIError.connection }
        channelManagementBusy = true;defer { if expectedGeneration == accountGeneration { channelManagementBusy = false } }
        let available = try await api.channels();try checkConversationSession(expectedGeneration)
        guard intent.matchesExactly(available) else { throw ChatTransferError(message:"This channel changed or is no longer available. Check its members in the official client before clearing this warning.") }
        let ids = try await api.members(channelID:intent.channelID);try checkConversationSession(expectedGeneration)
        guard ids.allSatisfy({ $0 > 0 }),Set(ids).count == ids.count,ids.contains(owner),Set(intent.members).isSubset(of:Set(ids)) else {
            throw ChatTransferError(message:"Not all selected people are confirmed members. No invitation was repeated. Check the member list before clearing this warning.")
        }
        let current = try await api.channels();try checkConversationSession(expectedGeneration)
        guard intent.matchesExactly(current),pendingInvitations[intent.channelID] == intent else { throw ChatAPIError.invalidResponse }
        do { try invitationJournal.remove(intent);pendingInvitations.removeValue(forKey:intent.channelID) }
        catch { invitationRecoveryError = "Membership was confirmed, but the saved invitation warning could not be cleared. Repair storage and refresh saved state." }
    }
    private func resetForwardRecovery() {
        forwardJournal.deactivate();forwardRecoveryScope = nil;pendingForwards = [:];forwardRecoveryError = nil;forwardRecoveryBusy = false
    }
    private func restoreForwardRecovery(scope:String?) {
        forwardRecoveryScope = scope;pendingForwards = [:]
        guard let scope else { forwardRecoveryError = "The account could not be identified for forwarding recovery. Forwarding is disabled.";return }
        do { pendingForwards = Dictionary(uniqueKeysWithValues:try forwardJournal.activate(scope:scope).map { ($0.id,$0) });forwardRecoveryError = nil }
        catch { forwardRecoveryError = "Saved forwarding state could not be loaded. Repair storage and refresh saved state before forwarding." }
    }
    func refreshForwardRecovery(expectedGeneration:Int) throws {
        try checkConversationSession(expectedGeneration)
        guard !forwardRecoveryBusy else { throw ChatAPIError.connection }
        restoreForwardRecovery(scope:forwardRecoveryScope)
        if let forwardRecoveryError { throw ChatTransferError(message:forwardRecoveryError) }
    }
    private func requireForwardReviewCleared(sourceID:Int64,channelID:Int64) throws {
        if let forwardRecoveryError { throw ChatTransferError(message:forwardRecoveryError) }
        guard !pendingForwards.values.contains(where:{ $0.sourceID == sourceID && $0.sourceChannelID == channelID }) else {
            throw NativeForwardFailure(uncertain:true,message:"A previous forward of this message is unconfirmed. Open Pending actions to check its status or acknowledge the outcome before another manual attempt.")
        }
    }
    func acknowledgeForwardOutcome(_ intent:ChatForwardIntent,expectedGeneration:Int) throws {
        try checkConversationSession(expectedGeneration)
        guard !forwardRecoveryBusy,forwardRecoveryError == nil,pendingForwards[intent.id] == intent,!pendingMessageActions.contains(intent.sourceID) else { throw ChatAPIError.connection }
        do { try forwardJournal.remove(intent);pendingForwards.removeValue(forKey:intent.id) }
        catch { forwardRecoveryError = "Saved forwarding state could not be updated. Repair storage and refresh saved state.";throw error }
    }
    @discardableResult func checkForwardStatus(_ intent:ChatForwardIntent,expectedGeneration:Int) async throws -> [ChatPost] {
        try refreshForwardRecovery(expectedGeneration:expectedGeneration)
        guard pendingForwards[intent.id] == intent,!pendingMessageActions.contains(intent.sourceID),let api = client,let me = currentUserID else { throw ChatAPIError.connection }
        forwardRecoveryBusy = true
        defer { if expectedGeneration == accountGeneration { forwardRecoveryBusy = false } }
        let available = try await api.channels();try checkConversationSession(expectedGeneration)
        guard ([intent.sourceChannelID]+intent.targets).allSatisfy({ id in available.contains { $0.id == id && ChatForwardPolicy.destination($0) } }) else {
            throw ChatTransferError(message:"A conversation is no longer readable here. Check the outcome in the official client before clearing this warning.")
        }
        let source = try await api.post(channelID:intent.sourceChannelID,postID:intent.sourceID,threadID:intent.sourceThreadID > 0 ? intent.sourceThreadID : nil)
        try checkConversationSession(expectedGeneration)
        let users = try await api.users();try checkConversationSession(expectedGeneration)
        guard ChatForwardIntent.contentFingerprint(source) == intent.fingerprint,
              ChatForwardPolicy.supports(source,channel:available.first { $0.id == intent.sourceChannelID },users:users) else {
            throw ChatTransferError(message:"The source message changed. Check each destination manually before clearing this warning.")
        }
        var confirmed:[ChatPost] = []
        for id in intent.targets {
            let page = try await api.posts(channelID:id);try checkConversationSession(expectedGeneration)
            let copies = page.filter { intent.newerThanBaseline($0) && ChatForwardPolicy.receipt($0,source:source,channelID:id,userID:me,previous:Set(intent.previousIDs[String(id)] ?? [])) }
            guard copies.count == 1 else { throw ChatTransferError(message:"Delivery is still unconfirmed for every destination. No request was repeated. Check the conversations manually if the copies are outside recent history.") }
            confirmed.append(copies[0])
        }
        guard pendingForwards[intent.id] == intent else { throw CancellationError() }
        do { try forwardJournal.remove(intent);pendingForwards.removeValue(forKey:intent.id) }
        catch { forwardRecoveryError = "All forwarded copies were confirmed, but the saved warning could not be cleared. Repair storage and refresh saved state." }
        return confirmed
    }
    func canKeepPinOnTop(_ post: ChatPost) -> Bool { canPin(post) && post.isPinned }
    private func canReadPinState(_ post: ChatPost) -> Bool {
        connected && !post.isReply && post.type != "system" && (post.delete_at ?? 0) == 0
            && !deletedPostIDs.contains(post.id) && canRead(post.channel_id)
            && channels.first(where: { $0.id == post.channel_id })?.encrypted == false
    }
    @discardableResult func refreshPinState(_ post: ChatPost) async -> Bool {
        guard canReadPinState(post), !pendingMessageActions.contains(post.id), let api = client else { return false }
        error = nil
        let epoch = connectionGeneration; let key = UUID(); canonicalReadKeys[post.id] = key
        do {
            let fresh = try await api.post(channelID: post.channel_id, postID: post.id)
            try Task.checkCancellation(); try checkConversationSession(epoch)
            guard canReadPinState(fresh), fresh.id == post.id, fresh.channel_id == post.channel_id,
                  canonicalReadKeys[post.id] == key else { throw ChatAPIError.invalidResponse }
            applyCanonical(fresh, readKey: key); pinStateNeedsRefresh.remove(post.id); return true
        } catch {
            if epoch == connectionGeneration { self.error = "Could not verify the pin state. Refresh again when connected." }
            return false
        }
    }
    @discardableResult func setPinSticky(_ post: ChatPost, enabled: Bool) async -> Bool {
        guard canKeepPinOnTop(post), let api = client else { return false }
        let epoch = connectionGeneration; var dispatched = false
        pendingMessageActions.insert(post.id); error = nil
        defer { if epoch == connectionGeneration { pendingMessageActions.remove(post.id) } }
        do {
            let fresh = try await api.post(channelID: post.channel_id, postID: post.id)
            try Task.checkCancellation(); try checkConversationSession(epoch)
            guard canInteract, canReadPinState(fresh), fresh.channel_id == post.channel_id, fresh.id == post.id,
                  fresh.isPinned, fresh.last_pin_at == post.last_pin_at else { throw ChatAPIError.invalidResponse }
            if (fresh.is_sticky == true) != enabled {
                guard (fresh.is_sticky == true) == (post.is_sticky == true) else { throw ChatAPIError.invalidResponse }
                dispatched = true
                try await api.setPinSticky(postID: post.id, enabled: enabled)
            }
            try Task.checkCancellation(); try checkConversationSession(epoch)
            let key = UUID(); canonicalReadKeys[post.id] = key
            let updated = try await api.post(channelID: post.channel_id, postID: post.id)
            try Task.checkCancellation(); try checkConversationSession(epoch)
            guard canInteract, canReadPinState(updated), updated.channel_id == post.channel_id, updated.id == post.id,
                  updated.isPinned, (updated.is_sticky == true) == enabled, canonicalReadKeys[post.id] == key else { throw ChatAPIError.invalidResponse }
            applyCanonical(updated, readKey: key); pinStateNeedsRefresh.remove(post.id); return true
        } catch {
            guard epoch == connectionGeneration else { return false }
            if dispatched { pinStateNeedsRefresh.insert(post.id) }
            self.error = "Could not confirm the keep-on-top change. Refresh this message’s pin state before trying again."
            return false
        }
    }
    @discardableResult func setPinned(_ post:ChatPost,enabled:Bool) async -> Bool {
        guard canPin(post),let api = client else { return false }
        let expected = connectionGeneration
        pendingMessageActions.insert(post.id);error = nil
        defer { if connectionGeneration == expected { pendingMessageActions.remove(post.id) } }
        do {
            try await api.setPinned(postID:post.id,enabled:enabled)
            try checkConversationSession(expected)
            let key = UUID();canonicalReadKeys[post.id] = key
            // Read the root in main context; do not rely on stale thread metadata.
            let updated = try await api.post(channelID:post.channel_id,postID:post.id)
            try checkConversationSession(expected)
            guard !updated.isReply,updated.isPinned == enabled else { throw ChatAPIError.invalidResponse }
            applyCanonical(updated,readKey:key)
            return true
        } catch {
            guard connectionGeneration == expected else { return false }
            pinStateNeedsRefresh.insert(post.id)
            self.error = "Could not confirm this pin change. Refresh before trying again."
            return false
        }
    }
    func snippetDraftKey(channelID:Int64,rootID:Int64?)->String { "\(channelID):\(rootID ?? 0)" }
    func canCreateSnippet(inThread:Bool = false)->Bool {
        canInteract && selectedChannel?.encrypted == false && !sending && !uploading && !preparingComposerAttachment && attachmentBatch == nil
            && (inThread ? canComposeInThread : threadRoot == nil)
    }
    private func snippetScopeAllows(_ post:ChatPost) -> Bool {
        connected && post.channel_id == selection && canRead(post.channel_id) && !deletedPostIDs.contains(post.id)
            && ChatSnippetRevision(post) != nil && channels.first(where:{ $0.id == post.channel_id })?.supportsSnippetReading == true
    }
    private func knownSnippetRevisionsMatch(postID:Int64,channelID:Int64,allowed:[ChatSnippetRevision]) -> Bool {
        let cached = posts + replies + [threadRoot,documentPreviewPost].compactMap { $0 }
        return cached.filter { $0.id == postID && $0.channel_id == channelID }.allSatisfy { post in
            ChatSnippetRevision(post).map { allowed.contains($0) } == true
        }
    }
    func canReadSnippet(_ post:ChatPost)->Bool {
        guard snippetScopeAllows(post),let revision = ChatSnippetRevision(post) else { return false }
        return knownSnippetRevisionsMatch(postID:post.id,channelID:post.channel_id,allowed:[revision])
    }
    func canEditSnippet(_ post:ChatPost)->Bool { canReadSnippet(post) && canChangeOwnMessage(post) }
    private func freshSnippetChannel(_ post:ChatPost,type:String,api:ChatAPIClient,expected:Int) async throws {
        let available = try await api.channels();try checkConversationSession(expected)
        guard available.allSatisfy({ $0.id > 0 }),Set(available.map(\.id)).count == available.count,
              let channel = available.first(where:{ $0.id == post.channel_id }),channel.type == type,channel.supportsSnippetReading else {
            throw ChatTransferError(message:"This conversation is no longer available for snippets. Refresh before continuing.")
        }
    }
    func isCurrentSnippetReview(_ review:ChatSnippetReview,post:ChatPost) -> Bool {
        review.accountGeneration == accountGeneration && ChatSnippetRevision(post) == review.revision && canReadSnippet(post)
            && channels.first(where:{ $0.id == post.channel_id })?.type == review.channelType
    }
    func snippetSnapshot(_ post:ChatPost) async throws -> ChatSnippetSnapshot {
        guard canReadSnippet(post),let revision = ChatSnippetRevision(post),let api = client,
              let channel = channels.first(where:{ $0.id == post.channel_id }) else { throw ChatAPIError.connection }
        let expected = accountGeneration
        try await freshSnippetChannel(post,type:channel.type,api:api,expected:expected)
        guard canReadSnippet(post),channels.first(where:{ $0.id == post.channel_id })?.type == channel.type else { throw CancellationError() }
        let before = try await api.post(channelID:post.channel_id,postID:post.id,threadID:post.thread_id);try checkConversationSession(expected)
        guard ChatSnippetRevision(before) == revision,canReadSnippet(post) else { throw ChatTransferError(message:"This snippet changed. Refresh the conversation before opening or copying it.") }
        let text = try await api.snippetText(postID:post.id);try checkConversationSession(expected)
        guard canReadSnippet(post),channels.first(where:{ $0.id == post.channel_id })?.type == channel.type else { throw CancellationError() }
        let after = try await api.post(channelID:post.channel_id,postID:post.id,threadID:post.thread_id);try checkConversationSession(expected)
        guard ChatSnippetRevision(after) == revision,canReadSnippet(post) else { throw ChatTransferError(message:"This snippet changed while loading. Refresh before continuing.") }
        try await freshSnippetChannel(post,type:channel.type,api:api,expected:expected)
        guard canReadSnippet(post),channels.first(where:{ $0.id == post.channel_id })?.type == channel.type else { throw CancellationError() }
        return .init(content:text,review:.init(revision:revision,contentDigest:ChatSnippetRevision.digest(text),channelType:channel.type,accountGeneration:expected))
    }
    func snippetText(_ post:ChatPost) async throws -> String { try await snippetSnapshot(post).content }
    func copySnippet(_ post:ChatPost,writeText:@MainActor (String)->Bool = { value in
        NSPasteboard.general.clearContents();return NSPasteboard.general.setString(value,forType:.string)
    }) async throws {
        let snapshot = try await snippetSnapshot(post)
        try checkConversationSession(snapshot.review.accountGeneration)
        guard isCurrentSnippetReview(snapshot.review,post:post) else { throw CancellationError() }
        guard writeText(snapshot.content) else { throw ChatTransferError(message:"The snippet could not be copied. Try copying again.") }
    }
    var snippetRecoveryAccountScope:String? { account.flatMap { ChatNotificationAccountScope.make(account:$0,userID:userID) } }
    func createSnippet(_ draft:NativeSnippetDraft,inThread:Bool,preservingStoredDraft:Bool = false) async throws -> ChatPost {
        guard canCreateSnippet(inThread:inThread),let api = client,let channelID = selection,let connectionID = live?.connectionID else { throw ChatAPIError.connection }
        let draft = try draft.validated(),expected = connectionGeneration,root = inThread ? threadRoot : nil
        let file = try draft.writeTemporary(),transferID = UUID();defer { NativeSnippetTemporaryFiles.shared.remove(file) }
        sending = true;uploading = true;uploadProgress = ChatUploadProgress(id:transferID);defer { if expected == connectionGeneration { sending = false;uploading = false;uploadProgress = nil } }
        let post = try await api.uploadAttachment(channelID:channelID,file:file,caption:draft.caption,connectionID:connectionID,threadID:root?.id ?? 0,onProgress:{ [weak self] sent,total in
            Task { @MainActor in guard let self,self.connectionGeneration == expected else { return };self.uploadProgress?.update(id:transferID,sent:sent,total:total) }
        })
        try checkConversationSession(expected)
        guard post.file_props?.is_snippet == true,post.file_props?.name == draft.filename,post.message == draft.caption else { throw ChatAPIError.invalidResponse }
        let text = try await api.snippetText(postID:post.id)
        try checkConversationSession(expected)
        guard text.utf8.elementsEqual(draft.content.utf8) else { throw ChatAPIError.invalidResponse }
        if !preservingStoredDraft { snippetDrafts[snippetDraftKey(channelID:channelID,rootID:root?.id)] = nil }
        if selection == channelID {
            let key = UUID();canonicalReadKeys[post.id] = key;applyCanonical(post,readKey:key)
            if let root,threadRoot?.id == root.id { refreshThreadHeader(channelID:channelID,rootID:root.id);if threadViewingContext { await openThread(root) } }
            else if viewingMessageContext { loadSelection() }
        }
        return post
    }
    func editSnippet(_ post:ChatPost,draft:NativeSnippetDraft,review:ChatSnippetReview? = nil) async throws {
        guard let api = client,let original = ChatSnippetRevision(post) else { throw ChatAPIError.connection }
        guard canEditSnippet(post) else { throw ChatSnippetEditFailure(uncertain:false,message:"This snippet is no longer available for editing. Refresh the conversation; your draft stays in this editor.") }
        let value = try draft.validated(),expected = accountGeneration
        if let review,(!isCurrentSnippetReview(review,post:post) || review.revision != original) { throw ChatSnippetEditFailure(uncertain:false,message:"This snippet changed. Reopen it to review the latest version; your draft stays in this editor.") }
        pendingMessageActions.insert(post.id);defer { if expected == accountGeneration { pendingMessageActions.remove(post.id) } }
        var dispatched = false
        do {
            let fresh = try await snippetSnapshot(post);try checkConversationSession(expected)
            if let review,fresh.review.contentDigest != review.contentDigest { throw ChatSnippetEditFailure(uncertain:false,message:"This snippet was edited elsewhere. Reopen it to review the latest code; your draft stays in this editor.") }
            guard canInteract,snippetScopeAllows(post),original.creatorID == currentUserID else { throw CancellationError() }
            dispatched = true
            do { try await api.setSnippet(postID:post.id,draft:value) }
            catch ChatAPIError.server(let code) { dispatched = false;throw ChatAPIError.server(code) }
            try checkConversationSession(expected)
            guard canInteract,snippetScopeAllows(post) else { throw CancellationError() }
            let updated = try await api.post(channelID:post.channel_id,postID:post.id,threadID:post.thread_id);try checkConversationSession(expected)
            guard let revision = ChatSnippetRevision(updated),revision.sameIdentity(as:original),snippetScopeAllows(updated),
                  updated.file_props?.name?.utf8.elementsEqual(value.filename.utf8) == true,updated.message.utf8.elementsEqual(value.caption.utf8) else { throw ChatAPIError.invalidResponse }
            let text = try await api.snippetText(postID:post.id);try checkConversationSession(expected)
            guard canInteract,snippetScopeAllows(updated) else { throw CancellationError() }
            let final = try await api.post(channelID:post.channel_id,postID:post.id,threadID:post.thread_id);try checkConversationSession(expected)
            guard ChatSnippetRevision(final) == revision,text.utf8.elementsEqual(value.content.utf8),snippetScopeAllows(final) else { throw ChatAPIError.invalidResponse }
            try await freshSnippetChannel(post,type:fresh.review.channelType,api:api,expected:expected)
            guard canInteract,snippetScopeAllows(final),knownSnippetRevisionsMatch(postID:post.id,channelID:post.channel_id,allowed:[original,revision]),
                  channels.first(where:{ $0.id == post.channel_id })?.type == fresh.review.channelType else { throw CancellationError() }
            let key = UUID();canonicalReadKeys[post.id] = key;applyCanonical(final,readKey:key)
        } catch {
            guard expected == accountGeneration else { throw CancellationError() }
            if dispatched { throw ChatSnippetEditFailure(uncertain:true,message:"This edit could not be confirmed. Check the conversation before saving again; your draft stays in this editor.") }
            if let error = error as? ChatTransferError { throw ChatSnippetEditFailure(uncertain:false,message:error.message+" Your draft stays in this editor.") }
            throw error
        }
    }

    var canCreatePoll:Bool {
        canInteract && selectedChannel?.encrypted == false && threadRoot == nil && !sending && !uploading && attachmentBatch == nil && !preparingComposerAttachment
    }
    func canReadPoll(_ post:ChatPost)->Bool {
        connected && post.channel_id == selection && canRead(post.channel_id) && channels.first(where:{ $0.id == post.channel_id })?.encrypted == false
            && post.type == "vote" && (post.delete_at ?? 0) == 0 && !deletedPostIDs.contains(post.id)
    }
    func createPoll(_ draft:ChatPollDraft,attachment:ChatPollAttachment? = nil) async throws -> ChatPost {
        guard canCreatePoll,let channel = selection,let api = client else { throw ChatAPIError.connection }
        let draft = try draft.validated(),expected = connectionGeneration
        sending = true;defer { if expected == connectionGeneration { sending = false } }
        let post:ChatPost
        if let attachment {
            let type = selectedChannel?.type,owner = currentUserID
            var dispatched = false,acknowledged = false
            func check() throws {
                try checkConversationSession(expected)
                guard canInteract,selection == channel,selectedChannel?.supportsSnippetReading == true,selectedChannel?.type == type,
                      threadRoot == nil,canRead(channel),currentUserID == owner,owner != nil else { throw CancellationError() }
                if case .nas = attachment {
                    let own = directory.filter { $0.user_id == owner }
                    guard own.count == 1,own[0].type == "human",own[0].human_type == "dsm" else { throw ChatPollError("NAS attachments require a DSM account.") }
                }
            }
            func freshChannel() async throws {
                try check();let available = try await api.channels();try check()
                guard Set(available.map(\.id)).count == available.count,let fresh = available.first(where:{ $0.id == channel }),
                      fresh.supportsSnippetReading,fresh.type == type else { throw ChatPollError("This conversation is no longer available for a poll attachment.") }
            }
            do {
                try await freshChannel()
                dispatched = true
                let received = try await api.createPoll(channelID:channel,draft:draft,attachment:attachment,authorize:{ try check() })
                acknowledged = true
                try check();guard received.creator_id == owner else { throw ChatAPIError.invalidResponse }
                try await freshChannel()
                let canonical = try await api.post(channelID:channel,postID:received.id);try check()
                try draft.requireCreated(canonical,channelID:channel,attachment:attachment)
                guard canonical.creator_id == owner else { throw ChatAPIError.invalidResponse };post = canonical
            } catch let error as ChatPollCreationFailure { throw error }
            catch let error as ChatAPIError { if case .server = error,!acknowledged { throw error };throw dispatched ? ChatPollCreationFailure.uncertain : .unsent(error) }
            catch { throw dispatched ? ChatPollCreationFailure.uncertain : .unsent(error) }
        } else { post = try await api.createPoll(channelID:channel,draft:draft) }
        try checkConversationSession(expected)
        if selection == channel { let key = UUID();canonicalReadKeys[post.id] = key;applyCanonical(post,readKey:key);if viewingMessageContext { loadSelection() } }
        pollDrafts[channel] = nil;pollAttachments[channel] = nil;return post
    }
    func pollDetails(_ post:ChatPost) async throws -> ChatPollDetails {
        guard canReadPoll(post),let api = client else { throw ChatAPIError.connection }
        let expected = connectionGeneration
        let current = try await api.post(channelID:post.channel_id,postID:post.id,threadID:post.thread_id)
        try checkConversationSession(expected)
        guard canReadPoll(current),let poll = current.props?.vote,poll.state != "delete" else { throw ChatPollError("This poll is no longer available.") }
        let choices = try await api.pollChoices(postID:post.id)
        try checkConversationSession(expected)
        guard canReadPoll(current) else { throw CancellationError() }
        return ChatPollDetails(post:current,poll:try poll.replacingChoices(choices))
    }
    func updatePoll(_ post:ChatPost,action:ChatPollAction) async throws -> ChatPollDetails {
        guard canInteract,canReadPoll(post),!pendingMessageActions.contains(post.id),let api = client,let me = currentUserID else { throw ChatAPIError.connection }
        let expected = connectionGeneration
        pendingMessageActions.insert(post.id);defer { if expected == connectionGeneration { pendingMessageActions.remove(post.id) } }
        let current = try await pollDetails(post)
        try checkConversationSession(expected)
        guard canInteract,canReadPoll(current.post),current.poll.isOpen() else { throw ChatPollError("This poll has closed. Refresh to see the final results.") }
        switch action {
        case .vote(let ids):
            guard Set(ids).count == ids.count,ids.allSatisfy({ id in current.poll.choices.contains { $0.id == id } }),current.poll.options.multiple || ids.count <= 1 else { throw ChatPollError("Choose an available option.") }
            try await api.votePoll(postID:post.id,choices:ids,connectionID:live?.connectionID)
        case .addOption(let text):
            let text = text.trimmingCharacters(in:.whitespacesAndNewlines)
            guard current.poll.options.add_option else { throw ChatPollError("This poll does not allow new options.") }
            guard !current.poll.choices.contains(where:{ $0.text == text }) else { throw ChatPollError("That option already exists.") }
            try await api.addPollOption(postID:post.id,text:text,connectionID:live?.connectionID)
        case .close:
            guard current.post.creator_id == me else { throw ChatPollError("Only the poll’s author can close it.") }
            try await api.closePoll(postID:post.id)
        case .edit(let draft):
            guard current.post.creator_id == me else { throw ChatPollError("Only the poll’s author can edit it.") }
            let draft = try draft.validated()
            if current.poll.totalSelections > 0 {
                guard draft.question == current.post.message,draft.multiple == current.poll.options.multiple,draft.anonymous == current.poll.options.anonymous,
                      draft.choices.map(\.serverID) == current.poll.choices.map({ Optional($0.id) }),draft.choices.map(\.text) == current.poll.choices.map(\.text) else { throw ChatPollError("Votes have arrived. Refresh before editing; only the closing time and new-option setting can change now.") }
            }
            try await api.editPoll(postID:post.id,channelID:post.channel_id,draft:draft,full:current.poll.totalSelections == 0)
        }
        try checkConversationSession(expected)
        guard canReadPoll(post) else { throw CancellationError() }
        let updated = try await pollDetails(post)
        try checkConversationSession(expected)
        switch action {
        case .vote(let ids):guard Set(updated.poll.selected(by:me)) == Set(ids) else { throw ChatAPIError.invalidResponse }
        case .addOption(let text):guard updated.poll.choices.contains(where:{ $0.text == text.trimmingCharacters(in:.whitespacesAndNewlines) }) else { throw ChatAPIError.invalidResponse }
        case .close:guard updated.poll.state == "close" else { throw ChatAPIError.invalidResponse }
        case .edit(let value):
            let value = try value.validated()
            guard updated.poll.options.add_option == value.allowAdd,abs(updated.poll.options.expire_at-value.options.expire_at) < 1000 else { throw ChatAPIError.invalidResponse }
            if current.poll.totalSelections == 0 {
                guard updated.post.message == value.question,updated.poll.choices.map(\.text) == value.choices.map(\.text),updated.poll.options.multiple == value.multiple,updated.poll.options.anonymous == value.anonymous else { throw ChatAPIError.invalidResponse }
            }
        }
        let key = UUID();canonicalReadKeys[post.id] = key;applyCanonical(updated.post,readKey:key)
        return updated
    }

    func conversationFiles(channelID: Int64, query: String, offset: Int, options: ChatLibraryFileOptions) async throws -> ChatSearchPage {
        guard canBrowseConversationContent(channelID), canRead(channelID), let api = client else { throw ChatAPIError.unsupportedAPI }
        let epoch = connectionGeneration
        let page = try await api.conversationFiles(channelID: channelID, query: query, offset: offset, options: options)
        try Task.checkCancellation(); try checkConversationSession(epoch)
        guard canBrowseConversationContent(channelID), canRead(channelID) else { throw CancellationError() }
        return page
    }

    func pinnedMessages(channelID:Int64,query:String,offset:Int,sort:ChatPinSort = .pinned) async throws -> ChatSearchPage {
        guard canBrowseConversationContent(channelID),let api = client else { throw ChatAPIError.unsupportedAPI }
        let expected = connectionGeneration
        try checkConversationSession(expected)
        let page = try await api.pinnedMessages(channelID:channelID,query:query,offset:offset,sort:sort)
        try checkConversationSession(expected)
        guard canBrowseConversationContent(channelID) else { throw CancellationError() }
        return page
    }

    /// Publish only an authoritative readback; a successful write alone does not prove the flag changed.
    @discardableResult func setBookmark(_ post: ChatPost, enabled: Bool) async -> Bool {
        guard canAct(on:post), let api = client else { return false }
        let expected = connectionGeneration
        pendingMessageActions.insert(post.id); error = nil
        defer { if connectionGeneration == expected { pendingMessageActions.remove(post.id) } }
        do {
            try await api.setBookmark(postID:post.id,enabled:enabled)
            try checkConversationSession(expected)
            let readKey = UUID(); canonicalReadKeys[post.id] = readKey
            let updated = try await api.post(channelID:post.channel_id,postID:post.id,threadID:post.thread_id)
            try checkConversationSession(expected)
            guard updated.id == post.id, updated.channel_id == post.channel_id, updated.is_star == enabled else {
                throw ChatAPIError.invalidResponse
            }
            applyCanonical(updated,readKey:readKey)
            return true
        } catch {
            guard connectionGeneration == expected else { return false }
            self.error = "Could not confirm the saved-message change. Refresh before trying again."
            return false
        }
    }

    func toggleThumbsUp(_ post: ChatPost) async {
        await toggleReaction(post, kind: .thumbsUp)
    }

    func toggleReaction(_ post: ChatPost, kind: ChatReactionKind) async {
        await toggleNamedReaction(post, name: kind.rawValue)
    }
    private func toggleNamedReaction(_ post: ChatPost, name: String) async {
        guard ChatReactionKind(rawValue: name) != nil else { return }
        guard canAct(on: post), let id = currentUserID, let api = client else { return }
        let enabled = !(post.reactions ?? []).contains { $0.sticker_name == name && $0.user_ids.contains(id) }
        if enabled, let kind = ChatReactionKind(rawValue: name) { emojiPreferences.record(kind) }
        let expected = connectionGeneration
        pendingMessageActions.insert(post.id)
        error = nil
        defer { if expected == connectionGeneration { pendingMessageActions.remove(post.id) } }
        do {
            try await api.setReaction(postID: post.id, stickerName: name, enabled: enabled)
            guard expected == connectionGeneration else { return }
            let readKey = UUID()
            canonicalReadKeys[post.id] = readKey
            let updated = try await api.post(channelID: post.channel_id, postID: post.id, threadID: post.thread_id)
            guard expected == connectionGeneration else { return }
            applyCanonical(updated, readKey: readKey)
        } catch {
            guard expected == connectionGeneration else { return }
            self.error = "Could not update this reaction. Refresh the message and try again."
        }
    }

    private func checkConversationSession(_ expected: Int) throws {
        try Task.checkCancellation()
        guard expected == connectionGeneration, connected else { throw CancellationError() }
    }

    func sidebarUser(_ channel:ChatChannel) -> ChatUser? {
        if channel.type == "synobot" { return directory.first { $0.user_id == currentUserID } }
        guard channel.type == "anonymous",let members = channelMemberIDs[channel.id] else { return nil }
        let peers = members.filter { $0 != currentUserID }
        guard peers.count == 1 else { return nil };return directory.first { $0.user_id == peers[0] }
    }
    func openProfileConversation(userID:Int64) async throws {
        guard !isEditingMessage else { throw ChatTransferError(message:"Finish editing the current message before opening a conversation.") }
        guard let person = directory.first(where: { $0.user_id == userID }), person.canStartConversation else { throw ChatAPIError.invalidResponse }
        let expected = connectionGeneration, origin = selection, root = threadRoot?.id
        let reviewed = try await loadQuickSwitcher()
        guard origin == selection, root == threadRoot?.id, !isEditingMessage else { throw CancellationError() }
        guard let fresh = reviewed.users.first(where: { $0.user_id == userID }), fresh.username == person.username, fresh.nickname == person.nickname else { throw ChatTransferError(message: "This profile changed. Refresh it before opening a conversation.") }
        try await startConversation(with:[userID], reviewed: reviewed)
        try checkConversationSession(expected)
        profileConversationRoute = UUID()
    }
    private func scheduleProfileRefresh() {
        profileRefreshID = UUID()
        profileRefreshTask?.cancel()
        profileRefreshTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds:150_000_000);try Task.checkCancellation();try await self?.refreshUserProfiles() } catch { }
        }
    }
    func refreshUserProfiles() async throws {
        guard connected,let api = client else { throw ChatAPIError.connection }
        let expected = connectionGeneration,key = UUID();profileRefreshID = key
        let users = try await api.users()
        try checkConversationSession(expected)
        guard profileRefreshID == key else { throw CancellationError() }
        guard users.allSatisfy({ $0.user_id > 0 }),Set(users.map(\.user_id)).count == users.count else { throw ChatAPIError.invalidResponse }
        let previous = encryptionKeyPair,next = users.first(where:{ $0.user_id == currentUserID })?.user_props?.key_pair
        if previous?.public_key != next?.public_key || previous?.private_key_enc != next?.private_key_enc { lockEncryption() }
        directory = users
    }

    func conversationMembers(channelID: Int64) async throws -> [ChatUser] {
        guard let api = client else { throw ChatAPIError.connection }
        let expected = connectionGeneration
        try checkConversationSession(expected)
        let ids = Set(try await api.members(channelID: channelID))
        try checkConversationSession(expected)
        let users = try await api.users()
        try checkConversationSession(expected)
        return users.filter { ids.contains($0.user_id) }.sorted { displayName($0).localizedCaseInsensitiveCompare(displayName($1)) == .orderedAscending }
    }

    func refreshChannelPermissions() async {
        guard let api = client else { return }
        let expected = connectionGeneration
        let permissions = try? await api.channelPermissions()
        guard expected == connectionGeneration, !Task.isCancelled else { return }
        channelPermissions = permissions
    }

    func createChannel(name: String, purpose: String, kind: ChatNamedChannelKind,encrypted:Bool = false) async throws {
        if encrypted {
            guard kind == .private else { throw ChatTransferError(message:"Encrypted channels must be private.") }
            try await createEncryptedPrivateChannel(name:name,purpose:purpose);return
        }
        guard canInteract, !sending, !channelManagementBusy, let api = client else { throw ChatAPIError.connection }
        let expected = connectionGeneration
        channelManagementBusy = true
        defer { if expected == connectionGeneration { channelManagementBusy = false } }
        let permissions = try await api.channelPermissions()
        guard expected == connectionGeneration, canInteract else { throw CancellationError() }
        guard permissions.allows("channel_create"), kind != .public || permissions.allows("channel_public") else {
            throw ChatTransferError(message: "Your account cannot create this type of channel.")
        }
        let channel = try await api.createNamedChannel(name: name, purpose: purpose, kind: kind,
            checkContinuation: { try self.checkConversationSession(expected) })
        try checkConversationSession(expected)
        channels = (channels.filter { $0.id != channel.id } + [channel]).sorted { title($0).localizedCaseInsensitiveCompare(title($1)) == .orderedAscending }
        if selection == channel.id { loadSelection() } else { selection = channel.id }
    }

    private func channelForMembershipChange(_ id: Int64, action: String) async throws -> (ChatAPIClient, ChatChannel, Int) {
        guard canInteract, !sending, currentUserID != nil, let api = client else { throw ChatAPIError.connection }
        let expected = connectionGeneration
        let permissions = try await api.channelPermissions()
        try checkConversationSession(expected)
        let available = try await api.channels()
        try checkConversationSession(expected)
        guard available.allSatisfy({ $0.id > 0 }),Set(available.map(\.id)).count == available.count else { throw ChatAPIError.invalidResponse }
        guard canInteract else { throw CancellationError() }
        guard permissions.allows(action), let channel = available.first(where: { $0.id == id }),
              (action == "channel_kick" ? channel.supportsMemberRemoval : channel.supportsMemberInvitation) else {
            throw ChatTransferError(message: "This channel does not allow that membership change.")
        }
        guard action != "channel_invite" || channel.id != 1, action != "channel_kick" || channel.type == "private" else {
            throw ChatTransferError(message: "This channel does not support that membership change.")
        }
        return (api, channel, expected)
    }

    private func readInvitationSnapshot(channelID:Int64,expected:Int,keyEpoch:Int) async throws -> ChatChannelInvitationSnapshot {
        let (api,channel,_) = try await channelForMembershipChange(channelID,action:"channel_invite")
        try checkConversationSession(expected)
        guard let owner = currentUserID else { throw ChatAPIError.connection }
        let ids = try await api.members(channelID:channelID);try checkConversationSession(expected)
        guard ids.allSatisfy({ $0 > 0 }),Set(ids).count == ids.count,ids.contains(owner) else { throw ChatAPIError.invalidResponse }
        let users = try await api.users();try checkConversationSession(expected)
        guard users.allSatisfy({ $0.user_id > 0 }),Set(users.map(\.user_id)).count == users.count,users.contains(where:{ $0.user_id == owner }) else { throw ChatAPIError.invalidResponse }
        var ownerKeys:ChatEncryptionOwnerState?
        if channel.encrypted {
            guard encryptionUnlocked,keyEpoch == encryptionGeneration,canRead(channelID),let cached = encryptionKeyPair,
                  let listed = users.first(where:{ $0.user_id == owner })?.user_props?.key_pair else { throw ChatCryptoError.invalidKey }
            let strict = try await api.encryptionOwnerState(userID:owner);try checkConversationSession(expected)
            guard strict.isInitialized,encryption.matchesUnlockedPublicKey(strict.pair.public_key),strict == ChatEncryptionOwnerState(userID:owner,pair:cached),strict == ChatEncryptionOwnerState(userID:owner,pair:listed),
                  keyEpoch == encryptionGeneration,encryptionUnlocked else { throw ChatTransferError(message:"Your encryption keys changed. Refresh the account and unlock this channel again.") }
            _ = try encryption.key(for:channel);ownerKeys = strict
        }
        guard canInteract else { throw CancellationError() }
        return .init(channel:channel,users:users,members:Set(ids),ownerID:owner,ownerKeys:ownerKeys,accountGeneration:expected,keyGeneration:keyEpoch)
    }
    func invitationSnapshot(channelID:Int64) async throws -> ChatChannelInvitationSnapshot {
        let epoch = accountGeneration,keyEpoch = encryptionGeneration
        try refreshInvitationRecovery(expectedGeneration:epoch)
        guard !channelManagementBusy else { throw ChatAPIError.connection }
        channelManagementBusy = true;defer { if epoch == accountGeneration { channelManagementBusy = false } }
        return try await readInvitationSnapshot(channelID:channelID,expected:epoch,keyEpoch:keyEpoch)
    }
    func inviteMembers(_ ids:Set<Int64>,channelID:Int64,reviewed:ChatChannelInvitationSnapshot? = nil) async throws {
        let epoch = accountGeneration,keyEpoch = encryptionGeneration,origin = selection
        try refreshInvitationRecovery(expectedGeneration:epoch)
        guard !channelManagementBusy,let api = client else { throw ChatAPIError.connection }
        guard pendingInvitations[channelID] == nil else { throw ChatChannelInvitationFailure(uncertain:true,message:"A previous invitation is unconfirmed. Review it in Pending actions before adding people again.") }
        if let reviewed { guard reviewed.accountGeneration == epoch,reviewed.ownerID == currentUserID,reviewed.channel.id == channelID else { throw ChatAPIError.connection } }
        channelManagementBusy = true;defer { if epoch == accountGeneration { channelManagementBusy = false } }
        var fresh = try await readInvitationSnapshot(channelID:channelID,expected:epoch,keyEpoch:keyEpoch)
        let baseline = reviewed ?? fresh
        func validate(_ current:ChatChannelInvitationSnapshot) throws {
            try checkConversationSession(epoch)
            guard origin == selection,canInteract,!sending,baseline.channel.sameInvitationScope(as:current.channel),
                  !ids.isEmpty,ids.allSatisfy({ $0 > 0 }),!ids.contains(current.ownerID),ids.isDisjoint(with:baseline.members),ids.isDisjoint(with:current.members) else {
                throw ChatTransferError(message:"The channel or member list changed. Refresh and review the people again.")
            }
            for id in ids {
                guard let previous = baseline.users.first(where:{ $0.user_id == id }),let person = current.users.first(where:{ $0.user_id == id }),
                      previous.canStartConversation,person.canStartConversation,previous.username == person.username,previous.nickname == person.nickname else {
                    throw ChatTransferError(message:"A selected person changed or is no longer available. Refresh and review the selection.")
                }
            }
            if current.channel.encrypted {
                guard keyEpoch == encryptionGeneration,baseline.keyGeneration == keyEpoch,baseline.ownerKeys == current.ownerKeys,encryptionUnlocked else { throw CancellationError() }
            }
        }
        try validate(fresh)
        let plan:ChatEncryptedChannelInvitation?
        if fresh.channel.encrypted {
            plan = try ChatEncryptedChannelInvitation(channel:fresh.channel,recipients:baseline.users.filter { ids.contains($0.user_id) },encryption:encryption)
            try plan?.validate(channel:fresh.channel,users:fresh.users)
            fresh = try await readInvitationSnapshot(channelID:channelID,expected:epoch,keyEpoch:keyEpoch)
            try validate(fresh);try plan?.validate(channel:fresh.channel,users:fresh.users)
        } else { plan = nil }
        let receipt = try ChatChannelInvitationIntent(channel:fresh.channel,members:ids),scope = invitationJournal.accountScope
        var saved = false,dispatched = false
        do {
            do { try invitationJournal.remember(receipt);saved = true;pendingInvitations[channelID] = receipt }
            catch { invitationRecoveryError = "The invitation was not sent because its recovery record could not be saved. Repair storage and refresh saved state.";throw error }
            try validate(fresh)
            dispatched = true
            if let plan { try await api.inviteEncryptedChannelMembers(plan,channel:fresh.channel,users:fresh.users) }
            else { try await api.inviteChannelMembers(ids,channel:fresh.channel) }
            try checkConversationSession(epoch)
            let updated = try await api.members(channelID:channelID);try checkConversationSession(epoch)
            guard Set(updated).count == updated.count,updated.allSatisfy({ $0 > 0 }),ids.isSubset(of:Set(updated)),updated.contains(fresh.ownerID) else { throw ChatAPIError.invalidResponse }
            let available = try await api.channels();try checkConversationSession(epoch)
            guard receipt.matchesExactly(available) else { throw ChatAPIError.invalidResponse }
            do { try invitationJournal.remove(receipt);pendingInvitations.removeValue(forKey:channelID) }
            catch { invitationRecoveryError = "Membership was confirmed, but its saved warning could not be cleared. Repair storage and refresh saved state; do not repeat the invitation automatically." }
            if keyEpoch == encryptionGeneration { directory = fresh.users }
        } catch {
            if saved && !dispatched {
                do { try invitationJournal.removeUndispatched(receipt,originalScope:scope);if epoch == accountGeneration { pendingInvitations.removeValue(forKey:channelID) } }
                catch { if epoch == accountGeneration { invitationRecoveryError = "An unsent invitation record could not be cleared. Repair storage and refresh saved state." } }
            }
            guard epoch == accountGeneration else { throw CancellationError() }
            if dispatched { throw ChatChannelInvitationFailure(uncertain:true,message:"Membership could not be confirmed. The invitation is saved across restarts. Use Pending actions to check status; it will not be sent again automatically.") }
            throw error
        }
    }

    func removeMember(_ userID: Int64, channelID: Int64) async throws {
        guard !channelManagementBusy else { throw ChatAPIError.invalidResponse }
        let epoch = connectionGeneration
        channelManagementBusy = true
        defer { if epoch == connectionGeneration { channelManagementBusy = false } }
        let (api, channel, expected) = try await channelForMembershipChange(channelID, action: "channel_kick")
        let members = Set(try await api.members(channelID: channelID))
        try checkConversationSession(expected)
        let users = try await api.users()
        try checkConversationSession(expected)
        guard userID != currentUserID, userID != channel.creator_id, members.contains(userID),
              users.contains(where: { $0.user_id == userID && $0.type == "human" && $0.human_type == "dsm" }) else {
            throw ChatTransferError(message: "This person cannot be removed here. Refresh the member list.")
        }
        guard expected == connectionGeneration, canInteract else { throw CancellationError() }
        try await api.removeChannelMember(userID, channel: channel)
        try checkConversationSession(expected)
        let updated = Set(try await api.members(channelID: channelID))
        try checkConversationSession(expected)
        guard !updated.contains(userID) else { throw ChatTransferError(message: "Removal could not be confirmed. Refresh the member list before trying again.") }
    }

    func startConversation(with peers: Set<Int64>, reviewed: ChatQuickSwitchSnapshot? = nil) async throws {
        guard canInteract, !sending, !isEditingMessage, !channelManagementBusy, !quickSwitcherBusy,
              let me = currentUserID, !peers.isEmpty, !peers.contains(me), peers.allSatisfy({ $0 > 0 }) else { throw ChatAPIError.invalidResponse }
        let epoch = accountGeneration, origin = selection, root = threadRoot?.id
        if let reviewed { guard reviewed.accountGeneration == epoch, reviewed.ownerID == me else { throw ChatAPIError.connection } }
        channelManagementBusy = true
        defer { if epoch == accountGeneration { channelManagementBusy = false } }
        let fresh = try await quickSwitchSnapshot()
        let baseline = reviewed ?? fresh
        let wanted = peers.union([me])
        let original = try existingConversation(members: wanted, snapshot: baseline)
        let result = try await resolveConversationStart(members: wanted, reviewed: baseline, fresh: fresh, expectedExisting: original?.channel?.id, epoch: epoch, origin: origin, root: root)
        try checkConversationSession(epoch)
        guard origin == selection, root == threadRoot?.id, !isEditingMessage else { throw CancellationError() }
        applyConversationRoute(result.entry, snapshot: result.snapshot)
    }

    func canViewPostHashtags(_ post: ChatPost) -> Bool {
        connected && currentUserID != nil && post.type != "system" && (post.delete_at ?? 0) == 0
            && !deletedPostIDs.contains(post.id) && canRead(post.channel_id)
            && channels.first(where: { $0.id == post.channel_id })?.encrypted == false
    }
    func canChangePostHashtags(_ post: ChatPost) -> Bool {
        canViewPostHashtags(post) && canAct(on: post) && !postHashtagsNeedRefresh.contains(post.id)
    }
    func postHashtags(_ post: ChatPost) async throws -> ChatPostHashtagSnapshot {
        guard canViewPostHashtags(post), !pendingMessageActions.contains(post.id), let api = client else { throw ChatAPIError.unsupportedAPI }
        let epoch = connectionGeneration; let key = UUID(); canonicalReadKeys[post.id] = key
        let fresh = try await api.post(channelID: post.channel_id, postID: post.id, threadID: post.thread_id)
        try Task.checkCancellation(); try checkConversationSession(epoch)
        guard fresh.id == post.id, fresh.channel_id == post.channel_id, (fresh.thread_id ?? 0) == (post.thread_id ?? 0),
              canViewPostHashtags(post), canViewPostHashtags(fresh) else { throw ChatAPIError.invalidResponse }
        guard canonicalReadKeys[post.id] == key else { throw ChatTransferError(message: "The message changed while loading tags. Refresh again.") }
        applyCanonical(fresh, readKey: key); postHashtagsNeedRefresh.remove(post.id)
        return .init(post: fresh, accountGeneration: epoch)
    }
    func changeAdditionalHashtag(_ source: ChatPostHashtagSnapshot, hashtag: String, enabled: Bool) async throws -> ChatPostHashtagSnapshot {
        let post = source.post
        guard source.accountGeneration == connectionGeneration, canChangePostHashtags(post), ChatHashtags.valid(hashtag), let api = client else { throw ChatAPIError.unsupportedAPI }
        let epoch = connectionGeneration; var dispatched = false
        pendingMessageActions.insert(post.id)
        defer { if epoch == connectionGeneration { pendingMessageActions.remove(post.id) } }
        func check(_ value: ChatPost) throws {
            try Task.checkCancellation(); try checkConversationSession(epoch)
            guard canInteract, canViewPostHashtags(post), canViewPostHashtags(value), value.id == post.id,
                  value.channel_id == post.channel_id, (value.thread_id ?? 0) == (post.thread_id ?? 0) else { throw CancellationError() }
        }
        do {
            let fresh = try await api.post(channelID: post.channel_id, postID: post.id, threadID: post.thread_id)
            try check(fresh)
            guard fresh.message == post.message, fresh.creator_id == post.creator_id, fresh.type == post.type else { throw ChatTransferError(message: "This message changed. Refresh its tags before continuing.") }
            let old = source.additional.filter { $0.hashtag == hashtag }
            let current = (fresh.hashtags_additional ?? []).filter { $0.hashtag == hashtag }
            if enabled && current.isEmpty && (fresh.hashtags ?? []).contains(hashtag) { throw ChatTransferError(message: "This hashtag is already indexed for this message.") }
            let alreadyDone = enabled ? !current.isEmpty : current.isEmpty
            if !alreadyDone {
                guard enabled || !old.isEmpty && old == current else { throw ChatTransferError(message: "Who added this tag changed. Refresh before removing it.") }
                dispatched = true
                try await api.setAdditionalHashtag(postID: post.id, hashtag: hashtag, enabled: enabled)
            }
            try check(fresh)
            let key = UUID(); canonicalReadKeys[post.id] = key
            let canonical = try await api.post(channelID: post.channel_id, postID: post.id, threadID: post.thread_id)
            try check(canonical)
            let exists = (canonical.hashtags_additional ?? []).contains { $0.hashtag == hashtag }
            guard exists == enabled, canonicalReadKeys[post.id] == key else { throw ChatTransferError(message: "Could not confirm this tag change. Refresh before continuing.") }
            applyCanonical(canonical, readKey: key); postHashtagsNeedRefresh.remove(post.id)
            return .init(post: canonical, accountGeneration: epoch)
        } catch {
            if dispatched, epoch == connectionGeneration { postHashtagsNeedRefresh.insert(post.id) }
            throw error
        }
    }

    func canViewReactionDetails(_ post: ChatPost) -> Bool {
        connected && currentUserID != nil && post.type != "system" && (post.delete_at ?? 0) == 0
            && !deletedPostIDs.contains(post.id) && canRead(post.channel_id)
    }
    func reactionDetails(_ post: ChatPost) async throws -> ChatReactionDetails {
        guard canViewReactionDetails(post), let api = client else { throw ChatAPIError.unsupportedAPI }
        let epoch = connectionGeneration
        let fresh = try await api.post(channelID: post.channel_id, postID: post.id, threadID: post.thread_id)
        try Task.checkCancellation(); try checkConversationSession(epoch)
        guard fresh.id == post.id, fresh.channel_id == post.channel_id, (fresh.thread_id ?? 0) == (post.thread_id ?? 0) else { throw ChatAPIError.invalidResponse }
        guard canViewReactionDetails(post), canViewReactionDetails(fresh) else { throw ChatAPIError.invalidResponse }
        return ChatReactionDetails(fresh.reactions ?? [])
    }

    func canViewReadStatus(_ post:ChatPost) -> Bool {
        connected && allowsReadStatus && currentUserID != nil && post.creator_id == currentUserID
            && post.type != "system" && (post.delete_at ?? 0) == 0 && !deletedPostIDs.contains(post.id) && canRead(post.channel_id)
    }
    func readStatus(_ post:ChatPost) async throws -> ChatPostReadStatus {
        guard canViewReadStatus(post), let api = client else { throw ChatAPIError.unsupportedAPI }
        let expected = connectionGeneration
        try checkConversationSession(expected)
        let status = try await api.readStatus(postID:post.id)
        try checkConversationSession(expected)
        guard canViewReadStatus(post) else { throw CancellationError() }
        return status
    }

    func followsThread(_ post: ChatPost) -> Bool? {
        let rootID = post.isReply ? post.thread_id ?? post.id : post.id
        return channels.first(where:{ $0.id == post.channel_id })?.subscribes.map { $0.contains(rootID) }
    }
    func threadCollection(channelID:Int64,offset:Int) async throws -> ChatThreadCollectionPage {
        guard let api = client, channels.contains(where:{ $0.id == channelID }) else { throw ChatAPIError.unsupportedAPI }
        let expected = connectionGeneration
        try checkConversationSession(expected)
        let page = try await api.threadCollection(channelID:channelID,offset:offset)
        try checkConversationSession(expected)
        guard channels.contains(where:{ $0.id == channelID }) else { throw CancellationError() }
        return page
    }
    @discardableResult func setThreadSubscription(_ root:ChatPost,enabled:Bool) async -> Bool {
        guard !root.isReply, canAct(on:root), followsThread(root) != nil, let api = client else { return false }
        let expected = connectionGeneration
        pendingMessageActions.insert(root.id); error = nil
        defer { if connectionGeneration == expected { pendingMessageActions.remove(root.id) } }
        do {
            try await api.setThreadSubscription(postID:root.id,enabled:enabled)
            try checkConversationSession(expected)
            let canonical = try await api.channels()
            try checkConversationSession(expected)
            guard let subscriptions = canonical.first(where:{ $0.id == root.channel_id })?.subscribes,
                  subscriptions.contains(root.id) == enabled else { throw ChatAPIError.invalidResponse }
            channels = canonical
            return true
        } catch {
            guard connectionGeneration == expected else { return false }
            self.error = "Could not confirm thread following. Refresh and try again."
            return false
        }
    }

    func canBrowseHashtags(_ channelID: Int64) -> Bool { canBrowseConversationContent(channelID) }
    func canBrowseConversationContent(_ channelID: Int64) -> Bool {
        connected && channels.first(where:{ $0.id == channelID })?.encrypted == false
    }
    func channelHashtags(channelID: Int64) async throws -> [String] {
        guard canBrowseHashtags(channelID), let api = client else { throw ChatAPIError.unsupportedAPI }
        let expected = connectionGeneration
        let tags = try await api.channelHashtags(channelID:channelID)
        try checkConversationSession(expected)
        guard canBrowseHashtags(channelID) else { throw CancellationError() }
        return tags
    }

    func searchMessages(query: String, channelID: Int64?, offset: Int, hashtag: String? = nil, filters: ChatSearchFilters = .init()) async throws -> ChatSearchPage {
        guard let api = client else { throw ChatAPIError.connection }
        let expected = connectionGeneration
        try checkConversationSession(expected)
        if hashtag != nil { guard let channelID, canBrowseHashtags(channelID) else { throw ChatAPIError.unsupportedAPI } }
        let result = try await api.searchMessages(query: query, channelID: channelID, offset: offset, hashtag: hashtag, filters: filters)
        try checkConversationSession(expected)
        return result
    }

    func canReceiveConversationFileDrop(inThread:Bool = false) -> Bool {
        canInteract && !sending && !isEditingMessage && !preparingComposerAttachment && attachmentBatch == nil
            && selection.map(canRead) == true && (!inThread || canComposeInThread)
    }
    @discardableResult func receiveConversationFileDrop(_ providers:[NSItemProvider],inThread:Bool = false) -> Bool {
        guard canReceiveConversationFileDrop(inThread:inThread),let channel = selectedChannel,!providers.isEmpty else { return false }
        let context = ComposerAttachmentContext(channelID:channel.id,rootID:inThread ? threadRoot?.id : nil,encrypted:channel.encrypted,keyEnvelope:channel.channel_key_enc)
        let expected = connectionGeneration,expectedEncryption = encryptionGeneration,key = UUID()
        error = nil;composerAttachmentRequestID = key;composerAttachmentContext = context;preparingComposerAttachment = true
        updateReadingVisibility(active:false,atBottom:false);updateThreadReadingVisibility(active:false,atBottom:false)
        composerAttachmentTask = Task { [weak self] in
            defer {
                if let self,self.composerAttachmentRequestID == key {
                    self.preparingComposerAttachment = false;self.composerAttachmentTask = nil;self.composerAttachmentContext = nil;self.composerAttachmentRequestID = nil
                }
            }
            do {
                let attachments = try await NativeConversationFileDropReader.readAttachments(providers)
                // Generated raster files belong to this read until an active
                // review takes ownership. Retired destinations leave no cache.
                var unclaimedImages = attachments.generatedImageFiles
                defer { for file in unclaimedImages { NativeComposerAttachmentReader.removeImage(file) } }
                guard let self,!Task.isCancelled,self.composerAttachmentRequestID == key,self.connectionGeneration == expected,
                      self.selection == context.channelID,self.canInteract,self.canRead(context.channelID),!self.sending,!self.isEditingMessage,
                      context.rootID == nil || self.threadRoot?.id == context.rootID,
                      !context.encrypted || self.encryptionGeneration == expectedEncryption,
                      self.selectedChannel?.encrypted == context.encrypted,self.selectedChannel?.channel_key_enc == context.keyEnvelope else { return }
                self.composerImageFiles.formUnion(attachments.generatedImageFiles)
                self.preparingComposerAttachment = false;self.stageAttachments(attachments.files,inThread:inThread)
                let staged = Set(self.attachmentBatch?.items.compactMap(\.localFile) ?? [])
                for file in attachments.generatedImageFiles {
                    if staged.contains(file) { unclaimedImages.remove(file) }
                    else { self.composerImageFiles.remove(file) }
                }
            } catch {
                guard let self,!Task.isCancelled,self.composerAttachmentRequestID == key,self.connectionGeneration == expected else { return }
                self.error = (error as? ChatTransferError)?.message ?? "Could not read the dropped files. Save them locally and try again."
            }
        }
        return true
    }

    func receiveComposerAttachment(_ input:NativeComposerAttachmentInput,inThread:Bool = false) {
        guard canInteract,!sending,!isEditingMessage,let channel = selectedChannel,canRead(channel.id),
              !inThread || canComposeInThread else { error = "Connect to a readable conversation before attaching files.";return }
        guard !preparingComposerAttachment else { error = "Wait for the attachment to finish preparing.";return }
        switch input {
        case .none:return
        case .invalid(let message):error = message
        case .files(let files):stageAttachments(files,inThread:inThread)
        case .image(let data,let format):
            prepareComposerAttachments([.image(data,format)], channel:channel, inThread:inThread)
        case .items(let items):
            prepareComposerAttachments(items, channel:channel, inThread:inThread)
        }
    }
    private func prepareComposerAttachments(_ items:[NativeComposerAttachmentItem],channel:ChatChannel,inThread:Bool) {
        let context = ComposerAttachmentContext(channelID:channel.id,rootID:inThread ? threadRoot?.id : nil,encrypted:channel.encrypted,keyEnvelope:channel.channel_key_enc)
        let expected = connectionGeneration,expectedEncryption = encryptionGeneration,key = UUID()
        composerAttachmentRequestID = key;composerAttachmentContext = context;preparingComposerAttachment = true
        updateReadingVisibility(active:false,atBottom:false);updateThreadReadingVisibility(active:false,atBottom:false)
        composerAttachmentTask = Task { [weak self] in
            defer {
                if let self,self.composerAttachmentRequestID == key { self.preparingComposerAttachment = false;self.composerAttachmentTask = nil;self.composerAttachmentContext = nil;self.composerAttachmentRequestID = nil }
            }
            do {
                let work = Task.detached(priority:.userInitiated) { try NativeComposerAttachmentReader.prepare(items) }
                let attachments = try await withTaskCancellationHandler(operation:{ try await work.value },onCancel:{ work.cancel() })
                var unclaimedImages = attachments.generatedImageFiles
                defer { for file in unclaimedImages { NativeComposerAttachmentReader.removeImage(file) } }
                guard let self,!Task.isCancelled,self.composerAttachmentRequestID == key,self.connectionGeneration == expected,
                      self.selection == context.channelID,self.canInteract,self.canRead(context.channelID),!self.sending,!self.isEditingMessage,
                      context.rootID == nil || self.threadRoot?.id == context.rootID,
                      !context.encrypted || self.encryptionGeneration == expectedEncryption,
                      self.selectedChannel?.encrypted == context.encrypted,self.selectedChannel?.channel_key_enc == context.keyEnvelope else { return }
                self.composerImageFiles.formUnion(attachments.generatedImageFiles)
                self.preparingComposerAttachment = false
                self.stageAttachments(attachments.files,inThread:inThread)
                let staged = Set(self.attachmentBatch?.items.compactMap(\.localFile) ?? [])
                for file in attachments.generatedImageFiles {
                    if staged.contains(file) { unclaimedImages.remove(file) }
                    else { self.composerImageFiles.remove(file) }
                }
            } catch {
                guard let self,self.composerAttachmentRequestID == key,!Task.isCancelled else { return }
                self.error = (error as? LocalizedError)?.errorDescription ?? "Could not prepare these clipboard attachments."
            }
        }
    }
    func captureScreenshot(inThread:Bool = false,capture:@escaping @Sendable () async throws -> Data? = NativeScreenshotCapture.capture) {
        guard canInteract,!sending,!isEditingMessage,!preparingComposerAttachment,attachmentBatch == nil,let channel = selectedChannel,canRead(channel.id),!inThread || canComposeInThread,ChatMessageText.isAllowed(inThread ? replyDraft : draft) else {return}
        let context = ComposerAttachmentContext(channelID:channel.id,rootID:inThread ? threadRoot?.id : nil,encrypted:channel.encrypted,keyEnvelope:channel.channel_key_enc)
        let expected = connectionGeneration,expectedEncryption = encryptionGeneration,key = UUID()
        composerAttachmentRequestID = key;composerAttachmentContext = context;preparingComposerAttachment = true;capturingScreenshot = true
        updateReadingVisibility(active:false,atBottom:false);updateThreadReadingVisibility(active:false,atBottom:false)
        composerAttachmentTask = Task { [weak self] in
            defer {if let self,self.composerAttachmentRequestID == key {self.preparingComposerAttachment = false;self.capturingScreenshot = false;self.composerAttachmentTask = nil;self.composerAttachmentContext = nil;self.composerAttachmentRequestID = nil}}
            do {
                guard let data = try await capture() else {return}
                try Task.checkCancellation()
                let work = Task.detached(priority:.userInitiated) {try NativeComposerAttachmentReader.writeImage(data,format:"png",basename:"Screenshot")}
                let file = try await withTaskCancellationHandler(operation:{try await work.value},onCancel:{work.cancel()})
                guard let self,!Task.isCancelled,self.composerAttachmentRequestID == key,self.connectionGeneration == expected,self.selection == context.channelID,self.canInteract,self.canRead(context.channelID),!self.isEditingMessage,!self.sending,context.rootID == nil || self.threadRoot?.id == context.rootID,!context.encrypted || self.encryptionGeneration == expectedEncryption,self.selectedChannel?.encrypted == context.encrypted,self.selectedChannel?.channel_key_enc == context.keyEnvelope else {NativeComposerAttachmentReader.removeImage(file);return}
                self.composerImageFiles.insert(file);self.preparingComposerAttachment = false;self.capturingScreenshot = false
                self.stageAttachments([file],inThread:inThread)
                if self.attachmentBatch?.items.contains(where:{$0.localFile == file}) != true {self.composerImageFiles.remove(file);NativeComposerAttachmentReader.removeImage(file)}
            } catch is CancellationError {} catch {
                guard let self,self.composerAttachmentRequestID == key,!Task.isCancelled else {return}
                self.error = (error as? LocalizedError)?.errorDescription ?? "Could not prepare the screenshot. Try capturing a smaller area."
            }
        }
    }
    func saveScreenshotCopy(itemID:UUID,chooseDestination:((String) async -> URL?)? = nil) async throws -> Bool {
        guard let batch = attachmentBatch,!batch.sending,let file = batch.items.first(where:{$0.id == itemID})?.localFile,file.lastPathComponent == "Screenshot.png",composerImageFiles.contains(file),canRead(batch.channelID) else {throw CancellationError()}
        let epoch = connectionGeneration,encryptionEpoch = encryptionGeneration,batchID = batch.id
        let destination:URL?
        if let chooseDestination {destination = await chooseDestination("Screenshot.png")}
        else {
            let panel = NSSavePanel();panel.title = "Save screenshot copy";panel.nameFieldStringValue = "Screenshot.png"
            panel.allowedContentTypes = [.png]
            let accepted = await withCheckedContinuation {continuation in panel.begin {continuation.resume(returning:$0 == .OK)}}
            destination = accepted ? panel.url : nil
        }
        guard let destination else {return false}
        func stillOwnsCapture()->Bool {connectionGeneration == epoch && (!batch.encrypted || encryptionGeneration == encryptionEpoch) && attachmentBatch?.id == batchID && attachmentBatch?.sending == false && attachmentBatch?.items.contains(where:{$0.id == itemID && $0.localFile == file}) == true && composerImageFiles.contains(file) && canRead(batch.channelID)}
        guard !Task.isCancelled,stillOwnsCapture() else {throw CancellationError()}
        let work = Task.detached(priority:.userInitiated) {try NativeScreenshotCopy.stage(file,to:destination)}
        let staged = try await withTaskCancellationHandler(operation:{try await work.value},onCancel:{work.cancel()})
        defer {try? FileManager.default.removeItem(at:staged)}
        guard !Task.isCancelled,stillOwnsCapture() else {throw CancellationError()}
        try NativeScreenshotCopy.commit(staged,to:destination);return true
    }
    func cancelAttachmentPreparation() { if preparingComposerAttachment { cancelComposerAttachmentPreparation() } }
    func cancelScreenshotCapture() {if capturingScreenshot {cancelComposerAttachmentPreparation()}}
    private func cancelComposerAttachmentPreparation() {
        composerAttachmentTask?.cancel();composerAttachmentTask = nil;composerAttachmentRequestID = nil
        composerAttachmentContext = nil;preparingComposerAttachment = false;capturingScreenshot = false
    }
    private func clearComposerImageFiles() {
        for file in composerImageFiles { NativeComposerAttachmentReader.removeImage(file) }
        composerImageFiles = []
    }

    func chooseAttachment(inThread: Bool = false) async {
        guard canInteract,!preparingComposerAttachment,!isEditingMessage,!sending,let channel = selectedChannel,canRead(channel.id) else { return }
        if let warning = ChatMessageText.warning(for:inThread ? replyDraft : draft) { error = warning;return }
        let rootID = inThread ? threadRoot?.id : nil
        guard !inThread || (rootID != nil && canComposeInThread) else { return }
        let expected = connectionGeneration,expectedEncryption = encryptionGeneration
        let picker = NSOpenPanel();picker.title = "Attach files to " + title(channel)
        picker.canChooseDirectories = false;picker.canChooseFiles = true;picker.allowsMultipleSelection = true
        let accepted = await withCheckedContinuation { continuation in picker.begin { continuation.resume(returning:$0 == .OK) } }
        guard accepted,!picker.urls.isEmpty,selection == channel.id,canInteract,!isEditingMessage,!sending,
              expected == connectionGeneration,!inThread || threadRoot?.id == rootID,
              !channel.encrypted || expectedEncryption == encryptionGeneration,
              selectedChannel?.encrypted == channel.encrypted,selectedChannel?.channel_key_enc == channel.channel_key_enc,
              canRead(channel.id) else { return }
        stageAttachments(picker.urls,inThread:inThread)
    }

    func stageAttachments(_ files:[URL],inThread:Bool = false) {
        guard canInteract,!preparingComposerAttachment,!sending,!isEditingMessage,let channel = selectedChannel,canRead(channel.id),
              !inThread || canComposeInThread else { return }
        let local:[URL]
        do {local = try ChatAttachmentSelection.localFiles(files)}
        catch {self.error = (error as? LocalizedError)?.errorDescription ?? "Choose local files to attach. No files were added.";return}
        guard !local.isEmpty else { error = "Choose local files to attach.";return }
        let rootID = inThread ? threadRoot?.id : nil
        guard !inThread || rootID != nil else { return }
        let caption = inThread ? replyDraft : draft
        if let warning = ChatMessageText.warning(for:caption) { error = warning;return }
        if let batch = attachmentBatch,batch.channelID == channel.id,batch.rootID == rootID,attachmentBatchSession == connectionGeneration {
            guard batch.append(local) else {error = batch.validationError ?? "Could not add these files. No files were added.";return}
        } else {
            attachmentBatch = NativeAttachmentBatch(files:local,caption:caption,channelID:channel.id,channelTitle:title(channel),rootID:rootID,encrypted:channel.encrypted,keyEnvelope:channel.channel_key_enc)
            attachmentBatchSession = connectionGeneration
        }
        updateReadingVisibility(active:false,atBottom:false)
        updateThreadReadingVisibility(active:false,atBottom:false)
        error = nil
    }

    func sendAttachmentBatch() {
        guard let batch = attachmentBatch,batch.canSend,attachmentBatchSession == connectionGeneration,
              canInteract,!sending,!isEditingMessage,selection == batch.channelID,
              batch.rootID == nil || threadRoot?.id == batch.rootID,
              let channel = selectedChannel,channel.encrypted == batch.encrypted,channel.channel_key_enc == batch.keyEnvelope,
              canRead(channel.id),let api = client,let connectionID = live?.connectionID else { return }
        let key:Data?
        do { key = channel.encrypted ? try encryption.key(for:channel) : nil }
        catch { self.error = "Unlock this conversation before attaching files.";return }
        let expected = connectionGeneration,expectedEncryption = encryptionGeneration
        sending = true;uploading = true;uploadIsEncrypted = key != nil;error = nil
        uploadTask = Task { [weak self] in
            defer {
                if let self,self.connectionGeneration == expected,self.attachmentBatch?.id == batch.id {
                    self.sending = false;self.uploading = false;self.uploadTask = nil;self.uploadIsEncrypted = false;self.uploadProgress = nil
                    if batch.finished { self.clearComposerImageFiles();self.attachmentBatch = nil;self.attachmentBatchSession = nil }
                }
            }
            await batch.run(canContinue:{ [weak self] in
                guard let self else { return false }
                return self.connectionGeneration == expected && self.attachmentBatch?.id == batch.id
                    && self.canInteract && self.selection == batch.channelID && (batch.rootID == nil || self.threadRoot?.id == batch.rootID)
                    && self.channels.first(where:{ $0.id == batch.channelID }).map({ $0.encrypted == batch.encrypted && $0.channel_key_enc == batch.keyEnvelope }) == true
                    && (!batch.encrypted || self.encryptionGeneration == expectedEncryption) && self.canRead(batch.channelID)
            },send:{ [weak self] item in
                guard let self,self.connectionGeneration == expected else { throw CancellationError() }
                if let nasFile = item.nasFile {return try await self.sendReviewedNASFile(nasFile,batch:batch,caption:item.caption,connectionID:connectionID,epoch:expected)}
                guard let localFile = item.localFile else {throw ChatAPIError.invalidResponse}
                self.uploadProgress = ChatUploadProgress(id:item.id)
                return try await api.uploadAttachment(channelID:batch.channelID,file:localFile,caption:item.caption,connectionID:connectionID,threadID:batch.rootID ?? 0,encryptionKey:key,onProgress:{ [weak self] sent,total in
                    Task { @MainActor [weak self] in
                        guard let self,self.connectionGeneration == expected,self.attachmentBatch?.id == batch.id else { return }
                        self.uploadProgress?.update(id:item.id,sent:sent,total:total)
                    }
                })
            },received:{ [weak self] post,item in
                guard let self,self.connectionGeneration == expected else { return }
                self.applyCanonical(post)
                if let rootID = batch.rootID {
                    if item.id == batch.originalCaptionItemID,self.threadDrafts[rootID] == batch.originalCaption { self.threadDrafts[rootID] = "" }
                    self.refreshThreadHeader(channelID:batch.channelID,rootID:rootID)
                } else if item.id == batch.originalCaptionItemID,self.drafts[batch.channelID] == batch.originalCaption { self.drafts[batch.channelID] = "" }
            })
            guard let self,self.connectionGeneration == expected,self.attachmentBatch?.id == batch.id,batch.finished else { return }
            self.sending = false;self.uploading = false;self.uploadTask = nil;self.uploadIsEncrypted = false;self.uploadProgress = nil
            self.clearComposerImageFiles();self.attachmentBatch = nil;self.attachmentBatchSession = nil
            if let rootID = batch.rootID,let root = self.threadRoot,root.id == rootID,self.threadViewingContext {
                await self.openThread(root)
            } else if batch.rootID == nil,self.selection == batch.channelID,self.viewingMessageContext {
                self.loadSelection()
            }
        }
    }
    func dismissAttachmentBatch() {
        guard attachmentBatch != nil || uploadTask != nil else { return }
        uploadTask?.cancel();uploadTask = nil;clearComposerImageFiles();attachmentBatch = nil;attachmentBatchSession = nil
        uploadProgress = nil;sending = false;uploading = false;uploadIsEncrypted = false
    }
    func cancelUpload() { uploadTask?.cancel() }

    func thumbnail(for post: ChatPost) async -> NSImage? {
        guard post.file_props?.is_image == true, let api = client, canRead(post.channel_id),
              let channel = channels.first(where: { $0.id == post.channel_id }) else { return nil }
        let key = "\(post.id):\(channel.channel_key_enc ?? "")" as NSString
        if let image = thumbnailCache.object(forKey: key) { return image }
        let expected = connectionGeneration
        let expectedEncryption = encryptionGeneration
        do {
            let bytes: Data
            if channel.encrypted {
                let secret = try encryption.key(for: channel)
                let id = UUID()
                let transfer = Task { try await api.encryptedImageData(postID: post.id, key: secret) }
                encryptedPreviewTasks[id] = transfer
                defer { encryptedPreviewTasks[id] = nil }
                bytes = try await withTaskCancellationHandler(operation: { try await transfer.value },
                                                               onCancel: { transfer.cancel() })
            } else { bytes = try await api.thumbnail(postID: post.id) }
            guard expected == connectionGeneration, expectedEncryption == encryptionGeneration,
                  !Task.isCancelled, canRead(post.channel_id),
                  channels.first(where: { $0.id == post.channel_id })?.channel_key_enc == channel.channel_key_enc,
                  let image = NativeInlineImagePreview.decode(bytes) else { return nil }
            thumbnailCache.setObject(image, forKey: key, cost: NativeInlineImagePreview.memoryCost(image,encodedBytes:bytes.count))
            return image
        } catch { return nil }
    }

    private func cancelLinkPreviewImages() {
        linkPreviewGeneration = UUID()
        #if DEBUG
        debugLinkPreviewEvents = [:];debugLinkPreviewEventOrder = []
        #endif
        for task in linkPreviewTasks.values { task.cancel() }
        linkPreviewTasks = [:]
        thumbnailCache.removeAllObjects()
    }

    private func refreshDisplaySettings() {
        guard let api = client else { return }
        let revision = UUID(); displaySettingsRevision = revision
        hidesLinkPreviews = true; allowsReadStatus = false
        let expected = connectionGeneration
        eventTasks[revision] = Task { [weak self] in
            defer { self?.eventTasks[revision] = nil }
            let settings = try? await api.displaySettings()
            guard let self, !Task.isCancelled, self.connectionGeneration == expected,
                  self.displaySettingsRevision == revision else { return }
            self.hidesLinkPreviews = settings?.hidesPreviews ?? true
            self.allowsReadStatus = settings?.allow_read_status == true
        }
    }

    private func currentLibraryLinkPost(_ entry: ChatLinkLibrary.Entry) -> ChatPost {
        posts.first { $0.id == entry.post.id } ?? replies.first { $0.id == entry.post.id } ?? entry.post
    }
    func canBrowseLibraryLink(_ entry: ChatLinkLibrary.Entry) -> Bool {
        let post = entry.post, current = currentLibraryLinkPost(entry)
        return connected && ChatMessageLinks.webURL(entry.rawURL) == entry.destination && canRead(post.channel_id) && (post.delete_at ?? 0) == 0 && !deletedPostIDs.contains(post.id)
            && channels.first(where: { $0.id == post.channel_id })?.encrypted == false && post.props?.encrypted != true
            && post.url_props?.contains(where: { $0.url == entry.rawURL }) == true
            && current.channel_id == post.channel_id && current.isReply == post.isReply
            && (!post.isReply || current.thread_id == post.thread_id)
            && (current.delete_at ?? 0) == 0 && current.props?.encrypted != true
            && current.url_props?.contains(where: { $0.url == entry.rawURL }) == true
    }
    func libraryLinkIsUnsafe(_ entry: ChatLinkLibrary.Entry) -> Bool {
        entry.post.props?.safe_url == false || currentLibraryLinkPost(entry).props?.safe_url == false
    }
    /// A library snapshot may outlive a message edit. Revalidate the exact
    /// destination/asset before cache hits, transfer publication and rendering.
    func canShowLibraryLinkImage(_ entry: ChatLinkLibrary.Entry) -> Bool {
        guard canBrowseLibraryLink(entry), !libraryLinkIsUnsafe(entry),
              let imageURL = entry.preview.image, ChatMessageLinks.webURL(imageURL) != nil else { return false }
        return entry.post.url_props?.contains(where: { $0.url == entry.rawURL && $0.image == imageURL }) == true
            && currentLibraryLinkPost(entry).url_props?.contains(where: { $0.url == entry.rawURL && $0.image == imageURL }) == true
    }
    func libraryLinkImage(_ entry: ChatLinkLibrary.Entry) async -> NSImage? {
        guard canShowLibraryLinkImage(entry), let api = client, let imageURL = entry.preview.image else { return nil }
        let key = "library-link:\(entry.post.id):\(imageURL)" as NSString
        if let image = thumbnailCache.object(forKey: key) { return image }
        let epoch = connectionGeneration, encryptionEpoch = encryptionGeneration, revision = linkPreviewGeneration
        let id = UUID(); let task = Task { try await api.linkPreviewImageData(postID: entry.post.id, imageURL: imageURL) }
        linkPreviewTasks[id] = task
        defer { linkPreviewTasks[id] = nil }
        do {
            let bytes = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            guard !Task.isCancelled, connectionGeneration == epoch, encryptionGeneration == encryptionEpoch,
                  linkPreviewGeneration == revision, canShowLibraryLinkImage(entry),
                  let image = NativeImagePreview.decode(bytes) else { return nil }
            thumbnailCache.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * 4)); return image
        } catch { return nil }
    }

    func linkPreviews(for post: ChatPost) -> [ChatIndexedLinkPreview] {
        guard connected,canRead(post.channel_id),channels.first(where:{ $0.id == post.channel_id })?.encrypted == false,
              !deletedPostIDs.contains(post.id) else { return [] }
        return ChatLinkPreviewPolicy.cards(in:post,hidden:hidesLinkPreviews)
    }

    func linkPreviewImage(for post: ChatPost, preview: ChatLinkPreview) async -> NSImage? {
        await linkPreviewAsset(for: post, preview: preview, asset: .image)
    }
    func linkPreviewFavicon(for post: ChatPost, preview: ChatLinkPreview) async -> NSImage? {
        await linkPreviewAsset(for: post, preview: preview, asset: .favicon)
    }
    private func canLoadLinkPreviewAsset(for post: ChatPost, preview: ChatLinkPreview, asset: ChatLinkPreviewAsset) -> Bool {
        guard let url = asset.url(in: preview), ChatMessageLinks.webURL(url) != nil,
              linkPreviews(for: post).contains(where: { $0.preview.url == preview.url && asset.url(in: $0.preview) == url }) else { return false }
        // A captured row may outlive an edit, safety update, or hidden card.
        // If a canonical timeline/thread record exists, it must still authorize
        // this exact destination and asset, not merely another visible card.
        if let current = posts.first(where: { $0.id == post.id }) ?? replies.first(where: { $0.id == post.id }) {
            return current.channel_id == post.channel_id && linkPreviews(for: current).contains(where: {
                $0.preview.url == preview.url && asset.url(in: $0.preview) == url
            })
        }
        return true
    }
    private func linkPreviewAsset(for post: ChatPost, preview: ChatLinkPreview, asset: ChatLinkPreviewAsset) async -> NSImage? {
        guard let api = client, let imageURL = asset.url(in: preview), canLoadLinkPreviewAsset(for: post, preview: preview, asset: asset) else {
            #if DEBUG
            debugRecordLinkPreview("not_authorized",postID:post.id,asset:asset)
            #endif
            return nil
        }
        let key = "link:\(asset.rawValue):\(post.id):\(imageURL)" as NSString
        if let image = thumbnailCache.object(forKey: key) {
            #if DEBUG
            debugRecordLinkPreview("cache_hit",postID:post.id,asset:asset)
            #endif
            return image
        }
        let expected = connectionGeneration; let expectedEncryption = encryptionGeneration; let revision = linkPreviewGeneration
        #if DEBUG
        debugRecordLinkPreview("start",postID:post.id,asset:asset,revision:revision)
        #endif
        let id = UUID(); let task = Task { try await api.linkPreviewImageData(postID: post.id, imageURL: imageURL) }
        linkPreviewTasks[id] = task
        defer { linkPreviewTasks[id] = nil }
        do {
            let bytes = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            #if DEBUG
            debugRecordLinkPreview("transport_return",postID:post.id,asset:asset,revision:revision)
            #endif
            guard !Task.isCancelled, connectionGeneration == expected, encryptionGeneration == expectedEncryption,
                  linkPreviewGeneration == revision, canLoadLinkPreviewAsset(for: post, preview: preview, asset: asset),
                  let image = NativeImagePreview.decode(bytes, maximumPixelSize: asset == .favicon ? 32 : 640) else {
                #if DEBUG
                let event:String
                if Task.isCancelled { event = "caller_cancelled" }
                else if connectionGeneration != expected || encryptionGeneration != expectedEncryption || linkPreviewGeneration != revision { event = "stale_scope" }
                else if !canLoadLinkPreviewAsset(for:post,preview:preview,asset:asset) { event = "not_authorized" }
                else { event = "decode_failure" }
                debugRecordLinkPreview(event,postID:post.id,asset:asset,revision:revision)
                #endif
                return nil
            }
            thumbnailCache.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * 4))
            #if DEBUG
            debugRecordLinkPreview("cache_admit",postID:post.id,asset:asset,revision:revision)
            #endif
            return image
        } catch {
            #if DEBUG
            let event = Task.isCancelled ? "caller_cancelled" : (connectionGeneration != expected || encryptionGeneration != expectedEncryption || linkPreviewGeneration != revision) ? "stale_scope" : "transfer_failure"
            debugRecordLinkPreview(event,postID:post.id,asset:asset,revision:revision)
            #endif
            return nil
        }
    }

    func hideLinkPreview(_ post: ChatPost, index: Int) async {
        guard canChangeOwnMessage(post), let api = client,
              linkPreviews(for: post).contains(where: { $0.index == index }) else { return }
        let expected = connectionGeneration
        pendingMessageActions.insert(post.id); error = nil
        defer { if connectionGeneration == expected { pendingMessageActions.remove(post.id) } }
        do {
            try await api.hideLinkPreview(postID: post.id, index: index)
            guard connectionGeneration == expected else { return }
            let readKey = UUID(); canonicalReadKeys[post.id] = readKey
            let updated = try await api.post(channelID: post.channel_id, postID: post.id, threadID: post.thread_id)
            guard connectionGeneration == expected else { return }
            applyCanonical(updated, readKey: readKey)
        } catch {
            guard connectionGeneration == expected else { return }
            self.error = "Could not confirm the preview change. Refresh the message before trying again."
        }
    }

    func documentKind(_ post:ChatPost)->NativeDocumentKind? { post.file_props?.is_snippet == true ? .text : NativeDocumentKind.forFilename(attachmentName(post)) }
    func canPreviewSearchDocument(_ post:ChatPost) -> Bool {
        canReadSearchResult(post) && ["file","vote"].contains(post.type) && post.file_props != nil
            && post.file_props?.is_image != true && documentKind(post) != nil
    }
    private func isSearchDocument(_ post:ChatPost) -> Bool {
        searchDocumentOwner != nil && searchDocumentSource?.postID == post.id && searchDocumentSource?.channelID == post.channel_id
    }
    func openSearchDocument(_ post:ChatPost,owner:UUID,playMedia:Bool = false) {
        guard canPreviewSearchDocument(post) else { return }
        closeDocumentPreview();searchDocumentSource = (post.id,post.channel_id);searchDocumentOwner = owner
        openDocumentPreview(post,playMedia:playMedia)
    }
    func openCollectionDocument(_ post:ChatPost,owner:UUID,playMedia:Bool = false) {
        if canPreviewSearchDocument(post) { openSearchDocument(post,owner:owner,playMedia:playMedia) }
        else if post.channel_id == selection,canPreviewDocument(post) {
            openDocumentPreview(post,playMedia:playMedia)
            if documentPreviewPost?.id == post.id { collectionDocumentOwner = owner }
        }
    }
    @discardableResult func jumpFromSearchDocument()->Bool {
        guard let post = documentPreviewPost,isSearchDocument(post),canPreviewSearchDocument(post) else { return false }
        closeDocumentPreview();navigateToMessage(channelID:post.channel_id,postID:post.id,threadID:post.isReply ? post.thread_id : nil);return true
    }
    func canPreviewDocument(_ post:ChatPost) -> Bool {
        let search = isSearchDocument(post) && canPreviewSearchDocument(post)
        return connected && (post.channel_id == selection || search) && canRead(post.channel_id) && (post.type == "file" || ((canReadPoll(post) || search) && post.file_props?.name != nil))
            && post.file_props?.is_image != true && (post.delete_at ?? 0) == 0 && !deletedPostIDs.contains(post.id)
            && documentKind(post) != nil
            && (documentKind(post) != .quickLook || channels.first(where: { $0.id == post.channel_id })?.encrypted == false)
    }
    func openDocumentPreview(_ post:ChatPost,playMedia:Bool = false,inlineAudio:Bool = false) {
        guard canPreviewDocument(post),let kind = documentKind(post),let api = client,
              let channel = channels.first(where:{ $0.id == post.channel_id }) else { return }
        collectionDocumentOwner = nil
        if !isSearchDocument(post) { searchDocumentOwner = nil;searchDocumentSource = nil }
        closeImageViewer();documentPreviewTask?.cancel();documentPreviewContent?.dispose()
        let request = UUID();documentPreviewRequestID = request
        inlineAudioOwnerID = nil
        documentPreviewInlineAudio = inlineAudio && kind == .audio
        documentPreviewPost = post;documentPreviewContent = nil;documentPreviewError = nil;documentPreviewLoading = true
        if !documentPreviewInlineAudio {
            updateReadingVisibility(active:false,atBottom:false);updateThreadReadingVisibility(active:false,atBottom:false)
        }
        let expected = connectionGeneration,expectedEncryption = encryptionGeneration
        documentPreviewTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.documentPreviewRequestID == request { self.documentPreviewLoading = false;self.documentPreviewTask = nil } }
            do {
                guard (post.file_props?.size ?? 0) <= Int64(kind.limit + (channel.encrypted ? 40 : 0)) else {
                    throw ChatTransferError(message:"This attachment is too large to preview. Save the original to open it.")
                }
                if kind.isMedia, !channel.encrypted, let byteCount = post.file_props?.size, byteCount > 0 {
                    do {
                        let playback = try await NativeMediaPlayback.stream(kind: kind, filename: self.attachmentName(post), byteCount: byteCount) { [weak self] range in
                            guard let self, !Task.isCancelled, self.documentPreviewRequestID == request,
                                  self.connectionGeneration == expected, self.encryptionGeneration == expectedEncryption,
                                  self.canPreviewDocument(post), self.channels.first(where: { $0.id == post.channel_id })?.encrypted == false else { throw CancellationError() }
                            let bytes = try await api.mediaRangeData(postID: post.id, range: range)
                            guard !Task.isCancelled, self.documentPreviewRequestID == request,
                                  self.connectionGeneration == expected, self.encryptionGeneration == expectedEncryption,
                                  self.canPreviewDocument(post), self.channels.first(where: { $0.id == post.channel_id })?.encrypted == false else { throw CancellationError() }
                            return bytes
                        }
                        guard !Task.isCancelled, self.documentPreviewRequestID == request,
                              self.connectionGeneration == expected, self.encryptionGeneration == expectedEncryption,
                              self.canPreviewDocument(post) else { playback.dispose(); return }
                        self.documentPreviewContent = .media(playback)
                        if playMedia { playback.togglePlayback() }
                        return
                    } catch ChatMediaRangeReadError.unsupported {
                        // Unsupported local types or a real attachment200 retain the bounded local-file path.
                        try Task.checkCancellation()
                    }
                }
                let key = channel.encrypted ? try self.encryption.key(for:channel) : nil
                let bytes = try await api.documentPreviewData(postID:post.id,maximumBytes:kind.limit,decryptionKey:key)
                try Task.checkCancellation()
                guard self.documentPreviewRequestID == request,self.connectionGeneration == expected,self.encryptionGeneration == expectedEncryption,
                      self.canPreviewDocument(post),self.channels.first(where:{ $0.id == post.channel_id })?.channel_key_enc == channel.channel_key_enc else { return }
                let content = try await NativeDocumentContent.load(bytes,kind:kind,filename:self.attachmentName(post))
                guard !Task.isCancelled,self.documentPreviewRequestID == request,self.connectionGeneration == expected,self.encryptionGeneration == expectedEncryption,
                      self.canPreviewDocument(post),self.channels.first(where:{ $0.id == post.channel_id })?.channel_key_enc == channel.channel_key_enc else { content.dispose();return }
                self.documentPreviewContent = content
                if playMedia,case .media(let media) = content { media.togglePlayback() }
            } catch {
                guard !Task.isCancelled,self.documentPreviewRequestID == request,self.connectionGeneration == expected,self.encryptionGeneration == expectedEncryption else { return }
                self.documentPreviewError = (error as? ChatTransferError)?.errorDescription ?? "Could not load this attachment. Try again, or save the original."
            }
        }
    }
    func ownsInlineAudio(postID: Int64, ownerID: UUID) -> Bool {
        inlineAudioPostID == postID && inlineAudioOwnerID == ownerID
    }
    func openInlineAudio(_ post: ChatPost, ownerID: UUID? = nil) {
        guard documentKind(post) == .audio, canPreviewDocument(post) else { return }
        if inlineAudioPostID == post.id {
            inlineAudioOwnerID = ownerID
            if documentPreviewError != nil { retryDocumentPreview() }
            else if case .media(let playback) = documentPreviewContent {
                if playback.failure != nil { retryDocumentPreview() }
                else if playback.player.rate == 0 { playback.togglePlayback() }
            }
            return
        }
        openDocumentPreview(post, playMedia: true, inlineAudio: true)
        inlineAudioOwnerID = ownerID
    }
    func closeInlineAudio(postID: Int64, ownerID: UUID) {
        if ownsInlineAudio(postID: postID, ownerID: ownerID) { closeDocumentPreview() }
    }
    func expandInlineAudio() {
        guard documentPreviewInlineAudio, documentPreviewPost != nil else { return }
        documentPreviewInlineAudio = false; inlineAudioOwnerID = nil
        updateReadingVisibility(active: false, atBottom: false)
        updateThreadReadingVisibility(active: false, atBottom: false)
    }
    func retryDocumentPreview() {
        if let post = documentPreviewPost {
            let owner = inlineAudioOwnerID, inline = documentPreviewInlineAudio,collectionOwner = collectionDocumentOwner
            openDocumentPreview(post, playMedia: true, inlineAudio: inline)
            if inline { inlineAudioOwnerID = owner }
            if documentPreviewPost?.id == post.id { collectionDocumentOwner = collectionOwner }
        }
    }
    func closeDocumentPreview() {
        collectionDocumentOwner = nil
        searchDocumentOwner = nil;searchDocumentSource = nil
        documentPreviewRequestID = nil;documentPreviewTask?.cancel();documentPreviewTask = nil
        documentPreviewContent?.dispose();documentPreviewPost = nil;documentPreviewContent = nil;documentPreviewLoading = false;documentPreviewError = nil;documentPreviewInlineAudio = false;inlineAudioOwnerID = nil
    }

    var imageViewerPosition: Int? { imageViewerPost.flatMap { post in imageViewerPosts.firstIndex(where: { $0.id == post.id }).map { $0 + 1 } } }
    var imageViewerCount: Int { imageViewerPosts.count }
    func imageGalleryContainsSource(postID:Int64,channelID:Int64)->Bool { imageViewerPosts.contains { $0.id == postID && $0.channel_id == channelID } }
    var canViewPreviousImage: Bool { (imageViewerPosition ?? 1) > 1 || imageHistoryHasOlder }
    var canViewNextImage: Bool { (imageViewerPosition ?? 0) < imageViewerPosts.count || imageHistoryHasNewer || imageLibraryHasMore }

    func openPollImage(_ post:ChatPost) {
        guard canReadPoll(post),post.file_props?.is_image == true,post.file_props?.name != nil else { return }
        closeDocumentPreview();closeImageViewer();imageViewerPosts = [post];loadViewerImage(post)
    }
    func releasePollAttachmentPresentation(_ owner:UUID) {
        guard pollAttachmentOwner == owner else { return }
        closeDocumentPreview();closeImageViewer();pollAttachmentOwner = nil
    }
    func openImage(_ post: ChatPost) {
        guard post.channel_id == selection, canRead(post.channel_id), post.file_props?.is_image == true,
              post.type == "file", (post.delete_at ?? 0) == 0, !deletedPostIDs.contains(post.id) else { return }
        closeDocumentPreview()
        // Navigate only the current presentation; do not silently mix thread and main histories.
        let visible = threadRoot.map { $0.id == post.id ? [$0] : replies } ?? posts
        guard visible.contains(where: { $0.id == post.id }) else { return }
        closeImageViewer()
        imageViewerPosts = ChatTimeline.merge([], visible.filter {
            $0.channel_id == post.channel_id && $0.type == "file" && $0.file_props?.is_image == true
                && ($0.delete_at ?? 0) == 0 && !deletedPostIDs.contains($0.id)
        })
        loadViewerImage(post)
        // The official client isolates thread replies and disables navigation
        // when the displayed image is itself the thread root.
        if threadRoot?.id != post.id {
            imageHistoryChannelID = post.channel_id;imageHistoryThreadID = threadRoot?.id
            loadImageHistory(.around)
        }
    }

    /// Explicit search-result context; never mix results into the loaded timeline gallery.
    func canReadSearchResult(_ post:ChatPost) -> Bool {
        connected && post.id > 0 && (post.delete_at ?? 0) == 0 && !deletedPostIDs.contains(post.id)
            && canRead(post.channel_id) && channels.first(where:{ $0.id == post.channel_id })?.supportsSearchSuggestion == true
    }
    func canReadSearchImage(_ post:ChatPost) -> Bool {
        canReadSearchResult(post) && ["file","vote"].contains(post.type) && post.file_props?.is_image == true
    }
    func openSearchImage(_ post:ChatPost,context:[ChatPost],owner:UUID,hasMore:Bool = false,loadMore:(() async throws -> ChatLibraryImagePage)? = nil) {
        guard context.filter({ $0.id == post.id }).count == 1,let source = context.first(where:{ $0.id == post.id && $0.channel_id == post.channel_id }),canReadSearchImage(source) else { return }
        var seen = Set<Int64>()
        let images = context.filter { canReadSearchImage($0) && seen.insert($0.id).inserted }
        closeDocumentPreview();closeImageViewer();searchImageOwner = owner;imageViewerPosts = images
        imageLibraryLoader = loadMore;imageLibraryHasMore = hasMore && loadMore != nil;loadViewerImage(source)
    }
    func openLibraryImage(_ post: ChatPost, context: [ChatPost], hasMore: Bool = false, loadMore: (() async throws -> ChatLibraryImagePage)? = nil) {
        guard post.channel_id == selection, canBrowseConversationContent(post.channel_id),
              threadRoot == nil, context.contains(where: { $0.id == post.id && $0.channel_id == post.channel_id }) else { return }
        let images = context.filter {
            $0.channel_id == post.channel_id && $0.type == "file" && $0.file_props?.is_image == true
                && ($0.delete_at ?? 0) == 0 && !deletedPostIDs.contains($0.id)
        }
        guard let canonical = images.first(where: { $0.id == post.id }) else { return }
        closeDocumentPreview()
        closeImageViewer()
        imageViewerPosts = images
        imageLibraryLoader = loadMore;imageLibraryHasMore = hasMore && loadMore != nil
        loadViewerImage(canonical)
    }

    func moveViewerImage(by offset: Int) {
        guard abs(offset) == 1, !imageHistoryLoading, let position = imageViewerPosition else { return }
        let index = position - 1 + offset
        guard imageViewerPosts.indices.contains(index) else {
            if offset > 0 && imageLibraryHasMore { loadMoreLibraryImages();return }
            if offset < 0 && imageHistoryHasOlder { loadImageHistory(.older,move:offset) }
            if offset > 0 && imageHistoryHasNewer { loadImageHistory(.newer,move:offset) }
            return
        }
        loadViewerImage(imageViewerPosts[index])
    }

    func retryImageHistory() {
        if imageLibraryLoader != nil { loadMoreLibraryImages() }
        else { loadImageHistory(imageHistoryRetryDirection) }
    }

    private func loadMoreLibraryImages() {
        guard let loader = imageLibraryLoader,let current = imageViewerPost,(searchImageOwner != nil || current.channel_id == selection),canRead(current.channel_id) else { return }
        let key = UUID(),epoch = connectionGeneration,envelope = channels.first(where:{ $0.id == current.channel_id })?.channel_key_enc
        let owner = searchImageOwner,originSelection = selection
        imageHistoryTask?.cancel();imageHistoryRequestID = key;imageHistoryLoading = true;imageHistoryError = nil
        imageHistoryTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.imageHistoryRequestID == key { self.imageHistoryLoading = false;self.imageHistoryTask = nil } }
            do {
                var previousCursor: Int?
                while true {
                    let page = try await loader()
                    guard !Task.isCancelled,self.connectionGeneration == epoch,self.imageHistoryRequestID == key,
                          self.selection == originSelection,self.searchImageOwner == owner,self.imageViewerPost?.id == current.id,
                          self.channels.first(where:{ $0.id == current.channel_id })?.channel_key_enc == envelope,self.canRead(current.channel_id) else { return }
                    if page.hasMore,let previousCursor,page.cursor <= previousCursor { throw ChatAPIError.invalidResponse }
                    previousCursor = page.cursor
                    var seen = Set<Int64>()
                    self.imageViewerPosts = page.posts.filter {
                        (owner != nil ? self.canReadSearchImage($0) : $0.channel_id == current.channel_id && $0.type == "file") && $0.file_props?.is_image == true
                            && ($0.delete_at ?? 0) == 0 && !self.deletedPostIDs.contains($0.id) && seen.insert($0.id).inserted
                    }
                    self.imageLibraryHasMore = page.hasMore
                    guard let index = self.imageViewerPosts.firstIndex(where:{$0.id == current.id}) else { self.closeImageViewer();return }
                    if self.imageViewerPosts.indices.contains(index + 1) { self.loadViewerImage(self.imageViewerPosts[index + 1]);return }
                    if !page.hasMore { return }
                    // Mixed file pages may contain no image. Advance raw source
                    // pages until an image or exhaustion, with cancellation and
                    // cursor progress checks on every response.
                }
            } catch {
                guard !Task.isCancelled,self.connectionGeneration == epoch,self.imageHistoryRequestID == key else { return }
                self.imageHistoryError = "More images could not be loaded. Your current image is still available."
            }
        }
    }

    private func loadImageHistory(_ direction: ChatImageHistoryDirection, move: Int = 0) {
        guard let api = client, let channelID = imageHistoryChannelID, channelID == selection,
              canRead(channelID), let current = imageViewerPost else { return }
        let anchor = direction == .older ? imageViewerPosts.first : direction == .newer ? imageViewerPosts.last : current
        guard let anchor else { return }
        let threadID = imageHistoryThreadID, epoch = connectionGeneration, envelope = channels.first { $0.id == channelID }?.channel_key_enc
        let key = UUID();imageHistoryTask?.cancel();imageHistoryRequestID = key
        imageHistoryLoading = true;imageHistoryError = nil;imageHistoryRetryDirection = direction
        imageHistoryTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.imageHistoryRequestID == key { self.imageHistoryLoading = false;self.imageHistoryTask = nil } }
            do {
                let page = try await api.imageHistory(channelID:channelID,anchorID:anchor.id,threadID:threadID,direction:direction)
                guard !Task.isCancelled,self.connectionGeneration == epoch,self.imageHistoryRequestID == key,
                      self.selection == channelID,self.imageHistoryChannelID == channelID,self.imageHistoryThreadID == threadID,
                      self.channels.first(where:{$0.id == channelID})?.channel_key_enc == envelope,self.canRead(channelID) else { return }
                let values = page.posts.filter { !self.deletedPostIDs.contains($0.id) }
                if direction == .around {
                    self.imageViewerPosts = values
                    if let displayed = self.imageViewerPost,!values.contains(where:{$0.id == displayed.id}) { self.imageViewerPosts = ChatTimeline.merge(values,[displayed]) }
                } else { self.imageViewerPosts = ChatTimeline.merge(self.imageViewerPosts,values) }
                if direction != .newer { self.imageHistoryHasOlder = page.hasOlder }
                if direction != .older { self.imageHistoryHasNewer = page.hasNewer }
                if move != 0,self.imageViewerPost?.id == current.id,let position = self.imageViewerPosition {
                    let index = position - 1 + move
                    if self.imageViewerPosts.indices.contains(index) { self.loadViewerImage(self.imageViewerPosts[index]) }
                }
            } catch {
                guard !Task.isCancelled,self.connectionGeneration == epoch,self.imageHistoryRequestID == key else { return }
                self.imageHistoryError = "More images could not be loaded. Your current image is still available."
            }
        }
    }

    func retryViewerImage() { if let post = imageViewerPost { loadViewerImage(post,original:imageViewerOriginal) } }
    func viewOriginalImage() {if let post = imageViewerPost,!imageViewerLoading {loadViewerImage(post,original:true)}}

    @discardableResult func jumpFromImageViewer() -> Bool {
        guard let post = imageViewerPost,(post.channel_id == selection || searchImageOwner != nil),canRead(post.channel_id),(post.delete_at ?? 0) == 0,!deletedPostIDs.contains(post.id) else {return false}
        closeImageViewer()
        navigateToMessage(channelID:post.channel_id,postID:post.id,threadID:post.isReply ? post.thread_id : nil)
        return true
    }

    func closeImageViewer() {
        searchImageOwner = nil
        imageLibraryLoader = nil;imageLibraryHasMore = false
        imageHistoryRequestID = nil;imageHistoryTask?.cancel();imageHistoryTask = nil
        imageHistoryChannelID = nil;imageHistoryThreadID = nil;imageHistoryHasOlder = false;imageHistoryHasNewer = false
        imageHistoryLoading = false;imageHistoryError = nil
        imageViewerRequestID = nil
        imageViewerTask?.cancel(); imageViewerTask = nil
        imageViewerPost = nil; imageViewerImage = nil;imageViewerFrameCount = 1;imageViewerOriginal = false
        imageViewerPosts = []; imageViewerLoading = false; imageViewerError = nil
    }

    private func loadViewerImage(_ post: ChatPost,original:Bool = false) {
        guard let api = client, canRead(post.channel_id),
              let channel = channels.first(where: { $0.id == post.channel_id }) else { closeImageViewer(); return }
        imageViewerTask?.cancel()
        let requestID = UUID()
        imageViewerRequestID = requestID
        let originalRequested = original || (post.file_props?.name as NSString?)?.pathExtension.lowercased() == "gif"
        imageViewerPost = post; imageViewerImage = nil; imageViewerError = nil; imageViewerLoading = true;imageViewerFrameCount = 1;imageViewerOriginal = originalRequested
        updateReadingVisibility(active: false, atBottom: false)
        updateThreadReadingVisibility(active: false, atBottom: false)
        let expected = connectionGeneration
        let expectedEncryption = encryptionGeneration
        imageViewerTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.imageViewerRequestID == requestID { self.imageViewerLoading = false; self.imageViewerTask = nil }
            }
            do {
                let data: Data
                if originalRequested,(post.file_props?.size ?? 0) > 32*1024*1024+40 {throw ChatAPIError.invalidResponse}
                if channel.encrypted {
                    data = try await api.encryptedImageData(postID: post.id, key: self.encryption.key(for: channel))
                } else if originalRequested {
                    data = try await api.documentPreviewData(postID:post.id,maximumBytes:32*1024*1024)
                } else { data = try await api.thumbnail(postID: post.id, size: .large) }
                try Task.checkCancellation()
                guard self.imageViewerRequestID == requestID, self.connectionGeneration == expected,
                      self.encryptionGeneration == expectedEncryption, self.canRead(post.channel_id),
                      self.channels.first(where: { $0.id == post.channel_id })?.channel_key_enc == channel.channel_key_enc else { return }
                guard let decoded = NativeViewerImage.decode(data,original:originalRequested) else {throw ChatAPIError.invalidResponse}
                self.imageViewerImage = decoded.image;self.imageViewerFrameCount = decoded.frameCount
            } catch {
                guard !Task.isCancelled, self.imageViewerRequestID == requestID,
                      self.connectionGeneration == expected, self.encryptionGeneration == expectedEncryption else { return }
                self.imageViewerError = "Could not display this image within the preview limits. Try again, or save the original file to open it."
            }
        }
    }

    private func updateDownload(_ id: UUID, epoch: Int, _ update: (ChatDownloadRecord) -> Void) {
        guard epoch == connectionGeneration, let index = downloadHistory.firstIndex(where: { $0.id == id }) else { return }
        let record = downloadHistory[index], state = record.state
        update(record); if record.state != state { downloadStateRevision += 1 }
    }
    private func reserveDownload(post: ChatPost, filename: String, encrypted: Bool, source: DownloadSource) -> UUID? {
        guard !downloading.contains(post.id), !downloadHistory.contains(where: { $0.state == .choosing }) else { return nil }
        let id = UUID(); downloading.insert(post.id); activeDownloadIDs[post.id] = id; downloadSources[id] = source
        downloadHistory.insert(.init(id: id, postID: post.id, channelID: post.channel_id, filename: filename, encrypted: encrypted, startedAt: Date()), at: 0)
        return id
    }
    private func releaseDownload(postID: Int64, id: UUID, epoch: Int) {
        guard epoch == connectionGeneration, activeDownloadIDs[postID] == id else { return }
        downloading.remove(postID); activeDownloadIDs.removeValue(forKey: postID); downloadTasks.removeValue(forKey: postID); downloadPanels.removeValue(forKey: postID)
    }
    private func savedDownload(_ id: UUID, epoch: Int, destination: URL) {
        updateDownload(id, epoch: epoch) { record in record.state = .saved; record.destination = destination; record.fileBytes = ((try? FileManager.default.attributesOfItem(atPath: destination.path)[.size]) as? NSNumber)?.int64Value; record.available = true; record.failure = nil }
    }
    private func downloadProgress(_ id: UUID, epoch: Int) -> ChatDownloadProgressRelay {
        ChatDownloadProgressRelay { [weak self] received, expected in
            Task { @MainActor in self?.updateDownload(id, epoch: epoch) { $0.progress(received: received, expected: expected) } }
        }
    }
    private func finishDownloadFailure(_ error: Error, id: UUID, epoch: Int) {
        let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
        let message = (error as? ChatTransferError)?.errorDescription ?? (error as? ChatCryptoError)?.errorDescription ?? (error as? ChatAPIError)?.errorDescription ?? "Could not save this attachment. Check the connection or choose another location."
        updateDownload(id, epoch: epoch) { record in if record.state.active { record.state = cancelled ? .cancelled : .failed; record.failure = cancelled ? nil : message } }
        if !cancelled, epoch == connectionGeneration { self.error = message }
    }
    func cancelDownload(postID: Int64) {
        if let id = activeDownloadIDs[postID] {
            guard downloadHistory.first(where: { $0.id == id })?.state.active == true else { return }
            updateDownload(id, epoch: connectionGeneration) { $0.state = .cancelled }
        }
        downloadTasks[postID]?.task.cancel(); downloadPanels[postID]?.cancel(nil)
    }
    private func chooseDownloadDestination(filename: String, postID: Int64) async -> URL? {
        let panel = NSSavePanel(); panel.title = "Save attachment"; panel.nameFieldStringValue = filename; panel.directoryURL = downloadPreferences.initialFolder
        downloadPanels[postID] = panel
        let accepted = await withCheckedContinuation { continuation in panel.begin { continuation.resume(returning: $0 == .OK) } }
        downloadPanels.removeValue(forKey: postID)
        return accepted ? panel.url : nil
    }
    func saveAttachment(_ post: ChatPost, chooseDestination: ((String) async -> URL?)? = nil,
                        openAfterSaving: ((URL) -> Bool)? = nil,
                        confirmOpening: ((ChatSavedFileOpening.Review) async -> ChatSavedFileOpening.Decision)? = nil,
                        revealer: ((URL) -> Void)? = nil) async {
        guard let api = client, canRead(post.channel_id), let channel = channels.first(where: { $0.id == post.channel_id }) else { return }
        let epoch = connectionGeneration, keyEpoch = encryptionGeneration
        let filename = ChatMultipartBody.safeFilename(attachmentName(post))
        guard let id = reserveDownload(post: post, filename: filename, encrypted: channel.encrypted, source: .current(post)) else { return }
        defer { releaseDownload(postID: post.id, id: id, epoch: epoch) }
        let destination: URL?
        if let chooseDestination { destination = await chooseDestination(filename) }
        else { destination = await chooseDownloadDestination(filename: filename, postID: post.id) }
        guard let destination, ChatSavedDownloadFile.validDestination(destination), !Task.isCancelled, epoch == connectionGeneration, client === api,
              downloadHistory.first(where: { $0.id == id })?.state == .choosing,
              !channel.encrypted || encryptionGeneration == keyEpoch, canRead(post.channel_id),
              let current = channels.first(where: { $0.id == post.channel_id }), current.encrypted == channel.encrypted, current.channel_key_enc == channel.channel_key_enc else {
            updateDownload(id, epoch: epoch) { if $0.state.active { $0.state = .cancelled } }; return
        }
        downloadPreferences.remember(destination: destination)
        let key: Data?
        do { key = current.encrypted ? try encryption.key(for: current) : nil }
        catch { finishDownloadFailure(error, id: id, epoch: epoch); return }
        updateDownload(id, epoch: epoch) { $0.state = .transferring; $0.destination = destination; $0.filename = ChatMultipartBody.safeFilename(destination.lastPathComponent) }
        let progress = downloadProgress(id, epoch: epoch)
        let transfer = Task {
            try await api.saveAttachment(postID: post.id, to: destination, decryptionKey: key, onProgress: { progress.update(received: $0, expected: $1) }, authorizeCommit: { commit in
                try Task.checkCancellation()
                guard self.connectionGeneration == epoch, self.client === api, self.canRead(post.channel_id),
                      !channel.encrypted || self.encryptionGeneration == keyEpoch,
                      let fresh = self.channels.first(where: { $0.id == post.channel_id }), fresh.encrypted == channel.encrypted, fresh.channel_key_enc == channel.channel_key_enc,
                      self.downloadHistory.first(where: { $0.id == id })?.state.active == true else { throw CancellationError() }
                self.updateDownload(id, epoch: epoch) { let bytes = progress.snapshot(); $0.progress(received: bytes.received, expected: bytes.expected); $0.state = .verifying }
                try commit() // No suspension between the final scope check and atomic commit.
                self.savedDownload(id, epoch: epoch, destination: destination)
            })
        }
        downloadTasks[post.id] = (key != nil, transfer)
        do {
            try await withTaskCancellationHandler { try await transfer.value } onCancel: { transfer.cancel() }
            guard !Task.isCancelled, epoch == connectionGeneration, client === api, canRead(post.channel_id),
                  !channel.encrypted || encryptionGeneration == keyEpoch,
                  channels.first(where: { $0.id == post.channel_id })?.channel_key_enc == channel.channel_key_enc else { return }
            if let openAfterSaving {
                // Saving is finished before a user reviews opening the result.
                releaseDownload(postID: post.id, id: id, epoch: epoch)
                await openDownload(id, opener: openAfterSaving, confirmOpening: confirmOpening, revealer: revealer)
            }
        } catch { finishDownloadFailure(error, id: id, epoch: epoch) }
    }
    private func canReadDownload(_ record:ChatDownloadRecord) -> Bool {
        guard record.encrypted else { return true }
        if case .archive(_,_,let archive,_) = downloadSources[record.id] { return canReadArchive(archive) }
        return canRead(record.channelID)
    }
    private func downloadEnvelope(_ record:ChatDownloadRecord) -> String? {
        if case .archive(_,_,let archive,_) = downloadSources[record.id] { return archive.props.channel.channel_key_enc }
        return channels.first(where:{$0.id == record.channelID})?.channel_key_enc
    }
    func downloadIsLocked(_ record: ChatDownloadRecord) -> Bool { record.encrypted && !canReadDownload(record) }
    func downloadName(_ record: ChatDownloadRecord) -> String { downloadIsLocked(record) ? "Encrypted attachment" : record.filename }
    func canUseSavedDownload(_ record: ChatDownloadRecord) -> Bool { record.state == .saved && record.available && canReadDownload(record) }
    func refreshDownloadFiles() async {
        guard !checkingDownloadFiles else { return }; checkingDownloadFiles = true; let epoch = connectionGeneration
        defer { if epoch == connectionGeneration { checkingDownloadFiles = false } }
        let files = downloadHistory.filter { $0.state == .saved }.compactMap { record in record.destination.map { (record.id, $0) } }
        let results = await Task.detached { files.map { ($0.0, ChatSavedDownloadFile.available($0.1)) } }.value
        guard epoch == connectionGeneration, !Task.isCancelled else { return }
        for (id, exists) in results { updateDownload(id, epoch: epoch) { if $0.state == .saved { $0.available = exists } } }
    }
    private func cancelPendingSavedFileOpen() {
        savedFileOpening.retire(); savedFileOpenPrompt.cancel(); savedFileOpenContext = nil
    }
    func openSavedAttachment(at url: URL, postID: Int64, expectedAccount: Int,
                             opener: ((URL) -> Bool)? = nil,
                             confirmOpening: ((ChatSavedFileOpening.Review) async -> ChatSavedFileOpening.Decision)? = nil,
                             revealer: ((URL) -> Void)? = nil) async {
        guard expectedAccount == connectionGeneration,
              let record = downloadHistory.first(where: { $0.postID == postID && $0.state == .saved && $0.destination?.standardizedFileURL == url.standardizedFileURL }) else { return }
        await openDownload(record.id, opener: opener, confirmOpening: confirmOpening, revealer: revealer)
    }
    func openDownload(_ id: UUID, reveal: Bool = false, opener: ((URL) -> Bool)? = nil,
                      confirmOpening: ((ChatSavedFileOpening.Review) async -> ChatSavedFileOpening.Decision)? = nil,
                      revealer: ((URL) -> Void)? = nil) async {
        guard let record = downloadHistory.first(where: { $0.id == id }), record.state == .saved,
              canReadDownload(record), let url = record.destination,
              reveal || (savedFileOpenContext == nil && !savedFileOpening.busy) else { return }
        let epoch = connectionGeneration, keyEpoch = encryptionGeneration
        let envelope = downloadEnvelope(record)
        let intent: UUID?
        if reveal { intent = nil }
        else {
            let next = UUID(); intent = next
            savedFileOpenContext = .init(id: next, channelID: record.channelID, encrypted: record.encrypted, keyEnvelope: envelope)
        }
        defer { if let intent, savedFileOpenContext?.id == intent { savedFileOpenContext = nil } }
        func checkCurrent() throws {
            try Task.checkCancellation()
            guard epoch == connectionGeneration, keyEpoch == encryptionGeneration,
                  intent == nil || savedFileOpenContext?.id == intent,
                  downloadHistory.first(where: { $0.id == id }) === record,
                  record.state == .saved, record.destination?.standardizedFileURL == url.standardizedFileURL,
                  canReadDownload(record) && downloadEnvelope(record) == envelope else { throw CancellationError() }
        }
        let available = await Task.detached { ChatSavedDownloadFile.available(url) }.value
        do { try checkCurrent() } catch { return }
        updateDownload(id, epoch: epoch) { $0.available = available }
        guard available else { return }
        let revealFile: (URL) -> Void = revealer ?? { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
        do {
            let result: ChatSavedFileOpening.Result
            if reveal {
                result = try await savedFileOpening.reveal(url: url, checkCurrent: checkCurrent, reveal: revealFile)
            } else {
                result = try await savedFileOpening.request(url: url, checkCurrent: checkCurrent,
                    confirm: confirmOpening ?? { [self] in await savedFileOpenPrompt.confirm($0) },
                    open: opener ?? { NSWorkspace.shared.open($0) }, reveal: revealFile)
            }
            if result == .opened { updateDownload(id, epoch: epoch) { $0.failure = nil } }
        } catch is CancellationError { }
        catch {
            guard (try? checkCurrent()) != nil else { return }
            updateDownload(id, epoch: epoch) {
                if error as? ChatSavedFileOpeningError == .unavailable { $0.available = false }
                $0.failure = error.localizedDescription
            }
        }
    }
    func canRetryDownload(_ record: ChatDownloadRecord) -> Bool {
        guard !record.state.active, !downloading.contains(record.postID), downloadSources[record.id] != nil else { return false }
        switch downloadSources[record.id] {
        case .current: return canRead(record.channelID)
        case .archive(_,_,let archive,_): return canReadArchive(archive)
        case nil: return false
        }
    }
    func retryDownload(_ id: UUID, chooseDestination: ((String) async -> URL?)? = nil) async {
        guard let record = downloadHistory.first(where: { $0.id == id }), canRetryDownload(record), let source = downloadSources[id] else { return }
        let epoch = connectionGeneration
        switch source {
        case .current(let post): await saveAttachment(post, chooseDestination: chooseDestination)
        case .archive(let kind, let name, let archive, let post):
            let keyEpoch = encryptionGeneration
            guard let api = client, let next = reserveDownload(post: post, filename: record.filename, encrypted: archive.props.channel.encrypted, source: source) else { return }
            defer { releaseDownload(postID: post.id, id: next, epoch: epoch) }
            let destination: URL?
            if let chooseDestination { destination = await chooseDestination(record.filename) }
            else { destination = await chooseDownloadDestination(filename: record.filename, postID: post.id) }
            guard let destination, ChatSavedDownloadFile.validDestination(destination), !Task.isCancelled, epoch == connectionGeneration,
                  !archive.props.channel.encrypted || keyEpoch == encryptionGeneration,canReadArchive(archive),
                  downloadHistory.first(where: { $0.id == next })?.state == .choosing else { updateDownload(next, epoch: epoch) { if $0.state.active { $0.state = .cancelled } }; return }
            do { try await transferArchivedAttachment(kind: kind, name: name, archive: archive, post: post, to: destination, expected: epoch, id: next, api: api) }
            catch { finishDownloadFailure(error, id: next, epoch: epoch) }
        }
    }
    func clearDownloadHistory(cancelActive: Bool = false) {
        cancelPendingSavedFileOpen()
        if cancelActive { for post in Array(downloading) { cancelDownload(postID: post) } }
        let removed = downloadHistory.filter { !$0.state.active }.map(\.id)
        downloadHistory.removeAll { removed.contains($0.id) }; for id in removed { downloadSources.removeValue(forKey: id) }
    }

    func stickerName(_ post: ChatPost) -> String? {
        guard canRead(post.channel_id) else { return nil }
        let text = messageText(post).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix(":"), text.hasSuffix(":"), text.count > 2 else { return nil }
        let name = String(text.dropFirst().dropLast())
        return ChatSticker.validName(name) ? name : nil
    }

    func sendSticker(_ name: String, inThread: Bool = false) async {
        guard !preparingComposerAttachment,attachmentBatch == nil,canInteract, !sending, !isEditingMessage, stickers.contains(name), let channel = selectedChannel,
              canRead(channel.id), let api = client, let connectionID = live?.connectionID else { return }
        guard !inThread || canComposeInThread else { return }
        let threadID = inThread ? (threadRoot?.id ?? 0) : 0
        let expected = connectionGeneration
        sending = true; error = nil; needsDeliveryCheck = false
        defer { if expected == connectionGeneration { sending = false } }
        do {
            let wire = try wireMessage(":" + name + ":", channelID: channel.id)
            let post = try await api.sendSticker(channelID: channel.id, name: name, wireText: wire, connectionID: connectionID, threadID: threadID)
            guard expected == connectionGeneration else { return }
            if selection == channel.id { if viewingMessageContext && !inThread { loadSelection() } else { applyCanonical(post) } }
            if threadID > 0 { refreshThreadHeader(channelID: channel.id, rootID: threadID) }
        } catch {
            guard expected == connectionGeneration else { return }
            needsDeliveryCheck = true
            self.error = "Sticker delivery could not be confirmed. Check recent messages before sending it again."
        }
    }

    func send() async {
        guard canSend else { return }
        if ChatSlashSyntax.name(draft) != nil {
            do { try await prepareSlashCommands(inThread: false, fromComposer: true) }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
            return
        }
        guard canSend, let channel = selectedChannel, let api = client,
              let connectionID = live?.connectionID else { return }
        let text = draft
        let expectedConnection = connectionGeneration
        sending = true
        needsDeliveryCheck = false
        error = nil
        defer { if connectionGeneration == expectedConnection { sending = false } }
        do {
            let wireText = try wireMessage(text, channelID: channel.id)
            let post = try await api.sendText(channelID: channel.id, text: wireText, connectionID: connectionID)
            guard connectionGeneration == expectedConnection else { return }
            if selection == channel.id {
                if viewingMessageContext { loadSelection() }
                else { applyCanonical(post) }
            }
            if drafts[channel.id] == text { drafts[channel.id] = "" }
        } catch let error as ChatCryptoError {
            guard connectionGeneration == expectedConnection else { return }
            needsDeliveryCheck = false
            self.error = error.errorDescription
        } catch ChatAPIError.server(411) {
            guard connectionGeneration == expectedConnection else { return }
            needsDeliveryCheck = false
            self.error = "Messages are being sent too quickly. Wait a moment; your draft is kept."
        } catch {
            guard connectionGeneration == expectedConnection else { return }
            // There is no discovered server idempotency key: never silently retry a create request.
            needsDeliveryCheck = true
            self.error = "Delivery could not be confirmed. Your draft is kept. Check recent messages before sending it again."
        }
    }

}


/// Socket events and send responses may refer to the same post, or arrive out of order.
enum ChatTimeline {
    static func merge(_ existing: [ChatPost], _ updates: [ChatPost], excluding deleted: Set<Int64> = []) -> [ChatPost] {
        var byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for post in updates where !deleted.contains(post.id) {
            if let previous = byID[post.id], (previous.update_at ?? previous.create_at) > (post.update_at ?? post.create_at) { continue }
            byID[post.id] = post
        }
        return byID.values.filter { !deleted.contains($0.id) }.sorted { $0.id < $1.id }
    }
}

extension NativeChatPreviewModel {
    func canBrowseReminders(channelID:Int64) -> Bool {
        connected && channels.first(where:{ $0.id == channelID })?.encrypted == false
    }
    func canRemind(_ post:ChatPost) -> Bool { canAct(on:post) && canBrowseReminders(channelID:post.channel_id) && !reminderBusy && ["normal","file","sticker"].contains(post.type) && post.props?.encrypted != true && directory.first(where:{ $0.user_id == post.creator_id })?.type == "human" }
    func reminderTime(for post:ChatPost) async throws -> Double {
        guard canBrowseReminders(channelID:post.channel_id),let api = client else { throw ChatAPIError.connection }
        let expected = connectionGeneration
        let result = try await api.reminderTime(postID:post.id)
        try checkConversationSession(expected)
        guard canBrowseReminders(channelID:post.channel_id) else { throw CancellationError() };return result
    }
    func reminders(channelID:Int64) async throws -> [ChatReminder] {
        guard canBrowseReminders(channelID:channelID),let api = client else { throw ChatAPIError.connection }
        let expected = connectionGeneration
        let result = try await api.reminders(channelID:channelID)
        try checkConversationSession(expected)
        guard canBrowseReminders(channelID:channelID) else { throw CancellationError() };return result
    }
    /// Read-before-write avoids silently replacing a reminder edited in another client.
    /// A dispatched change with no exact canonical receipt is uncertain, never retried.
    @discardableResult func changeReminder(_ post:ChatPost,date:Date?,expectedTime:Double) async throws -> Double {
        guard canRemind(post),let api = client,ChatReminderTime.valid(expectedTime) else { throw ChatAPIError.connection }
        let desired = try date.map { try ChatReminderTime.future($0) } ?? 0
        let expected = connectionGeneration
        reminderBusy = true;pendingMessageActions.insert(post.id)
        defer { if expected == connectionGeneration { reminderBusy = false;pendingMessageActions.remove(post.id) } }
        var dispatched = false
        do {
            let current = try await api.reminderTime(postID:post.id)
            try checkConversationSession(expected)
            guard current == expectedTime else { throw ChatReminderFailure(uncertain:false,message:"This reminder changed in another client. Refresh it before changing it.") }
            let source = try await api.post(channelID:post.channel_id,postID:post.id,threadID:post.isReply ? post.thread_id : nil)
            try checkConversationSession(expected)
            guard source.thread_id ?? 0 == post.thread_id ?? 0,source.creator_id == post.creator_id,["normal","file","sticker"].contains(source.type),source.props?.encrypted != true,(source.delete_at ?? 0) == 0,
                  canInteract,canBrowseReminders(channelID:post.channel_id),!deletedPostIDs.contains(post.id) else { throw ChatReminderFailure(uncertain:false,message:"This message is no longer available for a reminder.") }
            if current == desired { return current }
            dispatched = true
            if let date { try await api.setReminder(postID:post.id,date:date) }
            else { try await api.removeReminder(postID:post.id) }
            try checkConversationSession(expected)
            let actual = try await api.reminderTime(postID:post.id)
            try checkConversationSession(expected)
            guard actual == desired else { throw ChatAPIError.invalidResponse }
            reminderRevision = UUID();return actual
        } catch {
            guard expected == connectionGeneration else { throw CancellationError() }
            if dispatched { throw ChatReminderFailure(uncertain:true,message:"The reminder change could not be confirmed. Refresh Reminders before trying again.") }
            throw error
        }
    }
}

extension NativeChatPreviewModel {
    /// Opening a hidden chat uses the ordinary serialized read/presence path.
    /// The official client clears hide state through Channel.enter, not Channel.show.
    func openHiddenConversation(_ channel:ChatChannel) throws {
        guard canInteract,!sending,!isEditingMessage,!channelManagementBusy,!conversationOrganizationBusy,
              channels.contains(where:{ $0.id == channel.id && $0.type == channel.type }),channel.supportsOrganization(.hide) else { throw ChatAPIError.connection }
        selection = channel.id;loadSelection();hiddenConversationRoute = UUID()
    }
    func canOrganizeConversation(_ channel:ChatChannel,change:ChatConversationOrganizationChange) -> Bool {
        canInteract && !sending && !channelManagementBusy && !conversationOrganizationBusy
            && !unresolvedOrganization.contains(channel.id) && pendingChannelClosures[channel.id] == nil && !knownClosedChannelIDs.contains(channel.id) && (!change.changesVisibility || !isEditingMessage)
            && channels.contains(where:{ $0.id == channel.id && $0.type == channel.type && $0.encrypted == channel.encrypted })
            && channel.supportsOrganization(change)
    }
    func refreshConversationOrganization() async throws {
        guard connected,!conversationOrganizationBusy,let api = client else { throw ChatAPIError.connection }
        let expected = connectionGeneration
        do {
            let values = try await api.channels()
            try checkConversationSession(expected)
            guard Set(values.map(\.id)).count == values.count else { throw ChatAPIError.invalidResponse }
            channels = values.sorted { title($0).localizedCaseInsensitiveCompare(title($1)) == .orderedAscending }
            unresolvedOrganization = []
        } catch {
            guard expected == connectionGeneration,!Task.isCancelled else { throw CancellationError() }
            throw error
        }
    }
    func organizeConversation(_ channel:ChatChannel,change:ChatConversationOrganizationChange) async throws {
        guard canOrganizeConversation(channel,change:change),let api = client else { throw ChatAPIError.connection }
        let expected = connectionGeneration
        conversationOrganizationBusy = true
        defer { if expected == connectionGeneration { conversationOrganizationBusy = false } }
        var dispatched = false
        do {
            let before = try await api.channels()
            try checkConversationSession(expected)
            guard Set(before.map(\.id)).count == before.count,let current = before.first(where:{ $0.id == channel.id }),current.type == channel.type,current.encrypted == channel.encrypted,current.supportsOrganization(change),
                  canInteract,!sending,(!change.changesVisibility || !isEditingMessage) else { throw ChatConversationOrganizationFailure(uncertain:false,message:"This conversation is no longer available for that action. Refresh the conversation list.") }
            let unchanged:Bool
            switch change { case .star:unchanged = current.is_star == channel.is_star;case .hide:unchanged = current.last_hide_at == channel.last_hide_at }
            guard unchanged else { throw ChatConversationOrganizationFailure(uncertain:false,message:"This conversation changed in another client. Refresh the conversation list before trying again.") }
            if !change.matches(current) { dispatched = true;try await api.changeConversationOrganization(channelID:channel.id,change:change) }
            try checkConversationSession(expected)
            let after = try await api.channels()
            try checkConversationSession(expected)
            guard Set(after.map(\.id)).count == after.count,let confirmed = after.first(where:{ $0.id == channel.id }),confirmed.type == channel.type,confirmed.encrypted == channel.encrypted,change.matches(confirmed) else { throw ChatAPIError.invalidResponse }
            channels = after.sorted { title($0).localizedCaseInsensitiveCompare(title($1)) == .orderedAscending }
            if change == .hide,selection == channel.id {
                // Drafts are keyed by conversation and retained when leaving the hidden chat.
                selection = nil;loadSelection()
            }
        } catch {
            guard expected == connectionGeneration else { throw CancellationError() }
            if dispatched { unresolvedOrganization.insert(channel.id);throw ChatConversationOrganizationFailure(uncertain:true,message:"The conversation change could not be confirmed. Refresh the conversation list before trying again.") }
            throw error
        }
    }
    func performConversationOrganization(_ channel:ChatChannel,change:ChatConversationOrganizationChange) async {
        let expected = connectionGeneration;error = nil
        do { try await organizeConversation(channel,change:change) }
        catch is CancellationError { }
        catch { if expected == connectionGeneration { self.error = error.localizedDescription } }
    }
}

extension NativeChatPreviewModel {
    func canPreviewDiscoveredChannel(_ channel:ChatChannel) -> Bool {
        connected && !channelManagementBusy && channel.canJoinUnencryptedPublic
    }
    /// Read-only browser scope: no selection, presence, read receipts, badges or drafts change.
    func previewDiscoveredChannel(_ channel:ChatChannel) async throws -> ChatChannelPreviewSnapshot {
        guard canPreviewDiscoveredChannel(channel),let api = client else { throw ChatAPIError.connection }
        let expected = connectionGeneration
        let current = try await freshPreviewChannelScope(channel,expected:expected)
        let posts = try await api.publicChannelPreviewPosts(current)
        try checkConversationSession(expected)
        let confirmed = try await freshPreviewChannelScope(channel,expected:expected)
        return ChatChannelPreviewSnapshot(channel:confirmed,posts:posts,accountGeneration:expected)
    }
    private func freshPreviewChannelScope(_ channel:ChatChannel,expected:Int) async throws -> ChatChannel {
        try checkConversationSession(expected)
        guard channel.canJoinUnencryptedPublic,!channelManagementBusy,let api = client else { throw ChatAPIError.connection }
        let available = try await api.unjoinedChannels()
        try checkConversationSession(expected)
        guard !channelManagementBusy,let current = available.first(where:{ $0.id == channel.id }),current.canJoinUnencryptedPublic else {
            throw ChatTransferError(message:"This channel changed or is no longer available. Refresh channels before previewing.")
        }
        return current
    }
    func previewChannelMemberIDs(_ snapshot:ChatChannelPreviewSnapshot) async throws -> [Int64] {
        let expected = snapshot.accountGeneration
        _ = try await freshPreviewChannelScope(snapshot.channel,expected:expected)
        guard let api = client else { throw ChatAPIError.connection }
        let ids = try await api.members(channelID:snapshot.channel.id)
        try checkConversationSession(expected)
        guard ids.count <= 100_000,Set(ids).count == ids.count,ids.allSatisfy({ $0 > 0 }) else { throw ChatAPIError.invalidResponse }
        _ = try await freshPreviewChannelScope(snapshot.channel,expected:expected)
        return ids.sorted()
    }
    func previewChannelThumbnail(_ snapshot:ChatChannelPreviewSnapshot,postID:Int64) async throws -> NSImage {
        let expected = snapshot.accountGeneration
        try checkConversationSession(expected)
        guard let listed = snapshot.posts.first(where:{ $0.id == postID }),listed.channel_id == snapshot.channel.id,
              listed.file_props?.is_image == true,(listed.delete_at ?? 0) == 0,listed.props?.encrypted != true else { throw ChatAPIError.invalidResponse }
        _ = try await freshPreviewChannelScope(snapshot.channel,expected:expected)
        guard let api = client else { throw ChatAPIError.connection }
        let current = try await api.post(channelID:snapshot.channel.id,postID:postID)
        try checkConversationSession(expected)
        guard current.file_props?.is_image == true,(current.delete_at ?? 0) == 0,current.props?.encrypted != true else { throw ChatAPIError.invalidResponse }
        let bytes = try await api.thumbnail(postID:postID)
        try checkConversationSession(expected)
        _ = try await freshPreviewChannelScope(snapshot.channel,expected:expected)
        guard let image = NativeInlineImagePreview.decode(bytes) else { throw ChatAPIError.invalidResponse }
        return image
    }
    func previewLinkCards(_ snapshot:ChatChannelPreviewSnapshot,postID:Int64) -> [ChatIndexedLinkPreview] {
        guard connected,snapshot.accountGeneration == accountGeneration,snapshot.channel.canJoinUnencryptedPublic,
              let post = snapshot.posts.first(where:{ $0.id == postID && $0.channel_id == snapshot.channel.id }),
              !deletedPostIDs.contains(postID) else { return [] }
        return ChatLinkPreviewPolicy.cards(in:post,hidden:hidesLinkPreviews)
    }
    func previewChannelLinkAsset(_ snapshot:ChatChannelPreviewSnapshot,postID:Int64,index:Int,asset:ChatLinkPreviewAsset) async throws -> NSImage {
        let expected = snapshot.accountGeneration,preference = displaySettingsRevision
        try checkConversationSession(expected)
        guard let item = previewLinkCards(snapshot,postID:postID).first(where:{ $0.index == index }),
              let assetURL = asset.url(in:item.preview),ChatMessageLinks.webURL(assetURL) != nil else { throw ChatAPIError.invalidResponse }
        _ = try await freshPreviewChannelScope(snapshot.channel,expected:expected)
        guard let api = client else { throw ChatAPIError.connection }
        let current = try await api.post(channelID:snapshot.channel.id,postID:postID)
        try checkConversationSession(expected)
        guard displaySettingsRevision == preference,
              ChatLinkPreviewPolicy.cards(in:current,hidden:hidesLinkPreviews).contains(where:{
                  $0.index == index && $0.preview.url == item.preview.url && asset.url(in:$0.preview) == assetURL
              }) else { throw ChatAPIError.invalidResponse }
        let bytes = try await api.linkPreviewImageData(postID:postID,imageURL:assetURL)
        try checkConversationSession(expected)
        _ = try await freshPreviewChannelScope(snapshot.channel,expected:expected)
        guard displaySettingsRevision == preference,
              previewLinkCards(snapshot,postID:postID).contains(where:{ $0.index == index }),
              let image = NativeImagePreview.decode(bytes,maximumPixelSize:asset == .favicon ? 32 : 640) else { throw ChatAPIError.invalidResponse }
        return image
    }
    private func messageContainsLink(_ destination:URL,post:ChatPost,channel:ChatChannel,source:ChatMessageLinkSource) -> Bool {
        guard post.id > 0,post.channel_id == channel.id,post.type != "system",(post.delete_at ?? 0) == 0,!deletedPostIDs.contains(post.id),channel.encrypted || post.props?.encrypted != true else { return false }
        switch source {
        case .body:
            guard let text = try? encryption.message(post.message,channel:channel) else { return false }
            return ChatMessageLinks.renderedDestinations(text).contains(destination)
        case .botText(let text):
            return botAttachments(for:post).contains { $0.text == text } && ChatMessageLinks.renderedDestinations(text).contains(destination)
        case .card(let index):
            return !channel.encrypted && ChatLinkPreviewPolicy.cards(in:post,hidden:hidesLinkPreviews).contains { $0.index == index && $0.preview.url.flatMap(ChatMessageLinks.webURL) == destination }
        case .library(let rawURL):
            return !channel.encrypted && ChatMessageLinks.webURL(rawURL) == destination && (post.url_props ?? []).contains { $0.url == rawURL }
        }
    }
    func messageLinkIntent(_ post:ChatPost,destination:URL,source:ChatMessageLinkSource) throws -> ChatMessageLinkReview {
        try checkConversationSession(accountGeneration)
        guard ChatMessageLinks.messageURL(destination.absoluteString) == destination,canRead(post.channel_id),
              let channel = channels.first(where:{ $0.id == post.channel_id }),channel.is_closed != true,channel.is_joined != false,(channel.hide_global_at ?? 0) == 0 else { throw ChatAPIError.invalidResponse }
        let known = posts.first { $0.id == post.id } ?? replies.first { $0.id == post.id } ?? (threadRoot?.id == post.id ? threadRoot : nil) ?? post
        guard (known.thread_id ?? 0) == (post.thread_id ?? 0),messageContainsLink(destination,post:post,channel:channel,source:source),messageContainsLink(destination,post:known,channel:channel,source:source) else {
            throw ChatTransferError(message:"This link changed or is no longer available. Refresh the message before opening it.")
        }
        return .init(post:post,channel:channel,destination:destination,source:source,accountGeneration:accountGeneration,keyGeneration:encryptionGeneration,requiresConfirmation:post.props?.safe_url == false || known.props?.safe_url == false || ChatMessageLinks.applicationURL(destination.absoluteString) != nil,flaggedByServer:post.props?.safe_url == false || known.props?.safe_url == false)
    }
    func openMessageLink(_ review:ChatMessageLinkReview,allowUnsafe:Bool = false,open:(URL)->Bool = { NSWorkspace.shared.open($0) }) async throws -> ChatMessageLinkOpenResult {
        let expected = review.accountGeneration
        func check() throws {
            try checkConversationSession(expected)
            guard !review.channel.encrypted || review.keyGeneration == encryptionGeneration else { throw CancellationError() }
            let local = try messageLinkIntent(review.post,destination:review.destination,source:review.source)
            guard local.channel.type == review.channel.type,local.channel.encrypted == review.channel.encrypted,local.channel.channel_key_enc == review.channel.channel_key_enc else { throw CancellationError() }
        }
        try check()
        guard let api = client else { throw ChatAPIError.connection }
        func freshScope() async throws {
            let available = try await api.channels();try check()
            guard available.contains(where:{ $0.id == review.channel.id && $0.type == review.channel.type && $0.encrypted == review.channel.encrypted && $0.channel_key_enc == review.channel.channel_key_enc && $0.is_closed != true && $0.is_joined != false && ($0.hide_global_at ?? 0) == 0 }) else { throw ChatTransferError(message:"This conversation is no longer available. Refresh before opening its links.") }
        }
        try await freshScope()
        let current = try await api.post(channelID:review.post.channel_id,postID:review.post.id,threadID:review.post.isReply ? review.post.thread_id : nil)
        try check();try await freshScope()
        guard current.isReply == review.post.isReply,(current.thread_id ?? 0) == (review.post.thread_id ?? 0) else { throw ChatAPIError.invalidResponse }
        let fresh = try messageLinkIntent(current,destination:review.destination,source:review.source)
        if fresh.requiresConfirmation && !(allowUnsafe && review.requiresConfirmation && (!fresh.flaggedByServer || review.flaggedByServer)) { return .confirmation(fresh) }
        try check()
        guard open(review.destination) else { throw ChatTransferError(message:ChatMessageLinks.applicationURL(review.destination.absoluteString) != nil ? "LINE could not be opened. Check that LINE is installed and try again." : "The website could not be opened. Check your default browser and try again.") }
        return .opened
    }
    func previewLinkIntent(_ snapshot:ChatChannelPreviewSnapshot,postID:Int64,destination:URL,source:ChatPreviewLinkSource) throws -> ChatPreviewLinkReview {
        try checkConversationSession(snapshot.accountGeneration)
        guard snapshot.channel.canJoinUnencryptedPublic,ChatMessageLinks.messageURL(destination.absoluteString) == destination,
              let post = snapshot.posts.first(where:{ $0.id == postID && $0.channel_id == snapshot.channel.id }),!deletedPostIDs.contains(postID),
              ChatChannelPreviewContent.containsDestination(destination,in:post,source:source,hideCards:hidesLinkPreviews) else { throw ChatAPIError.invalidResponse }
        return ChatPreviewLinkReview(snapshot:snapshot,postID:postID,destination:destination,source:source,requiresConfirmation:post.props?.safe_url == false || ChatMessageLinks.applicationURL(destination.absoluteString) != nil,flaggedByServer:post.props?.safe_url == false)
    }
    /// Revalidate at each open, including after a flagged-link confirmation. Never opens a NAS API URL.
    func openPreviewLink(_ review:ChatPreviewLinkReview,allowUnsafe:Bool = false,
                         open:(URL)->Bool = { NSWorkspace.shared.open($0) }) async throws -> ChatPreviewLinkOpenResult {
        let expected = review.snapshot.accountGeneration
        _ = try previewLinkIntent(review.snapshot,postID:review.postID,destination:review.destination,source:review.source)
        _ = try await freshPreviewChannelScope(review.snapshot.channel,expected:expected)
        guard let api = client else { throw ChatAPIError.connection }
        let current = try await api.post(channelID:review.snapshot.channel.id,postID:review.postID)
        try checkConversationSession(expected)
        _ = try await freshPreviewChannelScope(review.snapshot.channel,expected:expected)
        guard !deletedPostIDs.contains(review.postID),
              ChatChannelPreviewContent.containsDestination(review.destination,in:current,source:review.source,hideCards:hidesLinkPreviews) else {
            throw ChatTransferError(message:"This link changed or is no longer available. Refresh the preview before opening it.")
        }
        let fresh = ChatPreviewLinkReview(snapshot:review.snapshot,postID:review.postID,destination:review.destination,source:review.source,requiresConfirmation:current.props?.safe_url == false || ChatMessageLinks.applicationURL(review.destination.absoluteString) != nil,flaggedByServer:current.props?.safe_url == false)
        if fresh.requiresConfirmation && !(allowUnsafe && review.requiresConfirmation && (!fresh.flaggedByServer || review.flaggedByServer)) { return .confirmation(fresh) }
        try checkConversationSession(expected)
        guard open(review.destination) else { throw ChatTransferError(message:ChatMessageLinks.applicationURL(review.destination.absoluteString) != nil ? "LINE could not be opened. Check that LINE is installed and try again." : "The website could not be opened. Check your default browser and try again.") }
        return .opened
    }
    func canJoinDiscoveredChannel(_ channel:ChatChannel) -> Bool {
        canInteract && !sending && !channelManagementBusy && !conversationOrganizationBusy && !isEditingMessage
            && !unresolvedMembership.contains(channel.id) && channel.canJoinUnencryptedPublic && channelPermissions?.allows("channel_join") == true
    }
    func canLeaveDiscoveredChannel(_ channel:ChatChannel) -> Bool {
        canInteract && !sending && !channelManagementBusy && !conversationOrganizationBusy && !isEditingMessage
            && !unresolvedMembership.contains(channel.id) && channel.canLeaveNamed && channelPermissions?.allows("channel_disjoin") == true
    }
    /// Refresh both membership scopes before unlocking any uncertain membership action.
    func channelDiscovery() async throws -> [ChatChannel] {
        guard connected,!channelManagementBusy,let api = client else { throw ChatAPIError.connection }
        let expected = connectionGeneration
        do {
            let permissions = try await api.channelPermissions()
            try checkConversationSession(expected)
            let available = try await api.unjoinedChannels()
            try checkConversationSession(expected)
            let joined = try await api.channels()
            try checkConversationSession(expected)
            guard Set(joined.map(\.id)).count == joined.count,Set(joined.map(\.id)).isDisjoint(with:Set(available.map(\.id))) else { throw ChatAPIError.invalidResponse }
            channelPermissions = permissions
            channels = joined.sorted { title($0).localizedCaseInsensitiveCompare(title($1)) == .orderedAscending }
            unresolvedMembership = []
            if let id = selection,!joined.contains(where:{ $0.id == id }) { selection = nil;loadSelection() }
            return available.filter { ["public","private"].contains($0.type) && $0.is_closed != true && ($0.hide_global_at ?? 0) == 0 }
                .sorted { title($0).localizedCaseInsensitiveCompare(title($1)) == .orderedAscending }
        } catch {
            guard expected == connectionGeneration,!Task.isCancelled else { throw CancellationError() };throw error
        }
    }
    @discardableResult func joinDiscoveredChannel(_ channel:ChatChannel) async throws -> ChatChannel {
        guard canJoinDiscoveredChannel(channel),let api = client else { throw ChatAPIError.connection }
        let expected = connectionGeneration
        channelManagementBusy = true
        defer { if expected == connectionGeneration { channelManagementBusy = false } }
        var dispatched = false
        do {
            let permissions = try await api.channelPermissions()
            try checkConversationSession(expected)
            guard permissions.allows("channel_join") else { throw ChatTransferError(message:"Your server permissions no longer allow joining channels.") }
            let available = try await api.unjoinedChannels()
            try checkConversationSession(expected)
            guard let current = available.first(where:{ $0.id == channel.id }),current.canJoinUnencryptedPublic,canInteract,!sending,!isEditingMessage else { throw ChatTransferError(message:"This channel changed or is no longer available. Refresh channels before joining.") }
            dispatched = true;try await api.joinPublicChannel(current)
            try checkConversationSession(expected)
            let after = try await api.channels()
            try checkConversationSession(expected)
            guard Set(after.map(\.id)).count == after.count,let joined = after.first(where:{ $0.id == channel.id }),joined.is_joined == true,joined.type == "public",!joined.encrypted else { throw ChatAPIError.invalidResponse }
            channels = after.sorted { title($0).localizedCaseInsensitiveCompare(title($1)) == .orderedAscending }
            selection = joined.id;loadSelection();return joined
        } catch {
            guard expected == connectionGeneration else { throw CancellationError() }
            if dispatched { unresolvedMembership.insert(channel.id);throw ChatChannelMembershipFailure(uncertain:true,message:"Joining could not be confirmed. Refresh Browse channels before trying again.") };throw error
        }
    }
    func leaveDiscoveredChannel(_ channel:ChatChannel) async throws {
        guard canLeaveDiscoveredChannel(channel),let api = client else { throw ChatAPIError.connection }
        let expected = connectionGeneration
        channelManagementBusy = true
        defer { if expected == connectionGeneration { channelManagementBusy = false } }
        var dispatched = false
        do {
            let permissions = try await api.channelPermissions()
            try checkConversationSession(expected)
            guard permissions.allows("channel_disjoin") else { throw ChatTransferError(message:"Your server permissions no longer allow leaving channels.") }
            let before = try await api.channels()
            try checkConversationSession(expected)
            guard Set(before.map(\.id)).count == before.count,let current = before.first(where:{ $0.id == channel.id }),current.type == channel.type,current.encrypted == channel.encrypted,(!channel.encrypted || current.channel_key_enc == channel.channel_key_enc),current.canLeaveNamed,canInteract,!sending,!isEditingMessage else { throw ChatTransferError(message:"This channel changed or is no longer joined. Refresh channels before leaving.") }
            dispatched = true;try await api.disjoinNamedChannel(current)
            try checkConversationSession(expected)
            let after = try await api.channels()
            try checkConversationSession(expected)
            guard Set(after.map(\.id)).count == after.count,!after.contains(where:{ $0.id == channel.id }) else { throw ChatAPIError.invalidResponse }
            channels = after.sorted { title($0).localizedCaseInsensitiveCompare(title($1)) == .orderedAscending }
            if selection == channel.id { selection = nil;loadSelection() }
        } catch {
            guard expected == connectionGeneration else { throw CancellationError() }
            if dispatched { unresolvedMembership.insert(channel.id);throw ChatChannelMembershipFailure(uncertain:true,message:"Leaving could not be confirmed. Refresh Browse channels before trying again.") };throw error
        }
    }
}

extension NativeChatPreviewModel {
    var isVerifiedAdministrator: Bool {
        guard let status = administratorStatus, status.isAdministrator,
              administratorStatusGeneration == accountGeneration,
              let userID = currentUserID, administratorStatusUserID == userID,
              directory.filter({ $0.user_id == userID && $0.username == status.username }).count == 1 else { return false }
        return true
    }
    private func resetAdministratorStatus() {
        administratorReadRevision = UUID()
        administratorStatus = nil; administratorStatusGeneration = nil; administratorStatusUserID = nil
    }
    @discardableResult func refreshAdministratorStatus() async throws -> Bool {
        guard connected, let api = client, let userID = currentUserID,
              let username = directory.first(where: { $0.user_id == userID })?.username, !username.isEmpty else {
            resetAdministratorStatus(); throw ChatAPIError.connection
        }
        let epoch = accountGeneration, revision = UUID()
        administratorReadRevision = revision
        do {
            let status = try await api.administratorStatus(expectedUsername: username)
            try checkConversationSession(epoch)
            guard client === api, administratorReadRevision == revision, currentUserID == userID,
                  directory.filter({ $0.user_id == userID && $0.username == username }).count == 1 else { throw CancellationError() }
            administratorStatus = status; administratorStatusGeneration = epoch; administratorStatusUserID = userID
            return status.isAdministrator
        } catch {
            // Retired reads must not reach caller error cleanup, which may
            // otherwise clear a newer authority snapshot for the same account.
            guard epoch == accountGeneration, administratorReadRevision == revision else { throw CancellationError() }
            resetAdministratorStatus()
            throw error
        }
    }
    func hasChannelDetailsEditingAuthority(_ channel: ChatChannel) -> Bool {
        channel.supportsDetailsEditing && (channel.id > 2 || isVerifiedAdministrator)
            && channels.contains(where: { $0.hasSameDetailsScope(as: channel) })
            && channelPermissions?.allows("channel_set") == true
    }
    func canEditChannelDetails(_ channel:ChatChannel) -> Bool {
        canInteract && !sending && !channelManagementBusy && !conversationOrganizationBusy
            && !unresolvedChannelDetails.contains(channel.id) && hasChannelDetailsEditingAuthority(channel)
    }
    var archiveContentEpoch:Int { encryptionGeneration }
    func canReadArchive(_ archive:ChatArchive) -> Bool {
        connected && archive.isReadable && (!archive.props.channel.encrypted || (try? encryption.key(for:archive.props.channel)) != nil)
    }
    private func archiveKey(_ archive:ChatArchive) throws -> Data? {
        guard connected,archive.isReadable else { throw ChatAPIError.invalidResponse }
        return archive.props.channel.encrypted ? try encryption.key(for:archive.props.channel) : nil
    }
    private func checkArchiveContent(_ archive:ChatArchive,account:Int,keyEpoch:Int) throws {
        try Task.checkCancellation();try checkConversationSession(account)
        guard canReadArchive(archive),!archive.props.channel.encrypted || encryptionGeneration == keyEpoch else { throw CancellationError() }
    }
    func archiveMessageText(_ post:ChatPost,archive:ChatArchive) -> String {
        guard canReadArchive(archive),post.channel_id == archive.props.channel.id else { return "Encrypted archive is locked" }
        if post.type == "system" { return post.systemEventText(names:names) }
        return (try? encryption.message(post.message,channel:archive.props.channel)) ?? "Could not decrypt this archived message"
    }
    func archiveFilename(_ post:ChatPost,archive:ChatArchive) -> String {
        guard canReadArchive(archive),post.channel_id == archive.props.channel.id,let name = post.file_props?.name else { return "Encrypted attachment" }
        guard let decoded = try? encryption.filename(name,channel:archive.props.channel) else { return "Encrypted attachment" }
        return ChatMultipartBody.safeFilename(decoded)
    }
    func canOpenArchiveAttachment(_ post:ChatPost,archive:ChatArchive) -> Bool {
        canReadArchive(archive) && post.id > 0 && post.channel_id == archive.props.channel.id && post.type == "file" && post.file_props != nil && (post.delete_at ?? 0) == 0 &&
        (archive.props.channel.encrypted || post.props?.encrypted != true)
    }
    func loadArchiveNames(kind:ChatArchiveKind) async throws -> [String] {
        guard connected,let api = client else { throw ChatAPIError.connection }
        let expected = connectionGeneration
        let names = try await api.archiveNames(kind:kind)
        try checkConversationSession(expected)
        if kind == .public {
            do { _ = try await refreshAdministratorStatus() }
            catch is CancellationError { throw CancellationError() }
            catch { /* Archives remain browsable without deletion authority. */ }
            try checkConversationSession(expected)
        }
        return names
    }
    func loadArchives(kind:ChatArchiveKind,name:String) async throws -> [ChatArchive] {
        guard connected,let api = client else { throw ChatAPIError.connection }
        let expected = connectionGeneration
        let values = try await api.archives(kind:kind,name:name)
        try checkConversationSession(expected)
        return values
    }
    func canReviewArchiveDeletion(kind: ChatArchiveKind) -> Bool {
        connected && (kind != .public || isVerifiedAdministrator)
    }
    private func requirePublicArchiveAdministrator() async throws {
        guard try await refreshAdministratorStatus(), isVerifiedAdministrator else {
            throw ChatTransferError(message:"Administrator access is required to delete public archives. No deletion was sent.")
        }
    }
    func prepareArchiveDeletion(_ archive: ChatArchive, kind: ChatArchiveKind, name: String) async throws -> ChatArchiveDeletionPreparation {
        guard connected, let api = client else { throw ChatAPIError.connection }
        let expected = accountGeneration
        if kind == .public { try await requirePublicArchiveAdministrator(); try checkConversationSession(expected) }
        return try await archiveDeletions.prepare(archive: archive, kind: kind, name: name, accountGeneration: expected,
            load: { try await api.archives(kind: $0, name: $1) },
            checkCurrent: { [self] in try checkConversationSession(expected) })
    }
    func deleteArchive(_ preparation: ChatArchiveDeletionPreparation) async throws {
        guard connected, preparation.accountGeneration == accountGeneration, let api = client else { throw ChatAPIError.connection }
        let expected = accountGeneration
        var needsAuthorityCheck = preparation.kind == .public
        try await archiveDeletions.delete(preparation,
            load: { [self] kind, name in
                let values = try await api.archives(kind:kind,name:name)
                try checkConversationSession(expected)
                // The first load is the final fresh preflight, before a receipt
                // is saved or the delete request is dispatched. Later loads
                // only establish canonical absence and never replay deletion.
                if needsAuthorityCheck {
                    try await requirePublicArchiveAdministrator(); try checkConversationSession(expected)
                    needsAuthorityCheck = false
                }
                return values
            }, dispatch: { try await api.deleteArchive(id: $0) },
            checkCurrent: { [self] in try checkConversationSession(expected) })
    }
    func checkArchiveDeletion(_ record: ChatArchiveDeletionRecord) async throws -> Bool {
        guard connected, let api = client else { throw ChatAPIError.connection }
        let expected = accountGeneration
        return try await archiveDeletions.checkOutcome(record,
            load: { try await api.archives(kind: $0, name: $1) },
            checkCurrent: { [self] in try checkConversationSession(expected) })
    }
    private func freshArchiveScopes(kind:ChatArchiveKind,name:String,scopes:[ChatArchive],expected:Int) async throws -> [ChatArchive] {
        guard connected,let api = client,!scopes.isEmpty,Set(scopes.map(\.id)).count == scopes.count else { throw ChatAPIError.connection }
        let current = try await api.archives(kind:kind,name:name)
        try checkConversationSession(expected)
        return try scopes.map { old in
            guard let value = current.first(where:{ $0.id == old.id }),value.isReadable,value.hasSameContentScope(as:old) else { throw ChatAPIError.invalidResponse }
            guard canReadArchive(value) else { throw ChatCryptoError.invalidKey }
            return value
        }
    }
    func searchArchivedMessages(kind:ChatArchiveKind,name:String,scopes:[ChatArchive],query:String,collection:ChatArchiveCollection,offset:Int = 0) async throws -> ChatArchiveSearchResult {
        guard connected,let api = client else { throw ChatAPIError.connection }
        let expected = connectionGeneration,keyEpoch = encryptionGeneration
        let fresh = try await freshArchiveScopes(kind:kind,name:name,scopes:scopes,expected:expected)
        for scope in fresh { try checkArchiveContent(scope,account:expected,keyEpoch:keyEpoch) }
        let result = try await api.searchArchives(scopes:fresh,query:query,collection:collection,offset:offset)
        for scope in scopes { try checkArchiveContent(scope,account:expected,keyEpoch:keyEpoch) }
        return result
    }
    func archivedMessageContext(kind:ChatArchiveKind,name:String,match:ChatArchiveMatch) async throws -> (root:ChatPost?,posts:[ChatPost]) {
        guard connected,let api = client else { throw ChatAPIError.connection }
        let expected = connectionGeneration,keyEpoch = encryptionGeneration
        let scopes = try await freshArchiveScopes(kind:kind,name:name,scopes:[match.archive],expected:expected)
        let archive = scopes[0]
        try checkArchiveContent(archive,account:expected,keyEpoch:keyEpoch)
        let isReply = match.post.isReply
        let threadID = isReply ? match.post.thread_id : nil
        var root:ChatPost?
        if let threadID {
            let roots = try await api.archiveContext(archive,postID:threadID,exact:true)
            for scope in scopes { try checkArchiveContent(scope,account:expected,keyEpoch:keyEpoch) }
            guard let original = roots.first(where:{ $0.id == threadID }),!original.isReply else { throw ChatAPIError.invalidResponse };root = original
        }
        let posts = try await api.archiveContext(archive,postID:match.post.id,threadID:threadID)
        for scope in scopes { try checkArchiveContent(scope,account:expected,keyEpoch:keyEpoch) }
        return (root,posts.filter { $0.id != root?.id })
    }

    private func validatedArchiveAttachment(kind:ChatArchiveKind,name:String,archive:ChatArchive,post:ChatPost,expected:Int,keyEpoch:Int) async throws -> ChatPost {
        try checkArchiveContent(archive,account:expected,keyEpoch:keyEpoch)
        guard connected,let api = client,canOpenArchiveAttachment(post,archive:archive) else { throw ChatAPIError.invalidResponse }
        let scopes = try await freshArchiveScopes(kind:kind,name:name,scopes:[archive],expected:expected)
        try checkArchiveContent(archive,account:expected,keyEpoch:keyEpoch)
        let posts = try await api.archiveContext(scopes[0],postID:post.id,threadID:post.isReply ? post.thread_id : nil,exact:true)
        try checkArchiveContent(archive,account:expected,keyEpoch:keyEpoch)
        guard let canonical = posts.first(where:{ $0.id == post.id }),canOpenArchiveAttachment(canonical,archive:archive),
              canonical.channel_id == post.channel_id,canonical.file_props?.name == post.file_props?.name,
              canonical.file_props?.size == post.file_props?.size,canonical.file_props?.is_image == post.file_props?.is_image,
              canonical.file_props?.type == post.file_props?.type else { throw ChatAPIError.invalidResponse }
        return canonical
    }
    func archivedAttachmentPreview(kind:ChatArchiveKind,name:String,archive:ChatArchive,post:ChatPost,maximumBytes:Int,expectedAccount:Int) async throws -> Data {
        guard let api = client,maximumBytes > 0,maximumBytes <= 128 * 1024 * 1024 else { throw ChatAPIError.connection }
        let keyEpoch = encryptionGeneration,key = try archiveKey(archive)
        let canonical = try await validatedArchiveAttachment(kind:kind,name:name,archive:archive,post:post,expected:expectedAccount,keyEpoch:keyEpoch)
        guard (canonical.file_props?.size ?? 0) <= Int64(maximumBytes + (key == nil ? 0 : 40)) else { throw ChatTransferError(message:"This attachment is too large to preview. Save the original to open it.") }
        let bytes = try await api.documentPreviewData(postID:canonical.id,maximumBytes:maximumBytes,decryptionKey:key)
        _ = try await validatedArchiveAttachment(kind:kind,name:name,archive:archive,post:post,expected:expectedAccount,keyEpoch:keyEpoch)
        return bytes
    }
    func saveArchivedAttachment(kind: ChatArchiveKind, name: String, archive: ChatArchive, post: ChatPost, to destination: URL, expectedAccount: Int) async throws {
        guard expectedAccount == connectionGeneration, let api = client, ChatSavedDownloadFile.validDestination(destination) else { throw ChatAPIError.connection }
        _ = try archiveKey(archive)
        let filename = archiveFilename(post,archive:archive)
        guard let id = reserveDownload(post: post, filename: filename, encrypted: archive.props.channel.encrypted, source: .archive(kind, name, archive, post)) else { throw ChatTransferError(message: "This attachment is already downloading, or another save location is being chosen.") }
        defer { releaseDownload(postID: post.id, id: id, epoch: expectedAccount) }
        try await transferArchivedAttachment(kind: kind, name: name, archive: archive, post: post, to: destination, expected: expectedAccount, id: id, api: api)
    }
    private func transferArchivedAttachment(kind: ChatArchiveKind, name: String, archive: ChatArchive, post: ChatPost, to destination: URL, expected expectedAccount: Int, id: UUID, api: ChatAPIClient) async throws {
        let keyEpoch = encryptionGeneration,key = try archiveKey(archive)
        downloadPreferences.remember(destination: destination)
        updateDownload(id, epoch: expectedAccount) { $0.state = .transferring; $0.destination = destination; $0.filename = ChatMultipartBody.safeFilename(destination.lastPathComponent) }
        let progress = downloadProgress(id, epoch: expectedAccount)
        let transfer = Task {
            _ = try await self.validatedArchiveAttachment(kind: kind, name: name, archive: archive, post: post, expected: expectedAccount,keyEpoch: keyEpoch)
            try await api.saveAttachment(postID: post.id, to: destination, decryptionKey:key, onProgress: { progress.update(received: $0, expected: $1) }, authorizeCommit: { commit in
                _ = try await self.validatedArchiveAttachment(kind: kind, name: name, archive: archive, post: post, expected: expectedAccount,keyEpoch: keyEpoch)
                try self.checkArchiveContent(archive,account:expectedAccount,keyEpoch:keyEpoch)
                guard self.downloadHistory.first(where: { $0.id == id })?.state.active == true else { throw CancellationError() }
                self.updateDownload(id, epoch: expectedAccount) { let bytes = progress.snapshot(); $0.progress(received: bytes.received, expected: bytes.expected); $0.state = .verifying }
                try commit()
                self.savedDownload(id, epoch: expectedAccount, destination: destination)
            })
        }
        downloadTasks[post.id] = (key != nil, transfer)
        do { try await withTaskCancellationHandler { try await transfer.value } onCancel: { transfer.cancel() } }
        catch { finishDownloadFailure(error, id: id, epoch: expectedAccount); throw error }
    }

    func loadArchivePosts(kind:ChatArchiveKind,name:String,archive:ChatArchive,before:Int64? = nil,threadID:Int64? = nil) async throws -> [ChatPost] {
        guard connected,let api = client else { throw ChatAPIError.connection }
        let expected = connectionGeneration,keyEpoch = encryptionGeneration
        let current = try await api.archives(kind:kind,name:name)
        try checkConversationSession(expected)
        guard let source = current.first(where:{ $0.id == archive.id }),source.isReadable,source.hasSameContentScope(as:archive) else { throw ChatAPIError.invalidResponse }
        try checkArchiveContent(source,account:expected,keyEpoch:keyEpoch)
        let posts = try await api.archivePosts(source,before:before,threadID:threadID)
        try checkArchiveContent(source,account:expected,keyEpoch:keyEpoch)
        return posts
    }

    func loadChannelGuests(channelID: Int64) async throws -> ChatChannelGuestsSnapshot {
        guard connected, !channelManagementBusy, let api = client else { throw ChatAPIError.connection }
        let expected = connectionGeneration
        let permissions = try await api.channelPermissions()
        try checkConversationSession(expected)
        guard permissions.allows("guest_manage") else { throw ChatTransferError(message: "Your account cannot manage guests in this channel.") }
        let values = try await api.channels()
        try checkConversationSession(expected)
        guard Set(values.map(\.id)).count == values.count,
              let channel = values.first(where: { $0.id == channelID }), channel.supportsGuestBrowser
        else { throw ChatTransferError(message: "Guests are available only in a joined, open private channel without encryption.") }
        let policy = try await api.guestPolicy()
        try checkConversationSession(expected)
        // Existing guests remain visible when new guest access is disabled.
        let guests = try await api.channelGuests(channelID: channelID)
        try checkConversationSession(expected)
        return .init(channel: channel, policy: policy, guests: guests, accountGeneration: expected)
    }

    func changeChannelGuest(_ change: ChatGuestChange, original: ChatChannelGuestsSnapshot) async throws -> ChatChannelGuestsSnapshot {
        guard connected, !channelManagementBusy, original.accountGeneration == accountGeneration, let api = client else { throw ChatAPIError.connection }
        let expected = accountGeneration
        return try await guestManagement.perform(change, original: original, read: { [self] in
            try await loadChannelGuests(channelID: original.channel.id)
        }, dispatch: { [self] record in
            try checkConversationSession(expected)
            guard !channelManagementBusy else { throw ChatAPIError.connection }
            try await api.applyGuestAction(record)
        }, check: { [self] in try checkConversationSession(expected) })
    }

    func loadChannelDetails(channelID:Int64) async throws -> ChatChannel {
        guard connected,!channelManagementBusy,let api = client else { throw ChatAPIError.connection }
        let expected = connectionGeneration
        do {
            let permissions = try await api.channelPermissions()
            try checkConversationSession(expected)
            let values = try await api.channels()
            try checkConversationSession(expected)
            guard Set(values.map(\.id)).count == values.count else { throw ChatAPIError.invalidResponse }
            guard let channel = values.first(where:{ $0.id == channelID }),["public","private"].contains(channel.type),channel.is_closed != true else { throw ChatTransferError(message:"This channel is no longer available.") }
            if channelID <= 2 {
                do { _ = try await refreshAdministratorStatus() }
                catch is CancellationError { throw CancellationError() }
                catch { resetAdministratorStatus() } // Read-only details still work.
                try checkConversationSession(expected)
            }
            channelPermissions = permissions
            channels = values.sorted { title($0).localizedCaseInsensitiveCompare(title($1)) == .orderedAscending }
            unresolvedChannelDetails.remove(channelID)
            return channel
        } catch {
            guard expected == connectionGeneration,!Task.isCancelled else { throw CancellationError() };throw error
        }
    }
    @discardableResult func saveChannelDetails(original:ChatChannel,draft:ChatChannelDetailsDraft) async throws -> ChatChannel {
        let patch = try draft.patch(relativeTo:original)
        guard canEditChannelDetails(original),let api = client else { throw ChatAPIError.connection }
        let expected = connectionGeneration
        channelManagementBusy = true
        defer { if expected == connectionGeneration { channelManagementBusy = false } }
        var dispatched = false
        do {
            let permissions = try await api.channelPermissions()
            try checkConversationSession(expected)
            guard permissions.allows("channel_set") else { throw ChatTransferError(message:"Your server permissions no longer allow changing channel details.") }
            let before = try await api.channels()
            try checkConversationSession(expected)
            guard Set(before.map(\.id)).count == before.count,let current = before.first(where:{ $0.id == original.id }),current.hasSameDetailsScope(as: original),current.supportsDetailsEditing,canInteract,!sending else { throw ChatTransferError(message:"This channel changed or is no longer available. Refresh its details before saving.") }
            guard patch.originalMatches(current,original:original) else { throw ChatChannelDetailsFailure(uncertain:false,message:"These details changed in another client. Refresh before saving; your edits have been kept.") }
            var administratorVerified = false
            if original.id <= 2 {
                administratorVerified = try await refreshAdministratorStatus()
                try checkConversationSession(expected)
                guard administratorVerified, isVerifiedAdministrator else { throw ChatTransferError(message:"Administrator access is required to edit this channel. No changes were sent.") }
            }
            if !patch.isEmpty { dispatched = true;try await api.setNamedChannelDetails(channelID:original.id,patch:patch,administratorVerified:administratorVerified) }
            try checkConversationSession(expected)
            let after = try await api.channels()
            try checkConversationSession(expected)
            guard Set(after.map(\.id)).count == after.count,let confirmed = after.first(where:{ $0.id == original.id }),confirmed.hasSameDetailsScope(as: original),confirmed.supportsDetailsEditing,patch.confirmed(by:confirmed) else { throw ChatAPIError.invalidResponse }
            channels = after.sorted { title($0).localizedCaseInsensitiveCompare(title($1)) == .orderedAscending }
            return confirmed
        } catch {
            guard expected == connectionGeneration else { throw CancellationError() }
            if dispatched { unresolvedChannelDetails.insert(original.id);throw ChatChannelDetailsFailure(uncertain:true,message:"The channel update could not be confirmed. Refresh its details before trying again; your edits have been kept.") };throw error
        }
    }
}


extension NativeChatPreviewModel {
    func canArchiveHistory(_ channel:ChatChannel) -> Bool {
        canInteract && !sending && !uploading && !isEditingMessage && !channelManagementBusy && !conversationOrganizationBusy
            && channelActionRecoveryError == nil && channel.supportsHistoryArchiving && pendingHistoryArchives[channel.id] == nil && pendingChannelClosures[channel.id] == nil && !knownClosedChannelIDs.contains(channel.id)
            && channelPermissions?.allows("channel_archive") == true
    }
    func prepareHistoryArchive(channelID:Int64) async throws -> ChatHistoryArchivePreparation {
        guard canInteract,!sending,!uploading,!isEditingMessage,!channelManagementBusy,let api = client,pendingHistoryArchives[channelID] == nil,pendingChannelClosures[channelID] == nil,channelActionRecoveryError == nil else { throw ChatAPIError.connection }
        let epoch = connectionGeneration
        let acl = try await api.channelPermissions();try checkConversationSession(epoch)
        guard acl.allows("channel_archive") else { throw ChatTransferError(message:"Your server permissions do not allow archiving history.") }
        let current = try await api.channels();try checkConversationSession(epoch)
        guard Set(current.map(\.id)).count == current.count,let channel = current.first(where:{ $0.id == channelID }),channel.supportsHistoryArchiving else { throw ChatTransferError(message:"Archiving is available for joined, unencrypted private channels.") }
        let history = try await api.posts(channelID:channelID);try checkConversationSession(epoch)
        guard Set(history.map(\.id)).count == history.count,history.allSatisfy({ $0.channel_id == channelID && $0.id > 0 }),let latest = history.map(\.id).max() else { throw ChatTransferError(message:"There is no current history to archive.") }
        let archives = try await archivePeriodsForChannel(channel:channel,epoch:epoch)
        channelPermissions = acl
        return .init(channel:channel,latestPostID:latest,priorArchiveIDs:Set(archives.map(\.id)),accountGeneration:accountGeneration)
    }
    @discardableResult func archiveHistory(_ preparation:ChatHistoryArchivePreparation) async throws -> ChatArchive {
        guard preparation.accountGeneration == accountGeneration,canArchiveHistory(preparation.channel),let api = client else { throw ChatAPIError.connection }
        // Repeat the preflight after the confirmation dialog. A changed channel or
        // newly arrived history needs a new confirmation instead of a silent update.
        let fresh = try await prepareHistoryArchive(channelID:preparation.channel.id)
        guard fresh.channel.name == preparation.channel.name,fresh.latestPostID == preparation.latestPostID,fresh.priorArchiveIDs == preparation.priorArchiveIDs else { throw ChatTransferError(message:"The channel or its history changed. Refresh and review before archiving.") }
        guard canArchiveHistory(fresh.channel) else { throw ChatAPIError.connection }
        let epoch = connectionGeneration
        channelManagementBusy = true
        defer { if epoch == connectionGeneration { channelManagementBusy = false } }
        var dispatched = false
        do {
            try checkConversationSession(epoch)
            try rememberChannelAction(.init(kind:.archive,channelID:fresh.channel.id,channelType:fresh.channel.type,encrypted:fresh.channel.encrypted,latestPostID:fresh.latestPostID,priorArchiveIDs:fresh.priorArchiveIDs.sorted()))
            pendingHistoryArchives[fresh.channel.id] = fresh
            dispatched = true
            try await api.archivePrivateChannelHistory(fresh.channel)
            try checkConversationSession(epoch)
            return try await confirmHistoryArchive(fresh,epoch:epoch)
        } catch {
            guard epoch == connectionGeneration else { throw CancellationError() }
            if !dispatched { throw error }
            throw ChatTransferError(message:"The archive request could not be confirmed. Use Check archive status; do not repeat the request in another client until you have checked Archive history.")
        }
    }
    func checkHistoryArchive(channelID:Int64) async throws -> ChatArchive {
        guard connected,!channelManagementBusy,let pending = pendingHistoryArchives[channelID] else { throw ChatAPIError.connection }
        let epoch = connectionGeneration
        channelManagementBusy = true
        defer { if epoch == connectionGeneration { channelManagementBusy = false } }
        return try await confirmHistoryArchive(pending,epoch:epoch)
    }
    private func confirmHistoryArchive(_ preparation:ChatHistoryArchivePreparation,epoch:Int) async throws -> ChatArchive {
        guard client != nil,preparation.accountGeneration == accountGeneration else { throw CancellationError() }
        let archives = try await archivePeriodsForChannel(channel:preparation.channel,epoch:epoch)
        let matches = archives.filter { !preparation.priorArchiveIDs.contains($0.id) && $0.props.channel.id == preparation.channel.id && $0.props.reason == "user_trigger" && $0.isReadable && $0.post_id_start <= preparation.latestPostID && $0.post_id_end >= preparation.latestPostID }
        guard matches.count == 1,let receipt = matches.first else { throw ChatTransferError(message:"No unique archive receipt is available yet. The request remains unconfirmed; check Archive history before taking further action.") }
        try forgetChannelAction(.init(kind:.archive,channelID:preparation.channel.id,channelType:preparation.channel.type,encrypted:preparation.channel.encrypted,latestPostID:preparation.latestPostID,priorArchiveIDs:preparation.priorArchiveIDs.sorted()))
        pendingHistoryArchives[preparation.channel.id] = nil
        let cached = posts + replies + imageViewerPosts + [threadRoot,documentPreviewPost].compactMap { $0 }
        deletedPostIDs.formUnion(cached.filter { $0.channel_id == preparation.channel.id && $0.id <= receipt.post_id_end }.map(\.id))
        if selection == preparation.channel.id { closeDocumentPreview();pendingLocation = nil;loadSelection() }
        refreshChannels()
        return receipt
    }
}


extension NativeChatPreviewModel {
    func canCloseChannel(_ channel:ChatChannel) -> Bool {
        canInteract && !sending && !uploading && !isEditingMessage && !channelManagementBusy && !conversationOrganizationBusy
            && channelActionRecoveryError == nil && channel.supportsClosing && !knownClosedChannelIDs.contains(channel.id)
            && pendingChannelClosures[channel.id] == nil && pendingHistoryArchives[channel.id] == nil
            && channelPermissions?.allows("channel_close") == true
    }
    private func archivePeriodsForChannel(channel:ChatChannel,epoch:Int) async throws -> [ChatArchive] {
        guard let kind = channel.archiveKind,let api = client else { throw ChatAPIError.invalidResponse }
        let names = try await api.archiveNames(kind:kind);try checkConversationSession(epoch)
        var result:[ChatArchive] = []
        for name in names {
            let periods = try await api.archives(kind:kind,name:name);try checkConversationSession(epoch)
            result += periods.filter { $0.props.channel.id == channel.id }
        }
        guard Set(result.map(\.id)).count == result.count else { throw ChatAPIError.invalidResponse }
        return result
    }
    func prepareChannelClose(channelID:Int64) async throws -> ChatChannelClosePreparation {
        guard canInteract,!sending,!uploading,!isEditingMessage,!channelManagementBusy,let api = client,
              pendingChannelClosures[channelID] == nil,pendingHistoryArchives[channelID] == nil,!knownClosedChannelIDs.contains(channelID),channelActionRecoveryError == nil else { throw ChatAPIError.connection }
        let epoch = connectionGeneration
        let acl = try await api.channelPermissions();try checkConversationSession(epoch)
        guard acl.allows("channel_close") else { throw ChatTransferError(message:"Your server permissions do not allow closing this channel.") }
        let joined = try await api.channels();try checkConversationSession(epoch)
        let channel = try await api.channelStatus(id:channelID);try checkConversationSession(epoch)
        guard Set(joined.map(\.id)).count == joined.count,joined.contains(where:{ $0.id == channelID }),channel.supportsClosing else { throw ChatTransferError(message:"This channel is no longer joined or available for closing.") }
        let periods = try await archivePeriodsForChannel(channel:channel,epoch:epoch)
        channelPermissions = acl
        return .init(channel:channel,priorArchiveIDs:Set(periods.map(\.id)),accountGeneration:accountGeneration)
    }
    @discardableResult func closeChannel(_ preparation:ChatChannelClosePreparation) async throws -> ChatArchive {
        guard preparation.accountGeneration == accountGeneration,canCloseChannel(preparation.channel),let api = client else { throw ChatAPIError.connection }
        let fresh = try await prepareChannelClose(channelID:preparation.channel.id)
        guard fresh.channel.name == preparation.channel.name,fresh.channel.type == preparation.channel.type,fresh.channel.encrypted == preparation.channel.encrypted,
              fresh.channel.total_member_count == preparation.channel.total_member_count,fresh.priorArchiveIDs == preparation.priorArchiveIDs else { throw ChatTransferError(message:"The channel changed. Refresh and review its details before closing.") }
        guard canCloseChannel(fresh.channel) else { throw ChatAPIError.connection }
        let epoch = connectionGeneration
        channelManagementBusy = true
        defer { if epoch == connectionGeneration { channelManagementBusy = false } }
        var dispatched = false
        do {
            try checkConversationSession(epoch)
            try rememberChannelAction(.init(kind:.close,channelID:fresh.channel.id,channelType:fresh.channel.type,encrypted:fresh.channel.encrypted,latestPostID:nil,priorArchiveIDs:fresh.priorArchiveIDs.sorted()))
            pendingChannelClosures[fresh.channel.id] = fresh
            dispatched = true
            try await api.closeChatChannel(fresh.channel);try checkConversationSession(epoch)
            return try await confirmChannelClose(fresh,epoch:epoch)
        } catch {
            guard epoch == connectionGeneration else { throw CancellationError() }
            if !dispatched { throw error }
            throw ChatTransferError(message:"Closing could not be confirmed. Use Check close status; do not repeat this request. Check the conversation list and Archive history before taking further action.")
        }
    }
    func checkChannelClose(channelID:Int64) async throws -> ChatArchive {
        guard connected,!channelManagementBusy,let pending = pendingChannelClosures[channelID] else { throw ChatAPIError.connection }
        let epoch = connectionGeneration;channelManagementBusy = true
        defer { if epoch == connectionGeneration { channelManagementBusy = false } }
        return try await confirmChannelClose(pending,epoch:epoch)
    }
    private func confirmChannelClose(_ preparation:ChatChannelClosePreparation,epoch:Int) async throws -> ChatArchive {
        guard let api = client,preparation.accountGeneration == accountGeneration else { throw CancellationError() }
        let joined = try await api.channels();try checkConversationSession(epoch)
        guard Set(joined.map(\.id)).count == joined.count,!joined.contains(where:{ $0.id == preparation.channel.id }) else { throw ChatTransferError(message:"The channel is still listed. Closing remains unconfirmed; check its status again.") }
        let periods = try await archivePeriodsForChannel(channel:preparation.channel,epoch:epoch)
        let matches = periods.filter { !preparation.priorArchiveIDs.contains($0.id) && $0.props.reason == "channel_closed" && $0.props.channel.type == preparation.channel.type && $0.props.channel.encrypted == preparation.channel.encrypted }
        guard matches.count == 1,let receipt = matches.first else { throw ChatTransferError(message:"The channel is no longer listed, but no unique closed-channel archive is available. Closing remains unconfirmed; check Archive history.") }
        try forgetChannelAction(.init(kind:.close,channelID:preparation.channel.id,channelType:preparation.channel.type,encrypted:preparation.channel.encrypted,latestPostID:nil,priorArchiveIDs:preparation.priorArchiveIDs.sorted()))
        pendingChannelClosures[preparation.channel.id] = nil
        invalidateClosedChannel(preparation.channel.id)
        return receipt
    }
    private func invalidateClosedChannel(_ id:Int64) {
        knownClosedChannelIDs.insert(id)
        channels.removeAll { $0.id == id }
        if selection == id {
            closeDocumentPreview();pendingLocation = nil;selection = nil;loadSelection()
        } else {
            if documentPreviewPost?.channel_id == id { closeDocumentPreview() }
            if imageViewerPost?.channel_id == id { closeImageViewer() }
            if threadRoot?.channel_id == id { closeThread() }
        }
    }
}


extension NativeChatPreviewModel {
    /// Called only after a coherent, authenticated account snapshot is available.
    var canRetryChannelActionRecovery:Bool { connected && !channelManagementBusy && channelActionScope != nil }
    func retryChannelActionRecovery() {
        guard canRetryChannelActionRecovery,let scope = channelActionScope else { return }
        restoreChannelActions(scope:scope,loaded:channels)
    }
    func restoreChannelActions(scope:String,loaded:[ChatChannel]) {
        channelActionScope = scope
        pendingHistoryArchives = [:];pendingChannelClosures = [:]
        do {
            let records = try channelActionJournal.activate(scope:scope)
            var archives:[Int64:ChatHistoryArchivePreparation] = [:],closures:[Int64:ChatChannelClosePreparation] = [:]
            for record in records {
                let channel = try record.channel(loaded:loaded)
                switch record.kind {
                case .archive: archives[channel.id] = .init(channel:channel,latestPostID:record.latestPostID!,priorArchiveIDs:Set(record.priorArchiveIDs),accountGeneration:accountGeneration)
                case .close: closures[channel.id] = .init(channel:channel,priorArchiveIDs:Set(record.priorArchiveIDs),accountGeneration:accountGeneration)
                }
            }
            pendingHistoryArchives = archives;pendingChannelClosures = closures;channelActionRecoveryError = nil
        } catch {
            channelActionRecoveryError = "Could not read pending channel actions. Archiving and closing are disabled; the saved record has been preserved."
        }
    }
    private func rememberChannelAction(_ record:ChatChannelActionRecord) throws {
        do { try channelActionJournal.remember(record) }
        catch { channelActionRecoveryError = "Could not save the pending channel action. No request was sent. Archiving and closing are disabled.";throw ChatTransferError(message:channelActionRecoveryError!) }
    }
    private func forgetChannelAction(_ record:ChatChannelActionRecord) throws {
        do { try channelActionJournal.remove(record);channelActionRecoveryError = nil }
        catch { channelActionRecoveryError = "The server result was confirmed, but its local recovery record could not be updated. Check status again after local storage is available.";throw ChatTransferError(message:channelActionRecoveryError!) }
    }
}


extension NativeChatPreviewModel {
    func loadNotificationSettings() async throws -> ChatNotificationSettingsSnapshot {
        guard connected,!notificationPreferencesBusy,let api = client else { throw ChatAPIError.connection }
        let epoch = connectionGeneration
        notificationPreferencesBusy = true
        defer { if epoch == connectionGeneration { notificationPreferencesBusy = false } }
        let settings = try await api.notificationSettings();try checkConversationSession(epoch)
        let clock = try await api.serverClock();try checkConversationSession(epoch)
        notificationPreferencesNeedRefresh = false
        return .init(settings:settings,clock:clock,timeZone:directory.first(where:{ $0.user_id == currentUserID })?.profileTimeZone,accountGeneration:accountGeneration)
    }
    func saveNotificationSettings(original:ChatNotificationSettingsSnapshot,draft:ChatNotificationSettingsDraft) async throws -> ChatNotificationSettingsSnapshot {
        let patch = try draft.patch(from:original.settings)
        guard !patch.isEmpty else { throw ChatAPIError.invalidResponse }
        var conflictKeys = Set(patch.keys)
        if patch["snooze_schedule_enable"] != nil {
            guard original.timeZone == directory.first(where:{ $0.user_id == currentUserID })?.profileTimeZone else { throw ChatPreferenceUpdateFailure(uncertain:false,message:"Your account time zone changed. Refresh before saving this schedule.") }
            conflictKeys.formUnion(["snooze_schedule_enable","snooze_schedule_start","snooze_schedule_end"])
        }
        return try await updateNotificationSettings(original:original,conflictKeys:conflictKeys) { _ in patch }
    }
    func setNotificationSnooze(minutes:Int,original:ChatNotificationSettingsSnapshot) async throws -> ChatNotificationSettingsSnapshot {
        guard [0,20,60,120,240,480,1440].contains(minutes) else { throw ChatAPIError.invalidResponse }
        return try await updateNotificationSettings(original:original,conflictKeys:["snooze"]) { clock in
            ["snooze":.integer(minutes == 0 ? 0 : clock.milliseconds()+Int64(minutes)*60_000)]
        }
    }
    private func updateNotificationSettings(original:ChatNotificationSettingsSnapshot,conflictKeys:Set<String>,patch:(ChatServerClock)->[String:ChatParameter]) async throws -> ChatNotificationSettingsSnapshot {
        guard connected,!notificationPreferencesBusy,!notificationPreferencesNeedRefresh,original.accountGeneration == accountGeneration,let api = client else { throw ChatAPIError.connection }
        let epoch = connectionGeneration;notificationPreferencesBusy = true
        defer { if epoch == connectionGeneration { notificationPreferencesBusy = false } }
        var dispatched = false
        do {
            let current = try await api.notificationSettings();try checkConversationSession(epoch)
            guard current.matches(original.settings,keys:conflictKeys) else { throw ChatPreferenceUpdateFailure(uncertain:false,message:"These preferences changed in another client. Refresh before saving.") }
            let clock = try await api.serverClock();try checkConversationSession(epoch)
            let values = patch(clock)
            dispatched = true;try await api.setNotificationSettings(values);try checkConversationSession(epoch)
            let after = try await api.notificationSettings();try checkConversationSession(epoch)
            guard values.allSatisfy({ key,value in (try? JSONEncoder().encode(after.fields[key])) == (try? JSONEncoder().encode(Optional(value))) }) else { throw ChatAPIError.invalidResponse }
            return .init(settings:after,clock:clock,timeZone:original.timeZone,accountGeneration:accountGeneration)
        } catch {
            guard epoch == connectionGeneration else { throw CancellationError() }
            if dispatched { notificationPreferencesNeedRefresh = true;throw ChatPreferenceUpdateFailure(uncertain:true,message:"The preference change could not be confirmed. Refresh to check the server before trying again.") }
            throw error
        }
    }
}


extension NativeChatPreviewModel {
    func loadManualPresence() async throws -> ChatManualPresenceSnapshot {
        guard connected,!manualPresenceBusy,currentUserID != nil else { throw ChatAPIError.connection }
        let epoch = connectionGeneration;manualPresenceBusy = true
        defer { if epoch == connectionGeneration { manualPresenceBusy = false } }
        try await refreshUserProfiles();try checkConversationSession(epoch)
        guard let userID = currentUserID,let away = manualAway else { throw ChatTransferError(message:"This server did not provide your manual availability setting.") }
        manualPresenceNeedsRefresh = false
        return .init(userID:userID,away:away,accountGeneration:accountGeneration)
    }
    func setManualPresence(away:Bool,original:ChatManualPresenceSnapshot) async throws -> ChatManualPresenceSnapshot {
        guard connected,!manualPresenceBusy,!manualPresenceNeedsRefresh,original.accountGeneration == accountGeneration,original.userID == currentUserID,let api = client else { throw ChatAPIError.connection }
        let epoch = connectionGeneration;manualPresenceBusy = true
        defer { if epoch == connectionGeneration { manualPresenceBusy = false } }
        var dispatched = false
        do {
            try await refreshUserProfiles();try checkConversationSession(epoch)
            guard let current = manualAway else { throw ChatTransferError(message:"Manual availability is unavailable. Refresh before trying again.") }
            guard current == original.away else { throw ChatManualPresenceFailure(uncertain:false,message:"Your availability changed in another client. Refresh before changing it.") }
            if current != away {
                dispatched = true;try await api.setManualAway(away);try checkConversationSession(epoch)
                try await refreshUserProfiles();try checkConversationSession(epoch)
            }
            guard manualAway == away else { throw ChatAPIError.invalidResponse }
            return .init(userID:original.userID,away:away,accountGeneration:accountGeneration)
        } catch {
            guard epoch == connectionGeneration else { throw CancellationError() }
            if dispatched { manualPresenceNeedsRefresh = true;throw ChatManualPresenceFailure(uncertain:true,message:"Your availability change could not be confirmed. Refresh to check the server before trying again.") }
            throw error
        }
    }
}


extension NativeChatPreviewModel {
    private func profileEditSnapshot(policy:ChatProfileEditingPolicy) throws -> ChatProfileEditSnapshot {
        guard let id = currentUserID,let user = directory.first(where:{ $0.user_id == id }),let description = user.user_props?.description else { throw ChatTransferError(message:"Your editable profile could not be loaded from this server.") }
        return .init(userID:id,nickname:user.nickname,description:description,policy:policy,accountGeneration:accountGeneration,avatarVersion:user.avatar_version)
    }
    func loadEditableProfile() async throws -> ChatProfileEditSnapshot {
        guard connected,!profileEditingBusy,let api = client else { throw ChatAPIError.connection }
        let epoch = connectionGeneration;profileEditingBusy = true
        defer { if epoch == connectionGeneration { profileEditingBusy = false } }
        let policy = try await api.profileEditingPolicy();try checkConversationSession(epoch)
        try await refreshUserProfiles();try checkConversationSession(epoch)
        let snapshot = try profileEditSnapshot(policy:policy);profileEditingNeedsRefresh = false;return snapshot
    }
    func saveProfileText(_ draft:ChatProfileTextDraft,original:ChatProfileEditSnapshot) async throws -> ChatProfileEditSnapshot {
        guard connected,!profileEditingBusy,!profileEditingNeedsRefresh,original.accountGeneration == accountGeneration,original.userID == currentUserID,let api = client else { throw ChatAPIError.connection }
        let patch = try draft.patch(from:original),epoch = connectionGeneration;profileEditingBusy = true
        defer { if epoch == connectionGeneration { profileEditingBusy = false } }
        var dispatched = false
        do {
            let policy = try await api.profileEditingPolicy();try checkConversationSession(epoch)
            try await refreshUserProfiles();try checkConversationSession(epoch)
            let fresh = try profileEditSnapshot(policy:policy)
            for field in patch.keys {
                guard policy.allows(field) else { throw ChatProfileEditFailure(uncertain:false,message:"Your administrator now manages this field. Refresh your profile.") }
                guard field == "nickname" ? fresh.nickname == original.nickname : fresh.description == original.description else { throw ChatProfileEditFailure(uncertain:false,message:"Your profile changed in another client. Refresh before saving.") }
            }
            if !patch.isEmpty {
                dispatched = true;try await api.setProfileText(patch);try checkConversationSession(epoch)
                try await refreshUserProfiles();try checkConversationSession(epoch)
            }
            let result = try profileEditSnapshot(policy:policy)
            for (field,value) in patch {
                guard case .string(let desired) = value,(field == "nickname" ? result.nickname : result.description) == desired else { throw ChatAPIError.invalidResponse }
            }
            return result
        } catch {
            guard epoch == connectionGeneration else { throw CancellationError() }
            if dispatched { profileEditingNeedsRefresh = true;throw ChatProfileEditFailure(uncertain:true,message:"Your profile change could not be confirmed. Refresh to check the server before trying again.") }
            throw error
        }
    }
}

extension NativeChatPreviewModel {
    func loadEditableProfilePhoto() async throws -> ChatProfilePhotoSnapshot {
        let epoch = accountGeneration,requiredRefresh = profileEditingNeedsRefresh
        do {
        let profile = try await loadEditableProfile();try checkConversationSession(epoch)
        guard let version = profile.avatarVersion,version >= 0,let api = client,!profileEditingBusy else { throw ChatTransferError(message:"Your profile photo information is unavailable.") }
        profileEditingBusy = true
        defer { if epoch == accountGeneration { profileEditingBusy = false } }
        let data = version > 0 ? try await api.avatarData(userID:profile.userID,size:.large,version:version) : nil
        try checkConversationSession(epoch)
        if let data,NativeAvatarStore.decode(data,maximumPixelSize:512) == nil { throw ChatAPIError.invalidResponse }
        return .init(profile:profile,image:data)
        } catch {
            if epoch == accountGeneration,requiredRefresh { profileEditingNeedsRefresh = true }
            throw error
        }
    }
    func saveProfilePhoto(_ png:Data?,original:ChatProfileEditSnapshot) async throws -> ChatProfilePhotoSnapshot {
        guard connected,!profileEditingBusy,!profileEditingNeedsRefresh,original.accountGeneration == accountGeneration,original.userID == currentUserID,original.avatarVersion != nil,let api = client else { throw ChatAPIError.connection }
        if let png { guard let image = NativeAvatarStore.decode(png,maximumPixelSize:512),image.size.width == 256,image.size.height == 256 else { throw ChatAPIError.invalidResponse } }
        let epoch = accountGeneration;profileEditingBusy = true
        defer { if epoch == accountGeneration { profileEditingBusy = false } }
        var dispatched = false
        do {
            let policy = try await api.profileEditingPolicy();try checkConversationSession(epoch)
            guard policy.allows("avatar") else { throw ChatTransferError(message:"Your administrator manages your profile photo.") }
            try await refreshUserProfiles();try checkConversationSession(epoch)
            let fresh = try profileEditSnapshot(policy:policy)
            guard fresh.avatarVersion == original.avatarVersion else { throw ChatProfileEditFailure(uncertain:false,message:"Your profile photo changed in another client. Refresh before changing it.") }
            if png != nil || fresh.avatarVersion != 0 {
                dispatched = true
                if let png { try await api.uploadProfilePhoto(png) } else { try await api.removeProfilePhoto() }
                try checkConversationSession(epoch);try await refreshUserProfiles();try checkConversationSession(epoch)
            }
            let result = try profileEditSnapshot(policy:policy)
            guard let version = result.avatarVersion,png == nil ? version == 0 : version > 0 && version != original.avatarVersion else { throw ChatAPIError.invalidResponse }
            let canonical = version > 0 ? try await api.avatarData(userID:result.userID,size:.large,version:version) : nil
            try checkConversationSession(epoch)
            if let canonical,NativeAvatarStore.decode(canonical,maximumPixelSize:512) == nil { throw ChatAPIError.invalidResponse }
            return .init(profile:result,image:canonical)
        } catch {
            guard epoch == accountGeneration else { throw CancellationError() }
            if dispatched { profileEditingNeedsRefresh = true;throw ChatProfileEditFailure(uncertain:true,message:"Your profile photo change could not be confirmed. Refresh to see the server photo before trying again.") }
            throw error
        }
    }
}


extension NativeChatPreviewModel {
    func loadPairedDevices() async throws -> ChatPairedDevicesSnapshot {
        guard connected,!pairedDevicesBusy,let api = client else { throw ChatAPIError.connection }
        let epoch = accountGeneration;pairedDevicesBusy = true
        defer { if epoch == accountGeneration { pairedDevicesBusy = false } }
        let devices = try await api.pairedNotificationDevices();try checkConversationSession(epoch)
        pairedDevicesNeedRefresh = false;return .init(devices:devices,accountGeneration:epoch)
    }
    func unpairDevice(_ device:ChatPairedDevice,original:ChatPairedDevicesSnapshot) async throws -> ChatPairedDevicesSnapshot {
        guard connected,!pairedDevicesBusy,!pairedDevicesNeedRefresh,original.accountGeneration == accountGeneration,original.devices.contains(device),let api = client else { throw ChatAPIError.connection }
        let epoch = accountGeneration;pairedDevicesBusy = true
        defer { if epoch == accountGeneration { pairedDevicesBusy = false } }
        var dispatched = false
        do {
            let current = try await api.pairedNotificationDevices();try checkConversationSession(epoch)
            if let fresh = current.first(where:{ $0.id == device.id }) {
                guard fresh == device else { throw ChatDeviceUpdateFailure(uncertain:false,message:"This device changed since you opened the list. Refresh before unpairing it.") }
                dispatched = true;try await api.unpairNotificationDevice(fresh);try checkConversationSession(epoch)
                let result = try await api.pairedNotificationDevices();try checkConversationSession(epoch)
                guard !result.contains(where:{ $0.id == device.id }) else { throw ChatAPIError.invalidResponse }
                return .init(devices:result,accountGeneration:epoch)
            }
            return .init(devices:current,accountGeneration:epoch)
        } catch {
            guard epoch == accountGeneration else { throw CancellationError() }
            if dispatched { pairedDevicesNeedRefresh = true;throw ChatDeviceUpdateFailure(uncertain:true,message:"Unpairing could not be confirmed. Refresh the device list before trying again.") }
            throw error
        }
    }
}


extension NativeChatPreviewModel {
    func archivePeriodPresentation(_ archive:ChatArchive) -> ChatArchivePeriodPresentation {
        .init(archive:archive,regional:regionalDisplay)
    }
    func formattedDate(_ date:Date,dateOnly:Bool = false,timeOnly:Bool = false) -> String {
        if let regionalDisplay { return regionalDisplay.format(date,dateOnly:dateOnly,timeOnly:timeOnly) }
        return date.formatted(date:timeOnly ? .omitted : .abbreviated,time:dateOnly ? .omitted : .shortened)
    }
    private func readRegionalSettings(_ api:ChatAPIClient,epoch:Int) async throws -> ChatRegionalSnapshot {
        let personal = try await api.desktopPersonalSettings();try checkConversationSession(epoch)
        let defaults = try await api.regionalDefaults();try checkConversationSession(epoch)
        let zones = try await api.regionalTimeZones();try checkConversationSession(epoch)
        let policy = try await api.profileEditingPolicy();try checkConversationSession(epoch)
        do { try await refreshUserProfiles() }
        catch is CancellationError {
            // A later socket-driven profile read may supersede this one. One fresh
            // read is safe; never retry a mutation or a cancelled/account-old task.
            try checkConversationSession(epoch);try Task.checkCancellation()
            try await refreshUserProfiles()
        }
        try checkConversationSession(epoch)
        guard let id = currentUserID,let timezone = directory.first(where:{$0.user_id == id})?.user_props?.timezone else { throw ChatAPIError.invalidResponse }
        return .init(personal:personal,defaults:defaults,zones:zones,userID:id,timezone:timezone,policy:policy,accountGeneration:epoch)
    }
    func loadRegionalSettings() async throws -> ChatRegionalSnapshot {
        guard connected,!regionalSettingsBusy,let api = client else { throw ChatAPIError.connection }
        let epoch = accountGeneration;regionalSettingsBusy = true
        defer { if epoch == accountGeneration { regionalSettingsBusy = false } }
        let result = try await readRegionalSettings(api,epoch:epoch);regionalSettingsNeedRefresh = false;regionalDisplay = result.display;return result
    }
    func saveRegionalSettings(_ draft:ChatRegionalDraft,original:ChatRegionalSnapshot) async throws -> ChatRegionalSnapshot {
        guard connected,!regionalSettingsBusy,!regionalSettingsNeedRefresh,original.accountGeneration == accountGeneration,original.userID == currentUserID,let api = client else { throw ChatAPIError.connection }
        let patch = try draft.changes(from:original.personal),epoch = accountGeneration;regionalSettingsBusy = true
        defer { if epoch == accountGeneration { regionalSettingsBusy = false } }
        var dispatched = false
        do {
            let fresh = try await api.desktopPersonalSettings();try checkConversationSession(epoch)
            var merged = fresh.Personal
            for (key,value) in patch {
                guard fresh.Personal[key] == original.personal.Personal[key] else { throw ChatTransferError(message:"These regional preferences changed elsewhere. Refresh before saving.") }
                merged[key] = .string(value)
            }
            if !patch.isEmpty { dispatched = true;try await api.applyDesktopPersonalSettings(merged);try checkConversationSession(epoch) }
            let result = try await readRegionalSettings(api,epoch:epoch)
            for (key,value) in patch { guard result.personal.Personal[key] == .string(value) else { throw ChatAPIError.invalidResponse } }
            regionalDisplay = result.display;return result
        } catch {
            guard epoch == accountGeneration else { throw CancellationError() }
            if dispatched { regionalSettingsNeedRefresh = true;throw ChatTransferError(message:"The regional preference change could not be confirmed. Refresh before trying again.") };throw error
        }
    }
    func saveRegionalTimeZone(_ value:String,original:ChatRegionalSnapshot) async throws -> ChatRegionalSnapshot {
        guard connected,!regionalSettingsBusy,!regionalSettingsNeedRefresh,original.accountGeneration == accountGeneration,original.userID == currentUserID,let api = client else { throw ChatAPIError.connection }
        let epoch = accountGeneration;regionalSettingsBusy = true
        defer { if epoch == accountGeneration { regionalSettingsBusy = false } }
        var dispatched = false
        do {
            let fresh = try await readRegionalSettings(api,epoch:epoch)
            guard fresh.timezone == original.timezone,fresh.policy.allows("timezone"),value == "def" || fresh.zones.contains(where:{$0.value == value}) else { throw ChatTransferError(message:"The timezone or its available choices changed. Refresh before saving.") }
            if value != fresh.selectedTimeZone { dispatched = true;try await api.setProfileTimeZone(value);try checkConversationSession(epoch) }
            let result = try await readRegionalSettings(api,epoch:epoch)
            guard result.selectedTimeZone == value else { throw ChatAPIError.invalidResponse };regionalDisplay = result.display;return result
        } catch {
            guard epoch == accountGeneration else { throw CancellationError() }
            if dispatched { regionalSettingsNeedRefresh = true;throw ChatTransferError(message:"The timezone change could not be confirmed. Refresh before trying again.") };throw error
        }
    }
}


extension NativeChatPreviewModel {
    func launcherCanOpen(_ app:ChatLauncherApplication)->Bool {connected && client?.launcherURL(for:app) != nil}
    func loadLauncherApplications() async throws -> ChatLauncherSnapshot {
        guard connected,!launcherBusy,let api = client else {throw ChatAPIError.connection}
        let epoch = accountGeneration;launcherBusy = true
        defer {if epoch == accountGeneration {launcherBusy = false}}
        let applications = try await api.launcherApplications();try checkConversationSession(epoch)
        launcherNeedsRefresh = false;return .init(applications:applications,accountGeneration:epoch)
    }
    func resolveLauncherApplication(_ app:ChatLauncherApplication,original:ChatLauncherSnapshot) async throws -> URL {
        guard connected,!launcherBusy,!launcherNeedsRefresh,original.accountGeneration == accountGeneration,original.applications.contains(app),let api = client else {throw ChatAPIError.connection}
        let epoch = accountGeneration;launcherBusy = true
        defer {if epoch == accountGeneration {launcherBusy = false}}
        let fresh = try await api.launcherApplications();try checkConversationSession(epoch)
        guard let current = fresh.first(where:{$0.appname == app.appname}),current.type == app.type,current.launch_url == app.launch_url,let url = api.launcherURL(for:current) else {throw ChatTransferError(message:"This application or its launch route changed. Refresh the list. Unsupported routes can be opened from the official client.")}
        return url
    }
    func saveLauncherOrder(_ names:[String],original:ChatLauncherSnapshot) async throws -> ChatLauncherSnapshot {
        guard connected,!launcherBusy,!launcherNeedsRefresh,original.accountGeneration == accountGeneration,!names.isEmpty,Set(names) == Set(original.applications.map(\.appname)),names.count == original.applications.count,let api = client else {throw ChatAPIError.connection}
        let epoch = accountGeneration;launcherBusy = true
        defer {if epoch == accountGeneration {launcherBusy = false}}
        var dispatched = false
        do {
            let fresh = try await api.launcherApplications();try checkConversationSession(epoch)
            guard fresh.map(\.appname) == original.applications.map(\.appname) else {throw ChatTransferError(message:"The application list or order changed elsewhere. Refresh before saving your order.")}
            if names != fresh.map(\.appname) {dispatched = true;try await api.setLauncherOrder(names);try checkConversationSession(epoch)}
            let result = try await api.launcherApplications();try checkConversationSession(epoch)
            guard result.map(\.appname) == names else {throw ChatAPIError.invalidResponse}
            return .init(applications:result,accountGeneration:epoch)
        } catch {
            guard epoch == accountGeneration else {throw CancellationError()}
            if dispatched {launcherNeedsRefresh = true;throw ChatTransferError(message:"The application order could not be confirmed. Refresh before changing it again.")};throw error
        }
    }
}


extension NativeChatPreviewModel {
    func canChooseNASFiles(inThread:Bool = false)->Bool {
        guard canInteract,!preparingComposerAttachment,!sending,!isEditingMessage,let channel = selectedChannel,!channel.encrypted,canRead(channel.id),let own = directory.first(where:{$0.user_id == currentUserID}),own.type == "human",own.human_type == "dsm" else {return false}
        return !inThread || canComposeInThread
    }
    private func checkNASContext(channelID:Int64,rootID:Int64?,epoch:Int) throws {
        try checkConversationSession(epoch)
        guard selection == channelID,selectedChannel?.encrypted == false,canRead(channelID),!isEditingMessage,rootID == nil || (threadRoot?.id == rootID && threadRoot?.channel_id == channelID) else {throw ChatTransferError(message:"The conversation changed. Reopen the NAS picker before continuing.")}
    }
    func loadNASRoots(channelID:Int64,rootID:Int64?,epoch:Int) async throws -> [ChatNASRoot] {
        guard canChooseNASFiles(inThread:rootID != nil),let api = client else {throw ChatAPIError.connection}
        try checkNASContext(channelID:channelID,rootID:rootID,epoch:epoch)
        let policy = try await api.nasUploadPolicy();try checkNASContext(channelID:channelID,rootID:rootID,epoch:epoch)
        guard policy.allow_ds_upload else {throw ChatTransferError(message:"Your server administrator has disabled NAS attachments.")}
        let roots = try await api.nasRoots();try checkNASContext(channelID:channelID,rootID:rootID,epoch:epoch);return roots
    }
    func loadNASFiles(folder:String,offset:Int,channelID:Int64,rootID:Int64?,epoch:Int) async throws -> ChatNASPage {
        guard canChooseNASFiles(inThread:rootID != nil),let api = client else {throw ChatAPIError.connection}
        try checkNASContext(channelID:channelID,rootID:rootID,epoch:epoch)
        let policy = try await api.nasUploadPolicy();try checkNASContext(channelID:channelID,rootID:rootID,epoch:epoch)
        guard policy.allow_ds_upload else {throw ChatTransferError(message:"Your server administrator has disabled NAS attachments.")}
        let result = try await api.nasFiles(folder:folder,offset:offset);try checkNASContext(channelID:channelID,rootID:rootID,epoch:epoch);return result
    }
    func stageNASFiles(_ selection:ChatNASSelection) {
        guard canChooseNASFiles(inThread:selection.rootID != nil),selection.accountGeneration == accountGeneration,self.selection == selection.channelID,selection.rootID == nil || threadRoot?.id == selection.rootID,let channel = selectedChannel else {return}
        guard !selection.files.isEmpty else {error = "Choose NAS files to attach.";return}
        let caption = selection.rootID == nil ? draft : replyDraft
        guard ChatMessageText.isAllowed(caption) else {return}
        if let batch = attachmentBatch {
            guard batch.channelID == channel.id,batch.rootID == selection.rootID,attachmentBatchSession == connectionGeneration,!batch.encrypted else {return}
            guard batch.appendNAS(selection.files) else {error = batch.validationError ?? "Could not add these NAS files. No files were added.";return}
        } else {
            let batch = NativeAttachmentBatch(files:[],caption:caption,channelID:channel.id,channelTitle:title(channel),rootID:selection.rootID,encrypted:false,keyEnvelope:channel.channel_key_enc)
            guard batch.appendNAS(selection.files) else {error = batch.validationError ?? "Could not add these NAS files. No files were added.";return}
            attachmentBatch = batch;attachmentBatchSession = connectionGeneration
        }
        error = nil;updateReadingVisibility(active:false,atBottom:false);updateThreadReadingVisibility(active:false,atBottom:false)
    }
    func sendReviewedNASFile(_ file:ChatNASFile,batch:NativeAttachmentBatch,caption:String,connectionID:String,epoch:Int) async throws -> ChatPost {
        guard let api = client else {throw ChatNASPreflightFailure(message:"This NAS file was not sent. Reconnect before continuing.")}
        var dispatched = false
        do {
            try checkNASContext(channelID:batch.channelID,rootID:batch.rootID,epoch:epoch)
            let policy = try await api.nasUploadPolicy();try checkNASContext(channelID:batch.channelID,rootID:batch.rootID,epoch:epoch)
            let users = try await api.users();try checkNASContext(channelID:batch.channelID,rootID:batch.rootID,epoch:epoch)
            guard let own = users.first(where:{$0.user_id == currentUserID}),own.type == "human",own.human_type == "dsm" else {throw ChatTransferError(message:"NAS attachments are unavailable for this account.")}
            let channels = try await api.channels();try checkNASContext(channelID:batch.channelID,rootID:batch.rootID,epoch:epoch)
            guard channels.contains(where:{$0.id == batch.channelID && !$0.encrypted && $0.is_closed != true}) else {throw ChatTransferError(message:"This conversation no longer allows NAS attachments.")}
            let fresh = try await api.nasFileInfo(file.path);try checkNASContext(channelID:batch.channelID,rootID:batch.rootID,epoch:epoch)
            guard file.matchesForSend(fresh),policy.allows(fresh) else {throw ChatTransferError(message:"The NAS file, permission or size limit changed. Remove this file and select it again.")}
            dispatched = true
            let post = try await api.sendNASFile(fresh,channelID:batch.channelID,caption:caption,connectionID:connectionID,threadID:batch.rootID ?? 0)
            return post
        } catch {
            if !dispatched {throw ChatNASPreflightFailure(message:(error as? LocalizedError)?.errorDescription ?? "This NAS file was not sent. Select it again after checking the server.")}
            throw error
        }
    }
}

extension NativeChatPreviewModel {
    func canChooseDriveFiles(inThread:Bool = false)->Bool {canChooseNASFiles(inThread:inThread) && attachmentBatch == nil}
    private func checkDriveContext(channelID:Int64,rootID:Int64?,epoch:Int) throws {
        try checkConversationSession(epoch)
        guard canChooseDriveFiles(inThread:rootID != nil),selection == channelID,rootID == nil || threadRoot?.id == rootID else {throw ChatTransferError(message:"The conversation changed. Reopen the Drive picker before continuing.")}
    }
    func loadDriveFiles(location:ChatDriveLocation,folderID:String?,offset:Int,channelID:Int64,rootID:Int64?,epoch:Int,labelID:ChatDriveLabel.ID? = nil,query:String? = nil) async throws -> ChatDriveBrowsePage {
        try checkDriveContext(channelID:channelID,rootID:rootID,epoch:epoch)
        guard let api = client else {throw ChatAPIError.connection}
        _ = try await api.drivePolicy();try checkDriveContext(channelID:channelID,rootID:rootID,epoch:epoch)
        let page = try await api.driveFiles(location:location,folderID:folderID,offset:offset,labelID:labelID,query:query);try checkDriveContext(channelID:channelID,rootID:rootID,epoch:epoch);return page
    }
    private func driveRecipients(users:[ChatUser],memberIDs:[Int64])->[ChatDriveRecipient] {
        let members = users.filter {memberIDs.contains($0.user_id) && $0.user_id != currentUserID && $0.type == "human" && $0.human_type == "dsm" && $0.is_disabled != true && ($0.delete_at ?? 0) == 0}
        guard members.allSatisfy({($0.dsm_uid ?? 0) > 0 && !($0.username ?? "").isEmpty}),Set(members.compactMap(\.dsm_uid)).count == members.count else {return []}
        return members.map {.init(chatID:$0.user_id,uid:$0.dsm_uid!,username:$0.username!,name:displayName($0))}.sorted {$0.chatID < $1.chatID}
    }
    func reviewDriveFile(_ selected:ChatDriveFile,channelID:Int64,rootID:Int64?,epoch:Int) async throws -> ChatDriveReview {
        try checkDriveContext(channelID:channelID,rootID:rootID,epoch:epoch)
        guard let api = client else {throw ChatAPIError.connection}
        let policy = try await api.drivePolicy();try checkDriveContext(channelID:channelID,rootID:rootID,epoch:epoch)
        let file = try await api.driveFile(id:selected.id);try checkDriveContext(channelID:channelID,rootID:rootID,epoch:epoch)
        guard selected.sameSelection(file) else {throw ChatTransferError(message:"The file or its access changed. Refresh and select it again.")}
        let users = try await api.users();try checkDriveContext(channelID:channelID,rootID:rootID,epoch:epoch)
        let members = try await api.members(channelID:channelID);try checkDriveContext(channelID:channelID,rootID:rootID,epoch:epoch)
        return .init(file:file,policy:policy,recipients:driveRecipients(users:users,memberIDs:members),memberIDs:members.sorted(),accountGeneration:epoch,channelID:channelID,rootID:rootID)
    }
    func changeDriveAccess(_ review:ChatDriveReview,draft:ChatDriveAccessDraft) async throws -> ChatDriveReview {
        let channel = review.channelID,root = review.rootID,epoch = review.accountGeneration
        try checkDriveContext(channelID:channel,rootID:root,epoch:epoch)
        guard draft.scope != .keep,let api = client else {throw ChatAPIError.invalidResponse}
        let policy = try await api.drivePolicy();try checkDriveContext(channelID:channel,rootID:root,epoch:epoch)
        let users = try await api.users();try checkDriveContext(channelID:channel,rootID:root,epoch:epoch)
        guard users.contains(where:{$0.user_id == currentUserID && $0.type == "human" && $0.human_type == "dsm"}) else {throw ChatAPIError.invalidResponse}
        let channels = try await api.channels();try checkDriveContext(channelID:channel,rootID:root,epoch:epoch)
        guard channels.contains(where:{$0.id == channel && !$0.encrypted && $0.is_closed != true}) else {throw ChatAPIError.invalidResponse}
        let members = try await api.members(channelID:channel);try checkDriveContext(channelID:channel,rootID:root,epoch:epoch)
        let recipients = driveRecipients(users:users,memberIDs:members)
        guard members.sorted() == review.memberIDs,recipients == review.recipients else {throw ChatTransferError(message:"Conversation members changed. Refresh and review access again.")}
        let file = try await api.driveFile(id:review.file.id);try checkDriveContext(channelID:channel,rootID:root,epoch:epoch)
        guard review.file.sameSelection(file),let edits = file.permissionEdits(draft,recipients:recipients,policy:policy),!edits.isEmpty else {throw ChatTransferError(message:"File access or server policy changed. Refresh before continuing.")}
        try await api.updateDriveAccess(id:file.id,edits:edits)
        try checkDriveContext(channelID:channel,rootID:root,epoch:epoch)
        let receipt = try await api.driveFile(id:file.id);try checkDriveContext(channelID:channel,rootID:root,epoch:epoch)
        guard receipt.selectable,receipt.name == file.name,receipt.type == file.type,receipt.hash == file.hash,receipt.size == file.size,receipt.confirms(draft,recipients:recipients),receipt.unrelatedPermissionsMatch(file,draft:draft,recipients:recipients) else {throw ChatTransferError(message:"The server has not confirmed the access change. Refresh to inspect current access; do not repeat automatically.")}
        return .init(file:receipt,policy:policy,recipients:recipients,memberIDs:members.sorted(),accountGeneration:epoch,channelID:channel,rootID:root)
    }
    func insertDriveLink(_ review:ChatDriveReview) async throws {
        let channel = review.channelID,root = review.rootID,epoch = review.accountGeneration
        try checkDriveContext(channelID:channel,rootID:root,epoch:epoch)
        guard let api = client else {throw ChatAPIError.connection}
        let original = root == nil ? draft : replyDraft
        _ = try await api.drivePolicy();try checkDriveContext(channelID:channel,rootID:root,epoch:epoch)
        let users = try await api.users();try checkDriveContext(channelID:channel,rootID:root,epoch:epoch)
        guard users.contains(where:{$0.user_id == currentUserID && $0.type == "human" && $0.human_type == "dsm"}) else {throw ChatTransferError(message:"Drive sharing is unavailable for this account.")}
        let channels = try await api.channels();try checkDriveContext(channelID:channel,rootID:root,epoch:epoch)
        guard channels.contains(where:{$0.id == channel && !$0.encrypted && $0.is_closed != true}) else {throw ChatTransferError(message:"Drive sharing is unavailable in this conversation.")}
        let file = try await api.driveFile(id:review.file.id);try checkDriveContext(channelID:channel,rootID:root,epoch:epoch)
        guard review.file.sameSelection(file) else {throw ChatTransferError(message:"The file or its access changed. Refresh and review it again.")}
        let url = try await api.createDriveLink(id:file.id);try checkDriveContext(channelID:channel,rootID:root,epoch:epoch)
        guard (root == nil ? draft : replyDraft) == original else {throw ChatTransferError(message:"Your message changed while creating the link. Refresh and review the file again.")}
        let text = original+(original.isEmpty ? "" : "\n")+url.absoluteString
        guard ChatMessageText.isAllowed(text) else {throw ChatTransferError(message:"The link would exceed the message limit. Shorten your message and review again.")}
        if root == nil {draft = text} else {replyDraft = text}
    }
}


struct NativeCalendarSnapshot {
    let calendars: [ChatCalendar]
    let timeZoneID: String
    let accountGeneration: Int
    let channelID: Int64
    let postID: Int64
}
extension NativeChatPreviewModel {
    func ensureCalendarDetection() async {
        guard connected, let api = client else { return }
        let epoch = accountGeneration,revision = calendarPreferenceReadRevision
        guard !calendarSettingsBusy else { return }
        if calendarDetectionTask == nil {
            calendarDetectionTask = Task { try? await api.calendarDetectionEnabled() }
        }
        let value = await calendarDetectionTask?.value
        guard connected, epoch == accountGeneration,revision == calendarPreferenceReadRevision,!calendarSettingsBusy else { return }
        calendarDetection = value ?? nil
    }
    func loadCalendarDetectionPreference() async throws -> NativeCalendarPreferenceSnapshot {
        guard connected,!calendarSettingsBusy,let api = client else { throw ChatAPIError.connection }
        let epoch = accountGeneration;calendarSettingsBusy = true;calendarPreferenceReadRevision = UUID()
        calendarDetectionTask?.cancel();calendarDetectionTask = nil
        defer { if accountGeneration == epoch { calendarSettingsBusy = false } }
        let enabled = try await api.calendarDetectionEnabled();try checkConversationSession(epoch)
        calendarDetection = enabled;calendarSettingsNeedRefresh = false
        return .init(enabled:enabled,accountGeneration:epoch)
    }
    func saveCalendarDetectionPreference(_ enabled:Bool,original:NativeCalendarPreferenceSnapshot) async throws -> NativeCalendarPreferenceSnapshot {
        guard connected,!calendarSettingsBusy,!calendarSettingsNeedRefresh,original.accountGeneration == accountGeneration,
              original.enabled != enabled,let api = client else { throw ChatAPIError.connection }
        let epoch = accountGeneration;calendarSettingsBusy = true;calendarPreferenceReadRevision = UUID()
        calendarDetectionTask?.cancel();calendarDetectionTask = nil
        var dispatched = false
        defer { if accountGeneration == epoch { calendarSettingsBusy = false } }
        do {
            let before = try await api.calendarDetectionEnabled();try checkConversationSession(epoch)
            guard before == original.enabled else { throw ChatPreferenceUpdateFailure(uncertain:false,message:"Date detection changed in another client. Refresh before saving.") }
            dispatched = true;try await api.setCalendarDetectionEnabled(enabled);try checkConversationSession(epoch)
            let after = try await api.calendarDetectionEnabled();try checkConversationSession(epoch)
            guard after == enabled else { throw ChatAPIError.invalidResponse }
            calendarDetection = after
            return .init(enabled:after,accountGeneration:epoch)
        } catch {
            guard accountGeneration == epoch else { throw CancellationError() }
            if dispatched { calendarSettingsNeedRefresh = true;throw ChatPreferenceUpdateFailure(uncertain:true,message:"The calendar preference change could not be confirmed. Refresh before saving again.") }
            throw error
        }
    }
    func canCreateCalendarEvent(_ post: ChatPost) -> Bool {
        connected && canRead(post.channel_id) && channels.first(where: { $0.id == post.channel_id })?.encrypted == false && !uncertainCalendarPosts.contains(post.id)
    }
    func loadCalendarEventOptions(for post: ChatPost) async throws -> NativeCalendarSnapshot {
        guard canCreateCalendarEvent(post), !calendarBusy, let api = client, let owner = account?.username else { throw ChatAPIError.connection }
        let epoch = accountGeneration
        calendarBusy = true
        defer { if epoch == accountGeneration { calendarBusy = false } }
        let enabled = try await api.calendarDetectionEnabled(); try checkConversationSession(epoch)
        calendarDetection = enabled
        guard enabled else { throw ChatCalendarFailure(message: "Date detection is disabled in your Synology Chat preferences.") }
        let list = try await api.calendars(); try checkConversationSession(epoch)
        let settings = try await api.calendarSettings(); try checkConversationSession(epoch)
        var calendars: [ChatCalendar] = []
        for calendar in list where calendar.eligible(owner: owner) {
            do { calendars.append(try await api.privateCalendar(calendar, owner: owner)) }
            catch is CancellationError { throw CancellationError() }
            catch { /* Shared and unknown calendars remain unavailable. */ }
            try checkConversationSession(epoch)
        }
        guard canCreateCalendarEvent(post) else { throw CancellationError() }
        guard !calendars.isEmpty else { throw ChatCalendarFailure(message: "No writable, unshared calendar owned by your account is available.") }
        let zone = TimeZone(identifier: settings.time_zone)?.identifier ?? TimeZone.current.identifier
        return .init(calendars: calendars, timeZoneID: zone, accountGeneration: epoch, channelID: post.channel_id, postID: post.id)
    }
    func createCalendarEvent(_ draft: ChatCalendarDraft, post: ChatPost, snapshot: NativeCalendarSnapshot) async throws -> ChatCalendarEvent {
        guard canCreateCalendarEvent(post), !calendarBusy, snapshot.accountGeneration == accountGeneration,
              snapshot.channelID == post.channel_id, snapshot.postID == post.id,
              let calendar = snapshot.calendars.first(where: { $0.id == draft.calendarID }),
              let api = client, let owner = account?.username else { throw ChatAPIError.connection }
        _ = try draft.parameters(calendar: calendar)
        let epoch = accountGeneration
        calendarBusy = true
        defer { if epoch == accountGeneration { calendarBusy = false } }
        var dispatched = false
        do {
            guard try await api.calendarDetectionEnabled() else { throw ChatCalendarFailure(message: "Date detection was disabled elsewhere. No event was created.") }
            try checkConversationSession(epoch)
            let fresh = try await api.privateCalendar(calendar, owner: owner); try checkConversationSession(epoch)
            guard canCreateCalendarEvent(post) else { throw CancellationError() }
            dispatched = true
            uncertainCalendarPosts.insert(post.id)
            let receipt = try await api.createCalendarEvent(draft, calendar: fresh); try checkConversationSession(epoch)
            let canonical = try await api.calendarEvent(receipt); try checkConversationSession(epoch)
            guard canonical.evt_id == receipt.evt_id, try canonical.matches(draft, calendar: fresh) else { throw ChatAPIError.invalidResponse }
            uncertainCalendarPosts.remove(post.id)
            return canonical
        } catch {
            guard epoch == accountGeneration else { throw CancellationError() }
            if dispatched { throw ChatCalendarFailure(message: "The event request was sent, but its result could not be confirmed. Check Synology Calendar before creating another event from this message. This request will not be retried.") }
            throw error
        }
    }
}


extension NativeChatPreviewModel {
    private func resetPromotionRecovery() {
        promotionJournal.deactivate();promotionRecoveryScope = nil;pendingPromotions = [:];promotionRecoveryError = nil
    }
    func restorePromotionRecovery(scope:String?) {
        promotionRecoveryScope = scope;pendingPromotions = [:]
        guard let scope else { promotionRecoveryError = "The account could not be identified for conversion recovery. Conversions are disabled.";return }
        do {
            pendingPromotions = Dictionary(uniqueKeysWithValues:try promotionJournal.activate(scope:scope).map { ($0.sourceID,ChatChannelPromotionAttempt(intent:$0,accountGeneration:accountGeneration,reviewedName:nil)) })
            promotionRecoveryError = nil
        } catch { promotionRecoveryError = "Saved conversion state could not be loaded. Conversions are disabled. Resolve the storage problem and refresh saved state; no request will be repeated." }
    }
    func refreshPromotionRecovery(expectedGeneration:Int? = nil) throws {
        try Task.checkCancellation()
        guard expectedGeneration == nil || expectedGeneration == accountGeneration else { throw CancellationError() }
        guard connected,!channelManagementBusy else { throw ChatAPIError.connection }
        restorePromotionRecovery(scope:promotionRecoveryScope)
        if let error = promotionRecoveryError { throw ChatTransferError(message:error) }
    }
    func acknowledgePromotionOutcome(_ intent:ChatChannelPromotionIntent,epoch:Int) throws {
        guard connected,epoch == accountGeneration,!channelManagementBusy,promotionRecoveryError == nil,
              pendingPromotions[intent.sourceID]?.intent == intent else { throw ChatAPIError.connection }
        do { try promotionJournal.remove(intent) }
        catch { promotionRecoveryError = "Saved conversion state could not be updated. Resolve the storage problem and refresh saved state.";throw error }
        pendingPromotions.removeValue(forKey:intent.sourceID)
    }
    func canPromoteConversation(_ channel: ChatChannel) -> Bool {
        canInteract && selection == channel.id && channel.supportsPromotion && canRead(channel.id)
        && !sending && !uploading && !isEditingMessage && !preparingComposerAttachment && attachmentBatch == nil
        && !channelManagementBusy && !conversationOrganizationBusy && promotionRecoveryError == nil && pendingPromotions[channel.id] == nil
        && pendingHistoryArchives[channel.id] == nil && pendingChannelClosures[channel.id] == nil
        && channelPermissions?.allows("channel_create") == true
    }
    func loadPromotionSnapshot(channelID: Int64) async throws -> ChatChannelPromotionSnapshot {
        guard let channel = channels.first(where: { $0.id == channelID }), canPromoteConversation(channel), let api = client, let me = currentUserID else { throw ChatAPIError.connection }
        let epoch = accountGeneration; channelManagementBusy = true
        defer { if epoch == accountGeneration { channelManagementBusy = false } }
        let permissions = try await api.channelPermissions(); try checkConversationSession(epoch)
        guard permissions.allows("channel_create") else { throw ChatTransferError(message: "Your account cannot create private channels.") }
        let list = try await api.channels(); try checkConversationSession(epoch)
        guard Set(list.map(\.id)).count == list.count, let fresh = list.first(where: { $0.id == channelID }), fresh.supportsPromotion, selection == channelID else { throw ChatTransferError(message: "This conversation changed or is no longer available.") }
        let ids = try await api.members(channelID: channelID); try checkConversationSession(epoch)
        let people = try await api.users(); try checkConversationSession(epoch)
        guard Set(people.map(\.user_id)).count == people.count, !ids.isEmpty, ids.count <= 1000, Set(ids).count == ids.count, ids.contains(me), ids.allSatisfy({ id in people.contains { $0.user_id == id && $0.canStartConversation } }) else { throw ChatTransferError(message: "The conversation's current members could not be verified as available Chat users.") }
        guard selection == channelID, channels.first(where: { $0.id == channelID })?.supportsPromotion == true else { throw CancellationError() }
        channelPermissions = permissions
        return .init(channel: fresh, memberIDs: Set(ids), memberNames: Dictionary(uniqueKeysWithValues: people.filter { ids.contains($0.user_id) }.map { ($0.user_id, displayName($0)) }), accountGeneration: epoch)
    }
    @discardableResult func promoteConversation(_ original: ChatChannelPromotionSnapshot, draft: ChatChannelPromotionDraft) async throws -> ChatChannel {
        try draft.validate(); let draft = draft.normalized
        guard original.accountGeneration == accountGeneration, let channel = channels.first(where: { $0.id == original.channel.id }), canPromoteConversation(channel), let api = client, let me = currentUserID else { throw ChatAPIError.connection }
        // This read refreshes ACL, membership and availability immediately before dispatch.
        let fresh = try await loadPromotionSnapshot(channelID: original.channel.id)
        guard fresh.accountGeneration == original.accountGeneration, fresh.memberIDs == original.memberIDs, fresh.channel.encrypted == original.channel.encrypted,
              draft.mode != .newChannel || original.memberIDs == [me] || channelPermissions?.allows("channel_invite") == true else { throw ChatChannelPromotionFailure(uncertain: false, message: "Members or permissions changed. Reopen this form before continuing.") }
        let epoch = accountGeneration; channelManagementBusy = true
        defer { if epoch == accountGeneration { channelManagementBusy = false } }
        var receipt = try ChatChannelPromotionIntent(snapshot:fresh,draft:draft)
        let receiptScope = promotionJournal.accountScope
        do { try promotionJournal.remember(receipt) }
        catch { promotionRecoveryError = "The conversion was not sent because its recovery record could not be saved. Resolve the storage problem and refresh saved state.";throw error }
        pendingPromotions[channel.id] = .init(intent:receipt,accountGeneration:epoch,reviewedName:draft.name)
        var dispatched = false
        do {
            try checkConversationSession(epoch)
            dispatched = true
            switch draft.mode {
            case .convert:
                try await api.promoteConversation(channelID: channel.id, name: draft.name, purpose: draft.purpose)
            case .newChannel:
                let target = try await api.createNamedChannel(name:draft.name,purpose:draft.purpose,kind:.private,
                    onCreated:{ id in
                        let updated = try receipt.withTarget(id)
                        do { try self.promotionJournal.replaceInScope(receipt,with:updated,originalScope:receiptScope) }
                        catch {
                            if epoch == self.accountGeneration { self.promotionRecoveryError = "Channel \(id) was created, but its recovery checkpoint could not be saved. Joining and invitations stopped. Resolve storage and refresh saved state." }
                            throw error
                        }
                        receipt = updated
                        if epoch == self.accountGeneration { self.pendingPromotions[channel.id] = .init(intent:updated,accountGeneration:epoch,reviewedName:draft.name) }
                    },checkContinuation:{ try self.checkConversationSession(epoch) })
                try checkConversationSession(epoch)
                let sourceMembers = try await api.members(channelID: channel.id); try checkConversationSession(epoch)
                let targetMembers = try await api.members(channelID: target.id); try checkConversationSession(epoch)
                let permissions = try await api.channelPermissions(); try checkConversationSession(epoch)
                let current = try await api.channels(); try checkConversationSession(epoch)
                let people = try await api.users(); try checkConversationSession(epoch)
                guard Set(current.map(\.id)).count == current.count, current.first(where: { $0.id == channel.id })?.supportsPromotion == true,
                      current.first(where: { $0.id == target.id }).map({ draft.matches($0) }) == true,
                      original.memberIDs.allSatisfy({ id in people.contains { $0.user_id == id && $0.canStartConversation } }),
                      Set(sourceMembers) == original.memberIDs, sourceMembers.count == original.memberIDs.count, Set(targetMembers) == [me], targetMembers.count == 1,
                      selection == channel.id, canInteract, permissions.allows("channel_create"),
                      original.memberIDs == [me] || permissions.allows("channel_invite") else { throw ChatAPIError.invalidResponse }
                let invite = original.memberIDs.subtracting([me])
                if !invite.isEmpty { try await api.inviteChannelMembers(invite, channel: target) }
            }
            try checkConversationSession(epoch)
            return try await confirmPromotion(channelID: channel.id, epoch: epoch, api: api)
        } catch {
            if !dispatched {
                do {
                    try promotionJournal.removeUndispatched(receipt,originalScope:receiptScope)
                    if epoch == accountGeneration { pendingPromotions.removeValue(forKey:channel.id) }
                } catch { if epoch == accountGeneration { promotionRecoveryError = "Saved conversion state could not be updated. Resolve storage and refresh saved state." } }
            }
            guard epoch == accountGeneration else { throw CancellationError() }
            if !dispatched { throw error }
            throw ChatChannelPromotionFailure(uncertain: true, message: promotionRecoveryError ?? "The channel request was sent, but the result could not be fully confirmed. Its recovery record survives restarting. Check status before taking further action; nothing will be repeated automatically.")
        }
    }
    @discardableResult func checkPromotionStatus(channelID: Int64,expectedGeneration:Int? = nil) async throws -> ChatChannel {
        try Task.checkCancellation()
        guard expectedGeneration == nil || expectedGeneration == accountGeneration else { throw CancellationError() }
        guard connected, !channelManagementBusy, pendingPromotions[channelID] != nil, let api = client else { throw ChatAPIError.connection }
        if promotionRecoveryScope != nil { try refreshPromotionRecovery() }
        let epoch = accountGeneration; channelManagementBusy = true
        defer { if epoch == accountGeneration { channelManagementBusy = false } }
        return try await confirmPromotion(channelID: channelID, epoch: epoch, api: api)
    }
    private func confirmPromotion(channelID: Int64, epoch: Int, api: ChatAPIClient) async throws -> ChatChannel {
        guard let attempt = pendingPromotions[channelID], attempt.accountGeneration == epoch,let me = currentUserID,attempt.intent.memberIDs.contains(me), let targetID = attempt.targetID else { throw ChatTransferError(message: "Creation has no confirmed channel ID. Inspect the channel list in Synology Chat before creating anything else.") }
        let list = try await api.channels(); try checkConversationSession(epoch)
        guard Set(list.map(\.id)).count == list.count, let target = list.first(where: { $0.id == targetID }), attempt.intent.matches(target) else { throw ChatTransferError(message: "The private channel is not yet confirmed with the requested details. Check Synology Chat; the request will not be resent.") }
        let members = try await api.members(channelID: targetID); try checkConversationSession(epoch)
        guard Set(members) == Set(attempt.intent.memberIDs), members.count == Set(attempt.intent.memberIDs).count else { throw ChatTransferError(message: "The channel exists, but its members differ from the reviewed list. Manage its members in Synology Chat; status checking never sends invitations.") }
        if attempt.intent.mode == .newChannel {
            guard let source = list.first(where: { $0.id == channelID }), source.supportsPromotion, !source.encrypted else { throw ChatAPIError.invalidResponse }
            let sourceMembers = try await api.members(channelID: channelID); try checkConversationSession(epoch)
            guard Set(sourceMembers) == Set(attempt.intent.memberIDs), sourceMembers.count == Set(attempt.intent.memberIDs).count else { throw ChatAPIError.invalidResponse }
        }
        channelNames.removeValue(forKey: targetID)
        channels = list.sorted { title($0).localizedCaseInsensitiveCompare(title($1)) == .orderedAscending }
        channelMemberIDs[targetID] = members
        do { try promotionJournal.remove(attempt.intent);pendingPromotions.removeValue(forKey:channelID) }
        catch { promotionRecoveryError = "The private channel is verified, but saved recovery state could not be updated. Resolve storage and refresh saved state before another conversion." }
        // Keep the user's current destination when recovering status elsewhere.
        if attempt.intent.mode == .newChannel, selection == channelID { selection = targetID }
        return target
    }
}


extension NativeChatPreviewModel {
    func botAttachments(for post: ChatPost) -> [ChatBotAttachment] {
        guard connected, canRead(post.channel_id), channels.first(where: { $0.id == post.channel_id })?.encrypted == false,
              post.props?.encrypted != true, (post.delete_at ?? 0) == 0 else { return [] }
        return (post.props?.attachments ?? []).prefix(100).enumerated().compactMap {
            guard case .object = $0.element else { return nil }
            return .init(index: $0.offset, raw: $0.element)
        }
    }
    private func botActionContextValid(_ post: ChatPost) -> Bool {
        connected && canInteract && selection == post.channel_id && canRead(post.channel_id)
        && channels.first(where: { $0.id == post.channel_id })?.encrypted == false
        && post.props?.encrypted != true && post.props?.forward == nil && post.type != "system"
        && (post.delete_at ?? 0) == 0 && !deletedPostIDs.contains(post.id)
        && (posts.contains { $0.id == post.id } || threadRoot?.id == post.id || replies.contains { $0.id == post.id })
        && (!post.isReply || threadRoot?.id == post.thread_id)
    }
    func canTriggerBotAction(_ post: ChatPost, selection: ChatBotActionSelection) -> Bool {
        botActionContextValid(post) && canAct(on: post) && !botActionsPending.contains(post.id)
        && botActionRecoveryError == nil && pendingBotActionReceipts[post.id] == nil
        && uncertainBotActions[post.id] == nil && selection.matches(post) && (try? selection.payload()) != nil
    }
    func triggerBotAction(_ post: ChatPost, selection: ChatBotActionSelection) async throws {
        guard canTriggerBotAction(post, selection: selection), let api = client else { throw ChatAPIError.connection }
        let epoch = accountGeneration, key = UUID(); canonicalReadKeys[post.id] = key
        botActionsPending.insert(post.id); pendingMessageActions.insert(post.id); botActionStatus[post.id] = nil
        defer { if epoch == accountGeneration { botActionsPending.remove(post.id); pendingMessageActions.remove(post.id) } }
        var dispatched = false, acknowledged = false
        do {
            let fresh = try await api.post(channelID: post.channel_id, postID: post.id, threadID: post.isReply ? post.thread_id : nil)
            try checkConversationSession(epoch)
            guard botActionContextValid(post), canonicalReadKeys[post.id] == key else { throw CancellationError() }
            applyCanonical(fresh, readKey: key)
            guard fresh.creator_id == post.creator_id, fresh.thread_id ?? 0 == post.thread_id ?? 0,
                  botActionContextValid(fresh), selection.matches(fresh) else {
                throw ChatBotActionFailure(uncertain: false, message: "This message or action changed. Review the updated message before choosing an action.")
            }
            // Persist uncertainty before the request can leave this process.
            // The receipt contains only context IDs and a card fingerprint.
            let receipt = try ChatBotActionIntent(post: fresh, selection: selection)
            try botActionJournal.remember(receipt)
            pendingBotActionReceipts[post.id] = receipt
            uncertainBotActions[post.id] = selection; dispatched = true
            try await api.triggerBotAttachment(postID: post.id, selection: selection)
            acknowledged = true
            guard epoch == accountGeneration else { throw CancellationError() }
            try retireBotActionReceipt(receipt)
            uncertainBotActions.removeValue(forKey: post.id)
            try checkConversationSession(epoch)
            botActionStatus[post.id] = "Action sent"
            guard botActionContextValid(fresh), canonicalReadKeys[post.id] == key else { return }
            do {
                let updated = try await api.post(channelID: post.channel_id, postID: post.id, threadID: post.isReply ? post.thread_id : nil)
                try checkConversationSession(epoch)
                guard botActionContextValid(fresh), canonicalReadKeys[post.id] == key else { return }
                applyCanonical(updated, readKey: key)
            } catch is CancellationError { throw CancellationError() }
            catch { if epoch == accountGeneration { botActionStatus[post.id] = "Action sent. Refresh the message to check for updates." } }
        } catch {
            guard epoch == accountGeneration else { throw CancellationError() }
            if acknowledged { throw error }
            if dispatched { throw ChatBotActionFailure(uncertain: true, message: "The action was sent, but its result is unknown. Check the message and integration before trying again. This action will not be repeated automatically.") }
            throw error
        }
    }
    func canCheckBotActionMessage(_ post: ChatPost) -> Bool {
        botActionContextValid(post) && botActionRecoveryError == nil && !botActionsPending.contains(post.id) && !pendingMessageActions.contains(post.id)
    }
    func checkBotActionMessage(_ post: ChatPost) async throws {
        guard canCheckBotActionMessage(post), let api = client else { throw ChatAPIError.connection }
        let epoch = accountGeneration, key = UUID(); canonicalReadKeys[post.id] = key
        botActionsPending.insert(post.id); pendingMessageActions.insert(post.id)
        defer { if epoch == accountGeneration { botActionsPending.remove(post.id); pendingMessageActions.remove(post.id) } }
        let fresh = try await api.post(channelID: post.channel_id, postID: post.id, threadID: post.isReply ? post.thread_id : nil)
        try checkConversationSession(epoch)
        guard botActionContextValid(post), canonicalReadKeys[post.id] == key else { throw CancellationError() }
        applyCanonical(fresh, readKey: key)
        if let pending = pendingBotActionReceipts[post.id], pending.matches(fresh), (fresh.delete_at ?? 0) == 0 {
            botActionStatus[post.id] = "The message is unchanged. The previous action's result is still unknown; check the integration."
        } else {
            if let pending = pendingBotActionReceipts[post.id] { try retireBotActionReceipt(pending) }
            uncertainBotActions.removeValue(forKey: post.id)
            botActionStatus[post.id] = "Message refreshed. Review any updated actions."
        }
    }
    private func retireBotActionReceipt(_ receipt: ChatBotActionIntent) throws {
        do { try botActionJournal.remove(receipt); pendingBotActionReceipts.removeValue(forKey: receipt.postID) }
        catch {
            botActionRecoveryError = "Saved integration action state could not be updated. Reconnect after resolving the storage problem; no action will be repeated automatically."
            throw error
        }
    }
    private func resetBotActionRecovery() {
        botActionJournal.deactivate(); pendingBotActionReceipts = [:]; botActionRecoveryError = nil
        botActionsPending = []; uncertainBotActions = [:]; botActionStatus = [:]
    }
    func restoreBotActionRecovery(scope: String?) {
        guard let scope else { botActionRecoveryError = "The account could not be identified for integration action recovery."; return }
        do {
            pendingBotActionReceipts = Dictionary(uniqueKeysWithValues: try botActionJournal.activate(scope: scope).map { ($0.postID, $0) })
            botActionRecoveryError = nil
            for postID in pendingBotActionReceipts.keys {
                botActionStatus[postID] = "An earlier integration action has an unknown result. Check the message and integration before choosing another action."
            }
        } catch {
            botActionRecoveryError = "Saved integration actions could not be loaded. Actions are disabled; keep the recovery file and reconnect after resolving the storage problem."
        }
    }
}


extension NativeChatPreviewModel {
    private func resetSlashRecovery() {
        slashActionJournal.deactivate();slashRecoveryScope = nil
        pendingSlashInvocations = [:];uncertainSlashInvocations = [];slashRecoveryError = nil;slashCommandRequest = nil;slashBusy = false
    }
    func restoreSlashRecovery(scope:String?) {
        slashRecoveryScope = scope;pendingSlashInvocations = [:];uncertainSlashInvocations = []
        guard let scope else { slashRecoveryError = "The account could not be identified for command recovery. Integration commands are disabled.";return }
        do {
            let records = try slashActionJournal.activate(scope:scope)
            pendingSlashInvocations = Dictionary(uniqueKeysWithValues:records.map { ($0.id,$0) })
            uncertainSlashInvocations = Set(pendingSlashInvocations.keys);slashRecoveryError = nil
        } catch { slashRecoveryError = "Saved command state could not be loaded. Integration commands are disabled. Keep the recovery file, resolve the storage problem and refresh saved command state." }
    }
    func refreshSlashRecovery(_ request:NativeSlashCommandRequest) throws {
        guard !slashBusy,slashCommandRequest?.id == request.id,slashContextCurrent(request) else { throw ChatAPIError.connection }
        restoreSlashRecovery(scope:slashRecoveryScope)
        if let error = slashRecoveryError { throw ChatTransferError(message:error) }
    }
    /// Local acknowledgement only. It never dispatches the old command or reconstructs its arguments.
    func acknowledgeSlashOutcome(_ receipt:ChatSlashActionIntent,request:NativeSlashCommandRequest) throws {
        guard !slashBusy,slashRecoveryError == nil,slashCommandRequest?.id == request.id,slashContextCurrent(request),
              receipt.channelID == request.channel.id,pendingSlashInvocations[receipt.id] == receipt else { throw ChatAPIError.connection }
        do { try slashActionJournal.remove(receipt) }
        catch { slashRecoveryError = "Saved command state could not be updated. Resolve the storage problem and refresh saved command state before running integration commands.";throw error }
        pendingSlashInvocations.removeValue(forKey:receipt.id);uncertainSlashInvocations.remove(receipt.id)
    }
    var availableSlashCommands: [ChatSlashCommand] { (try? ChatSlashCommand.catalogue(users: directory, encrypted: selectedChannel?.encrypted == true)) ?? [] }
    func canOpenSlashCommands(inThread: Bool = false) -> Bool {
        connected && !sending && !slashBusy && slashCommandRequest == nil && !isEditingMessage && !preparingComposerAttachment && attachmentBatch == nil
        && selectedChannel.map { canRead($0.id) } == true && (!inThread || threadRoot?.channel_id == selection)
    }
    private func slashContextCurrent(_ request: NativeSlashCommandRequest) -> Bool {
        connected && request.accountGeneration == accountGeneration && selection == request.channel.id && canRead(request.channel.id)
        && (request.rootID == nil || threadRoot?.id == request.rootID)
        && selectedChannel?.type == request.channel.type && selectedChannel?.encrypted == request.channel.encrypted
        && selectedChannel?.channel_key_enc == request.channel.channel_key_enc
    }
    func prepareSlashCommands(inThread: Bool = false, fromComposer: Bool = false) async throws {
        guard canOpenSlashCommands(inThread: inThread), let channel = selectedChannel, let api = client else { throw ChatAPIError.connection }
        let epoch = accountGeneration, rootID = inThread ? threadRoot?.id : nil, text = inThread ? replyDraft : draft
        slashBusy = true
        defer { if epoch == accountGeneration { slashBusy = false } }
        let users = try await api.users(); try checkConversationSession(epoch)
        let list = try await api.channels(); try checkConversationSession(epoch)
        let members = try await api.members(channelID: channel.id); try checkConversationSession(epoch)
        guard let fresh = list.first(where: { $0.id == channel.id }), fresh.is_closed != true, fresh.is_joined != false, (fresh.hide_global_at ?? 0) == 0,
              fresh.type == channel.type, fresh.encrypted == channel.encrypted, fresh.channel_key_enc == channel.channel_key_enc,
              !members.isEmpty, Set(members).count == members.count else { throw ChatAPIError.invalidResponse }
        let commands = try ChatSlashCommand.catalogue(users: users, encrypted: channel.encrypted)
        if fromComposer, let name = ChatSlashSyntax.name(text), !commands.contains(where: { $0.name == name }) { throw ChatTransferError(message: "Unknown or unavailable command /" + name + ". Your draft is kept.") }
        let request = NativeSlashCommandRequest(channel: fresh, rootID: rootID, memberIDs: Set(members), commands: commands,
                                              initialText: fromComposer ? text : "/", originText: fromComposer ? text : nil, accountGeneration: epoch)
        guard slashContextCurrent(request), !fromComposer || (inThread ? replyDraft : draft) == text else { throw CancellationError() }
        slashCommandRequest = request
    }
    func dismissSlashCommands() { slashCommandRequest = nil }
    func finishSlashCommand(_ request: NativeSlashCommandRequest) {
        guard slashCommandRequest?.id == request.id, request.accountGeneration == accountGeneration else { return }
        if let origin = request.originText {
            if let root = request.rootID { if threadDrafts[root] == origin { threadDrafts[root] = "" } }
            else if drafts[request.channel.id] == origin { drafts[request.channel.id] = "" }
        }
    }
    func finishSlashNickname(_ request: NativeSlashCommandRequest) { finishSlashCommand(request); if slashCommandRequest?.id == request.id { slashCommandRequest = nil } }
    func executeSlashCommand(_ request: NativeSlashCommandRequest, command: ChatSlashCommand, message: String) async throws -> ChatSlashResult {
        guard !slashBusy, slashCommandRequest?.id == request.id, slashContextCurrent(request), canInteract,
              request.commands.contains(command), ChatSlashSyntax.name(message) == command.name, ChatMessageText.isAllowed(message), let api = client else { throw ChatAPIError.connection }
        if command.kind == .help { finishSlashCommand(request); return .init(message: "Choose a command from the list to see its usage. Integration commands run in the conversation shown here.") }
        guard case .server(let userID) = command.kind else { throw ChatTransferError(message: "Use the display-name editor to save /nickname changes.") }
        guard slashRecoveryError == nil else { throw ChatTransferError(message:slashRecoveryError!) }
        let key = ChatSlashSyntax.invocationKey(channelID: request.channel.id, command: command, message: message)
        guard !uncertainSlashInvocations.contains(key) else { throw ChatSlashFailure(uncertain: true, message: "The result of this command is still unknown. Check the conversation and integration before attempting it again. This request will not be repeated.") }
        let epoch = accountGeneration; slashBusy = true
        defer { if epoch == accountGeneration { slashBusy = false } }
        var dispatched = false
        var saved:ChatSlashActionIntent?
        let receiptScope = slashActionJournal.accountScope
        do {
            let users = try await api.users(); try checkConversationSession(epoch)
            let current = try ChatSlashCommand.catalogue(users: users, encrypted: request.channel.encrypted)
            let list = try await api.channels(); try checkConversationSession(epoch)
            let members = try await api.members(channelID: request.channel.id); try checkConversationSession(epoch)
            guard current.contains(command), let channel = list.first(where: { $0.id == request.channel.id }),
                  channel.type == request.channel.type, channel.encrypted == request.channel.encrypted, channel.channel_key_enc == request.channel.channel_key_enc,
                  channel.is_closed != true, channel.is_joined != false, (channel.hide_global_at ?? 0) == 0, Set(members) == request.memberIDs, members.count == request.memberIDs.count,
                  canInteract, slashContextCurrent(request), slashCommandRequest?.id == request.id else { throw ChatSlashFailure(uncertain: false, message: "The command, conversation or its members changed. Reopen commands and review the destination again.") }
            let receipt = try ChatSlashActionIntent(channelID:channel.id,command:command,message:message)
            do { try slashActionJournal.remember(receipt) }
            catch { slashRecoveryError = "The command was not sent because its recovery record could not be saved. Resolve the storage problem and refresh saved command state.";throw error }
            saved = receipt;pendingSlashInvocations[key] = receipt;uncertainSlashInvocations.insert(key)
            try checkConversationSession(epoch)
            dispatched = true
            let response = try await api.executeSlashCommand(channelID: channel.id, userID: userID, message: message)
            guard epoch == accountGeneration else { throw CancellationError() }
            // A valid server acknowledgement remains success even if local cleanup fails.
            // Consume only the unchanged origin draft; retain the receipt/error to block replay.
            finishSlashCommand(request)
            do { try slashActionJournal.remove(receipt) }
            catch {
                slashRecoveryError = "The command was acknowledged, but its recovery record could not be updated. Refresh saved command state after resolving the storage problem; do not repeat it automatically."
                return response
            }
            pendingSlashInvocations.removeValue(forKey:key);uncertainSlashInvocations.remove(key)
            return response
        } catch {
            if !dispatched,let saved {
                do {
                    try slashActionJournal.removeUndispatched(saved,originalScope:receiptScope)
                    if epoch == accountGeneration { pendingSlashInvocations.removeValue(forKey:key);uncertainSlashInvocations.remove(key) }
                } catch { if epoch == accountGeneration { slashRecoveryError = "Saved command state could not be updated. Resolve the storage problem and refresh saved command state before running integration commands." } }
            }
            guard epoch == accountGeneration else { throw CancellationError() }
            if dispatched, uncertainSlashInvocations.contains(key) { throw ChatSlashFailure(uncertain: true, message: slashRecoveryError ?? "The command was sent, but its result is unknown. This is remembered across restarts. Check the conversation and integration before allowing another manual attempt; nothing will be repeated automatically.") }
            throw error
        }
    }
}


extension NativeChatPreviewModel {
    private func publishWebhookRecovery(_ records:[ChatWebhookActionIntent]) {
        pendingWebhookActions = Dictionary(uniqueKeysWithValues:records.map { ($0.id,$0) })
        uncertainWebhookIDs = Set(records.compactMap(\.webhookID))
        uncertainWebhookCreates = Set(records.filter { $0.operation == .create }.map(\.kind))
        uncertainWebhookRotations = Dictionary(uniqueKeysWithValues:records.compactMap { record in
            guard record.operation == .rotate,let id = record.webhookID,let fingerprint = record.previousTokenFingerprint else { return nil }
            return (id,fingerprint)
        })
    }
    private func restoreWebhookRecovery(scope:String?) {
        webhookRecoveryScope = scope;publishWebhookRecovery([])
        guard let scope else { webhookRecoveryError = "The account could not be identified for integration recovery. Changes are disabled.";return }
        do { publishWebhookRecovery(try webhookActionJournal.activate(scope:scope));webhookRecoveryError = nil }
        catch { webhookRecoveryError = "Saved integration actions could not be loaded. Changes are disabled. Keep the recovery file and refresh saved action state after resolving the storage problem." }
    }
    func refreshWebhookRecovery() throws {
        guard connected,!webhookBusy else { throw ChatAPIError.connection }
        restoreWebhookRecovery(scope:webhookRecoveryScope)
        if let failure = webhookRecoveryError { throw ChatTransferError(message:failure) }
    }
    private func rememberWebhookAction(_ record:ChatWebhookActionIntent) throws {
        guard webhookRecoveryError == nil,let scope = webhookRecoveryScope,webhookActionJournal.accountScope == scope else { throw ChatTransferError(message:webhookRecoveryError ?? "Refresh saved integration action state before making changes.") }
        do { try webhookActionJournal.remember(record) }
        catch { webhookRecoveryError = "The integration action was not sent because its recovery record could not be saved or another action is pending. Refresh saved action state before trying again.";throw error }
        publishWebhookRecovery(Array(pendingWebhookActions.values) + [record])
    }
    private func acquireWebhookActionLease(_ record:ChatWebhookActionIntent) throws -> ChatAccountActionLease {
        do { return try webhookActionJournal.acquireActionLease(for:record) }
        catch {
            restoreWebhookRecovery(scope:webhookRecoveryScope)
            throw ChatWebhookFailure(uncertain:true,message:webhookRecoveryError ?? "This integration action is pending or still running in another copy of the app. No new action was sent. Let it finish, then refresh and review its outcome.")
        }
    }
    @discardableResult private func finishWebhookAction(_ record:ChatWebhookActionIntent)->Bool {
        do { try webhookActionJournal.remove(record) }
        catch { webhookRecoveryError = "The server was checked, but saved integration action state could not be updated. Do not repeat the action; refresh saved action state after resolving the storage problem.";return false }
        if pendingWebhookActions[record.id] == record { pendingWebhookActions[record.id] = nil }
        publishWebhookRecovery(Array(pendingWebhookActions.values));return true
    }
    private func cancelUndispatchedWebhookAction(_ record:ChatWebhookActionIntent,scope:String?,epoch:Int) {
        do {
            try webhookActionJournal.removeUndispatched(record,originalScope:scope)
            if accountGeneration == epoch,pendingWebhookActions[record.id] == record {
                pendingWebhookActions[record.id] = nil;publishWebhookRecovery(Array(pendingWebhookActions.values))
            }
        } catch { if accountGeneration == epoch { webhookRecoveryError = "Saved integration action state could not be updated. Refresh saved action state before another change." } }
    }
    /// Explicit local acknowledgement after a fresh catalogue read. It never
    /// sends, recreates, rotates or removes the old integration operation.
    func acknowledgeWebhookOutcome(_ record:ChatWebhookActionIntent) async throws -> ChatWebhookCatalogue {
        guard connected,!webhookBusy else { throw ChatAPIError.connection }
        restoreWebhookRecovery(scope:webhookRecoveryScope)
        guard webhookRecoveryError == nil,pendingWebhookActions[record.id] == record else { throw ChatAPIError.connection }
        let lease = try acquireWebhookActionLease(record);defer { lease.release() }
        let epoch = accountGeneration;webhookBusy = true
        defer { if accountGeneration == epoch { webhookBusy = false } }
        let catalogue = try await webhookCatalogue();try checkConversationSession(epoch)
        guard finishWebhookAction(record) else { throw ChatTransferError(message:webhookRecoveryError ?? "Could not update saved action state.") }
        return catalogue
    }
    private func webhookCatalogue() async throws -> ChatWebhookCatalogue {
        guard connected, let api = client, let owner = currentUserID else { throw ChatAPIError.connection }
        let epoch = accountGeneration
        let acl = try await api.channelPermissions(); try checkConversationSession(epoch)
        guard acl.allows("webhook_read") || acl.allows("webhook_create") else { throw ChatTransferError(message: "Your account cannot manage integrations.") }
        let entries = try await api.webhookSummaries(); try checkConversationSession(epoch)
        let joined = try await api.channels(); try checkConversationSession(epoch)
        let unjoined = try await api.unjoinedChannels(); try checkConversationSession(epoch)
        var unique = Dictionary(uniqueKeysWithValues: joined.map { ($0.id, $0) })
        for channel in unjoined where unique[channel.id] == nil { unique[channel.id] = channel }
        return .init(entries: entries.filter { !$0.isDeleted && !$0.appManaged }, channels: unique.values.filter(\.webhookEligible).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }, ownerID: owner, canCreate: acl.allows("webhook_create"), accountGeneration: epoch)
    }
    private func ownedWebhook(_ id: Int64, kind: ChatWebhookKind) async throws -> ChatWebhookSnapshot {
        let catalogue = try await webhookCatalogue()
        guard catalogue.entries.contains(where: { $0.id == id && $0.kind == kind && $0.editable(by: catalogue.ownerID) }), let api = client else { throw ChatTransferError(message: "This integration is no longer editable by your account. Refresh the list.") }
        let detail = try await api.webhookDetail(kind: kind, id: id); try checkConversationSession(catalogue.accountGeneration)
        guard detail.user_id == id, detail.creator_id == nil || detail.creator_id == catalogue.ownerID, detail.bot_type == nil || detail.bot_type == kind.rawValue else { throw ChatAPIError.invalidResponse }
        return .init(detail: detail, kind: kind, catalogue: catalogue)
    }
    func loadWebhooks() async throws -> ChatWebhookCatalogue {
        guard !webhookBusy else { throw ChatAPIError.connection };restoreWebhookRecovery(scope:webhookRecoveryScope)
        webhookBusy = true; let epoch = accountGeneration
        defer { if epoch == accountGeneration { webhookBusy = false } }
        var catalogue = try await webhookCatalogue()
        if webhookRecoveryError == nil {
            for record in Array(pendingWebhookActions.values) where record.operation == .remove {
                guard let lease = try? webhookActionJournal.acquireActionLease(for:record) else { continue }
                defer { lease.release() }
                catalogue = try await webhookCatalogue()
                if let id = record.webhookID,!catalogue.entries.contains(where:{ $0.id == id }) { _ = finishWebhookAction(record) }
            }
        }
        return catalogue
    }
    func loadWebhook(_ id: Int64, kind: ChatWebhookKind) async throws -> ChatWebhookSnapshot {
        guard !webhookBusy else { throw ChatAPIError.connection };restoreWebhookRecovery(scope:webhookRecoveryScope)
        webhookBusy = true; let epoch = accountGeneration
        defer { if epoch == accountGeneration { webhookBusy = false } }
        var result = try await ownedWebhook(id, kind: kind)
        if webhookRecoveryError == nil {
            for record in Array(pendingWebhookActions.values) where record.webhookID == id && record.kind == kind {
                guard let lease = try? webhookActionJournal.acquireActionLease(for:record) else { continue }
                defer { lease.release() }
                result = try await ownedWebhook(id,kind:kind)
                switch record.operation {
                case .rotate:
                    if let fingerprint = result.detail.token?.fingerprint,fingerprint != record.previousTokenFingerprint { _ = finishWebhookAction(record) }
                case .create:
                    if result.detail.is_disabled { _ = finishWebhookAction(record) }
                case .edit,.remove: _ = finishWebhookAction(record)
                }
            }
        }
        return result
    }
    func webhookIncomingURL(_ snapshot: ChatWebhookSnapshot) throws -> String {
        guard snapshot.kind == .incoming, snapshot.catalogue.accountGeneration == accountGeneration, !uncertainWebhookIDs.contains(snapshot.detail.user_id), let token = snapshot.detail.token, let api = client else { throw ChatAPIError.connection }
        return try api.incomingWebhookURL(token: token).absoluteString
    }
    func saveWebhook(_ draft: ChatWebhookDraft, original: ChatWebhookSnapshot) async throws -> ChatWebhookSnapshot {
        let id = original.detail.user_id, epoch = accountGeneration
        guard webhookRecoveryError == nil,!webhookBusy, !uncertainWebhookIDs.contains(id), original.catalogue.accountGeneration == epoch, let api = client else { throw ChatAPIError.connection }
        webhookBusy = true; defer { if epoch == accountGeneration { webhookBusy = false } }
        var dispatched = false
        var saved:ChatWebhookActionIntent?
        let receiptScope = webhookActionJournal.accountScope
        do {
            var fresh = try await ownedWebhook(id, kind: original.kind)
            guard fresh.detail.sameConfiguration(as: original.detail) else { throw ChatTransferError(message: "The integration changed in another client. Refresh before saving.") }
            let draft = draft.normalized; try draft.validate(kind: original.kind, channels: fresh.catalogue.channels, original: fresh.detail)
            let record = try ChatWebhookActionIntent(operation:.edit,kind:original.kind,webhookID:id)
            let lease = try acquireWebhookActionLease(record);defer { lease.release() }
            try rememberWebhookAction(record);saved = record
            try checkConversationSession(epoch)
            var expected = ChatWebhookDraft(fresh.detail)
            let originalToken = fresh.detail.token
            let changesConfig = !draft.detailsMatch(fresh.detail, kind: original.kind) || draft.nickname != fresh.detail.nickname
            if !fresh.detail.is_disabled && (changesConfig || !draft.enabled) {
                dispatched = true; try await api.setWebhookEnabled(id: id, enabled: false); try checkConversationSession(epoch)
                fresh = try await ownedWebhook(id, kind: original.kind)
                expected.enabled = false
                guard expected.matches(fresh.detail, kind: original.kind), fresh.detail.token == originalToken else { throw ChatAPIError.invalidResponse }
            }
            if !draft.detailsMatch(fresh.detail, kind: original.kind) {
                dispatched = true; try await api.setWebhookDetails(id: id, kind: original.kind, draft: draft); try checkConversationSession(epoch)
                fresh = try await ownedWebhook(id, kind: original.kind)
                expected.channelID = draft.channelID; expected.triggerWord = draft.triggerWord; expected.callbackURL = draft.callbackURL
                guard expected.matches(fresh.detail, kind: original.kind), fresh.detail.token == originalToken else { throw ChatAPIError.invalidResponse }
            }
            if draft.nickname != fresh.detail.nickname {
                dispatched = true; try await api.setWebhookName(id: id, name: draft.nickname); try checkConversationSession(epoch)
                fresh = try await ownedWebhook(id, kind: original.kind)
                expected.nickname = draft.nickname
                guard expected.matches(fresh.detail, kind: original.kind), fresh.detail.token == originalToken else { throw ChatAPIError.invalidResponse }
            }
            if draft.enabled && fresh.detail.is_disabled {
                try draft.validate(kind: original.kind, channels: fresh.catalogue.channels)
                dispatched = true; try await api.setWebhookEnabled(id: id, enabled: true); try checkConversationSession(epoch)
            }
            let result = try await ownedWebhook(id, kind: original.kind)
            guard draft.matches(result.detail, kind: original.kind), result.detail.token == originalToken else { throw ChatAPIError.invalidResponse }
            _ = finishWebhookAction(record)
            return result
        } catch {
            if !dispatched,let saved { cancelUndispatchedWebhookAction(saved,scope:receiptScope,epoch:epoch) }
            guard epoch == accountGeneration else { throw CancellationError() }
            if dispatched { throw ChatWebhookFailure(uncertain: true, message: "The integration may have changed. Refresh to inspect its current settings before another action; it may remain disabled.") }
            throw error
        }
    }
    func createWebhook(kind: ChatWebhookKind, original: ChatWebhookCatalogue) async throws -> ChatWebhookSnapshot {
        guard webhookRecoveryError == nil,!webhookBusy,!uncertainWebhookCreates.contains(kind),original.accountGeneration == accountGeneration,let api = client else { throw ChatAPIError.connection }
        let epoch = accountGeneration;webhookBusy = true
        defer { if epoch == accountGeneration { webhookBusy = false } }
        let fresh = try await webhookCatalogue()
        guard fresh.canCreate else { throw ChatTransferError(message:"Your account cannot create integrations.") }
        var receipt = try ChatWebhookActionIntent(operation:.create,kind:kind)
        let lease = try acquireWebhookActionLease(receipt);defer { lease.release() }
        var targetLease:ChatAccountActionLease?;defer { targetLease?.release() }
        let scope = webhookActionJournal.accountScope
        try rememberWebhookAction(receipt)
        var dispatched = false
        do {
            try checkConversationSession(epoch);dispatched = true
            let created = try await api.createWebhook(kind:kind)
            guard !fresh.entries.contains(where:{ $0.id == created }) else { throw ChatAPIError.invalidResponse }
            let known = try receipt.withCreatedID(created)
            do { try webhookActionJournal.replaceInScope(receipt,with:known,originalScope:scope) }
            catch { if epoch == accountGeneration { webhookRecoveryError = "The integration was created, but its saved recovery checkpoint could not be updated. Inspect the integration list; do not create a replacement." };throw error }
            receipt = known
            if epoch == accountGeneration { pendingWebhookActions[receipt.id] = receipt;publishWebhookRecovery(Array(pendingWebhookActions.values)) }
            try checkConversationSession(epoch)
            targetLease = try webhookActionJournal.acquireActionLease(keys:["webhook:\(created)"])
            let result = try await ownedWebhook(created,kind:kind)
            if !result.detail.is_disabled { try await api.setWebhookEnabled(id:created,enabled:false);try checkConversationSession(epoch) }
            let disabled = try await ownedWebhook(created,kind:kind)
            guard disabled.detail.is_disabled else { throw ChatAPIError.invalidResponse }
            _ = finishWebhookAction(receipt);return disabled
        } catch {
            if !dispatched { cancelUndispatchedWebhookAction(receipt,scope:scope,epoch:epoch) }
            guard epoch == accountGeneration else { throw CancellationError() }
            if !dispatched { throw error }
            throw ChatWebhookFailure(uncertain:true,message:receipt.webhookID.map { "Integration \($0) was created but setup is unconfirmed. Refresh and inspect it; do not create a replacement." } ?? "Creation could not be confirmed. This is remembered across restarts. Inspect integrations before allowing another attempt.")
        }
    }
    func rotateWebhook(_ original: ChatWebhookSnapshot) async throws -> ChatWebhookSnapshot {
        let id = original.detail.user_id, epoch = accountGeneration
        guard webhookRecoveryError == nil,!webhookBusy, !uncertainWebhookIDs.contains(id), original.catalogue.accountGeneration == epoch, let api = client else { throw ChatAPIError.connection }
        webhookBusy = true; defer { if epoch == accountGeneration { webhookBusy = false } }
        let fresh = try await ownedWebhook(id, kind: original.kind)
        guard fresh.detail.sameConfiguration(as: original.detail), let old = fresh.detail.token else { throw ChatTransferError(message: "Refresh the integration before replacing its token.") }
        let record = try ChatWebhookActionIntent(operation:.rotate,kind:original.kind,webhookID:id,previousTokenFingerprint:old.fingerprint)
        let lease = try acquireWebhookActionLease(record);defer { lease.release() }
        let scope = webhookActionJournal.accountScope
        try rememberWebhookAction(record)
        var dispatched = false
        do {
            try checkConversationSession(epoch);dispatched = true
            let token = try await api.rotateWebhookToken(id: id); try checkConversationSession(epoch)
            let result = try await ownedWebhook(id, kind: original.kind)
            guard result.detail.token == token, token != old, result.detail.sameConfiguration(as: fresh.detail, includeToken: false) else { throw ChatAPIError.invalidResponse }
            _ = finishWebhookAction(record);return result
        } catch { if !dispatched { cancelUndispatchedWebhookAction(record,scope:scope,epoch:epoch) };guard epoch == accountGeneration else { throw CancellationError() };if !dispatched { throw error };throw ChatWebhookFailure(uncertain: true, message: "Token replacement could not be confirmed. Refresh to check for a new token. Do not repeat the replacement.") }
    }
    func removeWebhook(_ original: ChatWebhookSnapshot) async throws -> ChatWebhookCatalogue {
        let id = original.detail.user_id, epoch = accountGeneration
        guard webhookRecoveryError == nil,!webhookBusy, !uncertainWebhookIDs.contains(id), original.catalogue.accountGeneration == epoch, let api = client else { throw ChatAPIError.connection }
        webhookBusy = true; defer { if epoch == accountGeneration { webhookBusy = false } }
        let fresh = try await ownedWebhook(id, kind: original.kind)
        guard fresh.detail.sameConfiguration(as: original.detail) else { throw ChatTransferError(message: "Refresh before removing this integration; it changed in another client.") }
        let record = try ChatWebhookActionIntent(operation:.remove,kind:original.kind,webhookID:id)
        let lease = try acquireWebhookActionLease(record);defer { lease.release() }
        let scope = webhookActionJournal.accountScope
        try rememberWebhookAction(record)
        var dispatched = false
        do {
            try checkConversationSession(epoch);dispatched = true
            try await api.removeWebhook(id: id); try checkConversationSession(epoch)
            let result = try await webhookCatalogue()
            guard !result.entries.contains(where: { $0.id == id }) else { throw ChatAPIError.invalidResponse }
            _ = finishWebhookAction(record);return result
        } catch { if !dispatched { cancelUndispatchedWebhookAction(record,scope:scope,epoch:epoch) };guard epoch == accountGeneration else { throw CancellationError() };if !dispatched { throw error };throw ChatWebhookFailure(uncertain: true, message: "Removal could not be confirmed. Refresh the list to check whether the integration remains.") }
    }
}


extension NativeChatPreviewModel {
    private var selectedBotInteractionBlocked: Bool {
        guard let channel = selectedChannel, channel.type == "chatbot", let bot = channel.creator_id else { return false }
        return blockedBotIDs.contains(bot) || pendingBotSubscriptions[bot] != nil || botSubscriptionRecoveryError != nil
    }
    private func resetBotSubscriptionState() {
        botSubscriptionJournal.deactivate(); botBrowserBusy = false; blockedBotIDs = []; pendingBotSubscriptions = [:]; botSubscriptionRecoveryError = nil
    }
    private func restoreBotSubscriptions(scope: String?) {
        guard let scope else { botSubscriptionRecoveryError = "The account could not be identified for bot subscription recovery."; return }
        do { pendingBotSubscriptions = Dictionary(uniqueKeysWithValues: try botSubscriptionJournal.activate(scope: scope).map { ($0.botID, $0) }); botSubscriptionRecoveryError = nil }
        catch { botSubscriptionRecoveryError = "Saved bot operations could not be loaded. Bot changes are disabled; keep the recovery file and reconnect after resolving the storage problem." }
    }
    private func botCatalogue() async throws -> ChatBotCatalogue {
        guard connected, let api = client, let owner = currentUserID else { throw ChatAPIError.connection }
        let epoch = accountGeneration
        let users = try await api.chatbotSummaries(); try checkConversationSession(epoch)
        let joined = try await api.channels(); try checkConversationSession(epoch)
        let other = try await api.unjoinedChannels(); try checkConversationSession(epoch)
        let blocked = try await api.blockedChatbotIDs(); try checkConversationSession(epoch)
        let entries = try ChatBotCatalogue.entries(users: users, channels: joined + other.filter { $0.type == "chatbot" }, blockedIDs: blocked)
        return .init(entries: entries, joinedChannels: joined, blockedIDs: blocked, ownerID: owner, accountGeneration: epoch)
    }
    private func validateBotMembership(_ channel: ChatChannel, owner: Int64, epoch: Int) async throws {
        guard channel.type == "chatbot", !channel.encrypted, let api = client else { throw ChatAPIError.invalidResponse }
        let members = try await api.members(channelID: channel.id); try checkConversationSession(epoch)
        guard members == [owner] else { throw ChatTransferError(message: "This bot conversation does not belong exclusively to your account. No further action was taken.") }
    }
    private func publishBotCatalogue(_ catalogue: ChatBotCatalogue) {
        blockedBotIDs = catalogue.blockedIDs
        for entry in catalogue.entries { names[entry.id] = entry.bot.nickname; if let channel = entry.channel { channelNames[channel.id] = entry.bot.nickname } }
        channels = catalogue.joinedChannels.filter { $0.is_closed != true && !knownClosedChannelIDs.contains($0.id) && ($0.type != "chatbot" || !catalogue.blockedIDs.contains($0.creator_id ?? 0)) }.sorted { title($0).localizedCaseInsensitiveCompare(title($1)) == .orderedAscending }
        if let selected = selection, !channels.contains(where: { $0.id == selected }) {
            selection = nil; generation += 1; historyTask?.cancel(); closeThread(); posts = []
        }
    }
    private func reconcileBotSubscriptions(_ catalogue: ChatBotCatalogue) async throws {
        for intent in Array(pendingBotSubscriptions.values) where intent.isConfirmed(in: catalogue) {
            if !intent.blocked, let channel = catalogue.entries.first(where: { $0.id == intent.botID })?.channel {
                try await validateBotMembership(channel, owner: catalogue.ownerID, epoch: catalogue.accountGeneration)
            }
            try botSubscriptionJournal.remove(intent); pendingBotSubscriptions.removeValue(forKey: intent.botID)
        }
    }
    func loadBots() async throws -> ChatBotCatalogue {
        guard !botBrowserBusy else { throw ChatAPIError.connection }
        let epoch = accountGeneration; botBrowserBusy = true
        defer { if epoch == accountGeneration { botBrowserBusy = false } }
        if let account { restoreBotSubscriptions(scope: ChatNotificationAccountScope.make(account: account, userID: currentUserID)) }
        let catalogue = try await botCatalogue()
        if botSubscriptionRecoveryError == nil { try await reconcileBotSubscriptions(catalogue) }
        publishBotCatalogue(catalogue); return catalogue
    }
    private func freshBotEntry(_ original: ChatBotEntry, catalogue: ChatBotCatalogue) async throws -> (ChatBotEntry, ChatBotCatalogue) {
        guard catalogue.accountGeneration == accountGeneration, catalogue.ownerID == currentUserID, botSubscriptionRecoveryError == nil, pendingBotSubscriptions[original.id] == nil else { throw ChatTransferError(message: "Check pending bot operations before making another change.") }
        let fresh = try await botCatalogue()
        guard let entry = fresh.entries.first(where: { $0.id == original.id }), entry.bot == original.bot, entry.blocked == original.blocked, entry.channel?.id == original.channel?.id, entry.subscribed == original.subscribed else { throw ChatTransferError(message: "The bot or its subscription changed. Refresh the browser before continuing.") }
        return (entry, fresh)
    }
    @discardableResult func openBot(_ original: ChatBotEntry, catalogue: ChatBotCatalogue) async throws -> Bool {
        guard connected, !botBrowserBusy, !sending, !isEditingMessage, !preparingComposerAttachment, attachmentBatch == nil, slashCommandRequest == nil, let api = client else { throw ChatAPIError.connection }
        let epoch = accountGeneration, origin = selection, root = threadRoot?.id; botBrowserBusy = true
        defer { if epoch == accountGeneration { botBrowserBusy = false } }
        let (entry, fresh) = try await freshBotEntry(original, catalogue: catalogue)
        guard origin == selection, root == threadRoot?.id else { throw CancellationError() }
        var result = fresh
        if entry.subscribed, let channel = entry.channel {
            try await validateBotMembership(channel, owner: fresh.ownerID, epoch: epoch)
        } else {
            let intent = ChatBotSubscriptionIntent(botID: entry.id, blocked: false, priorChannelID: entry.channel?.id)
            let receiptScope = botSubscriptionJournal.accountScope
            try botSubscriptionJournal.remember(intent); pendingBotSubscriptions[entry.id] = intent
            var dispatched = false
            do {
                result = try await botCatalogue()
                if !intent.isConfirmed(in: result) {
                    guard let observed = result.entries.first(where: { $0.id == entry.id }), observed.bot == entry.bot, observed.blocked == entry.blocked, observed.channel?.id == entry.channel?.id, observed.subscribed == entry.subscribed else { throw ChatTransferError(message: "The bot changed before subscribing. Refresh the browser.") }
                    dispatched = true
                    let channel = try await api.initiateChatbot(userID: entry.id); try checkConversationSession(epoch)
                    result = try await botCatalogue()
                    guard result.entries.first(where: { $0.id == entry.id })?.channel?.id == channel.id else { throw ChatAPIError.invalidResponse }
                }
                guard intent.isConfirmed(in: result), let canonical = result.entries.first(where: { $0.id == entry.id })?.channel else { throw ChatAPIError.invalidResponse }
                try await validateBotMembership(canonical, owner: fresh.ownerID, epoch: epoch)
                try botSubscriptionJournal.remove(intent); pendingBotSubscriptions.removeValue(forKey: entry.id)
            } catch {
                if !dispatched {
                    do { try botSubscriptionJournal.removeUndispatched(intent, originalScope: receiptScope); if epoch == accountGeneration { pendingBotSubscriptions.removeValue(forKey: entry.id) } }
                    catch { guard epoch == accountGeneration else { throw CancellationError() }; throw ChatTransferError(message: "No subscription was sent, but its saved receipt could not be cleared. Refresh to check the pending operation.") }
                    guard epoch == accountGeneration else { throw CancellationError() }; throw error
                }
                guard epoch == accountGeneration else { throw CancellationError() }
                throw ChatTransferError(message: "The bot subscription could not be confirmed. Its pending operation was saved. Refresh to check the result; it will not be sent again automatically.")
            }
        }
        try checkConversationSession(epoch)
        publishBotCatalogue(result)
        guard origin == selection, root == threadRoot?.id, let channel = result.entries.first(where: { $0.id == entry.id && $0.subscribed })?.channel else { return false }
        closeThread(); if selection == channel.id { loadSelection() } else { selection = channel.id }
        return true
    }
    func unsubscribeBot(_ original: ChatBotEntry, catalogue: ChatBotCatalogue) async throws -> ChatBotCatalogue {
        guard connected, !botBrowserBusy, !sending, !isEditingMessage, let api = client else { throw ChatAPIError.connection }
        let epoch = accountGeneration; botBrowserBusy = true
        defer { if epoch == accountGeneration { botBrowserBusy = false } }
        let (entry, fresh) = try await freshBotEntry(original, catalogue: catalogue)
        guard entry.subscribed, let channel = entry.channel else { throw ChatTransferError(message: "Only a subscribed bot can be unsubscribed. Refresh the browser.") }
        try await validateBotMembership(channel, owner: fresh.ownerID, epoch: epoch)
        let intent = ChatBotSubscriptionIntent(botID: entry.id, blocked: true, priorChannelID: channel.id)
        let receiptScope = botSubscriptionJournal.accountScope
        try botSubscriptionJournal.remember(intent); pendingBotSubscriptions[entry.id] = intent
        var dispatched = false
        do {
            var result = try await botCatalogue()
            if !intent.isConfirmed(in: result) {
                guard let observed = result.entries.first(where: { $0.id == entry.id }), observed.bot == entry.bot, observed.channel?.id == channel.id, observed.subscribed else { throw ChatTransferError(message: "The bot changed before unsubscribing. Refresh the browser.") }
                try await validateBotMembership(channel, owner: fresh.ownerID, epoch: epoch)
                dispatched = true; try await api.blockChatbot(userID: entry.id); try checkConversationSession(epoch)
                result = try await botCatalogue()
            }
            guard intent.isConfirmed(in: result) else { throw ChatAPIError.invalidResponse }
            try botSubscriptionJournal.remove(intent); pendingBotSubscriptions.removeValue(forKey: entry.id)
            publishBotCatalogue(result); return result
        } catch {
            if !dispatched {
                do { try botSubscriptionJournal.removeUndispatched(intent, originalScope: receiptScope); if epoch == accountGeneration { pendingBotSubscriptions.removeValue(forKey: entry.id) } }
                catch { guard epoch == accountGeneration else { throw CancellationError() }; throw ChatTransferError(message: "No unsubscribe request was sent, but its saved receipt could not be cleared. Refresh to check the pending operation.") }
                guard epoch == accountGeneration else { throw CancellationError() }; throw error
            }
            guard epoch == accountGeneration else { throw CancellationError() }
            throw ChatTransferError(message: "Unsubscribing could not be confirmed. Its pending operation was saved. Refresh to check the result before another change.")
        }
    }
}


extension NativeChatPreviewModel {
    var canPresentQuickSwitcher: Bool {
        connected && !quickSwitcherBusy && !isEditingMessage && !sending && !channelManagementBusy && !botBrowserBusy && !webhookBusy && !slashBusy && slashCommandRequest == nil && !preparingComposerAttachment && attachmentBatch == nil
    }
    private func resetQuickSwitchState() { quickSwitcherBusy = false; pendingConversationStarts = [:]; conversationStartRecoveryError = nil; conversationStartJournal.deactivate() }
    private func restoreConversationStarts(scope: String?) {
        guard let scope else { conversationStartRecoveryError = "New conversations are disabled because this account could not be identified for recovery."; return }
        do { pendingConversationStarts = Dictionary(uniqueKeysWithValues: try conversationStartJournal.activate(scope: scope).map { ($0.id, $0) }); conversationStartRecoveryError = nil }
        catch { conversationStartRecoveryError = "Saved conversation operations could not be loaded. Existing conversations can still open; new starts are disabled until storage is repaired." }
    }
    private func quickSwitchSnapshot() async throws -> ChatQuickSwitchSnapshot {
        guard connected, let api = client, let owner = currentUserID else { throw ChatAPIError.connection }
        let epoch = accountGeneration
        let users = try await api.users(); try checkConversationSession(epoch)
        let channels = try await api.channels(); try checkConversationSession(epoch)
        let acl = try await api.channelPermissions(); try checkConversationSession(epoch)
        let blocked: Set<Int64>
        if channels.contains(where: { $0.type == "chatbot" }) { blocked = try await api.blockedChatbotIDs(); try checkConversationSession(epoch) } else { blocked = [] }
        let readable = channels.filter { $0.is_closed != true && !knownClosedChannelIDs.contains($0.id) }
        var members: [Int64: Set<Int64>] = [:]
        for channel in readable where ["anonymous", "synobot", "chatbot"].contains(channel.type) {
            let ids = try await api.members(channelID: channel.id); try checkConversationSession(epoch)
            guard Set(ids).count == ids.count, ids.allSatisfy({ $0 > 0 }) else { throw ChatAPIError.invalidResponse }
            members[channel.id] = Set(ids)
        }
        return try .build(users: users, channels: readable, members: members, ownerID: owner, canStart: acl.allows("channel_anonymous"), blockedBots: blocked, epoch: epoch, nameFormat: nameFormat)
    }
    private func confirmedConversation(_ intent: ChatConversationStartIntent, in snapshot: ChatQuickSwitchSnapshot) -> ChatQuickSwitchEntry? {
        guard intent.members.contains(snapshot.ownerID) else { return nil }
        return try? existingConversation(members: Set(intent.members), snapshot: snapshot)
    }
    func existingConversation(members: Set<Int64>, snapshot: ChatQuickSwitchSnapshot) throws -> ChatQuickSwitchEntry? {
        let matches = snapshot.entries.filter { $0.channel?.type == "anonymous" && !$0.encrypted && $0.memberIDs == members }
        guard matches.count <= 1 else { throw ChatTransferError(message: "More than one conversation matches these people. Open the intended conversation from the sidebar.") }
        return matches.first
    }
    private func validateConversationPeople(_ members: Set<Int64>, reviewed: ChatQuickSwitchSnapshot, fresh: ChatQuickSwitchSnapshot) throws {
        guard reviewed.ownerID == fresh.ownerID, members.contains(fresh.ownerID), members.count >= 2 else { throw ChatAPIError.invalidResponse }
        for id in members where id != fresh.ownerID {
            guard let previous = reviewed.users.first(where: { $0.user_id == id }), let current = fresh.users.first(where: { $0.user_id == id }),
                  previous.canStartConversation, current.canStartConversation, previous.username == current.username, previous.nickname == current.nickname else {
                throw ChatTransferError(message: "One of these people changed or is no longer available. Refresh and review the selection again.")
            }
        }
    }
    private func resolveConversationStart(members: Set<Int64>, reviewed: ChatQuickSwitchSnapshot, fresh initial: ChatQuickSwitchSnapshot, expectedExisting: Int64?, epoch: Int, origin: Int64?, root: Int64?) async throws -> (entry: ChatQuickSwitchEntry, snapshot: ChatQuickSwitchSnapshot) {
        try validateConversationPeople(members, reviewed: reviewed, fresh: initial)
        guard origin == selection, root == threadRoot?.id else { throw CancellationError() }
        var fresh = initial
        if let existing = try existingConversation(members: members, snapshot: fresh) {
            guard expectedExisting == nil || existing.channel?.id == expectedExisting else { throw ChatTransferError(message: "The reviewed conversation changed. Refresh the selection before opening it.") }
            return (existing, fresh)
        }
        guard expectedExisting == nil else { throw ChatTransferError(message: "The reviewed conversation is no longer available. Refresh before starting another.") }
        guard conversationStartRecoveryError == nil, fresh.canStartConversations, liveStatus == .live, let api = client else { throw ChatTransferError(message: "New conversations are currently unavailable. Refresh or reconnect.") }
        let intent = ChatConversationStartIntent(members: members)
        guard pendingConversationStarts[intent.id] == nil else { throw ChatTransferError(message: "This conversation start is unconfirmed. Refresh checks its result without repeating it.") }
        let scope = conversationStartJournal.accountScope
        try conversationStartJournal.remember(intent); pendingConversationStarts[intent.id] = intent
        var dispatched = false
        do {
            fresh = try await quickSwitchSnapshot()
            try validateConversationPeople(members, reviewed: reviewed, fresh: fresh)
            if try existingConversation(members: members, snapshot: fresh) == nil {
                guard fresh.canStartConversations, origin == selection, root == threadRoot?.id, liveStatus == .live, !isEditingMessage else { throw ChatTransferError(message: "The destination or permission changed before starting. Refresh the selection.") }
                dispatched = true
                let created = try await api.initiateConversation(userIDs: intent.members); try checkConversationSession(epoch)
                fresh = try await quickSwitchSnapshot()
                guard try existingConversation(members: members, snapshot: fresh)?.channel?.id == created.id else { throw ChatAPIError.invalidResponse }
            }
            guard let confirmed = try existingConversation(members: members, snapshot: fresh) else { throw ChatAPIError.invalidResponse }
            try conversationStartJournal.remove(intent); pendingConversationStarts.removeValue(forKey: intent.id)
            return (confirmed, fresh)
        } catch {
            if !dispatched {
                do { try conversationStartJournal.removeUndispatched(intent, originalScope: scope); if epoch == accountGeneration { pendingConversationStarts.removeValue(forKey: intent.id) } }
                catch { guard epoch == accountGeneration else { throw CancellationError() }; throw ChatTransferError(message: "No conversation request was sent, but the saved receipt could not be cleared. Refresh to inspect it.") }
                guard epoch == accountGeneration else { throw CancellationError() }; throw error
            }
            guard epoch == accountGeneration else { throw CancellationError() }
            throw ChatTransferError(message: "The conversation start could not be confirmed. Its operation was saved. Refresh to check for the conversation; this request will not be repeated automatically.")
        }
    }
    private func applyConversationRoute(_ routed: ChatQuickSwitchEntry, snapshot: ChatQuickSwitchSnapshot) {
        guard let channel = routed.channel else { return }
        directory = snapshot.users
        channelNames[channel.id] = routed.title
        if !routed.memberIDs.isEmpty { channelMemberIDs[channel.id] = routed.memberIDs.sorted() }
        blockedBotIDs = snapshot.blockedBots
        channels = snapshot.channels.filter { $0.is_closed != true && !knownClosedChannelIDs.contains($0.id) && ($0.type != "chatbot" || !snapshot.blockedBots.contains($0.creator_id ?? 0)) }.sorted { title($0).localizedCaseInsensitiveCompare(title($1)) == .orderedAscending }
        closeThread(); if selection == channel.id { loadSelection() } else { selection = channel.id }
    }
    func loadQuickSwitcher() async throws -> ChatQuickSwitchSnapshot {
        guard connected, !quickSwitcherBusy, !channelManagementBusy else { throw ChatAPIError.connection }
        let epoch = accountGeneration; quickSwitcherBusy = true
        defer { if epoch == accountGeneration { quickSwitcherBusy = false } }
        if let account { restoreConversationStarts(scope: ChatNotificationAccountScope.make(account: account, userID: currentUserID)) }
        let snapshot = try await quickSwitchSnapshot()
        if conversationStartRecoveryError == nil {
            for intent in Array(pendingConversationStarts.values) where confirmedConversation(intent, in: snapshot) != nil { try conversationStartJournal.remove(intent); pendingConversationStarts.removeValue(forKey: intent.id) }
        }
        return snapshot
    }
    func quickSwitchStartPending(_ entry: ChatQuickSwitchEntry, snapshot: ChatQuickSwitchSnapshot) -> Bool {
        pendingConversationStarts[ChatConversationStartIntent(members: entry.memberIDs.union([snapshot.ownerID])).id] != nil
    }
    @discardableResult func openQuickSwitch(_ original: ChatQuickSwitchEntry, snapshot: ChatQuickSwitchSnapshot) async throws -> Bool {
        guard canPresentQuickSwitcher, snapshot.accountGeneration == accountGeneration, snapshot.ownerID == currentUserID, snapshot.entries.contains(where: { $0.id == original.id }), let api = client else { throw ChatAPIError.connection }
        let epoch = accountGeneration, origin = selection, root = threadRoot?.id
        quickSwitcherBusy = true; defer { if epoch == accountGeneration { quickSwitcherBusy = false } }
        var fresh = try await quickSwitchSnapshot()
        guard origin == selection, root == threadRoot?.id else { throw CancellationError() }
        var entry: ChatQuickSwitchEntry?
        if let channel = original.channel {
            entry = fresh.entries.first { $0.channel?.id == channel.id }
            guard let current = entry, let canonical = current.channel, canonical.type == channel.type, canonical.encrypted == channel.encrypted, canonical.channel_key_enc == channel.channel_key_enc, canonical.name == channel.name, current.memberIDs == original.memberIDs else { throw ChatTransferError(message: "This conversation changed. Refresh the switcher before opening it.") }
        } else if let peer = original.person {
            entry = fresh.entries.first { $0.kind == .person && $0.person?.user_id == peer.user_id }
            guard let current = entry, current.person?.username == peer.username, current.person?.nickname == peer.nickname else { throw ChatTransferError(message: "This person changed or is no longer available. Refresh the switcher.") }
        }
        guard let chosen = entry else { throw ChatAPIError.invalidResponse }
        if chosen.channel == nil {
            guard let peer = chosen.person else { throw ChatAPIError.invalidResponse }
            let result = try await resolveConversationStart(members: [snapshot.ownerID, peer.user_id], reviewed: snapshot, fresh: fresh, expectedExisting: nil, epoch: epoch, origin: origin, root: root)
            entry = result.entry; fresh = result.snapshot
        }
        try checkConversationSession(epoch)
        guard origin == selection, root == threadRoot?.id, !isEditingMessage, let routed = entry, let channel = routed.channel else { return false }
        if channel.type == "chatbot", pendingBotSubscriptions[channel.creator_id ?? 0] != nil || botSubscriptionRecoveryError != nil { throw ChatTransferError(message: "Check this bot’s pending operation in Browse bots first.") }
        applyConversationRoute(routed, snapshot: fresh)
        return true
    }
}

extension NativeChatPreviewModel {
    var canEditChannelAlerts: Bool { connected && selectedChannel.map { $0.is_closed != true && $0.is_joined != false && ["public","private","anonymous","synobot","chatbot"].contains($0.type) } == true }
    private func channelAlertsSource(_ id: Int64, expected: Int) async throws -> (ChatChannel, Set<Int64>?) {
        guard connected, let api = client else { throw ChatAPIError.connection }
        let values = try await api.channels(); try checkChannelAlertsSession(expected)
        guard Set(values.map(\.id)).count == values.count, let channel = values.first(where: { $0.id == id }), channel.is_closed != true, channel.is_joined != false, !knownClosedChannelIDs.contains(channel.id),
              ["public","private","anonymous","synobot","chatbot"].contains(channel.type) else { throw ChatTransferError(message: "This conversation is no longer available. Close these settings and refresh.") }
        if ["anonymous","synobot","chatbot"].contains(channel.type) {
            let ids = try await api.members(channelID: id); try checkChannelAlertsSession(expected)
            guard let me = currentUserID, ids.contains(me), ids.allSatisfy({ $0 > 0 }), Set(ids).count == ids.count else { throw ChatAPIError.invalidResponse }
            return (channel, Set(ids))
        }
        return (channel, nil)
    }
    private func checkChannelAlertsSession(_ epoch: Int) throws {
        try Task.checkCancellation(); guard connected, epoch == accountGeneration else { throw CancellationError() }
    }
    private func matchingAlertSource(_ source: ChatChannelAlertsSnapshot, channel: ChatChannel, members: Set<Int64>?) -> Bool {
        source.channel.id == channel.id && source.channel.type == channel.type && source.channel.name == channel.name && source.channel.encrypted == channel.encrypted && source.channel.channel_key_enc == channel.channel_key_enc && source.memberIDs == members
    }
    func loadChannelAlerts(channelID: Int64) async throws -> ChatChannelAlertsSnapshot {
        guard connected, !channelAlertsBusy, let api = client else { throw ChatAPIError.connection }
        let epoch = accountGeneration; channelAlertsBusy = true
        defer { if epoch == accountGeneration { channelAlertsBusy = false } }
        let (channel, members) = try await channelAlertsSource(channelID, expected: epoch)
        let settings = try await api.channelAlerts(channelID: channelID); try checkChannelAlertsSession(epoch)
        channelAlertsNeedRefresh.remove(channelID)
        return .init(channel: channel, memberIDs: members, settings: settings, accountGeneration: epoch)
    }
    func saveChannelAlerts(original: ChatChannelAlertsSnapshot, draft: ChatChannelAlertsDraft) async throws -> ChatChannelAlertsSnapshot {
        guard connected, !channelAlertsBusy, !channelAlertsNeedRefresh.contains(original.channel.id), original.accountGeneration == accountGeneration, let api = client else { throw ChatAPIError.connection }
        let patch = try draft.patch(from: original.settings, channel: original.channel)
        guard !patch.isEmpty else { throw ChatAPIError.invalidResponse }
        let epoch = accountGeneration; channelAlertsBusy = true; var dispatched = false
        defer { if epoch == accountGeneration { channelAlertsBusy = false } }
        do {
            let (current, members) = try await channelAlertsSource(original.channel.id, expected: epoch)
            guard matchingAlertSource(original, channel: current, members: members) else { throw ChatPreferenceUpdateFailure(uncertain: false, message: "This conversation changed. Refresh before saving its notification settings.") }
            let before = try await api.channelAlerts(channelID: current.id); try checkChannelAlertsSession(epoch)
            guard patch.keys.allSatisfy({ before.fields[$0] == original.settings.fields[$0] }) else { throw ChatPreferenceUpdateFailure(uncertain: false, message: "These notification modes changed in another client. Refresh before saving.") }
            dispatched = true; try await api.setChannelAlerts(channel: current, patch: patch); try checkChannelAlertsSession(epoch)
            let after = try await api.channelAlerts(channelID: current.id); try checkChannelAlertsSession(epoch)
            let (confirmed, confirmedMembers) = try await channelAlertsSource(current.id, expected: epoch)
            guard matchingAlertSource(original, channel: confirmed, members: confirmedMembers), patch.allSatisfy({ after.fields[$0.key] == $0.value }) else { throw ChatAPIError.invalidResponse }
            // Reload the sidebar's personal preference projection; alert delivery
            // continues to consume the server's notification events.
            channels = (channels.filter { $0.id != confirmed.id } + [confirmed]).sorted { title($0).localizedCaseInsensitiveCompare(title($1)) == .orderedAscending }
            return .init(channel: confirmed, memberIDs: confirmedMembers, settings: after, accountGeneration: epoch)
        } catch {
            guard epoch == accountGeneration else { throw CancellationError() }
            if dispatched { channelAlertsNeedRefresh.insert(original.channel.id); throw ChatPreferenceUpdateFailure(uncertain: true, message: "The notification change could not be confirmed. Refresh to check the server before saving again.") }
            throw error
        }
    }
}

extension NativeChatPreviewModel {
    private func refreshSidebarAnchor() {
        sidebarAnchor = selection.flatMap { id in channels.first(where: { $0.id == id }).map { ChatSidebarProjection.anchor($0, pinUnread: sidebarSettings?.sidebar_pinning_unread == true) } }
    }
    func sidebarSections(query: String) -> [ChatSidebarSection] {
        ChatSidebarProjection.sections(channels: channels, pinUnread: sidebarSettings?.sidebar_pinning_unread == true, selectedID: selection, anchor: sidebarAnchor, closed: knownClosedChannelIDs, blockedBots: blockedBotIDs, query: query, title: title, searchNames: { channel in
            let ids: Set<Int64>
            if channel.type == "anonymous" { ids = Set((self.channelMemberIDs[channel.id] ?? []).filter { $0 != self.currentUserID }) }
            else if channel.type == "chatbot", let creator = channel.creator_id { ids = [creator] }
            else { return [] }
            return self.directory.filter { ids.contains($0.user_id) }.flatMap { [$0.nickname, $0.username ?? ""] }
        })
    }
    private func refreshSidebarSettingsInBackground() {
        guard connected, !sidebarSettingsBusy, let api = client else { return }
        let epoch = accountGeneration, revision = UUID(); sidebarReadRevision = revision
        eventTasks[revision] = Task { [weak self] in
            defer { self?.eventTasks[revision] = nil }
            let settings = try? await api.sidebarSettings()
            guard let self, !Task.isCancelled, self.accountGeneration == epoch, self.sidebarReadRevision == revision, !self.sidebarSettingsBusy, let settings else { return }
            self.sidebarSettings = settings
        }
    }
    func loadSidebarSettings() async throws -> ChatSidebarSettingsSnapshot {
        guard connected, !sidebarSettingsBusy, let api = client else { throw ChatAPIError.connection }
        let epoch = accountGeneration; sidebarSettingsBusy = true; sidebarReadRevision = UUID()
        defer { if epoch == accountGeneration { sidebarSettingsBusy = false } }
        let settings = try await api.sidebarSettings(); try checkConversationSession(epoch)
        sidebarSettings = settings; sidebarSettingsNeedRefresh = false
        return .init(settings: settings, accountGeneration: epoch)
    }
    func saveSidebarSettings(original: ChatSidebarSettingsSnapshot, pinUnread: Bool) async throws -> ChatSidebarSettingsSnapshot {
        guard connected, !sidebarSettingsBusy, !sidebarSettingsNeedRefresh, original.accountGeneration == accountGeneration, original.settings.sidebar_pinning_unread != pinUnread, let api = client else { throw ChatAPIError.connection }
        let epoch = accountGeneration; sidebarSettingsBusy = true; sidebarReadRevision = UUID(); var dispatched = false
        defer { if epoch == accountGeneration { sidebarSettingsBusy = false } }
        do {
            let before = try await api.sidebarSettings(); try checkConversationSession(epoch)
            guard before == original.settings else { throw ChatPreferenceUpdateFailure(uncertain:false,message:"The sidebar preference changed in another client. Refresh before saving.") }
            let requested = ChatSidebarSettings(sidebar_pinning_unread:pinUnread)
            dispatched = true; try await api.setSidebarSettings(requested); try checkConversationSession(epoch)
            let after = try await api.sidebarSettings(); try checkConversationSession(epoch)
            guard after == requested else { throw ChatAPIError.invalidResponse }
            sidebarSettings = after
            return .init(settings:after,accountGeneration:epoch)
        } catch {
            guard epoch == accountGeneration else { throw CancellationError() }
            if dispatched { sidebarSettingsNeedRefresh = true; throw ChatPreferenceUpdateFailure(uncertain:true,message:"The sidebar change could not be confirmed. Refresh to check the server before saving again.") }
            throw error
        }
    }
}

extension NativeChatPreviewModel {
    var nameFormat: ChatNameFormat { nameSettings?.prefer_user_name_format ?? .nickname }
    func displayName(_ user: ChatUser) -> String { nameFormat.display(user) }
    func additionalName(_ user: ChatUser) -> String? { nameFormat.additional(user) }
    private func rebuildDisplayNames() {
        names = Dictionary(directory.map { ($0.user_id, displayName($0)) }, uniquingKeysWith: { first,_ in first })
    }
    private func refreshNameSettingsInBackground() {
        guard connected, !nameSettingsBusy, let api = client else { return }
        let epoch = accountGeneration, revision = UUID(); nameReadRevision = revision
        eventTasks[revision] = Task { [weak self] in
            defer { self?.eventTasks[revision] = nil }
            let settings = try? await api.nameSettings()
            guard let self, !Task.isCancelled, self.accountGeneration == epoch, self.nameReadRevision == revision, !self.nameSettingsBusy, let settings else { return }
            self.nameSettings = settings
        }
    }
    func loadNameSettings() async throws -> ChatNameSettingsSnapshot {
        guard connected, !nameSettingsBusy, let api = client else { throw ChatAPIError.connection }
        let epoch = accountGeneration; nameSettingsBusy = true; nameReadRevision = UUID()
        defer { if epoch == accountGeneration { nameSettingsBusy = false } }
        let settings = try await api.nameSettings(); try checkConversationSession(epoch)
        nameSettings = settings; nameSettingsNeedRefresh = false
        return .init(settings:settings,accountGeneration:epoch)
    }
    func saveNameSettings(original: ChatNameSettingsSnapshot, format: ChatNameFormat) async throws -> ChatNameSettingsSnapshot {
        guard connected, !nameSettingsBusy, !nameSettingsNeedRefresh, original.accountGeneration == accountGeneration, original.settings.prefer_user_name_format != format, let api = client else { throw ChatAPIError.connection }
        let epoch = accountGeneration; nameSettingsBusy = true; nameReadRevision = UUID(); var dispatched = false
        defer { if epoch == accountGeneration { nameSettingsBusy = false } }
        do {
            let before = try await api.nameSettings(); try checkConversationSession(epoch)
            guard before == original.settings else { throw ChatPreferenceUpdateFailure(uncertain:false,message:"The name preference changed in another client. Refresh before saving.") }
            let requested = ChatNameSettings(prefer_user_name_format:format)
            dispatched = true; try await api.setNameSettings(requested); try checkConversationSession(epoch)
            let after = try await api.nameSettings(); try checkConversationSession(epoch)
            guard after == requested else { throw ChatAPIError.invalidResponse }
            nameSettings = after
            return .init(settings:after,accountGeneration:epoch)
        } catch {
            guard epoch == accountGeneration else { throw CancellationError() }
            if dispatched { nameSettingsNeedRefresh = true; throw ChatPreferenceUpdateFailure(uncertain:true,message:"The name preference change could not be confirmed. Refresh to check the server before saving again.") }
            throw error
        }
    }
}


extension NativeChatPreviewModel {
    private func refreshAppearanceSettingsInBackground() {
        guard connected, !appearanceSettingsBusy, let api = client else { return }
        let epoch = accountGeneration, revision = UUID(); appearanceReadRevision = revision
        eventTasks[revision] = Task { [weak self] in
            defer { self?.eventTasks[revision] = nil }
            let settings = try? await api.appearanceSettings()
            guard let self, !Task.isCancelled, self.accountGeneration == epoch,
                  self.appearanceReadRevision == revision, !self.appearanceSettingsBusy, let settings else { return }
            self.appearanceSettings = settings
        }
    }
    func loadAppearanceSettings() async throws -> ChatAppearanceSettingsSnapshot {
        guard connected, !appearanceSettingsBusy, let api = client else { throw ChatAPIError.connection }
        let epoch = accountGeneration; appearanceSettingsBusy = true; appearanceReadRevision = UUID()
        defer { if epoch == accountGeneration { appearanceSettingsBusy = false } }
        let settings = try await api.appearanceSettings(); try checkConversationSession(epoch)
        try Task.checkCancellation()
        appearanceSettings = settings; appearanceSettingsNeedRefresh = false
        return .init(settings: settings, accountGeneration: epoch)
    }
    func saveAppearanceSettings(original: ChatAppearanceSettingsSnapshot, desired: ChatAppearanceSettings) async throws -> ChatAppearanceSettingsSnapshot {
        guard connected, !appearanceSettingsBusy, !appearanceSettingsNeedRefresh,
              original.accountGeneration == accountGeneration, let api = client else { throw ChatAPIError.connection }
        let patch = try ChatAppearanceSettingsPatch(original: original.settings, desired: desired)
        let epoch = accountGeneration; appearanceSettingsBusy = true; appearanceReadRevision = UUID()
        var dispatched = false
        defer { if epoch == accountGeneration { appearanceSettingsBusy = false } }
        do {
            let before = try await api.appearanceSettings(); try checkConversationSession(epoch)
            try Task.checkCancellation()
            guard patch.matches(current: before, original: original.settings) else {
                throw ChatPreferenceUpdateFailure(uncertain: false, message: "Appearance changed in another client. Refresh before saving.")
            }
            _ = try api.requestForCall(api: "SYNO.Chat.User.Preference", method: "set", version: 4, parameters: patch.parameters)
            dispatched = true; try await api.setAppearanceSettings(patch); try checkConversationSession(epoch)
            let after = try await api.appearanceSettings(); try checkConversationSession(epoch)
            try Task.checkCancellation()
            guard patch.matches(current: after, original: desired) else { throw ChatAPIError.invalidResponse }
            appearanceSettings = after
            return .init(settings: after, accountGeneration: epoch)
        } catch {
            guard epoch == accountGeneration else { throw CancellationError() }
            if dispatched {
                appearanceSettingsNeedRefresh = true
                throw ChatPreferenceUpdateFailure(uncertain: true, message: "The appearance change could not be confirmed. Refresh to check the account before saving again.")
            }
            throw error
        }
    }
    func loadAppearanceWallpaper(_ settings: ChatAppearanceSettings) async throws -> Data? {
        guard connected, let api = client else { throw ChatAPIError.connection }
        let epoch = accountGeneration
        let data = try await api.appearanceWallpaper(settings)
        try checkConversationSession(epoch); try Task.checkCancellation()
        return data
    }
}

extension NativeChatPreviewModel {
    private func restoreEncryptedConversationRecovery(scope:String?) {
        encryptedConversationRecoveryScope = scope;pendingEncryptedConversationStarts = [:]
        guard let scope else { encryptedConversationRecoveryError = "This account could not be identified for encrypted conversation recovery.";return }
        do { pendingEncryptedConversationStarts = Dictionary(uniqueKeysWithValues:try encryptedConversationJournal.activate(scope:scope).map { ($0.id,$0) });encryptedConversationRecoveryError = nil }
        catch { encryptedConversationRecoveryError = "Saved encrypted conversation state could not be loaded. Repair storage and refresh before starting another encrypted conversation." }
    }
    private func finalEncryptedConversationPreflight(api:ChatAPIClient,epoch:Int,keyEpoch:Int,owner:ChatEncryptionKeyPair,plan:ChatEncryptedConversationStart) async throws -> [ChatUser] {
        let permissions = try await api.channelPermissions();try checkConversationSession(epoch)
        guard permissions.allows("channel_anonymous") else { throw ChatTransferError(message:"Your account cannot start conversations.") }
        let fresh = try await api.encryptionConversationDirectory(ownerID:plan.ownerID);try checkConversationSession(epoch)
        guard canInteract,!sending,!isEditingMessage,liveStatus == .live,encryptionUnlocked,keyEpoch == encryptionGeneration,
              currentUserID == plan.ownerID,let cached = encryptionKeyPair,
              fresh.owner == ChatEncryptionOwnerState(userID:plan.ownerID,pair:owner),
              fresh.owner == ChatEncryptionOwnerState(userID:plan.ownerID,pair:cached) else { throw CancellationError() }
        let selected = fresh.users.filter { plan.userIDs.contains($0.user_id) }
        try plan.validate(owner:owner,users:selected,encryption:encryption)
        return selected
    }
    func refreshEncryptedConversationRecovery(expectedGeneration:Int) throws {
        try checkConversationSession(expectedGeneration)
        guard !channelManagementBusy else { throw ChatAPIError.connection }
        restoreEncryptedConversationRecovery(scope:encryptedConversationRecoveryScope)
        if let error = encryptedConversationRecoveryError { throw ChatTransferError(message:error) }
    }
    func acknowledgeEncryptedConversationStart(_ intent:ChatEncryptedConversationIntent,expectedGeneration:Int) throws {
        try refreshEncryptedConversationRecovery(expectedGeneration:expectedGeneration)
        guard pendingEncryptedConversationStarts[intent.id] == intent,intent.ownerID == currentUserID else { throw ChatAPIError.connection }
        do { try encryptedConversationJournal.remove(intent);pendingEncryptedConversationStarts.removeValue(forKey:intent.id) }
        catch { encryptedConversationRecoveryError = "The saved encrypted conversation warning could not be cleared.";throw error }
    }
    private func matchingEncryptedConversation(_ members:Set<Int64>,snapshot:ChatQuickSwitchSnapshot) throws -> ChatQuickSwitchEntry? {
        let matches = snapshot.entries.filter { $0.channel?.type == "anonymous" && $0.encrypted && $0.channel?.is_joined == true && $0.memberIDs == members }
        guard matches.count <= 1 else { throw ChatTransferError(message:"More than one encrypted conversation matches these people. Open the intended conversation from the sidebar.") }
        return matches.first
    }
    func existingEncryptedConversation(members:Set<Int64>,snapshot:ChatQuickSwitchSnapshot) throws -> ChatQuickSwitchEntry? { try matchingEncryptedConversation(members,snapshot:snapshot) }
    func prepareEncryptedConversationOpen(_ intent:ChatEncryptedConversationIntent,expectedGeneration:Int) async throws -> ChatEncryptedConversationOpenReview {
        let keyEpoch = encryptionGeneration
        let status = try await checkEncryptedConversationStart(intent,expectedGeneration:expectedGeneration)
        guard [.verified,.existingNeedsReview].contains(status.status),encryptionUnlocked,keyEpoch == encryptionGeneration,
              pendingEncryptedConversationStarts[intent.id] == intent,let owner = encryptionKeyPair else { throw ChatTransferError(message:"Unlock encryption and verify this conversation before opening it.") }
        let snapshot = try await quickSwitchSnapshot();try checkConversationSession(expectedGeneration)
        let current = encryptedConversationRecoveryResult(intent,snapshot:snapshot,owner:owner)
        guard current == status,keyEpoch == encryptionGeneration,pendingEncryptedConversationStarts[intent.id] == intent,let id = current.candidateChannelID,
              let channel = snapshot.channels.first(where:{ $0.id == id }) else { throw ChatAPIError.invalidResponse }
        return .init(intent:intent,channel:channel,accountGeneration:expectedGeneration,keyGeneration:keyEpoch,requiresExistingReview:status.status == .existingNeedsReview,participants:snapshot.users.filter { intent.memberIDs.contains($0.user_id) })
    }
    func openRecoveredEncryptedConversation(_ review:ChatEncryptedConversationOpenReview) async throws {
        let epoch = review.accountGeneration,keyEpoch = review.keyGeneration,intent = review.intent
        let origin = selection,originThread = threadRoot?.id
        try checkConversationSession(epoch)
        guard !channelManagementBusy,encryptionUnlocked,keyEpoch == encryptionGeneration,pendingEncryptedConversationStarts[intent.id] == intent,
              let owner = encryptionKeyPair,let api = client else { throw ChatAPIError.connection }
        channelManagementBusy = true;defer { if epoch == accountGeneration { channelManagementBusy = false } }
        let first = try await quickSwitchSnapshot();try checkConversationSession(epoch)
        let snapshot = try await quickSwitchSnapshot();try checkConversationSession(epoch)
        let fresh = try await api.encryptionConversationDirectory(ownerID:intent.ownerID);try checkConversationSession(epoch)
        guard keyEpoch == encryptionGeneration,encryptionUnlocked,pendingEncryptedConversationStarts[intent.id] == intent,
              currentUserID == intent.ownerID,fresh.owner == ChatEncryptionOwnerState(userID:intent.ownerID,pair:owner),intent.matchesReviewedKeys(fresh.users),
              review.participants.allSatisfy({ person in fresh.users.contains { $0.user_id == person.user_id && $0.username == person.username && $0.nickname == person.nickname } }) else { throw CancellationError() }
        let status = encryptedConversationRecoveryResult(intent,snapshot:snapshot,owner:fresh.owner.pair)
        let expected:ChatEncryptedConversationRecovery.Status = review.requiresExistingReview ? .existingNeedsReview : .verified
        guard origin == selection,originThread == threadRoot?.id,!isEditingMessage,
              status == encryptedConversationRecoveryResult(intent,snapshot:first,owner:fresh.owner.pair),status.status == expected,status.candidateChannelID == review.channel.id,
              let route = try matchingEncryptedConversation(Set(intent.memberIDs),snapshot:snapshot),let channel = route.channel,
              channel.id == review.channel.id,let old = review.channel.channel_key_enc,let current = channel.channel_key_enc,
              try ChatContentCrypto.decodeBase64(old) == ChatContentCrypto.decodeBase64(current) else { throw ChatTransferError(message:"The conversation changed after review. Check its status again before opening it.") }
        do { try encryptedConversationJournal.remove(intent);pendingEncryptedConversationStarts.removeValue(forKey:intent.id) }
        catch { encryptedConversationRecoveryError = "The conversation is verified, but its saved warning could not be cleared." }
        applyConversationRoute(route,snapshot:snapshot)
    }
    private func encryptedConversationRecoveryResult(_ intent:ChatEncryptedConversationIntent,snapshot:ChatQuickSwitchSnapshot,owner:ChatEncryptionKeyPair) -> ChatEncryptedConversationRecovery.Result {
        let observations = snapshot.channels.map { channel in
            ChatEncryptedConversationRecovery.Snapshot(channel:channel,memberIDs:snapshot.entries.first(where:{ $0.channel?.id == channel.id }).map { Array($0.memberIDs) })
        }
        return ChatEncryptedConversationRecovery.evaluate(intent,owner:owner,users:snapshot.users,snapshots:observations,encryption:encryption)
    }
    /// Read-only: does not clear a receipt, switch conversations or repeat a request.
    func checkEncryptedConversationStart(_ intent:ChatEncryptedConversationIntent,expectedGeneration:Int) async throws -> ChatEncryptedConversationRecovery.Result {
        try refreshEncryptedConversationRecovery(expectedGeneration:expectedGeneration)
        guard pendingEncryptedConversationStarts[intent.id] == intent,intent.ownerID == currentUserID,let api = client else { throw ChatAPIError.connection }
        let keyEpoch = encryptionGeneration
        channelManagementBusy = true;defer { if expectedGeneration == accountGeneration { channelManagementBusy = false } }
        let owner = try await api.encryptionOwnerState(userID:intent.ownerID);try checkConversationSession(expectedGeneration)
        var snapshot = try await quickSwitchSnapshot();try checkConversationSession(expectedGeneration)
        let first = encryptedConversationRecoveryResult(intent,snapshot:snapshot,owner:owner.pair)
        snapshot = try await quickSwitchSnapshot();try checkConversationSession(expectedGeneration)
        let freshOwner = try await api.encryptionOwnerState(userID:intent.ownerID);try checkConversationSession(expectedGeneration)
        guard freshOwner == owner,keyEpoch == encryptionGeneration,pendingEncryptedConversationStarts[intent.id] == intent else { throw CancellationError() }
        let result = encryptedConversationRecoveryResult(intent,snapshot:snapshot,owner:freshOwner.pair)
        guard result == first else { throw ChatTransferError(message:"The encrypted conversation changed while checking. Refresh its status again.") }
        return result
    }
    /// One reviewed account transaction. The ordinary start path is independent.
    func startEncryptedConversation(with peers:Set<Int64>,reviewed:ChatQuickSwitchSnapshot) async throws {
        let epoch = accountGeneration,keyEpoch = encryptionGeneration,origin = selection,root = threadRoot?.id
        try refreshEncryptedConversationRecovery(expectedGeneration:epoch)
        guard canInteract,!sending,!isEditingMessage,!channelManagementBusy,encryptionUnlocked,liveStatus == .live,
              let api = client,let ownerID = currentUserID,let owner = encryptionKeyPair,
              reviewed.accountGeneration == epoch,reviewed.ownerID == ownerID,!peers.isEmpty,!peers.contains(ownerID),peers.allSatisfy({ $0 > 0 }),
              pendingEncryptedConversationStarts.isEmpty else { throw ChatAPIError.connection }
        let members = peers.union([ownerID]),users = reviewed.users.filter { members.contains($0.user_id) }
        let plan = try ChatEncryptedConversationStart(ownerID:ownerID,owner:owner,users:users,encryption:encryption)
        guard Set(plan.userIDs) == members else { throw ChatAPIError.invalidResponse }
        let reviewedExisting = try matchingEncryptedConversation(members,snapshot:reviewed)?.channel?.id
        channelManagementBusy = true;defer { if epoch == accountGeneration { channelManagementBusy = false } }
        try await checkEncryptedCreationContext(api:api,expected:epoch,keyEpoch:keyEpoch,ownerID:ownerID,owner:owner,permission:"channel_anonymous")
        var snapshot = try await quickSwitchSnapshot();try checkConversationSession(epoch)
        try validateConversationPeople(members,reviewed:reviewed,fresh:snapshot)
        try plan.validate(owner:owner,users:snapshot.users.filter { members.contains($0.user_id) },encryption:encryption)
        guard origin == selection,root == threadRoot?.id,keyEpoch == encryptionGeneration else { throw CancellationError() }
        if let existing = try matchingEncryptedConversation(members,snapshot:snapshot) {
            guard reviewedExisting == nil || existing.channel?.id == reviewedExisting,let channel = existing.channel else { throw ChatAPIError.invalidResponse }
            _ = try encryption.key(for:channel)
            let confirmed = try await quickSwitchSnapshot();try checkConversationSession(epoch)
            try plan.validate(owner:owner,users:confirmed.users.filter { members.contains($0.user_id) },encryption:encryption)
            guard let route = try matchingEncryptedConversation(members,snapshot:confirmed),route.channel?.id == channel.id,route.channel?.channel_key_enc == channel.channel_key_enc else { throw ChatAPIError.invalidResponse }
            _ = try await finalEncryptedConversationPreflight(api:api,epoch:epoch,keyEpoch:keyEpoch,owner:owner,plan:plan)
            guard origin == selection,root == threadRoot?.id,!isEditingMessage else { throw CancellationError() }
            applyConversationRoute(route,snapshot:confirmed);return
        }
        guard reviewedExisting == nil else { throw ChatTransferError(message:"The reviewed encrypted conversation is no longer available. Refresh before starting another.") }
        var intent = try ChatEncryptedConversationIntent(plan:plan,owner:owner)
        let scope = encryptedConversationJournal.accountScope
        do { try encryptedConversationJournal.rememberAsOnlyPending(intent) }
        catch { encryptedConversationRecoveryError = "The encrypted conversation receipt could not be saved. Refresh recovery before trying again.";throw error }
        pendingEncryptedConversationStarts[intent.id] = intent
        var dispatched = false
        do {
            snapshot = try await quickSwitchSnapshot();try checkConversationSession(epoch)
            try validateConversationPeople(members,reviewed:reviewed,fresh:snapshot)
            try plan.validate(owner:owner,users:snapshot.users.filter { members.contains($0.user_id) },encryption:encryption)
            guard try matchingEncryptedConversation(members,snapshot:snapshot) == nil else { throw ChatTransferError(message:"An encrypted conversation appeared before creation. Refresh and review it instead.") }
            let dispatchUsers = try await finalEncryptedConversationPreflight(api:api,epoch:epoch,keyEpoch:keyEpoch,owner:owner,plan:plan)
            guard origin == selection,root == threadRoot?.id,!isEditingMessage,liveStatus == .live else { throw CancellationError() }
            dispatched = true
            let created:ChatChannel
            do { created = try await api.initiateEncryptedConversation(plan,owner:owner,users:dispatchUsers,encryption:encryption) }
            catch let uncertain as ChatEncryptedConversationResponseUnconfirmed {
                if let id = uncertain.candidateChannelID {
                    let updated = try intent.recordingCandidate(id);try encryptedConversationJournal.replaceInScope(intent,with:updated,originalScope:scope);intent = updated
                    if epoch == accountGeneration { pendingEncryptedConversationStarts[intent.id] = intent }
                }
                throw uncertain
            }
            let updated = try intent.recordingCandidate(created.id)
            try encryptedConversationJournal.replaceInScope(intent,with:updated,originalScope:scope);intent = updated
            if epoch == accountGeneration { pendingEncryptedConversationStarts[intent.id] = intent }
            try checkConversationSession(epoch)
            guard keyEpoch == encryptionGeneration,encryptionUnlocked else { throw CancellationError() }
            snapshot = try await quickSwitchSnapshot();try checkConversationSession(epoch)
            guard encryptedConversationRecoveryResult(intent,snapshot:snapshot,owner:owner).status == .verified else { throw ChatAPIError.invalidResponse }
            let confirmed = try await quickSwitchSnapshot();try checkConversationSession(epoch)
            _ = try await finalEncryptedConversationPreflight(api:api,epoch:epoch,keyEpoch:keyEpoch,owner:owner,plan:plan)
            guard encryptedConversationRecoveryResult(intent,snapshot:confirmed,owner:owner).status == .verified,
                  let route = try matchingEncryptedConversation(members,snapshot:confirmed),route.channel?.id == created.id,
                  origin == selection,root == threadRoot?.id,!isEditingMessage else { throw ChatAPIError.invalidResponse }
            do { try encryptedConversationJournal.remove(intent);pendingEncryptedConversationStarts.removeValue(forKey:intent.id) }
            catch { encryptedConversationRecoveryError = "Creation is confirmed, but its saved warning could not be cleared. Repair storage and refresh recovery." }
            applyConversationRoute(route,snapshot:confirmed)
        } catch {
            if !dispatched {
                do { try encryptedConversationJournal.removeUndispatched(intent,originalScope:scope);if epoch == accountGeneration { pendingEncryptedConversationStarts.removeValue(forKey:intent.id) } }
                catch { if epoch == accountGeneration { encryptedConversationRecoveryError = "No creation request was sent, but its saved receipt could not be cleared." } }
            }
            guard epoch == accountGeneration else { throw CancellationError() }
            if dispatched { throw ChatTransferError(message:"Encrypted conversation creation could not be confirmed. Its request is saved. Check Pending actions before trying again; no automatic retry was made.") }
            throw error
        }
    }
}
