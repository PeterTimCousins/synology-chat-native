import AppKit
import Foundation

#if DEBUG
if let index = CommandLine.arguments.firstIndex(of:"--native-own-edit-live-probe") {
    guard CommandLine.arguments.indices.contains(index+1),CommandLine.arguments.contains("--disable-native-read-state") else { exit(2) }
    let receipt = URL(fileURLWithPath:CommandLine.arguments[index+1])
    guard !FileManager.default.fileExists(atPath:receipt.path) else { exit(2) }
    DispatchQueue.global().asyncAfter(deadline:.now()+120) { exit(2) }
    let application = NSApplication.shared;application.setActivationPolicy(.prohibited)
    Task { @MainActor in exit(await ChatOwnEditLiveProbe.run(receipt:receipt) ? 0 : 1) };application.run();exit(1)
}
if let index = CommandLine.arguments.firstIndex(of:"--native-virtual-thread-editor-render") {
    guard CommandLine.arguments.indices.contains(index+1) else { exit(2) }
    let directory = URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true)
    guard !FileManager.default.fileExists(atPath:directory.path) else { exit(2) }
    DispatchQueue.global().asyncAfter(deadline:.now()+25) { exit(2) }
    let application = NSApplication.shared;application.setActivationPolicy(.prohibited)
    Task { @MainActor in exit(await NativeRichThreadChecks.renderVirtualThreadEditor(to:directory) ? 0 : 1) };application.run();exit(1)
}
if let index = CommandLine.arguments.firstIndex(of:"--native-virtual-main-composer-render") {
    guard CommandLine.arguments.indices.contains(index+1) else { exit(2) }
    let directory = URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true)
    guard !FileManager.default.fileExists(atPath:directory.path) else { exit(2) }
    DispatchQueue.global().asyncAfter(deadline:.now()+25) { exit(2) }
    let application = NSApplication.shared;application.setActivationPolicy(.prohibited)
    Task { @MainActor in exit(await NativeRichThreadChecks.renderVirtualMainComposer(to:directory) ? 0 : 1) };application.run();exit(1)
}
if let index = CommandLine.arguments.firstIndex(where:{ ["--native-virtual-thread-viewport-render","--native-virtual-thread-resize-render","--native-virtual-thread-async-render","--native-virtual-thread-composer-render"].contains($0) }) {
    guard CommandLine.arguments.indices.contains(index+1) else { exit(2) }
    let directory = URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true)
    guard !FileManager.default.fileExists(atPath:directory.path) else { exit(2) }
    DispatchQueue.global().asyncAfter(deadline:.now()+25) { exit(2) }
    let application = NSApplication.shared;application.setActivationPolicy(.prohibited)
    let flag = CommandLine.arguments[index]
    let probe:NativeRichThreadChecks.VirtualViewportProbe
    switch flag {
    case "--native-virtual-thread-resize-render":probe = .resize
    case "--native-virtual-thread-async-render":probe = .asyncImage
    case "--native-virtual-thread-composer-render":probe = .composer
    default:probe = .none
    }
    Task { @MainActor in exit(await NativeRichThreadChecks.renderVirtualViewport(to:directory,probe:probe) ? 0 : 1) };application.run();exit(1)
}
if let index = CommandLine.arguments.firstIndex(where:{ $0 == "--native-virtual-rich-actions-render" || $0 == "--native-virtual-reaction-input-render" }) {
    guard CommandLine.arguments.indices.contains(index+1) else { exit(2) }
    let directory = URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true)
    guard !FileManager.default.fileExists(atPath:directory.path) else { exit(2) }
    DispatchQueue.global().asyncAfter(deadline:.now()+25) { exit(2) }
    let application = NSApplication.shared;application.setActivationPolicy(.prohibited)
    let reactionInput = CommandLine.arguments[index] == "--native-virtual-reaction-input-render"
    Task { @MainActor in exit(await NativeVirtualTimelineRichActionChecks.render(to:directory,reactionInput:reactionInput) ? 0 : 1) };application.run();exit(1)
}
if let index = CommandLine.arguments.firstIndex(of:"--native-virtual-actions-render") {
    guard CommandLine.arguments.indices.contains(index+1) else { exit(2) }
    let directory = URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true)
    guard !FileManager.default.fileExists(atPath:directory.path) else { exit(2) }
    DispatchQueue.global().asyncAfter(deadline:.now()+25) { exit(2) }
    let application = NSApplication.shared;application.setActivationPolicy(.prohibited)
    Task { @MainActor in exit(await NativeVirtualTimelineActionChecks.render(to:directory) ? 0 : 1) };application.run();exit(1)
}
if let index = CommandLine.arguments.firstIndex(where:{ $0 == "--native-table-exact-editor-render" || $0 == "--native-table-exact-editor-closed-event-render" || $0 == "--native-virtual-exact-editor-render" }) {
    guard CommandLine.arguments.indices.contains(index+1) else { exit(2) }
    let directory = URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true)
    guard !FileManager.default.fileExists(atPath:directory.path) else { exit(2) }
    DispatchQueue.global().asyncAfter(deadline:.now()+25) { exit(2) }
    let application = NSApplication.shared;application.setActivationPolicy(.prohibited)
    let closeTypingEvent = CommandLine.arguments[index] == "--native-table-exact-editor-closed-event-render"
    let useVirtual = CommandLine.arguments[index] == "--native-virtual-exact-editor-render"
    Task { @MainActor in exit(await NativeTableEditorProcessChecks.render(to:directory,closeTypingEvent:closeTypingEvent,useVirtual:useVirtual) ? 0 : 1) };application.run();exit(1)
}
for (flag,probe) in [("--native-table-cache-ownership-render",NativeRichHistoryChecks.TableProbe.cache),("--native-table-anchor-ownership-render",NativeRichHistoryChecks.TableProbe.anchor),("--native-table-editor-ownership-render",NativeRichHistoryChecks.TableProbe.editor),("--native-table-editor-micro-render",NativeRichHistoryChecks.TableProbe.editorMicro),("--native-virtual-cache-ownership-render",NativeRichHistoryChecks.TableProbe.cache),("--native-virtual-anchor-ownership-render",NativeRichHistoryChecks.TableProbe.anchor),("--native-virtual-editor-ownership-render",NativeRichHistoryChecks.TableProbe.editor),("--native-virtual-editor-micro-render",NativeRichHistoryChecks.TableProbe.editorMicro)] {
    if let index = CommandLine.arguments.firstIndex(of:flag) {
        guard CommandLine.arguments.indices.contains(index+1) else { exit(2) }
        let directory = URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true)
        guard !FileManager.default.fileExists(atPath:directory.path) else { exit(2) }
        DispatchQueue.global().asyncAfter(deadline:.now()+25) { exit(2) }
        let application = NSApplication.shared;application.setActivationPolicy(.prohibited)
        let useVirtual = flag.hasPrefix("--native-virtual-")
        Task { @MainActor in exit(await NativeRichHistoryChecks.renderPaged(to:directory,navigation:.anchors,useNativeTable:!useVirtual,useNativeVirtual:useVirtual,probe:probe) ? 0 : 1) };application.run();exit(1)
    }
}
for (flag,mode) in [("--native-table-paged-history-render",NativeRichHistoryChecks.PagedNavigation.directClip),("--native-table-resized-history-render",NativeRichHistoryChecks.PagedNavigation.resizing),("--native-table-anchored-history-render",NativeRichHistoryChecks.PagedNavigation.anchors),("--native-table-sequential-history-render",NativeRichHistoryChecks.PagedNavigation.sequential),("--native-virtual-paged-history-render",NativeRichHistoryChecks.PagedNavigation.directClip),("--native-virtual-resized-history-render",NativeRichHistoryChecks.PagedNavigation.resizing),("--native-virtual-anchored-history-render",NativeRichHistoryChecks.PagedNavigation.anchors),("--native-virtual-sequential-history-render",NativeRichHistoryChecks.PagedNavigation.sequential)] {
    if let index = CommandLine.arguments.firstIndex(of:flag) {
        guard CommandLine.arguments.indices.contains(index+1) else { exit(2) }
        let directory = URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true)
        guard !FileManager.default.fileExists(atPath:directory.path) else { exit(2) }
        DispatchQueue.global().asyncAfter(deadline:.now()+25) { exit(2) }
        let application = NSApplication.shared;application.setActivationPolicy(.prohibited)
        let useVirtual = flag.hasPrefix("--native-virtual-")
        Task { @MainActor in exit(await NativeRichHistoryChecks.renderPaged(to:directory,navigation:mode,useNativeTable:!useVirtual,useNativeVirtual:useVirtual) ? 0 : 1) };application.run();exit(1)
    }
}
if let index = CommandLine.arguments.firstIndex(of:"--native-rich-composer-render") {
    guard CommandLine.arguments.indices.contains(index+1) else { exit(2) }
    let directory = URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true)
    guard !FileManager.default.fileExists(atPath:directory.path) else { exit(2) }
    DispatchQueue.global().asyncAfter(deadline:.now()+25) { exit(2) }
    let application = NSApplication.shared;application.setActivationPolicy(.prohibited)
    Task { @MainActor in exit(await NativeRichThreadChecks.render(to:directory,inThread:false) ? 0 : 1) };application.run();exit(1)
}
if let index = CommandLine.arguments.firstIndex(of:"--native-rich-thread-render") {
    guard CommandLine.arguments.indices.contains(index+1) else { exit(2) }
    let directory = URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true)
    guard !FileManager.default.fileExists(atPath:directory.path) else { exit(2) }
    DispatchQueue.global().asyncAfter(deadline:.now()+25) { exit(2) }
    let application = NSApplication.shared;application.setActivationPolicy(.prohibited)
    Task { @MainActor in exit(await NativeRichThreadChecks.render(to:directory) ? 0 : 1) };application.run();exit(1)
}

for (flag,mode) in [("--native-resized-rich-history-render",NativeRichHistoryChecks.PagedNavigation.resizing),("--native-anchored-rich-history-render",NativeRichHistoryChecks.PagedNavigation.anchors),("--native-sequential-rich-history-render",NativeRichHistoryChecks.PagedNavigation.sequential)] {
    if let index = CommandLine.arguments.firstIndex(of:flag) {
        guard CommandLine.arguments.indices.contains(index+1) else { exit(2) }
        let directory = URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true)
        guard !FileManager.default.fileExists(atPath:directory.path) else { exit(2) }
        DispatchQueue.global().asyncAfter(deadline:.now()+25) { exit(2) }
        let application = NSApplication.shared;application.setActivationPolicy(.prohibited)
        Task { @MainActor in exit(await NativeRichHistoryChecks.renderPaged(to:directory,navigation:mode) ? 0 : 1) };application.run();exit(1)
    }
}
if let index = CommandLine.arguments.firstIndex(of:"--native-paged-rich-history-render") {
    guard CommandLine.arguments.indices.contains(index+1) else { exit(2) }
    let directory = URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true)
    guard !FileManager.default.fileExists(atPath:directory.path) else { exit(2) }
    DispatchQueue.global().asyncAfter(deadline:.now()+25) { exit(2) }
    let application = NSApplication.shared;application.setActivationPolicy(.prohibited)
    Task { @MainActor in exit(await NativeRichHistoryChecks.renderPaged(to:directory) ? 0 : 1) };application.run();exit(1)
}
if let index = CommandLine.arguments.firstIndex(of:"--native-rich-history-render") {
    guard CommandLine.arguments.indices.contains(index+1) else { exit(2) }
    let directory = URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true)
    guard !FileManager.default.fileExists(atPath:directory.path) else { exit(2) }
    DispatchQueue.global().asyncAfter(deadline:.now()+25) { exit(2) }
    let application = NSApplication.shared;application.setActivationPolicy(.prohibited)
    Task { @MainActor in exit(await NativeRichHistoryChecks.render(to:directory) ? 0 : 1) };application.run();exit(1)
}
if let index = CommandLine.arguments.firstIndex(of:"--native-held-history-render") {
    guard CommandLine.arguments.indices.contains(index+1) else { exit(2) }
    let directory = URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true)
    guard !FileManager.default.fileExists(atPath:directory.path) else { exit(2) }
    DispatchQueue.global().asyncAfter(deadline:.now()+25) { exit(2) }
    let application = NSApplication.shared;application.setActivationPolicy(.prohibited)
    Task { @MainActor in exit(await NativeTimelineChecks.renderHeldReload(to:directory) ? 0 : 1) };application.run();exit(1)
}
if let index = CommandLine.arguments.firstIndex(of:"--native-localization-bundle-probe") {
    guard CommandLine.arguments.indices.contains(index+1) else { exit(2) }
    exit(NativeLocalizationBundleProbe.run(output:URL(fileURLWithPath:CommandLine.arguments[index+1])) ? 0 : 1)
}
if let index = CommandLine.arguments.firstIndex(of:"--native-account-settings-render") {
    guard CommandLine.arguments.indices.contains(index+1) else { exit(2) }
    let directory = URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true)
    let application = NSApplication.shared;application.setActivationPolicy(.prohibited)
    DispatchQueue.global().asyncAfter(deadline:.now()+25) { exit(2) }
    Task { @MainActor in exit(await NativeNotificationSettingsFixture.renderAccountSettings(to:directory) ? 0 : 1) };application.run();exit(1)
}
if [NativeNotificationSettingsFixture.regionalBundleID,NativeNotificationSettingsFixture.regionalAXBundleID].contains(Bundle.main.bundleIdentifier ?? "") {
    MainActor.assumeIsolated { NativeNotificationSettingsFixture.runRegionalChecks() };exit(0)
}
if Bundle.main.bundleIdentifier == NativeConversationDropFixture.bundleID {
    MainActor.assumeIsolated { NativeConversationDropFixture.run() };exit(0)
}
if Bundle.main.bundleIdentifier == NativeWebhookRecoveryChecks.bundleID {
    MainActor.assumeIsolated { NativeWebhookRecoveryChecks.run() };exit(0)
}
if let index = CommandLine.arguments.firstIndex(of:"--native-notification-settings-render") {
    guard CommandLine.arguments.indices.contains(index+1) else { exit(2) }
    let directory = URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true)
    let application = NSApplication.shared;application.setActivationPolicy(.prohibited)
    DispatchQueue.global().asyncAfter(deadline:.now()+25) { exit(2) }
    Task { @MainActor in exit(await NativeNotificationSettingsFixture.render(to:directory) ? 0 : 1) };application.run();exit(1)
}
if let index = CommandLine.arguments.firstIndex(of:"--native-attachment-review-render") {
    guard CommandLine.arguments.indices.contains(index+1) else { exit(2) }
    let directory = URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true)
    let application = NSApplication.shared;application.setActivationPolicy(.prohibited)
    DispatchQueue.global().asyncAfter(deadline:.now()+25) { exit(2) }
    Task { @MainActor in exit(await NativeAttachmentReviewFixture.render(to:directory) ? 0 : 1) };application.run();exit(1)
}
if Bundle.main.bundleIdentifier == NativeTimelineChecks.bundleID {
    MainActor.assumeIsolated { NativeTimelineChecks.run() };exit(0)
}
if Bundle.main.bundleIdentifier == NativeYouTubeChecks.bundleID {
    MainActor.assumeIsolated { NativeYouTubeChecks.run() };exit(0)
}
if let index = CommandLine.arguments.firstIndex(of:"--native-encrypted-conversation-process") {
    guard CommandLine.arguments.indices.contains(index+2) else { exit(2) }
    let directory = URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true),phase = CommandLine.arguments[index+2]
    Task { @MainActor in exit(await NativeEncryptedConversationProcessFixture.run(directory:directory,phase:phase) ? 0 : 1) };dispatchMain()
}
if Bundle.main.bundleIdentifier == NativeEncryptedConversationChecks.bundleID {
    MainActor.assumeIsolated { NativeEncryptedConversationChecks.run() };exit(0)
}
if let index = CommandLine.arguments.firstIndex(of:"--native-encrypted-conversation-render") {
    guard CommandLine.arguments.indices.contains(index+1) else { exit(2) }
    let output = URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true),application = NSApplication.shared
    application.setActivationPolicy(.prohibited);DispatchQueue.global().asyncAfter(deadline:.now()+40) { exit(2) }
    Task { @MainActor in exit(await NativeEncryptedConversationUIFixture.render(to:output) ? 0 : 1) };application.run();exit(1)
}
if let index = CommandLine.arguments.firstIndex(of:"--native-preview-checks-panel-render") {
    guard CommandLine.arguments.indices.contains(index+1) else { exit(2) }
    let output = URL(fileURLWithPath:CommandLine.arguments[index+1]);let application = NSApplication.shared;application.setActivationPolicy(.prohibited)
    DispatchQueue.global().asyncAfter(deadline:.now()+20) { exit(2) }
    Task { @MainActor in exit(await NativeSearchPreviewChecks.renderPanel(to:output) ? 0 : 1) };application.run();exit(1)
}
if [NativeSearchPreviewChecks.bundleID,NativeSearchPreviewChecks.sidebarBundleID].contains(Bundle.main.bundleIdentifier ?? "") {
    MainActor.assumeIsolated { NativeSearchPreviewChecks.run() };exit(0)
}
if let index = CommandLine.arguments.firstIndex(of:"--native-search-results-render") {
    guard CommandLine.arguments.indices.contains(index+1) else { exit(2) }
    let directory = URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true)
    let application = NSApplication.shared;application.setActivationPolicy(.prohibited)
    DispatchQueue.global().asyncAfter(deadline:.now()+20) { exit(2) }
    Task { @MainActor in exit(await NativeSearchResultsUIFixture.render(to:directory) ? 0 : 1) };application.run();exit(1)
}
if let index = CommandLine.arguments.firstIndex(of:"--native-poll-attachment-render") {
    guard CommandLine.arguments.indices.contains(index+1) else { exit(2) }
    let directory = URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true)
    let application = NSApplication.shared;application.setActivationPolicy(.prohibited)
    DispatchQueue.global().asyncAfter(deadline:.now()+20) { exit(2) }
    Task { @MainActor in exit(await NativePollAttachmentUIFixture.render(to:directory) ? 0 : 1) };application.run();exit(1)
}
if let index = CommandLine.arguments.firstIndex(of:"--native-snippet-import-render") {
    guard CommandLine.arguments.indices.contains(index+1) else { exit(2) }
    let directory = URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true)
    let application = NSApplication.shared;application.setActivationPolicy(.prohibited)
    DispatchQueue.global().asyncAfter(deadline:.now()+20) { exit(2) }
    Task { @MainActor in exit(await NativeSnippetImportUIFixture.render(to:directory) ? 0 : 1) };application.run();exit(1)
}
if let index = CommandLine.arguments.firstIndex(of:"--native-snippet-revision-render") {
    guard CommandLine.arguments.indices.contains(index+1) else { exit(2) }
    let directory = URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true)
    let application = NSApplication.shared;application.setActivationPolicy(.prohibited)
    DispatchQueue.global().asyncAfter(deadline:.now()+20) { exit(2) }
    Task { @MainActor in exit(await NativeSnippetRevisionUIFixture.render(to:directory) ? 0 : 1) };application.run();exit(1)
}
if let index = CommandLine.arguments.firstIndex(of:"--native-search-suggestions-render") {
    guard CommandLine.arguments.indices.contains(index+1) else { exit(2) }
    let directory = URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true)
    let application = NSApplication.shared;application.setActivationPolicy(.prohibited)
    DispatchQueue.global().asyncAfter(deadline:.now()+20) { exit(2) }
    Task { @MainActor in exit(await NativeSearchSuggestionUIFixture.render(to:directory) ? 0 : 1) };application.run();exit(1)
}
if let index = CommandLine.arguments.firstIndex(of:"--native-encrypted-join-contract") {
    guard CommandLine.arguments.indices.contains(index+2) else { exit(2) }
    let directory = URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true),phase = CommandLine.arguments[index+2]
    DispatchQueue.global().asyncAfter(deadline:.now()+20) { exit(2) }
    Task { @MainActor in exit(await NativeEncryptedJoinProcessFixture.run(directory:directory,phase:phase) ? 0 : 1) };dispatchMain()
}
if let index = CommandLine.arguments.firstIndex(of:"--native-encrypted-creation-render") {
    guard CommandLine.arguments.indices.contains(index+1) else { exit(2) }
    let directory = URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true)
    let application = NSApplication.shared;application.setActivationPolicy(.prohibited)
    DispatchQueue.global().asyncAfter(deadline:.now()+20) { exit(2) }
    Task { @MainActor in exit(await NativeEncryptedCreationUIFixture.render(to:directory) ? 0 : 1) };application.run();exit(1)
}
if let index = CommandLine.arguments.firstIndex(of:"--native-channel-invitation-render") {
    guard CommandLine.arguments.indices.contains(index+1) else { exit(2) }
    let directory = URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true)
    let application = NSApplication.shared;application.setActivationPolicy(.prohibited)
    DispatchQueue.global().asyncAfter(deadline:.now()+20) { exit(2) }
    Task { @MainActor in exit(await NativeChannelInvitationUIFixture.render(to:directory) ? 0 : 1) };application.run();exit(1)
}
if let index = CommandLine.arguments.firstIndex(of:"--native-forward-recovery-contract") {
    guard CommandLine.arguments.indices.contains(index+2) else { exit(2) }
    let directory = URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true),phase = CommandLine.arguments[index+2]
    Task { @MainActor in exit(await NativeForwardRecoveryFixture.runContract(directory:directory,phase:phase) ? 0 : 1) };dispatchMain()
}
if let index = CommandLine.arguments.firstIndex(of:"--native-forward-recovery-render") {
    guard CommandLine.arguments.indices.contains(index+1) else { exit(2) }
    let directory = URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true)
    let application = NSApplication.shared;application.setActivationPolicy(.prohibited)
    DispatchQueue.global().asyncAfter(deadline:.now()+20) { exit(2) }
    Task { @MainActor in exit(await NativeForwardRecoveryFixture.render(to:directory) ? 0 : 1) };application.run();exit(1)
}
if let index = CommandLine.arguments.firstIndex(of:"--native-conversion-recovery-contract") {
    guard CommandLine.arguments.indices.contains(index+2) else { exit(2) }
    let directory = URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true),phase = CommandLine.arguments[index+2]
    Task { @MainActor in exit(await NativeConversionRecoveryFixture.runContract(directory:directory,phase:phase) ? 0 : 1) };dispatchMain()
}
if let index = CommandLine.arguments.firstIndex(of:"--native-conversion-recovery-render") {
    guard CommandLine.arguments.indices.contains(index+1) else { exit(2) }
    let directory = URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true)
    let application = NSApplication.shared;application.setActivationPolicy(.prohibited)
    DispatchQueue.global().asyncAfter(deadline:.now()+20) { exit(2) }
    Task { @MainActor in exit(await NativeConversionRecoveryFixture.render(to:directory) ? 0 : 1) };application.run();exit(1)
}
if Bundle.main.bundleIdentifier == "com.costwisegroup.synology-chat-native.conversion-recovery-fixture" {
    MainActor.assumeIsolated { NativeConversionRecoveryFixture.run() };exit(0)
}

if let index = CommandLine.arguments.firstIndex(of:"--native-slash-recovery-contract") {
    guard CommandLine.arguments.indices.contains(index+2) else { exit(2) }
    let directory = URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true),phase = CommandLine.arguments[index+2]
    Task { @MainActor in exit(await NativeSlashRecoveryFixture.runContract(directory:directory,phase:phase) ? 0 : 1) }
    dispatchMain()
}
if let index = CommandLine.arguments.firstIndex(of:"--native-slash-recovery-render") {
    guard CommandLine.arguments.indices.contains(index+1) else { exit(2) }
    let directory = URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true)
    let application = NSApplication.shared;application.setActivationPolicy(.prohibited)
    DispatchQueue.global().asyncAfter(deadline:.now()+20) { exit(2) }
    Task { @MainActor in exit(await NativeSlashRecoveryFixture.render(to:directory) ? 0 : 1) }
    application.run();exit(1)
}
if Bundle.main.bundleIdentifier == "com.costwisegroup.synology-chat-native.slash-recovery-fixture" {
    MainActor.assumeIsolated { NativeSlashRecoveryFixture.run() }
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of:"--native-inline-image-contract"), CommandLine.arguments.indices.contains(index+1) {
    let receipt = URL(fileURLWithPath:CommandLine.arguments[index+1])
    Task { @MainActor in exit(await ChatInlineImageContractProbe.run(receipt:receipt) ? 0 : 1) }
    dispatchMain()
}
if Bundle.main.bundleIdentifier == "com.costwisegroup.synology-chat-native.channel-settings-fixture" {
    MainActor.assumeIsolated { NativeChannelSettingsUIFixture.run() }
    exit(0)
}
if Bundle.main.bundleIdentifier == "com.costwisegroup.synology-chat-native.bot-recovery-fixture" {
    MainActor.assumeIsolated { NativeBotAttachmentsFixture.runRecoveryFixture() }
    exit(0)
}
if Bundle.main.bundleIdentifier == "com.costwisegroup.synology-chat-native.encrypted-archive-fixture" {
    MainActor.assumeIsolated { NativeEncryptedArchiveUIFixture.run() }
    exit(0)
}
if let index = CommandLine.arguments.firstIndex(where: { ["--native-inline-audio-render", "--native-file-open-render"].contains($0) }), CommandLine.arguments.indices.contains(index + 1) {
    let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
    let fixtureApp = NSApplication.shared
    fixtureApp.setActivationPolicy(.prohibited)
    DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
        fputs("Offscreen fixture timed out without opening a window.\n", stderr)
        exit(2)
    }
    Task { @MainActor in
        let result: Bool
        if CommandLine.arguments[index] == "--native-file-open-render" { result = NativeSavedFileOpenRenderFixture.render(to: directory) }
        else { result = await NativeInlineAudioRenderFixture.render(to: directory) }
        exit(result ? 0 : 1)
    }
    fixtureApp.run()
    exit(1)
}
if let index = CommandLine.arguments.firstIndex(of: "--native-media-stream-probe"), CommandLine.arguments.indices.contains(index + 1) {
    let receipt = URL(fileURLWithPath: CommandLine.arguments[index + 1])
    Task { exit(await ChatMediaStreamingProbe.run(receipt: receipt) ? 0 : 1) }
    dispatchMain()
}
if let index = CommandLine.arguments.firstIndex(of: "--native-media-range-probe"), CommandLine.arguments.indices.contains(index + 1) {
    let receipt = URL(fileURLWithPath: CommandLine.arguments[index + 1])
    Task { exit(await ChatMediaRangeProbe.run(receipt: receipt) ? 0 : 1) }
    dispatchMain()
}
if let index = CommandLine.arguments.firstIndex(of: "--native-appearance-roundtrip"), CommandLine.arguments.indices.contains(index + 1) {
    let receipt = URL(fileURLWithPath: CommandLine.arguments[index + 1])
    Task { exit(await ChatAppearanceRoundTripProbe.run(receipt: receipt) ? 0 : 1) }
    dispatchMain()
}
if let index = CommandLine.arguments.firstIndex(of: "--native-appearance-contract-probe"), CommandLine.arguments.indices.contains(index + 1) {
    let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
    Task { exit(await ChatAppearanceContractProbe.run(directory: directory) ? 0 : 1) }
    dispatchMain()
}
if let index = CommandLine.arguments.firstIndex(where: { ["--native-administrator-contract", "--native-administrator-verified"].contains($0) }), CommandLine.arguments.indices.contains(index + 1) {
    let receipt = URL(fileURLWithPath: CommandLine.arguments[index + 1])
    Task { exit(await ChatAdministratorContractProbe.run(receipt: receipt, verifyProduction: CommandLine.arguments[index] == "--native-administrator-verified") ? 0 : 1) }
    dispatchMain()
}
if let index = CommandLine.arguments.firstIndex(of: "--native-peter-check"), CommandLine.arguments.indices.contains(index + 1) {
    let receipt = URL(fileURLWithPath: CommandLine.arguments[index + 1])
    let send = CommandLine.arguments.contains("--send-one-peter-test")
    let replyIndex = CommandLine.arguments.firstIndex(of: "--verify-peter-reply")
    let reply = replyIndex.flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil }
    Task { exit(await ChatPeterInteroperabilityProbe.run(receipt: receipt, send: send, expectedReply: reply) ? 0 : 1) }
    dispatchMain()
}
if let index = CommandLine.arguments.firstIndex(where:{["--native-reminder-delivery-probe","--native-reminder-cleanup-probe"].contains($0)}),CommandLine.arguments.indices.contains(index+1) {
    let receipt = URL(fileURLWithPath:CommandLine.arguments[index+1]),cleanup = CommandLine.arguments[index] == "--native-reminder-cleanup-probe"
    Task { @MainActor in exit(await ChatReminderDeliveryProbe.run(receiptURL:receipt,cleanup:cleanup) ? 0 : 1) }
    dispatchMain()
}
if let index = CommandLine.arguments.firstIndex(of:"--native-collection-recovery-probe"), CommandLine.arguments.indices.contains(index + 1) {
    let receipt = URL(fileURLWithPath:CommandLine.arguments[index + 1])
    Task { @MainActor in exit(await ChatCollectionRecoveryProbe.run(receiptURL:receipt) ? 0 : 1) }
    dispatchMain()
}
if CommandLine.arguments.contains("--native-upload-cancel-probe") {
    Task { @MainActor in exit(await ChatUploadCancellationProbe.run() ? 0 : 1) }
    dispatchMain()
}
if CommandLine.arguments.contains("--native-conversation-probe") {
    Task { exit(await ChatConversationProbe.run() ? 0 : 1) }
    dispatchMain()
}
if CommandLine.arguments.contains("--native-message-gap-probe") {
    Task { @MainActor in exit(await ChatMessageGapProbe.run() ? 0 : 1) }
    dispatchMain()
}
if CommandLine.arguments.contains("--native-quickconnect-probe") {
    guard let index = CommandLine.arguments.firstIndex(of: "--quickconnect-id"), index + 1 < CommandLine.arguments.count else {
        print("Supply --quickconnect-id ID for this read-only probe."); exit(1)
    }
    let id = CommandLine.arguments[index + 1]
    Task { exit(await ChatQuickConnectProbe.run(id: id) ? 0 : 1) }
    dispatchMain()
}

if CommandLine.arguments.contains("--native-feature-probe") {
    Task {
        let passed = await ChatReadOnlyFeatureProbe.run()
        exit(passed ? 0 : 1)
    }
    dispatchMain()
}

if CommandLine.arguments.contains("--native-attachment-probe") {
    Task {
        let passed = await ChatAttachmentProbe.run(inThread: CommandLine.arguments.contains("--thread-attachment"))
        exit(passed ? 0 : 1)
    }
    dispatchMain()
}

if CommandLine.arguments.contains("--native-read-state-probe") {
    Task { @MainActor in
        let passed = await ChatReadStateProbe.run()
        exit(passed ? 0 : 1)
    }
    dispatchMain()
}

if CommandLine.arguments.contains("--native-thread-probe") {
    Task { @MainActor in
        let passed = await ChatThreadProbe.run(create: CommandLine.arguments.contains("--send-test-to-peter"))
        exit(passed ? 0 : 1)
    }
    dispatchMain()
}

if CommandLine.arguments.contains("--native-live-probe") {
    Task { @MainActor in
        let passed = await ChatLiveProbe.run(sendTest: CommandLine.arguments.contains("--send-test-to-peter"))
        exit(passed ? 0 : 1)
    }
    dispatchMain()
}

// Development probe reports counts only and never prints URLs, tokens or message contents.
if CommandLine.arguments.contains("--native-api-probe") {
    Task {
        do {
            let imported = try OfficialChatSessionLoader.load()
            let client = try ChatAPIClient(session: imported.session)
            try await client.discover()
            print("API discovery verified.")
            let users = try await client.users()
            print("User decoding verified.")
            let channels = try await client.channels()
            print("Channel decoding verified.")
            print("Native unread badge count: \(channels.reduce(0) { min(9999, $0 + $1.badgeUnreadCount) })")
            var postCount = 0
            if let channel = channels.first(where: { !$0.encrypted }) {
                postCount = try await client.posts(channelID: channel.id).count
                print("History decoding verified.")
                _ = try await client.members(channelID: channel.id)
            }
            print("Native API verified: \(channels.count) channels, \(users.count) users, \(postCount) posts in first unencrypted channel.")
            exit(0)
        } catch {
            print((error as? LocalizedError)?.errorDescription ?? "Native API probe failed.")
            exit(1)
        }
    }
    dispatchMain()
}
#endif

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
MenuBuilder.install()
app.run()
