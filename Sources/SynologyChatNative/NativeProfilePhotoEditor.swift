import SwiftUI
import UniformTypeIdentifiers

struct NativeProfilePhotoEditor:View {
    @ObservedObject var model:NativeChatPreviewModel
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot:ChatProfilePhotoSnapshot?
    @State private var candidate:CGImage?
    @State private var rendered:Data?
    @State private var zoom = 1.0
    @State private var x = 0.5
    @State private var y = 0.5
    @State private var busy = false
    @State private var failure:String?
    @State private var task:Task<Void,Never>?
    @State private var request = UUID()
    @State private var epoch = -1
    @State private var choose = false
    @State private var confirmRemove = false
    @State private var confirmDiscard = false
    private var allowed:Bool { snapshot?.profile.policy.allows("avatar") == true && !model.profileEditingNeedsRefresh }
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                Text("Profile photo").font(.title2.bold());Spacer()
                Button("Refresh") { if candidate != nil { confirmDiscard = true } else { run() } }.disabled(busy)
                Button("Done") { if candidate != nil { confirmDiscard = true } else { dismiss() } }.disabled(busy)
            }
            HStack(alignment:.top,spacing:24) {
                Group {
                    if let data = rendered ?? snapshot?.image,let image = NSImage(data:data) { Image(nsImage:image).resizable().interpolation(.high).scaledToFit() }
                    else { Image(systemName:"person.crop.square.fill").resizable().scaledToFit().foregroundColor(NativeChatColors.muted) }
                }.frame(width:180,height:180).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:12)).accessibilityLabel(candidate == nil ? "Current server profile photo" : "Cropped photo preview")
                VStack(alignment:.leading,spacing:12) {
                    Text(candidate == nil ? "Your photo is visible to people in Synology Chat." : "Adjust the square crop, then save. Your original file stays on your Mac.").fixedSize(horizontal:false,vertical:true)
                    Button("Choose photo…") { choose = true }.disabled(busy || !allowed)
                    if candidate != nil {
                        Button("Discard selected photo") { candidate = nil;rendered = nil;failure = nil }.disabled(busy)
                    } else {
                        Button("Remove photo…") { confirmRemove = true }.disabled(busy || !allowed || snapshot?.profile.avatarVersion == 0)
                    }
                }.font(.callout)
            }
            if candidate != nil {
                cropSlider("Zoom",value:$zoom,range:1...4)
                cropSlider("Horizontal position",value:$x,range:0...1)
                cropSlider("Vertical position",value:$y,range:0...1)
                Text("Only the cropped image is uploaded; source photo metadata is excluded.").font(.caption).foregroundColor(NativeChatColors.muted)
                HStack { Spacer();Button("Save photo") { run(save:true) }.disabled(busy || !allowed || rendered == nil) }
            }
            if let snapshot,!snapshot.profile.policy.allows("avatar") { Text("Your administrator manages your profile photo.").foregroundColor(NativeChatColors.muted) }
            if busy { ProgressView("Checking profile photo…");Button("Stop waiting") { request = UUID();task?.cancel();busy = false;failure = "Stopped waiting. Refresh to check the server photo before continuing." } }
            if let failure { Text(failure).foregroundColor(.orange).textSelection(.enabled).fixedSize(horizontal:false,vertical:true) }
            if model.profileEditingNeedsRefresh { Text("Refresh before changing your photo again.").foregroundColor(.orange) }
        }.padding(24).frame(width:550).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance().tint(NativeChatColors.green)
            .interactiveDismissDisabled(busy || candidate != nil)
            .fileImporter(isPresented:$choose,allowedContentTypes:[.image]) { result in
                do { let image = try NativeProfilePhoto.load(result.get());candidate = image;zoom = 1;x = 0.5;y = 0.5;renderCrop();failure = nil }
                catch { failure = error.localizedDescription }
            }
            .confirmationDialog("Remove your Synology Chat profile photo?",isPresented:$confirmRemove,titleVisibility:.visible) { Button("Remove photo",role:.destructive) { run(remove:true) };Button("Cancel",role:.cancel) { } }
            .confirmationDialog("Discard this selected photo?",isPresented:$confirmDiscard,titleVisibility:.visible) { Button("Discard and refresh",role:.destructive) { candidate = nil;rendered = nil;run() };Button("Discard and close",role:.destructive) { dismiss() };Button("Keep editing",role:.cancel) { } }
            .onChange(of:zoom) { _ in renderCrop() }.onChange(of:x) { _ in renderCrop() }.onChange(of:y) { _ in renderCrop() }
            .onAppear { epoch = model.accountGeneration;model.conversationLibraryVisible = true;run() }
            .onDisappear { task?.cancel();model.conversationLibraryVisible = false }
            .onChange(of:model.accountGeneration) { if $0 != epoch { dismiss() } }
            .onChange(of:model.connected) { if !$0 { dismiss() } }
    }
    private func cropSlider(_ label:String,value:Binding<Double>,range:ClosedRange<Double>)->some View {
        HStack { Text(label).font(.caption).frame(width:130,alignment:.leading);Slider(value:value,in:range).accessibilityLabel(label).disabled(busy) }
    }
    private func renderCrop() {
        guard let candidate else { return }
        do { rendered = try NativeProfilePhoto.render(candidate,zoom:zoom,x:x,y:y) }
        catch { rendered = nil;failure = error.localizedDescription }
    }
    private func run(save:Bool = false,remove:Bool = false) {
        guard !busy else { return };busy = true;failure = nil;let key = UUID();request = key;let image = rendered
        task = Task { @MainActor in
            defer { if request == key { busy = false } }
            do {
                let result:ChatProfilePhotoSnapshot
                if (save || remove),let snapshot { result = try await model.saveProfilePhoto(remove ? nil : image,original:snapshot.profile) }
                else { result = try await model.loadEditableProfilePhoto() }
                try Task.checkCancellation();guard request == key else { return };snapshot = result;candidate = nil;rendered = nil
            } catch is CancellationError { }
            catch { if request == key { failure = error.localizedDescription } }
        }
    }
}
