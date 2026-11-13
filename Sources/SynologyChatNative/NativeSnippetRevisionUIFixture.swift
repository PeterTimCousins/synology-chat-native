#if DEBUG
import AppKit
import SwiftUI

@MainActor enum NativeSnippetRevisionUIFixture {
    static func render(to directory:URL) async -> Bool {
        do {
            NSApplication.shared.setActivationPolicy(.prohibited)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let original = NativeSnippetDraft(filename:"Planning.swift",caption:"Discussion notes",content:"// Project planning\nlet title = \"Roadmap\"\nlet nextStep = \"Review changes\"\n\nprint(title, nextStep)\n")
            var changed = original;changed.content += "\n// Local changes have not been sent\n";changed.caption = "Updated discussion notes"
            let modes:[(String,ChatAppearanceStyle,Int)] = [("dark-card",.dark,0),("light-card",.light,0),("dark-expanded",.dark,1),("dark-editor",.dark,2),("light-editor",.light,2),("dark-conflict",.dark,3),("dark-uncertain",.dark,4),("light-uncertain",.light,4)]
            for (name,style,mode) in modes {
                let temporary = URL(fileURLWithPath:"/private/tmp/native-channel-invitation-fixture.snippet-render-"+UUID().uuidString,isDirectory:true)
                let (model,_) = try await NativeChannelInvitationUIFixture.makeModel(directory:temporary,unlock:false,configure:{ $0.encrypted = false })
                defer { model.signOutLocally();try? FileManager.default.removeItem(at:temporary) }
                let object:[String:Any] = ["post_id":1001,"channel_id":23,"creator_id":10,"type":"file","message":original.caption,"create_at":1000,"update_at":1000,"file_props":["name":original.filename,"size":original.content.utf8.count,"is_image":false,"is_snippet":true,"snippet_preview":original.content.split(separator:"\n",omittingEmptySubsequences:false).prefix(2).joined(separator:"\n"),"snippet_lines":original.lineCount,"snippet_preview_more":true]]
                let post = try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:object));model.posts = [post]
                let failure:String? = mode == 3 ? "This snippet was edited elsewhere. Reopen it to review the latest code; your draft stays in this editor." : mode == 4 ? "This edit could not be confirmed. Check the conversation before saving again; your draft stays in this editor." : nil
                let editor = try NativeSnippetComposer.renderFixture(model:model,post:post,original:original,draft:changed,uncertain:mode >= 3,failure:failure)
                let content = Group {
                    if mode < 2 { NativeSnippetCard.renderFixture(post:post,model:model,full:mode == 1 ? original.content : nil) }
                    else { editor }
                }.environment(\.nativeChatStyle,style).preferredColorScheme(style.colorScheme)
                let view = NSHostingView(rootView:content);view.appearance = NSAppearance(named:style == .dark ? .darkAqua : .aqua)
                view.frame = NSRect(x:0,y:0,width:mode < 2 ? 640 : 900,height:mode == 0 ? 330 : mode == 1 ? 550 : 710)
                view.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:100_000_000);view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw ChatAPIError.invalidResponse }
                view.cacheDisplay(in:view.bounds,to:bitmap)
                guard let bytes = bitmap.representation(using:.png,properties:[:]) else { throw ChatAPIError.invalidResponse }
                try bytes.write(to:directory.appendingPathComponent(name+".png"),options:.withoutOverwriting)
            }
            return true
        } catch { fputs("Offscreen synthetic snippet rendering failed.\n",stderr);return false }
    }
}
#endif
