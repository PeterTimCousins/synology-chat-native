import SwiftUI

struct NativeSnippetImportReview:View {
    let proposal:NativeSnippetImportProposal
    let accept:()->Void
    let cancel:()->Void
    private var preview:String { NativeSnippetDraft.preview(proposal.imported.content) }
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            Label("Import text file",systemImage:"doc.text").font(.title2.bold())
            Text(proposal.imported.filename).font(.headline).lineLimit(2).truncationMode(.middle)
            Text("\(proposal.imported.lineCount) lines · \(proposal.imported.content.utf8.count.formatted()) bytes · \(NativeSnippetLanguage.forFilename(proposal.imported.filename).title)").font(.caption).foregroundColor(NativeChatColors.muted)
            NativeCodeEditor(text:.constant(preview),filename:proposal.imported.filename,editable:false,label:"Imported snippet preview").frame(minHeight:180,maxHeight:.infinity)
                .clipShape(RoundedRectangle(cornerRadius:8))
            if proposal.imported.lineCount > 12 { Text("Showing the first 12 lines. The full text will be available in the editor.").font(.caption).foregroundColor(NativeChatColors.muted) }
            Text(proposal.replacesCurrentCode ? "This replaces the current filename and code. Your description is kept. Nothing is sent until you choose Send or Save in the editor." : "This fills in the filename and code. Your description is kept. Nothing is sent until you choose Send in the editor.")
                .font(.callout).foregroundColor(NativeChatColors.muted).fixedSize(horizontal:false,vertical:true)
            HStack { Spacer();Button("Cancel",action:cancel).keyboardShortcut(.cancelAction);Button("Use this file",action:accept).buttonStyle(NativeSendButtonStyle()).keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width:640,height:500).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance()
    }
}
