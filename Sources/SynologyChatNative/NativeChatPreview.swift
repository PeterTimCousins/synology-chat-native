import Combine
import AppKit
import SwiftUI
import OSLog

struct NativeChatPreviewView: View {
    @StateObject private var model: NativeChatPreviewModel
    init(model: NativeChatPreviewModel, appearancePreferences: NativeAppearancePreferences = .shared) {
        _model = StateObject(wrappedValue: model)
        _appearancePreferences = ObservedObject(wrappedValue: appearancePreferences)
    }
    @State private var filter = ""
    @State private var collapsedSidebar: Set<ChatSidebarGroup> = []
    @State private var showQuickSwitcher = false
    @State private var alertChannelID: Int64?
    @State private var showNameSettings = false
    @State private var showSidebarSettings = false
    @State private var showAppearanceSettings = false
    @ObservedObject private var appearancePreferences = NativeAppearancePreferences.shared
    private var effectiveStyle: ChatAppearanceStyle { appearancePreferences.followsAccount ? model.appearanceSettings?.style ?? .dark : .dark }
    private var wallpaperSettings: ChatAppearanceSettings? { appearancePreferences.followsAccount ? model.appearanceSettings : nil }
    @State private var showDownloads = false
    @State private var showSignIn = false
    @State private var showSearch = false
    @State private var showHashtags = false
    @State private var showLibrary = false
    @State private var showSavedMessages = false
    @State private var showReminders = false
    @State private var showArchives = false
    @State private var showHiddenConversations = false
    @State private var showBotBrowser = false
    @State private var showChannelBrowser = false
    @State private var showChannelDetails = false
    @State private var promotingChannel: ChatChannel?
    @State private var closingChannel:ChatChannel?
    @State private var showPendingChannelActions = false
    @State private var showNotificationPreferences = false
    @State private var showNASPicker = false
    @State private var showDrivePicker = false
    @State private var pendingNASSelection:ChatNASSelection?
    @State private var showApplicationLauncher = false
    @State private var showRegionalSettings = false
    @State private var showCalendarPreferences = false
    @State private var showWebhooks = false
    @State private var showPairedDevices = false
    @State private var showProfilePhoto = false
    @State private var showProfileEditor = false
    @State private var showManualPresence = false
    @State private var showThreads = false
    @State private var showPins = false
    @State private var showNewConversation = false
    @State private var showNewChannel = false
    @State private var showMembers = false
    @State private var showStickers = false
    @State private var showMentions = false
    @State private var showPoll = false
    @State private var showSnippet = false
    @State private var snippetRecovery:NativeLongMessageSnippetRecovery?
    @State private var showSchedule = false
    @State private var showScheduledMessages = false
    @State private var composerSelection = NSRange(location: NSNotFound, length: 0)
    @State private var showEncryptionUnlock = false
    @State private var showEncryptionManagement = false
    @State private var attemptedRestore = false
    @State private var windowActive = false
    @State private var atBottom = false
    @State private var initialScroll = true
    @State private var composerFocused = false

    private var usesNativeVirtualTimeline = NativeChatAppConfiguration.usesNativeMessageViewport
    func usingNativeMessageViewport()->Self {
        var view = self;view.usesNativeVirtualTimeline = true
#if DEBUG
        view.usesNativeTableTimeline = false
#endif
        return view
    }
    #if DEBUG
    private var usesNativeTableTimeline = false
    private var nativeAutomaticComposer = false
    private var nativeTableFixtureEditors:[Int64:NativeMessageEditorFixture] = [:]
    func usingNativeTableTimeline(fixtureEditors:[Int64:NativeMessageEditorFixture] = [:])->Self {
        var view = self;view.usesNativeTableTimeline = true;view.usesNativeVirtualTimeline = false;view.nativeTableFixtureEditors = fixtureEditors;return view
    }
    func usingNativeVirtualTimeline(fixtureEditors:[Int64:NativeMessageEditorFixture] = [:],automaticallySizesComposer:Bool = false)->Self {
        var view = self;view.usesNativeVirtualTimeline = true;view.usesNativeTableTimeline = false;view.nativeTableFixtureEditors = fixtureEditors;view.nativeAutomaticComposer = automaticallySizesComposer;return view
    }
    #endif
    private var automaticallySizesComposer:Bool {
#if DEBUG
        return usesNativeVirtualTimeline && nativeAutomaticComposer
#else
        return false
#endif
    }
    @ViewBuilder private var conversationTimeline:some View {
        if usesNativeVirtualTimeline {
            nativeConversationTimeline
                .background(NativeConversationWallpaper(model:model,settings:wallpaperSettings,behindMessages:true))
                .overlay {
                    if model.loadingHistory && model.posts.isEmpty && model.error == nil {
                        ProgressView("Loading messages…").controlSize(.regular).font(.callout)
                            .foregroundColor(NativeChatColors.muted).padding(16)
                            .background(NativeChatColors.canvas.opacity(0.92),in:RoundedRectangle(cornerRadius:12))
                            .allowsHitTesting(false)
                    }
                }
        } else { legacyConversationTimeline }
    }
    @ViewBuilder private var nativeConversationTimeline:some View {
#if DEBUG
        NativeVirtualTimeline(model:model,onBottomChanged:{ bottom in atBottom = bottom;updateReadVisibility() },fixtureEditors:nativeTableFixtureEditors)
#else
        NativeVirtualTimeline(model:model,onBottomChanged:{ bottom in atBottom = bottom;updateReadVisibility() })
#endif
    }
    @ViewBuilder private var legacyConversationTimeline:some View {
#if DEBUG
        if usesNativeTableTimeline {
            NativeTableTimeline(model:model,onBottomChanged:{ bottom in atBottom = bottom;updateReadVisibility() },fixtureEditors:nativeTableFixtureEditors)
                .background(NativeConversationWallpaper(model:model,settings:wallpaperSettings,behindMessages:true))
                .overlay {
                    if model.loadingHistory && model.posts.isEmpty && model.error == nil {
                        ProgressView("Loading messages…").controlSize(.regular).font(.callout)
                            .foregroundColor(NativeChatColors.muted).padding(16)
                            .background(NativeChatColors.canvas.opacity(0.92),in:RoundedRectangle(cornerRadius:12))
                            .allowsHitTesting(false)
                    }
                }
        } else { standardConversationTimeline }
        #else
        standardConversationTimeline
        #endif
    }
    private var standardConversationTimeline:some View {
                        ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                if model.canLoadOlder {
                                    Button("Load earlier messages") { Task { await model.loadOlder() } }
                                        .disabled(model.loadingHistory).frame(maxWidth: .infinity)
                                }
                                if model.posts.isEmpty && !model.loadingHistory && model.error == nil {
                                    Text("No messages yet. Say hello below.").foregroundColor(NativeChatColors.muted)
                                }
                                ForEach(Array(model.posts.enumerated()), id: \.element.id) { item in
                                    NativeTimelineRowContent(post:item.element,previous:item.offset > 0 ? model.posts[item.offset-1] : nil,model:model)
                                }
                                if model.viewingMessageContext && model.canLoadNewer {
                                    Button("Load newer messages") { Task { await model.loadNewer() } }
                                        .disabled(model.loadingHistory).frame(maxWidth:.infinity)
                                }
                                Color.clear.frame(height: 1).id("timeline-bottom")
                            }.padding(.horizontal,16).padding(.vertical,20).frame(maxWidth: .infinity, alignment: .leading)
                                .background(NativeTimelineViewport(token:model.historyViewportToken,changed: { [token = model.historyViewportToken,account = model.accountGeneration,channel = model.selection] postID,bottom in
                                    model.noteTimelineViewport(postID:postID,atBottom:bottom,token:token,account:account,channelID:channel)
                                }).allowsHitTesting(false))
                                .background(NativeScrollVisibility(readerContext: .init(account:model.accountGeneration,channelID:model.selection,threadID:nil,viewportToken:model.historyViewportToken,isLoading:model.loadingHistory),keepLatestAfterResize: { [account = model.accountGeneration,channel = model.selection,token = model.historyViewportToken] isCurrent in
                                    // AppKit geometry can arrive before SwiftUI's anchor map.
                                    DispatchQueue.main.async {
                                        guard isCurrent(),model.accountGeneration == account,model.selection == channel,
                                              model.historyViewportToken == token,!model.loadingHistory,!model.posts.isEmpty else { return }
                                        proxy.scrollTo("timeline-bottom",anchor:.bottom)
                                        initialScroll = false
                                    }
                                }) { bottom in atBottom = bottom; updateReadVisibility() })
                        }.background(NativeConversationWallpaper(model: model, settings: wallpaperSettings, behindMessages: true))
                        .overlay {
                            if model.loadingHistory && model.posts.isEmpty && model.error == nil {
                                ProgressView("Loading messages…").controlSize(.regular).font(.callout)
                                    .foregroundColor(NativeChatColors.muted).padding(16)
                                    .background(NativeChatColors.canvas.opacity(0.92),in:RoundedRectangle(cornerRadius:12))
                                    .allowsHitTesting(false)
                            }
                        }
                        .onChange(of: model.posts.last?.id) { id in
                            if id != nil, !model.viewingMessageContext, initialScroll || atBottom, model.scrollPostID == nil {
                                // Wait for SwiftUI to install identifiers, but never
                                // apply a queued latest jump to a replacement reader.
                                let account = model.accountGeneration,channel = model.selection,token = model.historyViewportToken
                                DispatchQueue.main.async {
                                    guard model.accountGeneration == account,model.selection == channel,model.historyViewportToken == token,
                                          !model.viewingMessageContext,model.scrollPostID == nil,initialScroll || atBottom else { return }
                                    proxy.scrollTo("timeline-bottom", anchor: .bottom)
                                    initialScroll = false
                                }
                            }
                            updateReadVisibility()
                        }
                        .onChange(of:model.latestHistoryScrollRevision) { revision in
                            let account = model.accountGeneration,channel = model.selection,token = model.historyViewportToken
                            DispatchQueue.main.async {
                                guard model.accountGeneration == account,model.selection == channel,model.historyViewportToken == token,
                                      model.latestHistoryScrollRevision == revision,!model.viewingMessageContext,!model.posts.isEmpty else { return }
                                proxy.scrollTo("timeline-bottom",anchor:.bottom)
                                initialScroll = false
                            }
                        }
                        .onChange(of: model.historyScrollRevision) { revision in
                            if let id = model.scrollPostID {
                                initialScroll = false
                                let account = model.accountGeneration, channel = model.selection, token = model.historyViewportToken
                                let top = model.scrollAnchorAtTop
                                // Context rows are installed in this same update.
                                // Defer the jump until their identifiers exist.
                                DispatchQueue.main.async {
                                    guard model.accountGeneration == account,model.selection == channel,model.historyViewportToken == token,model.historyScrollRevision == revision,model.scrollPostID == id else { return }
                                    proxy.scrollTo(id, anchor: top ? .top : .center)
                                }
                            }
                        }
                        }
    }

    private var chatLayout: some View {
        GeometryReader { layout in
            HSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(NativeChatAppConfiguration.productName).font(.system(size: 19, weight: .bold))
                        Text(NativeChatAppConfiguration.developmentUI ? "Native client · Preview" : "Your team, connected").font(.caption).foregroundColor(NativeChatColors.muted)
                    }.padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 20)
                    Divider().overlay(NativeChatColors.separator)
                    if model.connected {
                        HStack {
                            HStack(spacing: 7) {
                                Image(systemName: "magnifyingglass").font(.system(size: 12))
                                TextField("Find a conversation", text: $filter)
                                    .textFieldStyle(.plain).font(.system(size: 13))
                                    .accessibilityLabel("Find a conversation")
                            }.foregroundColor(NativeChatColors.muted).padding(8)
                                .background(Color.white.opacity(0.045)).clipShape(RoundedRectangle(cornerRadius: 7))
                            Button { showNewConversation = true } label: { Image(systemName: "square.and.pencil") }
                                .help("New conversation").accessibilityLabel("New conversation")
                                .keyboardShortcut("n", modifiers: .command).disabled(!model.canInteract || model.channelManagementBusy)
                            if model.canCreateNamedChannel {
                                Button { showNewChannel = true } label: { Image(systemName: "plus") }
                                    .help("New channel").accessibilityLabel("New channel")
                            }
                        }.buttonStyle(NativeToolbarButtonStyle()).padding(12)
                        Button { showThreads = true } label: {
                            HStack(spacing:10) {
                                Image(systemName:"text.bubble").frame(width:24)
                                Text("Threads").font(.system(size:13,weight:.medium))
                                Spacer()
                            }.foregroundColor(NativeChatColors.muted).padding(.horizontal,18).padding(.vertical,8).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("Threads collection")
                        Button { showSavedMessages = true } label: {
                            HStack(spacing:10) {
                                Image(systemName:"bookmark").frame(width:24)
                                Text("Saved messages").font(.system(size:13,weight:.medium))
                                Spacer()
                            }.foregroundColor(NativeChatColors.muted).padding(.horizontal,18).padding(.vertical,8).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("Saved messages")
                        Button { showReminders = true } label: {
                            HStack(spacing:10) {
                                Image(systemName:"bell").frame(width:24)
                                Text("Reminders").font(.system(size:13,weight:.medium))
                                Spacer()
                            }.foregroundColor(NativeChatColors.muted).padding(.horizontal,18).padding(.vertical,8).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("Reminders")
                        Menu {
                            Button("Quick switcher…") { toggleQuickSwitcher() }.disabled(!model.canPresentQuickSwitcher)
                            Divider()
                            Button("Browse channels…") { showChannelBrowser = true }
                            Button("Browse bots…") { showBotBrowser = true }
                            Button("Archive history…") { showArchives = true }
                            Button("Hidden conversations…") { showHiddenConversations = true }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "ellipsis.circle").frame(width: 24)
                                Text("More").font(.system(size: 13, weight: .medium))
                                Spacer()
                                Image(systemName: "chevron.down").font(.system(size: 10))
                            }.foregroundColor(NativeChatColors.muted).padding(.horizontal, 18).padding(.vertical, 8).contentShape(Rectangle())
                        }.menuStyle(.borderlessButton).menuIndicator(.hidden)
                            .tint(NativeChatColors.muted).padding(.horizontal, 18)
                            .accessibilityLabel("More: quick switcher, channels, bots, archive history and hidden conversations")
                            .help("Conversation tools · Quick switcher: ⌘K")
                            .padding(.bottom, 8)
                        if model.hasPendingActions {
                            Button { showPendingChannelActions = true } label: {
                                Label("Pending actions",systemImage:"exclamationmark.circle").foregroundColor(.orange).padding(.horizontal,18).padding(.vertical,8)
                            }.buttonStyle(.plain)
                        }
                        List(selection: $model.selection) {
                            ForEach(model.sidebarSections(query: filter)) { section in
                                let group = sidebarGroupTitle(section.group)
                                let items = section.channels
                                if !items.isEmpty {
                                    Section {
                                        if !collapsedSidebar.contains(section.group) || !filter.isEmpty {
                                        ForEach(items) { channel in
                                            HStack(spacing: 9) {
                                                if ["public", "private"].contains(channel.type) {
                                                    Image(systemName: channel.encrypted || channel.type == "private" ? "lock" : "number")
                                                        .font(.system(size: 14)).foregroundColor(NativeChatColors.muted).frame(width: 24)
                                                } else if channel.type == "chatbot" {
                                                    Image(systemName: "sparkles").foregroundColor(NativeChatColors.muted).frame(width: 24)
                                                } else { NativeUserAvatar(avatars:model.avatars,user:model.sidebarUser(channel),name:model.title(channel),size:24) }
                                                Text(model.title(channel)).font(.system(size: 13, weight: channel.sidebarUnreadCount > 0 ? .semibold : .regular)).lineLimit(1)
                                                Spacer(minLength: 0)
                                                if channel.badgeUnreadCount > 0 { Text("\(channel.badgeUnreadCount)").font(.system(size: 11, weight: .bold)).foregroundColor(NativeChatColors.sidebar)
                                                    .padding(.horizontal, 6).padding(.vertical, 2).background(NativeChatColors.green).clipShape(Capsule()) }
                                            }.padding(.horizontal, 8).padding(.vertical, 6).tag(channel.id)
                                            .contextMenu {
                                                Button(channel.is_star == true ? "Remove from starred" : "Star conversation") { Task { await model.performConversationOrganization(channel,change:.star(channel.is_star != true)) } }
                                                    .disabled(!model.canOrganizeConversation(channel,change:.star(channel.is_star != true)))
                                                if channel.supportsClosing && (model.channelPermissions?.allows("channel_close") == true || model.pendingChannelClosures[channel.id] != nil) {
                                                    Button(model.pendingChannelClosures[channel.id] == nil ? (channel.type == "anonymous" ? "Close conversation…" : "Close channel…") : "Check close status…") { closingChannel = channel }
                                                        .disabled(model.channelManagementBusy)
                                                }
                                                if channel.type != "synobot" {
                                                    Button("Hide conversation") { Task { await model.performConversationOrganization(channel,change:.hide) } }
                                                        .disabled(!model.canOrganizeConversation(channel,change:.hide))
                                                }
                                            }

                                                .listRowSeparator(.hidden)
                                                .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                                                .listRowBackground(model.selection == channel.id ? NativeChatColors.selected : Color.clear)
                                                .accessibilityElement(children: .ignore)
                                                .accessibilityLabel(NativeLocalizedStrings.objects("%@, %@",model.title(channel),channel.sidebarUnreadDescription))
                                                .accessibilityHint(channel.encrypted ? "Encrypted conversation" : "Open conversation")
                                        }
                                        }
                                    } header: {
                                        Button {
                                            if collapsedSidebar.contains(section.group) { collapsedSidebar.remove(section.group) } else { collapsedSidebar.insert(section.group) }
                                        } label: {
                                            HStack {
                                                Text(group.uppercased()).tracking(0.7); Spacer()
                                                Image(systemName: collapsedSidebar.contains(section.group) && filter.isEmpty ? "chevron.right" : "chevron.down")
                                            }.font(.system(size:10,weight:.bold)).foregroundColor(NativeChatColors.muted).padding(.top,10).padding(.bottom,4)
                                        }.buttonStyle(.plain).disabled(!filter.isEmpty)
                                            .accessibilityLabel(NativeLocalizedStrings.object(filter.isEmpty ? (collapsedSidebar.contains(section.group) ? "Expand %@" : "Collapse %@") : "%@ search results",group))
                                    }
                                }
                            }
                        }.listStyle(.plain).scrollContentBackground(.hidden)
                    } else { Spacer() }
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        if model.connected {
                            HStack(spacing: 10) {
                                NativeUserIdentity(model:model,userID:model.userID ?? 0,size:30)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(model.directory.first(where: { $0.user_id == model.userID }).map { model.displayName($0) } ?? NativeLocalizedStrings.text("Your account"))
                                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                    HStack(spacing: 5) {
                                        Circle().fill(model.liveStatus == .live ? NativeChatColors.green : .orange).frame(width: 5, height: 5)
                                        Text(model.liveStatus == .live ? (model.manualAway == true ? "Away · Connected" : "Connected") : model.liveStatus == .reconnecting ? "Reconnecting…" : "Offline")
                                            .font(.system(size: 11)).foregroundColor(NativeChatColors.muted).lineLimit(1)
                                            .help(model.liveStatus.title).accessibilityLabel(model.liveStatus.title)
                                    }
                                }
                                Spacer(minLength: 0)
                                Menu {
                                Button("Settings…") { model.showDesktopSettings = true }
                                Button("Synology apps…") {showApplicationLauncher = true}.disabled(!model.connected)
                                Button("Name display…") { showNameSettings = true }.disabled(!model.connected)
                                Button("Appearance…") { showAppearanceSettings = true }.disabled(!model.connected)
                                Button("Sidebar preferences…") { showSidebarSettings = true }.disabled(!model.connected)
                                Button("Calendar preferences…") {showCalendarPreferences = true}.disabled(!model.connected)
                                Button("Language & time…") {showRegionalSettings = true}.disabled(!model.connected)
                                Button("Downloads…") { showDownloads = true }.disabled(!model.connected)
                                Button("Integrations…") { showWebhooks = true }.disabled(!model.connected)
                                Button("Paired devices…") { showPairedDevices = true }.disabled(!model.connected)
                                Button("Profile photo…") { showProfilePhoto = true }.disabled(!model.connected)
                                Button("Edit profile…") { showProfileEditor = true }.disabled(!model.connected)
                                Button("Availability…") { showManualPresence = true }.disabled(!model.connected)
                                Button("Notification preferences…") { showNotificationPreferences = true }.disabled(!model.connected)
                                Button("Reconnect") { Task { await model.connect() } }.disabled(model.connecting || model.sending)
                                Button(model.notificationsEnabled ? "Disable notifications" : model.notificationStatus) {
                                    Task { await model.toggleNotifications() }
                                }
                                if model.hasEncryptionKeyPair {
                                    Button(model.encryptionUnlocked ? "Lock encrypted conversations" : "Unlock encrypted conversations") {
                                        if model.encryptionUnlocked { model.lockEncryption() } else { showEncryptionUnlock = true }
                                    }.disabled(model.sending)
                                }
                                Button("Encryption settings…") { showEncryptionManagement = true }.disabled(!model.connected || model.sending)
                                if model.notificationsEnabled && NativeChatAppConfiguration.developmentUI {
                                    Button("Test notification") { model.testNotification() }
                                }
                                Divider()
                                if model.canRevokeSession {
                                    Button("Sign out") { Task { await model.signOutNativeSession() } }.disabled(model.sending || model.connecting)
                                } else {
                                    Button("Disconnect") { model.signOutLocally() }.disabled(model.sending || model.connecting)
                                }
                                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 28) }
                                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                                    .accessibilityLabel("Account and connection settings").help(model.accountDisplay)
                            }
                        } else {
                            Button(model.restoringSavedSession ? "Restoring sign-in…" : model.connecting ? "Connecting…" : "Sign in to Synology Chat") { showSignIn = true }
                                .buttonStyle(.borderedProminent).disabled(model.connecting || model.restoringSavedSession)
                            if NativeChatAppConfiguration.allowsOfficialSessionImport {
                                Button("Use official app session") { Task { await model.connect() } }
                                    .font(.caption).disabled(model.connecting || model.restoringSavedSession)
                            }
                        }
                        Text(model.connected ? NativeLocalizedStrings.count("%lld conversations",Int64(model.channels.count)) :
                            (NativeChatAppConfiguration.allowsOfficialSessionImport ? "Sign in directly, or use your current official app session while testing." : "Sign in to load your conversations."))
                            .font(.caption).foregroundColor(NativeChatColors.muted).fixedSize(horizontal: false, vertical: true)
                    }.padding(16)
                }.frame(minWidth: 230, idealWidth: layout.size.width < 980 ? 250 : 280,
                        maxWidth: layout.size.width < 980 ? 250 : 290).background(NativeChatColors.sidebar)
                VStack(alignment: .leading, spacing: 0) {
                    conversationHeader(compact: layout.size.width < 1040)
                    Divider().overlay(NativeChatColors.separator)
                    if model.viewingMessageContext {
                        HStack {
                            Text("Showing message context").font(.caption).foregroundColor(NativeChatColors.muted)
                            Spacer()
                            Button("Back to latest") { model.loadSelection(returningToLatest:true) }.font(.caption)
                        }.padding(.horizontal, 20).padding(.vertical, 10)
                        Divider()
                    }
                    if let error = model.error {
                        Text(error).font(.callout).foregroundColor(.orange).padding(16).textSelection(.enabled)
                        Divider()
                    }
                    if let notice = model.draftRecoveryNotice {
                        Label(notice, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundColor(.orange).padding(16)
                            .accessibilityLabel(notice)
                        Divider()
                    }
                    if model.selection == nil {
                        VStack(spacing: 12) {
                            Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 34)).foregroundColor(NativeChatColors.green)
                            Text(model.connected ? "Choose a conversation" : "Your conversations").font(.title3.weight(.medium))
                            Text(model.connected ? "Read recent messages or load earlier history." : "Sign in to connect directly to your server.")
                                .foregroundColor(NativeChatColors.muted)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        conversationTimeline
                    }
                    Divider()
                    if let channel = model.selectedChannel, model.canRead(channel.id) {
                        VStack(alignment: .leading, spacing: 0) {
                            NativeFormattingToolbar(text: Binding(get: { model.draft }, set: { model.draft = $0 }), selection: $composerSelection, focused: $composerFocused)
                                .disabled(model.isEditingMessage || model.sending).padding(.horizontal, 10).padding(.top, 6)
                            ZStack(alignment: .topLeading) {
                                if model.draft.isEmpty {
                                    Text(NativeLocalizedStrings.object("Message %@",model.title(channel))).font(.system(size: 14))
                                        .foregroundColor(NativeChatColors.muted).padding(.horizontal, 13).padding(.top, 15)
                                        .allowsHitTesting(false).accessibilityHidden(true)
                                }
                                NativeAutocompleteComposer(model: model, channelID: channel.id, text: Binding(get: { model.draft }, set: { model.draft = $0 }), selection: $composerSelection, focused: $composerFocused, label: NativeLocalizedStrings.object("Message to %@",model.title(channel)),maximumHeight:automaticallySizesComposer ? 180 : 64,automaticallySizes:automaticallySizesComposer,onAttachmentInput:{ model.receiveComposerAttachment($0) })
                                    .id(channel.id).disabled(model.isEditingMessage)
                                    .font(.system(size: 14)).scrollContentBackground(.hidden)
                                    .padding(8)
                                    .accessibilityLabel(NativeLocalizedStrings.object("Message to %@",model.title(channel)))
                            }
                            NativeSlashSuggestions(model: model)
                            NativeUploadStatusView(model: model).padding(.horizontal, 12)
                            NativeMessageLengthNotice(text: model.draft,convertToSnippet:model.prepareLongMessageSnippet() == nil ? nil : { snippetRecovery = model.prepareLongMessageSnippet() }).padding(.horizontal, 12)
                            HStack(spacing: 8) {
                                Menu {
                                    Button("From this Mac…") {Task {await model.chooseAttachment()}}
                                    Button("Capture screenshot…") {model.captureScreenshot(inThread:false)}.disabled(model.preparingComposerAttachment || model.attachmentBatch != nil)
                                    Button("From NAS…") {showNASPicker = true}.disabled(!model.canChooseNASFiles())
                                    Button("From Synology Drive…") {showDrivePicker = true}.disabled(!model.canChooseDriveFiles())
                                } label: {Image(systemName:"plus")}
                                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                                    .frame(width: 30, height: 30)
                                    .buttonStyle(NativeToolbarButtonStyle())
                                    .accessibilityLabel("Attach a file").help("Attach a file")
                                    .disabled(!model.canInteract || model.sending || !ChatMessageText.isAllowed(model.draft))
                                Button { showStickers = true } label: { Image(systemName: "face.smiling") }
                                    .buttonStyle(NativeToolbarButtonStyle()).accessibilityLabel("Emoji and stickers")
                                    .disabled(!model.canInteract || model.sending)
                                    .popover(isPresented: $showStickers) {
                                        NativeComposerEmojiPicker(preferences: model.emojiPreferences, chooseEmoji: { kind in
                                            let edit = ChatComposerEdit.insert(kind.emoji, into: model.draft, selection: composerSelection)
                                            model.draft = edit.text; composerSelection = edit.selection
                                            showStickers = false; composerFocused = true
                                        }, chooseSticker: { name in
                                            showStickers = false; Task { await model.sendSticker(name) }
                                        }, assets: model.stickers)
                                    }
                                Button { showMentions = true } label: { Image(systemName: "at") }
                                    .buttonStyle(NativeToolbarButtonStyle()).accessibilityLabel("Mention a member")
                                    .disabled(!model.canInteract || model.sending)
                                    .popover(isPresented: $showMentions) {
                                        NativeMentionPicker(model: model, channelID: channel.id) { id in
                                            let edit = ChatComposerEdit.insert("@u:\(id)", into: model.draft, selection: composerSelection, separated: true)
                                            model.draft = edit.text; composerSelection = edit.selection
                                            showMentions = false; composerFocused = true
                                        }
                                    }
                                Button { Task { do { try await model.prepareSlashCommands() } catch is CancellationError { } catch { model.error = error.localizedDescription } } } label: { Image(systemName: "command") }
                                    .buttonStyle(NativeToolbarButtonStyle()).accessibilityLabel("Commands").help("Commands")
                                    .disabled(!model.canOpenSlashCommands())
                                Button { snippetRecovery = nil;showSnippet = true } label: { Image(systemName:"chevron.left.forwardslash.chevron.right") }
                                    .buttonStyle(NativeToolbarButtonStyle()).accessibilityLabel("Create a snippet").help("Create a snippet")
                                    .disabled(!model.canCreateSnippet())
                                Button { showPoll = true } label: { Image(systemName:"chart.bar.xaxis") }
                                    .buttonStyle(NativeToolbarButtonStyle()).accessibilityLabel("Create a poll").help("Create a poll")
                                    .disabled(!model.canCreatePoll)
                                Text(model.needsDeliveryCheck ? "Draft kept · Check recent messages" : "⌘ Return to send")
                                    .font(.system(size: 11)).foregroundColor(NativeChatColors.muted).lineLimit(2)
                                Spacer(minLength: 0)
                                Button { Task { await model.send() } } label: {
                                    HStack(spacing: 7) {
                                        Text(model.sending ? "Sending…" : "Send")
                                        Image(systemName: "paperplane.fill").font(.system(size: 11))
                                    }
                                }.accessibilityLabel(model.sending ? "Sending…" : "Send")
                                    .keyboardShortcut(.return, modifiers: .command)
                                    .buttonStyle(NativeSendButtonStyle()).disabled(!model.canSend)
                                Menu {
                                    Button("Schedule message…") { showSchedule = true }.disabled(!model.canCreateSchedule)
                                    Button("Scheduled messages…") { showScheduledMessages = true }.disabled(model.selection.map { !model.canManageSchedules(channelID:$0) } ?? true)
                                } label: { Image(systemName:"chevron.down") }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Send options")

                            }.padding(.horizontal, 10).padding(.bottom, 10)
                        }.background(NativeChatColors.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(composerFocused ? NativeChatColors.muted.opacity(0.5) : NativeChatColors.separator, lineWidth: 1))
                            .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 20)
                    } else {
                        if model.selectedChannel?.encrypted == true {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(model.hasEncryptionKeyPair ? "Unlock to read and send encrypted messages." : "Set up encryption for this account to access encrypted conversations.")
                                    .font(.callout).foregroundColor(NativeChatColors.muted)
                                if model.hasEncryptionKeyPair { Button("Unlock encrypted conversations") { showEncryptionUnlock = true }.buttonStyle(.borderedProminent) }
                                else { Button("Set up encryption…") { showEncryptionManagement = true }.buttonStyle(.borderedProminent).disabled(!model.connected || model.sending) }
                            }.padding(16)
                        } else {
                            Text(NativeChatAppConfiguration.developmentUI ? "Native preview" : "").font(.caption).foregroundColor(NativeChatColors.muted).padding(16)
                        }
                    }
                }.frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity).background(NativeChatColors.canvas)
                    .nativeConversationFileDrop(model:model)
            }
        }
        .foregroundColor(NativeChatColors.text)
        .tint(NativeChatColors.green)
    }

    private func conversationHeader(compact: Bool) -> some View {
        HStack(spacing: 10) {
            Button {
                if let channel = model.selectedChannel, ["public", "private"].contains(channel.type) { showChannelDetails = true }
                else { showMembers = true }
            } label: {
                HStack(spacing: 10) {
                    if let channel = model.selectedChannel {
                        Image(systemName: channel.encrypted || channel.type == "private" ? "lock" : channel.type == "public" ? "number" : "bubble.left.and.bubble.right")
                            .font(.system(size: 17, weight: .medium)).foregroundColor(NativeChatColors.muted)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(model.selectedChannel.map(model.title) ?? NativeLocalizedStrings.text("Conversations"))
                                .font(.system(size: 18, weight: .bold)).lineLimit(1).foregroundColor(NativeChatColors.text)
                            if model.selectedChannel?.is_star == true {
                                Image(systemName: "star.fill").font(.system(size: 11)).foregroundColor(NativeChatColors.green).accessibilityLabel("Starred")
                            }
                            if model.selectedChannel != nil { Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundColor(NativeChatColors.muted) }
                        }
                        Text(conversationSubtitle).font(.system(size: 11)).foregroundColor(NativeChatColors.muted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).layoutPriority(1)
                .disabled(model.selectedChannel == nil || !model.connected)
                .help((model.selectedChannel.map(model.title) ?? NativeLocalizedStrings.text("Conversations")) + "\n" + conversationSubtitle)
                .accessibilityLabel(model.selectedChannel.map { channel in NativeLocalizedStrings.object(["public", "private"].contains(channel.type) ? "Channel details for %@" : "Conversation members for %@",model.title(channel)) } ?? NativeLocalizedStrings.text("Conversations"))
            if model.connected {
                HStack(spacing: 5) {
                    Circle().fill(model.liveStatus == .live ? NativeChatColors.green : .orange).frame(width: 6, height: 6)
                    if !compact || model.liveStatus != .live { Text(connectionStatusLabel).font(.caption).foregroundColor(model.liveStatus == .rejected ? .orange : NativeChatColors.muted) }
                }.fixedSize().help(model.liveStatus.title).accessibilityElement(children: .ignore).accessibilityLabel(model.liveStatus.title)
            }
            if model.loadingHistory || model.connecting || model.preparingComposerAttachment { ProgressView().controlSize(.small) }
            HStack(spacing: 3) {
                Button { showMembers = true } label: { Image(systemName: "person.2") }
                    .help("Conversation members").accessibilityLabel("Conversation members").disabled(model.selection == nil || !model.connected)
                if !compact {
                    Button { showPins = true } label: { Image(systemName: "pin") }
                        .help("Pinned messages").accessibilityLabel("Pinned messages").disabled(model.selection.map { !model.canBrowseConversationContent($0) } ?? true)
                    Button { showLibrary = true } label: { Image(systemName: "square.stack.3d.up") }
                        .help("Files and links").accessibilityLabel("Files and links").disabled(model.selection.map { !model.canBrowseConversationContent($0) } ?? true)
                }
                Button { showSearch = true } label: { Image(systemName: "magnifyingglass") }
                    .help("Search messages (⌘F)").accessibilityLabel("Search messages").keyboardShortcut("f", modifiers: .command).disabled(!model.connected)
                Button { model.loadSelection() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh messages (⌘R)").accessibilityLabel("Refresh messages").keyboardShortcut("r", modifiers: .command).disabled(model.selection == nil || model.loadingHistory || model.connecting)
                Menu {
                    if compact {
                        Button("Pinned messages") { showPins = true }.disabled(model.selection.map { !model.canBrowseConversationContent($0) } ?? true)
                        Button("Files and links") { showLibrary = true }.disabled(model.selection.map { !model.canBrowseConversationContent($0) } ?? true)
                    }
                    Button("Browse hashtags") { showHashtags = true }.disabled(model.selection.map { !model.canBrowseHashtags($0) } ?? true)
                    if let channel = model.selectedChannel {
                        Divider()
                        Button(channel.is_star == true ? "Remove from starred" : "Star conversation") { Task { await model.performConversationOrganization(channel, change: .star(channel.is_star != true)) } }
                            .disabled(!model.canOrganizeConversation(channel, change: .star(channel.is_star != true)))
                        Button("Conversation notifications…") { alertChannelID = channel.id }.disabled(!model.canEditChannelAlerts || model.channelAlertsBusy)
                        if model.pendingPromotions[channel.id] != nil || model.promotionRecoveryError != nil { Button("Check conversion status…") { promotingChannel = channel }.disabled(model.channelManagementBusy) }
                        else if channel.type == "anonymous" { Button("Convert to private channel…") { promotingChannel = channel }.disabled(!model.canPromoteConversation(channel)) }
                        if ["public", "private"].contains(channel.type) { Button("Channel details…") { showChannelDetails = true } }
                        if channel.supportsClosing && (model.channelPermissions?.allows("channel_close") == true || model.pendingChannelClosures[channel.id] != nil) {
                            Button(model.pendingChannelClosures[channel.id] == nil ? (channel.type == "anonymous" ? "Close conversation…" : "Close channel…") : "Check close status…") { closingChannel = channel }.disabled(model.channelManagementBusy)
                        }
                        if channel.type != "synobot" {
                            Button("Hide conversation") { Task { await model.performConversationOrganization(channel, change: .hide) } }.disabled(!model.canOrganizeConversation(channel, change: .hide))
                        }
                        Divider()
                        Button("Refresh conversation list") { Task { do { try await model.refreshConversationOrganization() } catch is CancellationError { } catch { model.error = "Could not refresh the conversation list." } } }.disabled(model.conversationOrganizationBusy)
                    }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 30, height: 30)
                    .accessibilityLabel("Conversation actions").help("Conversation actions")
            }.buttonStyle(NativeToolbarButtonStyle()).fixedSize()
        }.padding(.horizontal, compact ? 18 : 24).frame(height: 68)
    }
    private func sidebarGroupTitle(_ group:ChatSidebarGroup)->String {
        switch group {
        case .unread: return NativeLocalizedStrings.text("Unread")
        case .starred: return NativeLocalizedStrings.text("Starred")
        case .channels: return NativeLocalizedStrings.text("Channels")
        case .conversations: return NativeLocalizedStrings.text("Conversations")
        case .bots: return NativeLocalizedStrings.text("Bots")
        }
    }
    private var conversationSubtitle: String {
        guard let channel = model.selectedChannel else { return NativeLocalizedStrings.text("Your team conversations") }
        let purpose = channel.purpose?.trimmingCharacters(in: .whitespacesAndNewlines)
        let category: String
        switch channel.type {
        case "public": category = NativeLocalizedStrings.text("Public channel")
        case "private": category = NativeLocalizedStrings.text("Private channel")
        case "synobot": category = NativeLocalizedStrings.text("Your private space")
        case "chatbot": category = NativeLocalizedStrings.text("Bot conversation")
        default: category = NativeLocalizedStrings.text((channel.total_member_count ?? 0) > 2 ? "Group conversation" : "Direct message")
        }
        let description = purpose?.isEmpty == false ? purpose! : category
        return channel.encrypted ? NativeLocalizedStrings.object("Encrypted · %@",description) : description
    }
    private var connectionStatusLabel: String {
        switch model.liveStatus {
        case .connecting: return NativeLocalizedStrings.text("Connecting")
        case .live: return NativeLocalizedStrings.text("Live")
        case .reconnecting: return NativeLocalizedStrings.text("Reconnecting")
        case .offline: return NativeLocalizedStrings.text("Offline")
        case .rejected: return NativeLocalizedStrings.text("Reconnect needed")
        }
    }

    private var observedChat: some View {
        chatLayout
        .onChange(of:model.hiddenConversationRoute) { _ in showHiddenConversations = false;filter = "" }
        .onChange(of:model.profileConversationRoute) { _ in
            showChannelDetails = false;showChannelBrowser = false;showMembers = false;showThreads = false;showSavedMessages = false;showReminders = false;showHiddenConversations = false;showPins = false;showLibrary = false;showSearch = false;showHashtags = false
        }
        .background(NativeWindowActivity(userActivityChanged: { active in
            model.updateWindowActivity(active, applicationHidden: NSApp.isHidden)
        }) { active in
            windowActive = active; updateReadVisibility()
        })
        .onChange(of: model.selection) { _ in
            if let id = model.selection, let section = model.sidebarSections(query: filter).first(where: { $0.channels.contains(where: { $0.id == id }) }) { collapsedSidebar.remove(section.group) }
            showChannelDetails = false; promotingChannel = nil
            showSnippet = false;showPoll = false;showMembers = false; showSnippet = false;showPoll = false;showPins = false; showLibrary = false; showHashtags = false; showMentions = false; showStickers = false
            composerSelection = NSRange(location: NSNotFound, length: 0)
            atBottom = false; initialScroll = true
            model.updateReadingVisibility(active: false, atBottom: false)
            model.loadSelection()
            focusComposer()
        }
        .background(NativeQuickSwitchKeysView(connected:model.connected,presented:showQuickSwitcher,action:toggleQuickSwitcher).frame(width:1,height:1).accessibilityHidden(true))
        .onChange(of: model.isEditingMessage) { editing in
            if editing { composerFocused = false } else { focusComposer() }
        }
        .onChange(of: model.loadingHistory) { _ in updateReadVisibility() }
        .onChange(of: model.connected) { connected in
            if !connected {
                composerFocused = false; showQuickSwitcher = false; collapsedSidebar = []
                showSnippet = false;showPoll = false;showPins = false; showLibrary = false; showHashtags = false; showMentions = false; showStickers = false
                showThreads = false; showSavedMessages = false; showSearch = false; showMembers = false; showNewConversation = false
                showNewChannel = false; showEncryptionUnlock = false; showEncryptionManagement = false
            }
        }
        .onChange(of: model.liveStatus) { _ in updateReadVisibility() }
        .onChange(of: model.imageViewerPost?.id) { _ in updateReadVisibility() }
        .onChange(of:model.documentPreviewPost?.id) { _ in updateReadVisibility() }
        .onChange(of:model.documentPreviewIsPresented) { _ in updateReadVisibility() }
        .onChange(of:model.attachmentBatch?.id) { _ in updateReadVisibility() }
        .onChange(of:model.preparingComposerAttachment) { _ in updateReadVisibility() }
    }

    private var conversationPresentations: some View {
        observedChat
        .sheet(isPresented:Binding(get:{ model.pollAttachmentOwner == nil && model.searchDocumentOwner == nil && model.collectionDocumentOwner == nil && model.documentPreviewIsPresented && model.threadRoot == nil && !showLibrary && !showSavedMessages && !showPins && !showThreads },set:{ if !$0 && model.pollAttachmentOwner == nil && model.searchDocumentOwner == nil && model.collectionDocumentOwner == nil && model.documentPreviewIsPresented { model.closeDocumentPreview() } }),onDismiss:focusComposer) {
            NativeDocumentPreview(model:model)
        }
        .sheet(isPresented:Binding(get:{ model.attachmentBatch != nil && model.threadRoot == nil },set:{ if !$0 { model.dismissAttachmentBatch() } }),onDismiss:focusComposer) {
            if let batch = model.attachmentBatch { NativeAttachmentBatchView(model:model,batch:batch) }
        }
        .sheet(isPresented: Binding(get: { model.threadRoot != nil }, set: { if !$0 { model.closeThread() } }), onDismiss: focusComposer) {
            conversationThread
        }
        .sheet(isPresented: Binding(get: { model.pollAttachmentOwner == nil && model.searchImageOwner == nil && model.imageViewerPost != nil && model.threadRoot == nil && !showLibrary },
                                   set: { if !$0,model.pollAttachmentOwner == nil,model.searchImageOwner == nil { model.closeImageViewer() } }), onDismiss: focusComposer) {
            NativeImageViewer(model: model)
        }
        .sheet(isPresented:$showSchedule,onDismiss:focusComposer) { if let channel = model.selection { NativeScheduleComposer(model:model,channelID:channel) } }
        .sheet(isPresented:$showScheduledMessages,onDismiss:focusComposer) { if let channel = model.selection { NativeScheduledMessagesView(model:model,channelID:channel) } }
        .sheet(isPresented:$showSnippet,onDismiss:focusComposer) { if let channel = model.selection { NativeSnippetComposer(model:model,channelID:channel) } }
        .sheet(item:$snippetRecovery,onDismiss:focusComposer) { recovery in NativeSnippetComposer(model:model,channelID:recovery.channelID,recovery:recovery) }
        .sheet(isPresented:$showPoll,onDismiss:focusComposer) {
            if let channelID = model.selection { NativePollComposer(model:model,channelID:channelID) }
        }
        .sheet(isPresented: $showSignIn, onDismiss: focusComposer) {
            NativeSignInView { account, warning in
                showSignIn = false
                await model.connect(using: account)
                if let warning { model.error = warning }
            }
        }
        .sheet(isPresented:$showPins,onDismiss:focusComposer) {
            if let channel = model.selectedChannel { NativeMessageCollection(model:model,channelID:channel.id) }
        }
        .sheet(isPresented:$showThreads,onDismiss:focusComposer) {
            NativeThreadsView(model:model)
        }
        .sheet(isPresented:$showDrivePicker) {NativeDriveFilePicker(model:model,inThread:false)}
        .sheet(isPresented:$showNASPicker,onDismiss:{if let pendingNASSelection {model.stageNASFiles(pendingNASSelection)};pendingNASSelection = nil}) {NativeNASFilePicker(model:model,inThread:false) {pendingNASSelection = $0}}
    }

    @ViewBuilder private var conversationThread:some View {
        if usesNativeVirtualTimeline {
#if DEBUG
            NativeThreadView(appearancePreferences:appearancePreferences,model:model)
                .usingNativeVirtualTimeline(fixtureEditors:nativeTableFixtureEditors,automaticallySizesComposer:automaticallySizesComposer)
#else
            NativeThreadView(appearancePreferences:appearancePreferences,model:model).usingNativeMessageViewport()
#endif
        } else { NativeThreadView(appearancePreferences:appearancePreferences,model:model) }
    }

    private var accountPresentations: some View {
        conversationPresentations
        .sheet(isPresented:$showApplicationLauncher,onDismiss:focusComposer) {NativeApplicationLauncherView(model:model)}
        .sheet(isPresented:Binding(get:{ alertChannelID != nil },set:{ if !$0 { alertChannelID = nil } }),onDismiss:focusComposer) { if let id = alertChannelID { NativeChannelAlertsView(model:model,channelID:id) } }
        .sheet(isPresented:$showNameSettings,onDismiss:focusComposer) { NativeNameSettingsView(model:model) }
        .sheet(isPresented:$showAppearanceSettings,onDismiss:focusComposer) { NativeAppearanceSettingsView(model:model,preferences:appearancePreferences) }
        .sheet(isPresented:$showSidebarSettings,onDismiss:focusComposer) { NativeSidebarSettingsView(model:model) }
        .sheet(isPresented:$model.showDesktopSettings,onDismiss:focusComposer) { NativeDesktopSettingsView(model:model,preferences:.shared) }
        .sheet(isPresented:$showCalendarPreferences,onDismiss:focusComposer) {NativeCalendarPreferencesView(model:model)}
        .sheet(isPresented:$showRegionalSettings,onDismiss:focusComposer) {NativeRegionalSettingsView(model:model)}
        .sheet(isPresented:$showWebhooks,onDismiss:focusComposer) { NativeWebhooksView(model:model) }
        .sheet(isPresented:$showPairedDevices,onDismiss:focusComposer) { NativePairedDevicesView(model:model) }
        .sheet(isPresented:$showProfilePhoto,onDismiss:focusComposer) { NativeProfilePhotoEditor(model:model) }
        .sheet(item: Binding(get: { model.slashCommandRequest }, set: { if $0 == nil { model.dismissSlashCommands() } }), onDismiss: focusComposer) { NativeSlashCommandView(model: model, request: $0) }
        .sheet(isPresented:$showProfileEditor,onDismiss:focusComposer) { NativeProfileEditorView(model:model) }
        .sheet(isPresented:$showManualPresence,onDismiss:focusComposer) { NativeManualPresenceView(model:model) }
        .sheet(isPresented:$showNotificationPreferences,onDismiss:focusComposer) { NativeNotificationSettingsView(model:model) }
        .sheet(isPresented:$showPendingChannelActions,onDismiss:focusComposer) { NativePendingChannelActionsView(model:model) }
        .sheet(item: $promotingChannel, onDismiss: focusComposer) { NativeChannelPromotionView(model: model, channelID: $0.id) }
        .sheet(item:$closingChannel,onDismiss:focusComposer) { NativeChannelCloseView(model:model,channel:$0) }
        .sheet(isPresented:$showChannelDetails,onDismiss:focusComposer) { if let id = model.selection { NativeChannelDetailsView(model:model,channelID:id) } }
        .sheet(isPresented:$showArchives,onDismiss:focusComposer) { NativeArchivesView(model:model) }
        .sheet(isPresented:$showDownloads,onDismiss:focusComposer) { NativeDownloadsView(model:model) }
        .sheet(isPresented:$showQuickSwitcher,onDismiss:focusComposer) { NativeQuickSwitcherView(model:model) }
        .sheet(isPresented:$showBotBrowser,onDismiss:focusComposer) { NativeBotBrowserView(model:model) }
        .sheet(isPresented:$showChannelBrowser,onDismiss:focusComposer) { NativeChannelBrowserView(model:model) }
        .sheet(isPresented:$showHiddenConversations,onDismiss:focusComposer) { NativeHiddenConversationsView(model:model) }
        .sheet(isPresented:$showReminders,onDismiss:focusComposer) { NativeRemindersView(model:model) }
        .sheet(isPresented:$showSavedMessages,onDismiss:focusComposer) {
            NativeMessageCollection(model:model)
        }
        .sheet(isPresented:$showLibrary,onDismiss:focusComposer) {
            if let channel = model.selectedChannel { NativeConversationLibrary(model:model,channelID:channel.id) }
        }
        .sheet(isPresented:$showHashtags,onDismiss:focusComposer) {
            if let channel = model.selectedChannel { NativeHashtagBrowser(model:model,channelID:channel.id) }
        }
        .sheet(isPresented: $showSearch, onDismiss: focusComposer) {
            NativeMessageSearchView(model: model)
        }
        .sheet(isPresented: $showEncryptionUnlock, onDismiss: focusComposer) { NativeEncryptionUnlockView(model: model) }
        .sheet(isPresented: $showEncryptionManagement, onDismiss: focusComposer) { NativeEncryptionManagementView(model: model) }
        .sheet(isPresented: $showNewConversation, onDismiss: focusComposer) { NativeNewConversationView(model: model) }
        .sheet(isPresented: $showNewChannel, onDismiss: focusComposer) { NativeCreateChannelView(model: model) }
        .sheet(isPresented: $showMembers, onDismiss: focusComposer) {
            if let channel = model.selectedChannel { NativeConversationMembersView(model: model, channel: channel).id(channel.id) }
        }
    }

    var body: some View {
        accountPresentations
        .onAppear(perform: restoreSessionIfNeeded)
        .onDisappear { model.previewDidDisappear() }
        .frame(minWidth: 800, minHeight: 560)
        .environment(\.nativeChatStyle, effectiveStyle)
        .preferredColorScheme(effectiveStyle.colorScheme)
    }

    private func restoreSessionIfNeeded() {
        guard !attemptedRestore else { return }
        attemptedRestore = true
        Task { @MainActor in
            if model.connected && model.liveStatus == .offline { await model.connect() }
            else if NativeChatAppConfiguration.automaticallyRestoresSavedSession { await model.restoreSavedSession() }
            if !model.connected && !NativeChatAppConfiguration.developmentUI { showSignIn = true }
        }
    }

    private func toggleQuickSwitcher() {
        if showQuickSwitcher { if !model.quickSwitcherBusy { showQuickSwitcher = false }; return }
        guard model.canPresentQuickSwitcher else { return }
        composerFocused = false; showQuickSwitcher = true
    }
    private func focusComposer() {
        composerFocused = model.connected && model.selection.map { model.canRead($0) } == true
            && !showNameSettings && !showAppearanceSettings && !showSidebarSettings && alertChannelID == nil && !showDownloads && !model.showDesktopSettings && !showQuickSwitcher && model.threadRoot == nil && model.imageViewerPost == nil && !model.documentPreviewIsPresented && !showSearch && !showSignIn && !showEncryptionUnlock && !showEncryptionManagement
            && !showSnippet && snippetRecovery == nil && !showPoll && !showNewConversation && !showNewChannel && !showMembers && !showLibrary && !showSavedMessages && !showThreads && !showPins && model.attachmentBatch == nil
    }

    private func updateReadVisibility() { model.updateReadingVisibility(active: windowActive, atBottom: atBottom) }
}

final class NativeChatPreviewWindowController: NSWindowController, NSWindowDelegate {
    private let model = NativeChatPreviewModel(channelActionJournal:.applicationSupport(), botSubscriptionJournal: .applicationSupport(), conversationStartJournal: .applicationSupport(), downloadPreferences: .standard(), emojiPreferences: .standard(), draftStore: .applicationSupport(), guestJournal: .applicationSupport(), encryptionJournal: .applicationSupport(), archiveDeletionJournal: .applicationSupport(), botActionJournal: .applicationSupport(), slashActionJournal:.applicationSupport(),promotionJournal:.applicationSupport(),forwardJournal:.applicationSupport(),invitationJournal:.applicationSupport(),encryptedCreationJournal:.applicationSupport(),encryptedConversationJournal:.applicationSupport(),webhookActionJournal:.applicationSupport(),scheduleCreationJournal:.applicationSupport())
    private let interfaceZoom = NativeInterfaceZoom(defaults: .standard)
    var isNativeFullScreen: Bool { window?.styleMask.contains(.fullScreen) == true }
    var canChangeInterfaceZoom: Bool { window != nil && NSApp.keyWindow === window && window?.attachedSheet == nil }
    private var availableZoomSize: CGSize {
        guard let window, let screen = window.screen ?? NSScreen.main else { return CGSize(width: 1600, height: 1120) }
        return window.contentRect(forFrameRect: screen.visibleFrame).size
    }
    func canStepZoom(_ direction: Int) -> Bool { canChangeInterfaceZoom && interfaceZoom.next(direction, maximum: NativeInterfaceZoom.capacity(contentSize: availableZoomSize)) != nil }
    func stepZoom(_ direction: Int) {
        guard canChangeInterfaceZoom, let next = interfaceZoom.next(direction, maximum: NativeInterfaceZoom.capacity(contentSize: availableZoomSize)) else { return }
        interfaceZoom.set(next); fitInterfaceZoom()
    }
    func resetInterfaceZoom() { guard canChangeInterfaceZoom else { return }; interfaceZoom.set(1); fitInterfaceZoom() }
    func toggleNativeFullScreen() { guard canChangeInterfaceZoom else { return }; window?.toggleFullScreen(nil) }
    private func fitInterfaceZoom() {
        guard let window else { return }
        interfaceZoom.fit(contentSize: availableZoomSize)
        let minimum = NativeInterfaceZoom.logicalMinimum
        let content = NSRect(x: 0, y: 0, width: minimum.width * interfaceZoom.effective, height: minimum.height * interfaceZoom.effective)
        window.minSize = window.frameRect(forContentRect: content).size
        guard !window.styleMask.contains(.fullScreen) else { return }
        var frame = window.frame
        let top = frame.maxY
        frame.size.width = max(frame.width, window.minSize.width); frame.size.height = max(frame.height, window.minSize.height)
        frame.origin.y = top - frame.height
        if let screen = window.screen {
            let bounds = screen.visibleFrame
            frame.size.width = min(frame.width, bounds.width); frame.size.height = min(frame.height, bounds.height)
            frame.origin.x = min(max(frame.minX, bounds.minX), bounds.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, bounds.minY), bounds.maxY - frame.height)
        }
        if frame != window.frame { window.setFrame(frame, display: true) }
    }
    private var unreadObservation: AnyCancellable?
    func observeUnread(_ callback: @escaping (Int) -> Void) {
        unreadObservation = model.$channels.map { $0.reduce(0) { min(9999, $0 + $1.badgeUnreadCount) } }.removeDuplicates().sink(receiveValue: callback)
    }
    func showDesktopSettings() {
        guard window?.attachedSheet == nil else { return }
        model.showDesktopSettings = true
    }
    private let windowLog = Logger(subsystem: "com.costwisegroup.synology-chat-native", category: "native-window")
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = NativeChatAppConfiguration.windowTitle
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 26/255, green: 29/255, blue: 33/255, alpha: 1)
        window.contentViewController = NSHostingController(rootView: NativeChatZoomRoot(model: model, zoom: interfaceZoom))
        window.setContentSize(NSSize(width: 1120, height: 780))
        window.minSize = NSSize(width: 800, height: 580)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        fitInterfaceZoom()
        model.prepareNotificationWindow { [weak self] in
            self?.showWindow(nil)
            self?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    override func showWindow(_ sender: Any?) {
        windowLog.notice("Native window shown")
        model.updateWindowVisibility(true, applicationActive: NSApp.isActive, applicationHidden: NSApp.isHidden)
        if window?.isMiniaturized == true { window?.deminiaturize(sender) }
        super.showWindow(sender)
    }
    func windowDidChangeScreen(_ notification: Notification) { fitInterfaceZoom() }
    func windowDidExitFullScreen(_ notification: Notification) { fitInterfaceZoom() }
    func windowDidBecomeKey(_ notification: Notification) { model.updateWindowVisibility(true, applicationActive: NSApp.isActive, applicationHidden: NSApp.isHidden) }
    func windowDidMiniaturize(_ notification: Notification) { model.updateWindowVisibility(false, applicationActive: NSApp.isActive, applicationHidden: NSApp.isHidden) }
    func windowDidDeminiaturize(_ notification: Notification) { model.updateWindowVisibility(true, applicationActive: NSApp.isActive, applicationHidden: NSApp.isHidden) }
    #if DEBUG
    func reviewSyntheticComposerInput(image:Bool) {
        guard NativeChatAppConfiguration.allowsOfficialSessionImport,model.userID == 10,model.selection == 93,
              model.selectedChannel?.type == "anonymous",model.attachmentBatch == nil,
              model.threadRoot == nil || model.threadRoot?.id == 399431958735 else { return }
        let rootID = model.threadRoot?.id
        Task {
            do {
                let members = try await model.conversationMembers(channelID:93)
                guard Set(members.map(\.user_id)) == Set([Int64(6),Int64(10)]),model.userID == 10,model.selection == 93,model.threadRoot?.id == rootID else { return }
                let scope = rootID == nil ? "root" : "thread"
                let caption = "Native " + (image ? "clipboard image" : "drop files") + " " + scope + " test — Peter."
                let existing = rootID == nil ? model.draft : model.replyDraft
                guard existing.isEmpty || existing == caption else { return }
                @MainActor func findEditor(_ view:NSView) -> NativeComposerText.ComposerTextView? {
                    if let editor = view as? NativeComposerText.ComposerTextView,editor.isEditable { return editor }
                    for child in view.subviews { if let editor = findEditor(child) { return editor } }
                    return nil
                }
                guard let content = (window?.attachedSheet ?? window)?.contentView,let editor = findEditor(content) else { return }
                let board = NSPasteboard(name:.init("native-private-composer-test-"+UUID().uuidString))
                defer { board.clearContents() }
                if image { board.setData(NativeSyntheticClipboardImage.data,forType:.png) }
                else {
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("native-drop-fixture-"+UUID().uuidString)
                    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
                    var values:[NSPasteboardItem] = []
                    for letter in ["a","b"] {
                        let file = folder.appendingPathComponent("native-drop-"+scope+"-"+letter+".txt")
                        try Data(("Synthetic native dropped file "+scope+" "+letter+". No private data.\n").utf8).write(to:file)
                        let value = NSPasteboardItem();value.setString(file.absoluteString,forType:.fileURL);values.append(value)
                    }
                    board.writeObjects(values)
                }
                if rootID == nil { model.draft = caption } else { model.replyDraft = caption }
                _ = editor.consumeAttachment(board)
            } catch { model.error = "Could not prepare the synthetic composer input." }
        }
    }
    func stageSyntheticMedia() {
        guard NativeChatAppConfiguration.allowsOfficialSessionImport,model.userID == 10,model.selection == 93,
              model.selectedChannel?.type == "anonymous",model.threadRoot == nil,model.draft.isEmpty,model.attachmentBatch == nil else { return }
        Task {
            do {
                let members = try await model.conversationMembers(channelID:93)
                guard Set(members.map(\.user_id)) == Set([Int64(6),Int64(10)]) else { return }
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("native-media-fixture-"+UUID().uuidString)
                let files = try await NativeSyntheticMedia.files(in:folder)
                guard model.userID == 10,model.selection == 93,model.threadRoot == nil,model.draft.isEmpty,model.attachmentBatch == nil else { try? FileManager.default.removeItem(at:folder);return }
                model.draft = "Native audio playback test — Peter."
                model.stageAttachments(files,inThread:false)
            } catch { model.error = "Could not prepare synthetic media fixtures." }
        }
    }
    func stageSyntheticAnimatedImage() {
        guard NativeChatAppConfiguration.allowsOfficialSessionImport,model.userID == 10,model.selection == 93,model.selectedChannel?.type == "anonymous",model.threadRoot == nil,model.draft.isEmpty,model.attachmentBatch == nil else {return}
        Task {
            do {
                let members = try await model.conversationMembers(channelID:93)
                guard Set(members.map(\.user_id)) == Set([Int64(6),Int64(10)]),model.userID == 10,model.selection == 93,model.threadRoot == nil,model.draft.isEmpty,model.attachmentBatch == nil else {return}
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("native-animated-fixture-"+UUID().uuidString)
                try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
                let file = folder.appendingPathComponent("native-animated-viewer.gif")
                try NativeSyntheticAnimatedImage.gif().write(to:file)
                model.draft = "Native animated image viewer test — synthetic colours only."
                model.stageAttachments([file],inThread:false)
            } catch {model.error = "Could not prepare the synthetic animated image."}
        }
    }
    func stageSyntheticDocument() {
        guard NativeChatAppConfiguration.allowsOfficialSessionImport,model.userID == 10,model.selection == 93,
              model.selectedChannel?.type == "anonymous",model.threadRoot == nil,model.draft.isEmpty,model.attachmentBatch == nil else { return }
        Task {
            do {
                let members = try await model.conversationMembers(channelID:93)
                guard Set(members.map(\.user_id)) == Set([Int64(6),Int64(10)]),model.userID == 10,model.selection == 93,model.threadRoot == nil,model.draft.isEmpty else { return }
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("native-document-fixture-"+UUID().uuidString)
                try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
                let file = folder.appendingPathComponent("native-document-preview.pdf")
                try NativeSyntheticDocument.data().write(to:file)
                model.draft = "Native PDF preview test — Peter."
                model.stageAttachments([file],inThread:false)
            } catch { model.error = "Could not prepare the synthetic PDF fixture." }
        }
    }
    func stageSyntheticAttachmentBatch() {
        guard NativeChatAppConfiguration.allowsOfficialSessionImport,model.userID == 10,model.selection == 93,
              model.selectedChannel?.type == "anonymous",model.threadRoot == nil || model.threadRoot?.id == 399431958735 else { return }
        let rootID = model.threadRoot?.id
        Task {
            do {
                let members = try await model.conversationMembers(channelID:93)
                guard Set(members.map(\.user_id)) == Set([Int64(6),Int64(10)]),model.userID == 10,model.selection == 93,model.threadRoot?.id == rootID else { return }
                let scope = rootID == nil ? "root" : (model.threadViewingContext ? "thread-context" : "thread")
                let captionScope = scope.replacingOccurrences(of:"-",with:" ")
                let caption = rootID == nil ? model.draft : model.replyDraft
                guard caption.isEmpty || caption.hasPrefix("Native multi " + captionScope + " test — ") else { return }
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("synology-native-multi-fixture-"+UUID().uuidString)
                try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
                let files = try ["a","b"].map { letter -> URL in
                    let file = folder.appendingPathComponent("native-multi-"+scope+"-"+letter+".txt")
                    try Data(("Synthetic native multi-file "+scope+" "+letter+" fixture. No private data.\n").utf8).write(to:file)
                    return file
                }
                if caption.isEmpty {
                    if rootID == nil { model.draft = "Native multi root test — first file." }
                    else { model.replyDraft = "Native multi " + captionScope + " test — first file." }
                }
                model.stageAttachments(files,inThread:rootID != nil)
            } catch { model.error = "Could not stage the synthetic attachment fixture." }
        }
    }
    #endif
    func setCompactSize(_ compact: Bool) {
        guard !isNativeFullScreen else { return }
        let size = compact ? NSSize(width: 820, height: 600) : NSSize(width: 1120, height: 780)
        window?.setContentSize(NSSize(width: size.width * interfaceZoom.effective, height: size.height * interfaceZoom.effective))
        fitInterfaceZoom()
    }
    func prepareForTermination() { model.prepareForTermination() }
    func windowWillClose(_ notification: Notification) {
        model.previewDidDisappear()
        windowLog.notice("Native window closed; background connection retained")
    }
    required init?(coder: NSCoder) { nil }
}
