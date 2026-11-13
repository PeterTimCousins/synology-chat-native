#if DEBUG
import AppKit
import SwiftUI

@MainActor enum NativeSnippetImportUIFixture {
    static func render(to directory:URL) async -> Bool {
        do {
            NSApplication.shared.setActivationPolicy(.prohibited)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let original = NativeSnippetDraft(filename:"Current.swift",caption:"Keep the project context",content:"// Existing editor text\nlet version = 1\n")
            let imported = NativeSnippetDraft(filename:"Imported.py",content:(1...15).map { "print(\"Imported line \($0)\")" }.joined(separator:"\r\n")+"\r\n")
            let empty = NativeSnippetDraft(caption:original.caption)
            let cases:[(String,ChatAppearanceStyle,Int)] = [("dark-new-review",.dark,0),("light-replace-review",.light,1),("dark-imported-editor",.dark,2),("light-imported-editor",.light,2),("dark-new-composer",.dark,3),("dark-rejected-editor",.dark,4)]
            for (name,style,mode) in cases {
                let temporary = URL(fileURLWithPath:"/private/tmp/native-channel-invitation-fixture.import-render-"+UUID().uuidString,isDirectory:true)
                let (model,_) = try await NativeChannelInvitationUIFixture.makeModel(directory:temporary,unlock:false,configure:{ $0.encrypted = false })
                defer { model.signOutLocally();try? FileManager.default.removeItem(at:temporary) }
                let post = try JSONDecoder().decode(ChatPost.self,from:JSONSerialization.data(withJSONObject:["post_id":1001,"channel_id":23,"creator_id":10,"type":"file","message":original.caption,"create_at":1000,"file_props":["name":original.filename,"size":original.content.utf8.count,"is_snippet":true,"snippet_preview":original.content,"snippet_lines":original.lineCount]]));model.posts = [post]
                let proposal = NativeSnippetImportProposal(original:mode == 0 ? empty : original,imported:imported)
                let next = try proposal.applying(to:proposal.original)
                let editor = try NativeSnippetComposer.renderFixture(model:model,post:post,original:original,draft:mode == 4 ? original : next,uncertain:false,failure:nil,importFailure:mode == 4 ? "Choose valid UTF-8 text, or UTF-16 text with a byte-order mark. Binary files cannot be imported as snippets." : nil)
                let content = Group {
                    if mode < 2 { NativeSnippetImportReview(proposal:proposal,accept:{},cancel:{}) }
                    else if mode == 3 { NativeSnippetComposer.renderNewFixture(model:model,draft:next) }
                    else { editor }
                }.environment(\.nativeChatStyle,style).preferredColorScheme(style.colorScheme)
                let view = NSHostingView(rootView:content);view.appearance = NSAppearance(named:style == .dark ? .darkAqua : .aqua)
                view.frame = NSRect(x:0,y:0,width:mode < 2 ? 640 : 900,height:mode < 2 ? 500 : 710)
                view.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:100_000_000);view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw ChatAPIError.invalidResponse }
                view.cacheDisplay(in:view.bounds,to:bitmap)
                guard let bytes = bitmap.representation(using:.png,properties:[:]) else { throw ChatAPIError.invalidResponse }
                try bytes.write(to:directory.appendingPathComponent(name+".png"),options:.withoutOverwriting)
            }
            return true
        } catch { fputs("Offscreen synthetic snippet import rendering failed.\n",stderr);return false }
    }
}
#endif
