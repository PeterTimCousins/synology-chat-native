import AppKit
import SwiftUI

enum ChatMessageLinkPresentation {
    static func isLINE(_ destination:URL)->Bool { ChatMessageLinks.applicationURL(destination.absoluteString) != nil }
    static func title(_ destination:URL?)->String { destination.map(isLINE) == true ? "Open LINE?" : "Open a flagged link?" }
    static func action(_ destination:URL,websiteAction:String = "Open website")->String { isLINE(destination) ? "Open LINE" : websiteAction }
    static func message(_ destination:URL,flagged:Bool)->String {
        if isLINE(destination) {
            return "This link will open LINE on this Mac." + (flagged ? " Synology also marked this message’s links as unsafe." : "") + "\n\nDestination: " + destination.absoluteString
        }
        return "Synology marked a link in this message as unsafe. Destination: " + (destination.host ?? "")
    }
}

@MainActor final class NativeMessageWebsiteOpening:ObservableObject {
    @Published var pending:ChatMessageLinkReview?
    @Published private(set) var busy = false
    @Published private(set) var error:String?
    private var task:Task<Void,Never>?
    private var request = UUID()
    private var destinationAction:((URL)->Bool)?
    func clear() { request = UUID();task?.cancel();task = nil;pending = nil;busy = false;error = nil;destinationAction = nil }
    func begin(model:NativeChatPreviewModel,post:ChatPost,destination:URL,source:ChatMessageLinkSource,
               open:@escaping(URL)->Bool = { NSWorkspace.shared.open($0) }) {
        guard !busy else { return }
        pending = nil;error = nil;destinationAction = open
        do { perform(try model.messageLinkIntent(post,destination:destination,source:source),model:model,confirmed:false) }
        catch { self.error = error.localizedDescription }
    }
    func confirm(_ review:ChatMessageLinkReview,model:NativeChatPreviewModel) {
        guard !busy else { return };pending = nil;perform(review,model:model,confirmed:true)
    }
    private func perform(_ review:ChatMessageLinkReview,model:NativeChatPreviewModel,confirmed:Bool) {
        request = UUID();let key = request;busy = true;error = nil
        let action = destinationAction ?? { NSWorkspace.shared.open($0) }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if request == key { busy = false;task = nil } }
            do {
                let result = try await model.openMessageLink(review,allowUnsafe:confirmed,open:{ destination in
                    guard request == key,!Task.isCancelled else { return false }
                    return action(destination)
                })
                try Task.checkCancellation();guard request == key else { return }
                if case .confirmation(let review) = result { pending = review }
            } catch is CancellationError { }
            catch { if request == key { self.error = error.localizedDescription } }
        }
    }
}

struct NativeMessageWebsiteFeedback:View {
    @ObservedObject var opening:NativeMessageWebsiteOpening
    @ObservedObject var model:NativeChatPreviewModel
    var confirmationAction = "Open website"
    var body:some View {
        VStack(alignment:.leading,spacing:4) {
            if opening.busy { ProgressView("Checking link…").controlSize(.small) }
            if let error = opening.error { Text(error).font(.caption).foregroundColor(.orange).fixedSize(horizontal:false,vertical:true) }
        }.padding(.top,opening.busy || opening.error != nil ? 8 : 0)
        .alert(ChatMessageLinkPresentation.title(opening.pending?.destination),isPresented:Binding(get:{ opening.pending != nil },set:{ if !$0 { opening.pending = nil } }),presenting:opening.pending) { review in
            Button("Cancel",role:.cancel) { opening.pending = nil }
            Button(ChatMessageLinkPresentation.action(review.destination,websiteAction:confirmationAction)) { opening.confirm(review,model:model) }
        } message: { review in Text(ChatMessageLinkPresentation.message(review.destination,flagged:review.flaggedByServer)) }
            .onDisappear { opening.clear() }
            .onChange(of:model.connected) { if !$0 { opening.clear() } }
            .onChange(of:model.accountGeneration) { _ in opening.clear() }
            .onChange(of:model.encryptionUnlocked) { _ in opening.clear() }
    }
}
