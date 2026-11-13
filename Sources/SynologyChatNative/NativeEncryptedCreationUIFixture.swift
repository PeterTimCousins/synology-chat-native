#if DEBUG
import AppKit
import SwiftUI

@MainActor enum NativeEncryptedCreationUIFixture {
    /// Own-view rendering only: no windows, screen capture, input or session import.
    static func render(to directory:URL) async -> Bool {
        do {
            NSApplication.shared.setActivationPolicy(.prohibited)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let modes:[(String,ChatAppearanceStyle,Int)] = [("dark-create",.dark,0),("light-create",.light,0),("dark-locked-create",.dark,1),("dark-pending-create",.dark,2),("dark-known-recovery",.dark,3),("light-known-recovery",.light,3),("dark-unknown-recovery",.dark,4),("dark-recovery-centre",.dark,5),("dark-unjoined-recovery",.dark,6)]
            for (name,style,mode) in modes {
                let temporary = URL(fileURLWithPath:"/private/tmp/native-channel-invitation-fixture.creation-render-"+UUID().uuidString,isDirectory:true)
                let (model,backend) = try await NativeChannelInvitationUIFixture.makeModel(directory:temporary)
                defer { model.signOutLocally();try? FileManager.default.removeItem(at:temporary) }
                if mode > 1 {
                    if mode == 6 { backend.rejectJoin = true }
                    else if mode == 4 { backend.loseCreateReply = true } else { backend.loseJoinReply = true }
                    do { try await model.createChannel(name:"Project-planning",purpose:"Planning and decisions for the team",kind:.private,encrypted:true);throw ChatAPIError.invalidResponse }
                    catch { guard model.pendingEncryptedCreations.count == 1,backend.creates.count == 1 else { throw error } }
                }
                if mode == 1 || mode == 3 { model.lockEncryption() }
                if mode == 5 { model.channels = [] }
                let content = Group {
                    if mode < 3 { NativeCreateChannelView.renderFixture(model:model,encrypted:mode == 0) }
                    else if mode != 5,let intent = model.pendingEncryptedCreations.values.first { NativeEncryptedCreationRecoveryView(model:model,intent:intent) }
                    else { NativePendingChannelActionsView(model:model) }
                }.environment(\.nativeChatStyle,style).preferredColorScheme(style.colorScheme)
                let width = mode < 3 ? 520.0 : mode != 5 ? 580.0 : 600.0,height = mode < 3 ? 600.0 : mode < 5 ? 470.0 : 520.0
                let view = NSHostingView(rootView:content);view.appearance = NSAppearance(named:style == .dark ? .darkAqua : .aqua)
                view.frame = NSRect(x:0,y:0,width:width,height:height);view.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:60_000_000);view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw ChatAPIError.invalidResponse }
                view.cacheDisplay(in:view.bounds,to:bitmap)
                guard let bytes = bitmap.representation(using:.png,properties:[:]) else { throw ChatAPIError.invalidResponse }
                try bytes.write(to:directory.appendingPathComponent(name+".png"),options:.withoutOverwriting)
            }
            return true
        } catch { fputs("Offscreen synthetic encrypted creation rendering failed.\n",stderr);return false }
    }
}
#endif
