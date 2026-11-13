#if DEBUG
import AppKit
import SwiftUI

@MainActor enum NativeEncryptedConversationUIFixture {
    static func render(to output:URL) async -> Bool {
        do {
            NSApplication.shared.setActivationPolicy(.prohibited)
            try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
            for (name,style,mode) in [("dark-new-encrypted",ChatAppearanceStyle.dark,0),("light-new-encrypted",.light,0),("dark-new-locked",.dark,1),("light-new-locked",.light,1),("dark-pending-encrypted-start",.dark,2),("light-pending-encrypted-start",.light,2),("dark-recovery-verified",.dark,3),("light-recovery-verified",.light,3),("dark-recovery-locked",.dark,4)] {
                let directory = URL(fileURLWithPath:"/private/tmp/native-channel-invitation-fixture.encrypted-start-"+UUID().uuidString,isDirectory:true)
                let (model,state) = try await NativeChannelInvitationUIFixture.makeModel(directory:directory,configure:{ $0.allowAnonymous = true })
                defer { model.signOutLocally();try? FileManager.default.removeItem(at:directory) }
                let snapshot = try await model.loadQuickSwitcher()
                var intent:ChatEncryptedConversationIntent?,status:ChatEncryptedConversationRecovery.Result?
                if mode >= 2 {
                    state.loseAnonymousReply = true
                    do { try await model.startEncryptedConversation(with:[20],reviewed:snapshot);throw ChatAPIError.invalidResponse }
                    catch { guard state.anonymousStarts.count == 1,let record = model.pendingEncryptedConversationStarts.values.first else { throw error };intent = record }
                    if mode == 4 { model.lockEncryption() }
                    status = try await model.checkEncryptedConversationStart(intent!,expectedGeneration:model.accountGeneration)
                }
                if mode == 1 { model.lockEncryption() }
                let content = Group {
                    if mode <= 1 { NativeNewConversationView.renderFixture(model:model,snapshot:snapshot,selected:[20],encrypted:mode == 0) }
                    else if mode == 2 { NativePendingChannelActionsView(model:model) }
                    else { NativeEncryptedConversationRecoveryView.renderFixture(model:model,intent:intent!,status:status) }
                }.environment(\.nativeChatStyle,style).preferredColorScheme(style.colorScheme)
                let host = NSHostingView(rootView:content);host.appearance = NSAppearance(named:style == .dark ? .darkAqua : .aqua)
                host.frame = NSRect(x:0,y:0,width:mode <= 1 ? 540 : 620,height:mode <= 1 ? 680 : mode == 2 ? 520 : 450)
                host.layoutSubtreeIfNeeded();for _ in 0..<8 { try await Task.sleep(nanoseconds:50_000_000);host.layoutSubtreeIfNeeded() }
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in:host.bounds) else { throw ChatAPIError.invalidResponse }
                host.cacheDisplay(in:host.bounds,to:bitmap);guard let data = bitmap.representation(using:.png,properties:[:]) else { throw ChatAPIError.invalidResponse }
                try data.write(to:output.appendingPathComponent(name+".png"),options:.withoutOverwriting)
            }
            return true
        } catch { fputs("Synthetic encrypted conversation UI rendering failed.\n",stderr);return false }
    }
}
#endif
