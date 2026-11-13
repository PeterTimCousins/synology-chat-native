#if DEBUG
import AppKit
import SwiftUI

@MainActor enum NativePollAttachmentUIFixture {
    static func render(to directory:URL) async -> Bool {
        do {
            NSApplication.shared.setActivationPolicy(.prohibited)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let modes:[(String,ChatAppearanceStyle,Int)] = [("dark-local-create",.dark,0),("light-nas-create",.light,1),("dark-empty-create",.dark,2),("dark-unconfirmed-create",.dark,3),("dark-attached-poll",.dark,4),("light-image-poll",.light,5)]
            for (name,style,mode) in modes {
                let temporary = URL(fileURLWithPath:"/private/tmp/native-channel-invitation-fixture.poll-render-"+UUID().uuidString,isDirectory:true)
                let (model,_) = try await NativeChannelInvitationUIFixture.makeModel(directory:temporary,unlock:false,configure:{ $0.encrypted = false })
                defer { model.signOutLocally();try? FileManager.default.removeItem(at:temporary) }
                var draft = ChatPollDraft();draft.question = "Which proposal should we review next?";draft.choices = [.init(text:"Review the engineering proposal"),.init(text:"Review the design proposal")];draft.allowAdd = true;model.pollDrafts[23] = draft
                let file = temporary.appendingPathComponent("Research notes for next week's review.txt");try Data("Synthetic file".utf8).write(to:file)
                if mode == 0 || mode == 3 { model.pollAttachments[23] = .local(try ChatPollLocalFile(file)) }
                if mode == 1 {
                    let nas = try JSONDecoder().decode(ChatNASFile.self,from:JSONSerialization.data(withJSONObject:["path":"/Synthetic/Research notes.txt","name":"Research notes.txt","isdir":false,"additional":["size":14000,"time":["mtime":1000],"perm":["acl":["read":true]]]]));model.pollAttachments[23] = .nas(nas)
                }
                let post = try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:["post_id":1001,"channel_id":23,"creator_id":10,"type":"vote","message":draft.question,"create_at":1000,"file_props":["name":mode == 5 ? "Design proposals.png" : file.lastPathComponent,"size":14000,"is_image":mode == 5],"props":["vote":["state":"open","options":["multiple":false,"anonymous":false,"add_option":true,"expire_at":0],"choices":[["id":"a","text":draft.choices[0].text,"count":2],["id":"b","text":draft.choices[1].text,"count":1]]]]]));model.posts = [post]
                let content = Group {
                    if mode < 4 { NativePollComposer.renderFixture(model:model,channelID:23,uncertain:mode == 3) }
                    else { NativePollCard(post:post,model:model).padding(18) }
                }.environment(\.nativeChatStyle,style).preferredColorScheme(style.colorScheme)
                let view = NSHostingView(rootView:content);view.appearance = NSAppearance(named:style == .dark ? .darkAqua : .aqua)
                view.frame = NSRect(x:0,y:0,width:mode < 4 ? 620 : 600,height:mode < 4 ? 780 : 430)
                view.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:120_000_000);view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw ChatAPIError.invalidResponse }
                view.cacheDisplay(in:view.bounds,to:bitmap);guard let data = bitmap.representation(using:.png,properties:[:]) else { throw ChatAPIError.invalidResponse }
                try data.write(to:directory.appendingPathComponent(name+".png"),options:.withoutOverwriting)
            }
            return true
        } catch { fputs("Offscreen synthetic poll attachment rendering failed.\n",stderr);return false }
    }
}
#endif
