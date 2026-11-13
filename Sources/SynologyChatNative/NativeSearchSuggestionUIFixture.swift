#if DEBUG
import AppKit
import SwiftUI

@MainActor enum NativeSearchSuggestionUIFixture {
    static func render(to directory:URL) async -> Bool {
        do {
            NSApplication.shared.setActivationPolicy(.prohibited)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let model = NativeChatPreviewModel(restoreNotificationPreference:false,makeClient:{ _ in throw ChatAPIError.unsupportedAPI })
            let users:[[String:Any]] = (1...140).map { ["user_id":$0,"username":String(format:"person-%03d",$0),"nickname":String(format:"Project colleague %03d",$0),"type":"human","human_type":"dsm"] }
            model.directory = try JSONDecoder().decode([ChatUser].self,from:JSONSerialization.data(withJSONObject:users))
            let channels:[[String:Any]] = [
                ["channel_id":93,"name":"Project-planning","type":"private","encrypted":false,"is_joined":true,"unread":0],
                ["channel_id":94,"name":"Project-decisions","type":"private","encrypted":false,"is_joined":true,"unread":0],
                ["channel_id":95,"name":"Encrypted project","type":"private","encrypted":true,"is_joined":true,"unread":0],
                ["channel_id":96,"name":"Hidden project","type":"private","encrypted":false,"is_joined":true,"hide_global_at":1000,"unread":0],
                ["channel_id":97,"name":"Unjoined project","type":"public","encrypted":false,"is_joined":false,"unread":0],
                ["channel_id":98,"name":"Closed project","type":"private","encrypted":false,"is_joined":true,"is_closed":true,"unread":0]]
            model.channels = try JSONDecoder().decode([ChatChannel].self,from:JSONSerialization.data(withJSONObject:channels))
            model.connected = true;model.liveStatus = .live;model.selection = 93
            defer { model.signOutLocally() }
            let cases:[(String,ChatAppearanceStyle,String,Int?,Int?,Int64?)] = [("dark-empty",.dark,"",nil,0,nil),("light-empty",.light,"",nil,0,nil),("dark-fuzzy",.dark,"pc",nil,0,nil),("dark-many-people",.dark,"from:",nil,80,nil),("dark-middle-slot",.dark,"report  has:file",7,3,nil),("dark-literal",.dark,"\"from:Peter\"",nil,nil,nil),("dark-fixed-conversation",.dark,"in:",nil,0,93),("dark-conversation-scopes",.dark,"in:",nil,0,nil)]
            for (name,style,query,caret,selected,fixed) in cases {
                let content = NativeMessageSearchView.renderFixture(model:model,query:query,caret:caret,selected:selected,fixedChannelID:fixed).environment(\.nativeChatStyle,style).preferredColorScheme(style.colorScheme)
                let view = NSHostingView(rootView:content);view.appearance = NSAppearance(named:style == .dark ? .darkAqua : .aqua)
                view.frame = NSRect(x:0,y:0,width:680,height:640);view.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:100_000_000);view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw ChatAPIError.invalidResponse }
                view.cacheDisplay(in:view.bounds,to:bitmap)
                guard let bytes = bitmap.representation(using:.png,properties:[:]) else { throw ChatAPIError.invalidResponse }
                try bytes.write(to:directory.appendingPathComponent(name+".png"),options:.withoutOverwriting)
            }
            return true
        } catch { fputs("Offscreen synthetic search suggestion rendering failed.\n",stderr);return false }
    }
}
#endif
