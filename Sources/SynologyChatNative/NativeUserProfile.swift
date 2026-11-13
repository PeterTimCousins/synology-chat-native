import AppKit
import SwiftUI
import ImageIO

@MainActor final class NativeAvatarStore:ObservableObject {
    @Published private(set) var revision = 0
    private(set) var epoch = UUID()
    private var api:ChatAPIClient?
    private let images = NSCache<NSString,NSImage>()
    private let failures = NSCache<NSString,NSNumber>()
    private var tasks:[String:Task<Void,Never>] = [:]
    init() { images.countLimit = 128;images.totalCostLimit = 24*1024*1024;failures.countLimit = 256 }
    func attach(_ client:ChatAPIClient?) {
        epoch = UUID();tasks.values.forEach { $0.cancel() };tasks = [:];images.removeAllObjects();failures.removeAllObjects();api = client;revision += 1
    }
    func key(_ user:ChatUser?,size:ChatAvatarSize) -> String? {
        guard let user,user.user_id > 0,user.is_disabled != true,(user.delete_at ?? 0) == 0 else { return nil }
        let version = user.avatar_version ?? 0
        guard version >= 0,version <= 9007199254740991,version > 0 || user.app_id?.isEmpty == false else { return nil }
        return "\(epoch):\(user.user_id):\(version):\(user.app_id ?? ""):\(size.rawValue)"
    }
    func image(_ user:ChatUser?,size:ChatAvatarSize) -> NSImage? { key(user,size:size).flatMap { images.object(forKey:$0 as NSString) } }
    func failed(_ user:ChatUser?,size:ChatAvatarSize) -> Bool { key(user,size:size).map { failures.object(forKey:$0 as NSString) != nil } ?? false }
    func load(_ user:ChatUser?,size:ChatAvatarSize,retry:Bool = false) {
        guard let user,let key = key(user,size:size),let api else { return }
        if retry { failures.removeObject(forKey:key as NSString) }
        guard tasks[key] == nil,images.object(forKey:key as NSString) == nil,failures.object(forKey:key as NSString) == nil else { return }
        let expected = epoch
        tasks[key] = Task { [weak self] in
            defer { if self?.epoch == expected { self?.tasks[key] = nil } }
            do {
                let data = try await api.avatarData(userID:user.user_id,size:size,version:user.avatar_version ?? 0)
                try Task.checkCancellation();guard let self,self.epoch == expected else { return }
                guard let image = Self.decode(data,maximumPixelSize:size == .large ? 512 : 96) else { throw ChatAPIError.invalidResponse }
                self.images.setObject(image,forKey:key as NSString,cost:Int(image.size.width*image.size.height*4));self.revision += 1
            } catch is CancellationError { }
            catch { if let self,self.epoch == expected,!Task.isCancelled { self.failures.setObject(true,forKey:key as NSString);self.revision += 1 } }
        }
    }
    func waitForLoads() async { for task in tasks.values { await task.value } }
    static func decode(_ data:Data,maximumPixelSize:Int) -> NSImage? {
        guard data.count <= 2*1024*1024,let source = CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,["public.png","public.jpeg","com.compuserve.gif","org.webmproject.webp"].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0,height > 0,width <= 4096,height <= 4096,width*height <= 16*1024*1024 else { return nil }
        return NativeImagePreview.decode(data,maximumPixelSize:maximumPixelSize)
    }
}

struct NativeUserAvatar:View {
    @ObservedObject var avatars:NativeAvatarStore
    let user:ChatUser?
    let name:String
    var size:CGFloat = 34
    var resolution:ChatAvatarSize = .small
    var body:some View {
        ZStack {
            NativeChatAvatar(name:name,size:size,hexColor:user?.user_props?.avatar_color)
            if let image = avatars.image(user,size:resolution) { Image(nsImage:image).resizable().interpolation(.high).scaledToFill().frame(width:size,height:size).clipped() }
        }.frame(width:size,height:size).clipShape(RoundedRectangle(cornerRadius:size*0.23)).accessibilityHidden(true)
            .task(id:avatars.key(user,size:resolution)) { avatars.load(user,size:resolution) }
    }
}

struct NativeUserIdentity:View {
    @ObservedObject var model:NativeChatPreviewModel
    let userID:Int64
    var size:CGFloat = 34
    var showsName = false
    var showsAvatar = true
    @State private var showing = false
    private var user:ChatUser? { model.directory.first { $0.user_id == userID } }
    var body:some View {
        Button { showing = true } label: {
            HStack(spacing:10) {
                if showsAvatar { NativeUserAvatar(avatars:model.avatars,user:user,name:model.names[userID] ?? "User \(userID)",size:size) }
                if showsName { Text(model.names[userID] ?? "User \(userID)").font(.system(size:14,weight:.bold)) }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(user?.canViewProfile != true || !model.connected)
            .accessibilityLabel("View profile for " + (model.names[userID] ?? "User \(userID)"))
            .popover(isPresented:$showing) { NativeUserProfileView(model:model,userID:userID) }
            .onChange(of:model.connected) { if !$0 { showing = false } }
            .onChange(of:model.accountGeneration) { _ in showing = false }
            .onDisappear { showing = false }
    }
}

struct NativeUserProfileView:View {
    @ObservedObject var model:NativeChatPreviewModel
    let userID:Int64
    @Environment(\.dismiss) private var dismiss
    @State private var refreshing = false
    @State private var failure:String?
    @State private var task:Task<Void,Never>?
    private var user:ChatUser? { model.directory.first { $0.user_id == userID } }
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            if let user {
                HStack(alignment:.top) {
                    NativeUserAvatar(avatars:model.avatars,user:user,name:model.displayName(user),size:96,resolution:.large)
                    Spacer()
                    Button { refresh() } label: { Image(systemName:"arrow.clockwise") }.accessibilityLabel("Refresh profile").disabled(refreshing)
                    Button { dismiss() } label: { Image(systemName:"xmark") }.accessibilityLabel("Close profile")
                }.buttonStyle(NativeToolbarButtonStyle())
                VStack(alignment:.leading,spacing:5) {
                    Text(model.displayName(user)).font(.system(size:22,weight:.bold)).textSelection(.enabled)
                    if let username = model.additionalName(user) { Text(username).foregroundColor(NativeChatColors.muted).textSelection(.enabled) }
                    if user.human_type == "guest" { Text("Guest").font(.caption).foregroundColor(NativeChatColors.muted) }
                }
                Divider().overlay(NativeChatColors.separator)
                if let email = user.user_props?.email,!email.isEmpty { Label { Text(email).textSelection(.enabled) } icon: { Image(systemName:"envelope") }.font(.callout) }
                if let timezone = user.profileTimeZone {
                    TimelineView(.periodic(from:Date(),by:60)) { context in
                        Label { Text((model.regionalDisplay?.format(context.date,timeOnly:true,zone:timezone) ?? Self.localTime(context.date,zone:timezone))+" local time").font(.callout) } icon: { Image(systemName:"clock") }
                    }
                    Text(timezone.identifier).font(.caption).foregroundColor(NativeChatColors.muted)
                }
                if let description = user.user_props?.description,!description.isEmpty {
                    ScrollView { Text(description).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }.frame(maxHeight:130)
                }
                NativeAvatarRetry(avatars:model.avatars,user:user)
                if user.user_id != model.userID,user.canStartConversation {
                    Button("Message") {
                        refreshing = true
                        task = Task { @MainActor in
                            defer { refreshing = false }
                            do { try await model.openProfileConversation(userID:userID);try Task.checkCancellation();dismiss() }
                            catch is CancellationError { }
                            catch { failure = (error as? ChatTransferError)?.errorDescription ?? "Could not verify this conversation. Refresh before trying again." }
                        }
                    }.buttonStyle(NativeSendButtonStyle()).disabled(refreshing || !model.canInteract || model.isEditingMessage)
                }
            } else { Text("This profile is no longer available.").foregroundColor(NativeChatColors.muted) }
            if let failure { Text(failure).font(.caption).foregroundColor(.orange) }
        }.padding(24).frame(width:340,alignment:.leading).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance().tint(NativeChatColors.green)
            .task { refresh() }
            .onDisappear { task?.cancel() }
            .onChange(of:model.connected) { if !$0 { dismiss() } }
            .onChange(of:model.accountGeneration) { _ in dismiss() }
            .onChange(of:user?.canViewProfile) { if $0 != true { dismiss() } }
    }
    static func localTime(_ date:Date,zone:TimeZone) -> String { let f = DateFormatter();f.locale = .autoupdatingCurrent;f.timeZone = zone;f.dateStyle = .none;f.timeStyle = .short;return f.string(from:date) }
    private func refresh() {
        task?.cancel();refreshing = true;failure = nil
        task = Task { @MainActor in
            defer { refreshing = false }
            do { try await model.refreshUserProfiles();try Task.checkCancellation() }
            catch is CancellationError { }
            catch { failure = "Could not refresh this profile. Showing the last loaded details." }
        }
    }
}

private struct NativeAvatarRetry:View {
    @ObservedObject var avatars:NativeAvatarStore
    let user:ChatUser
    var body:some View { if avatars.failed(user,size:.large) { Button("Retry profile image") { avatars.load(user,size:.large,retry:true) }.font(.caption).buttonStyle(NativeToolbarButtonStyle()) } }
}
