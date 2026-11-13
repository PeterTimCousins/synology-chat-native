import SwiftUI

struct NativePairedDevicesView:View {
    @ObservedObject var model:NativeChatPreviewModel
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot:ChatPairedDevicesSnapshot?
    @State private var selected:ChatPairedDevice?
    @State private var busy = false
    @State private var failure:String?
    @State private var task:Task<Void,Never>?
    @State private var request = UUID()
    @State private var epoch = -1
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack { Text("Paired devices").font(.title2.bold());Spacer();Button("Refresh") { run() }.disabled(busy);Button("Done") { dismiss() }.disabled(busy) }
            Text("Devices registered for Synology Chat notifications. Unpairing stops Chat notifications on that device; pair it again from that device to restore them.").font(.callout).foregroundColor(NativeChatColors.muted).fixedSize(horizontal:false,vertical:true)
            if let snapshot {
                if snapshot.devices.isEmpty { Label("No paired notification devices",systemImage:"iphone.slash").padding(.vertical,24) }
                else {
                    ScrollView {
                        LazyVStack(spacing:12) {
                            ForEach(snapshot.devices) { device in
                                HStack(alignment:.top,spacing:12) {
                                    Image(systemName:"bell").font(.title2).foregroundColor(NativeChatColors.muted)
                                    VStack(alignment:.leading,spacing:5) {
                                        Text(device.device_name.isEmpty ? "Unnamed device" : device.device_name).font(.headline)
                                        Text("System \(device.firmware_version.display) · Chat \(device.app_version.display)").font(.caption).foregroundColor(NativeChatColors.muted)
                                    };Spacer()
                                    Button("Unpair…") { selected = device }.disabled(busy || model.pairedDevicesNeedRefresh).accessibilityLabel("Unpair \(device.device_name.isEmpty ? "unnamed device" : device.device_name)")
                                }.padding(14).background(NativeChatColors.surface).clipShape(RoundedRectangle(cornerRadius:10))
                            }
                        }
                    }.frame(height:min(320,CGFloat(snapshot.devices.count)*78))
                }
            }
            if busy { ProgressView("Checking paired devices…");Button("Stop waiting") { request = UUID();task?.cancel();busy = false;failure = "Stopped waiting. Refresh to check the device list." } }
            if let failure { Text(failure).foregroundColor(.orange).textSelection(.enabled).fixedSize(horizontal:false,vertical:true) }
            if model.pairedDevicesNeedRefresh { Text("Refresh before unpairing another device.").foregroundColor(.orange) }
        }.padding(24).frame(width:600).foregroundColor(NativeChatColors.text).background(NativeChatColors.canvas).nativeChatAppearance().tint(NativeChatColors.green).interactiveDismissDisabled(busy)
            .confirmationDialog("Unpair \(selected?.device_name.isEmpty == false ? selected!.device_name : "this device")?",isPresented:Binding(get:{selected != nil},set:{if !$0 {selected = nil}}),titleVisibility:.visible) {
                Button("Unpair device",role:.destructive) { if let selected { run(device:selected) };selected = nil }
                Button("Cancel",role:.cancel) { selected = nil }
            } message:{ Text("This device will stop receiving Synology Chat notifications. You can register it again from that device.") }
            .onAppear { epoch = model.accountGeneration;model.conversationLibraryVisible = true;run() }
            .onDisappear { task?.cancel();model.conversationLibraryVisible = false }
            .onChange(of:model.accountGeneration) { if $0 != epoch { dismiss() } }
            .onChange(of:model.connected) { if !$0 { dismiss() } }
    }
    private func run(device:ChatPairedDevice? = nil) {
        guard !busy else { return };busy = true;failure = nil;let key = UUID();request = key
        task = Task { @MainActor in
            defer { if request == key { busy = false } }
            do {
                let result:ChatPairedDevicesSnapshot
                if let device,let snapshot { result = try await model.unpairDevice(device,original:snapshot) }
                else { result = try await model.loadPairedDevices() }
                try Task.checkCancellation();guard request == key else { return };snapshot = result
            } catch is CancellationError { }
            catch { if request == key { failure = error.localizedDescription } }
        }
    }
}
