import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

struct NativeConversationDropAttachments {
    let files: [URL]
    let generatedImageFiles: Set<URL>
}

/// Explicit saved-file or raster drops. Never fetches remote URLs or sends files.
enum NativeConversationFileDropReader {
    static let maximumFiles = ChatAttachmentSelection.maximumFiles
    /// Inspect only advertised types during hover. Do not invoke data providers
    /// until the user actually drops, and never silently discard a bad item.
    @MainActor static func hasFileReferences(_ pasteboard:NSPasteboard)->Bool {
        guard let items = pasteboard.pasteboardItems,!items.isEmpty,items.count <= maximumFiles else { return false }
        return items.allSatisfy { $0.types.contains(.fileURL) }
    }
    @MainActor static func providers(from pasteboard:NSPasteboard)->[NSItemProvider]? {
        guard hasFileReferences(pasteboard),let items = pasteboard.pasteboardItems else { return nil }
        var providers:[NSItemProvider] = []
        for item in items {
            guard let data = item.data(forType:.fileURL),!data.isEmpty,data.count <= ChatAttachmentSelection.maximumReferenceBytes else { return nil }
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier:UTType.fileURL.identifier,visibility:.all) { callback in
                callback(data,nil);return nil
            }
            providers.append(provider)
        }
        return providers
    }
    static var attachmentTypes: [NSPasteboard.PasteboardType] { [.fileURL] + NativeComposerAttachmentReader.imageTypes.map(\.0) }
    static var attachmentIdentifiers: [String] { attachmentTypes.map(\.rawValue) }
    @MainActor static func hasAttachments(_ pasteboard: NSPasteboard) -> Bool {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty, items.count <= maximumFiles else { return false }
        return items.allSatisfy { item in attachmentTypes.contains { item.types.contains($0) } }
    }
    @MainActor static func attachmentProviders(from pasteboard: NSPasteboard, maximumImageBytes: Int = NativeComposerAttachmentReader.maximumImageBytes) -> [NSItemProvider]? {
        guard maximumImageBytes >= 0, maximumImageBytes <= NativeComposerAttachmentReader.maximumImageBytes,
              hasAttachments(pasteboard), let items = pasteboard.pasteboardItems else { return nil }
        var providers: [NSItemProvider] = []
        var imageBytes = 0
        for item in items {
            guard let type = attachmentTypes.first(where: { item.types.contains($0) }),
                  let data = item.data(forType: type), !data.isEmpty,
                  data.count <= (type == .fileURL ? ChatAttachmentSelection.maximumReferenceBytes : maximumImageBytes - imageBytes) else { return nil }
            // File URLs reference existing streamed files. Only materialized
            // raster representations consume the whole-batch memory budget.
            if type != .fileURL { imageBytes += data.count }
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: type.rawValue, visibility: .all) { callback in
                callback(data, nil); return nil
            }
            providers.append(provider)
        }
        return providers
    }
    /// Successful return transfers generated-file ownership to the caller.
    @MainActor static func readAttachments(_ providers: [NSItemProvider], timeoutNanoseconds: UInt64 = 15_000_000_000, maximumImageBytes: Int = NativeComposerAttachmentReader.maximumImageBytes) async throws -> NativeConversationDropAttachments {
        guard maximumImageBytes >= 0, maximumImageBytes <= NativeComposerAttachmentReader.maximumImageBytes,
              !providers.isEmpty, providers.count <= maximumFiles else { throw ChatTransferError(message: "Drop up to 100 saved local files or images at once.") }
        let selected = try providers.map { provider -> (NSItemProvider, String, String?) in
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) { return (provider, UTType.fileURL.identifier, nil) }
            guard let image = NativeComposerAttachmentReader.imageTypes.first(where: { provider.hasItemConformingToTypeIdentifier($0.0.rawValue) }) else {
                throw ChatTransferError(message: "Every dropped item must be a saved local file or supported image. No files were added.")
            }
            return (provider, image.0.rawValue, image.1)
        }
        var files: [URL] = [], generated: Set<URL> = [], imageBytes = 0
        do {
            for (provider, identifier, format) in selected {
                try Task.checkCancellation()
                if let format {
                    let data = try await loadData(provider, identifier: identifier, timeoutNanoseconds: timeoutNanoseconds)
                    guard !data.isEmpty, data.count <= maximumImageBytes - imageBytes else { throw ChatTransferError(message: "Dropped images must total at most 128 MB. No files were added.") }
                    imageBytes += data.count
                    let worker = Task.detached(priority: .userInitiated) { try NativeComposerAttachmentReader.writeImage(data, format: format) }
                    let file = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                    generated.insert(file); files.append(file)
                } else {
                    files.append(contentsOf: try await read([provider], timeoutNanoseconds: timeoutNanoseconds))
                }
            }
            let complete = try ChatAttachmentSelection.localFiles(files)
            let worker = Task.detached(priority: .userInitiated) { try ChatAttachmentSelection.requireAvailable(complete) }
            try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            try Task.checkCancellation()
            return .init(files: complete, generatedImageFiles: generated)
        } catch {
            for file in generated { NativeComposerAttachmentReader.removeImage(file) }
            throw error
        }
    }
    @MainActor private static func loadData(_ provider: NSItemProvider, identifier: String, timeoutNanoseconds: UInt64) async throws -> Data {
        let request = NativeFileDropRequest()
        let timeout = Task {
            do { try await Task.sleep(nanoseconds: timeoutNanoseconds) } catch { return }
            request.finish(.failure(ChatTransferError(message: "The dropped image took too long to load. Try again.")))
        }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard request.install(continuation) else { return }
                request.setProgress(provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, error in
                    if let error { request.finish(.failure(error)) }
                    else if let data { request.finish(.success(data)) }
                    else { request.finish(.failure(ChatAPIError.invalidResponse)) }
                })
            }
        }, onCancel: { request.finish(.failure(CancellationError())) })
    }
    #if DEBUG
    @MainActor static func trace(_ message:String) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("native-file-drop-trace-"+String(ProcessInfo.processInfo.processIdentifier)+".txt")
        if !FileManager.default.fileExists(atPath:file.path) { FileManager.default.createFile(atPath:file.path,contents:Data(),attributes:[.posixPermissions:0o600]) }
        guard let handle = try? FileHandle(forWritingTo:file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd();try? handle.write(contentsOf:Data((message+"\n").utf8))
    }
    #endif
    @MainActor static func read(_ providers:[NSItemProvider],timeoutNanoseconds:UInt64 = 15_000_000_000) async throws -> [URL] {
        guard !providers.isEmpty,providers.count <= maximumFiles,
              providers.allSatisfy({$0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)}) else {
            throw ChatTransferError(message:"Drop up to 100 saved local files at once.")
        }
        var files:[URL] = [],known = Set<URL>()
        for provider in providers {
            try Task.checkCancellation()
            let request = NativeFileDropRequest()
            let timeout = Task {
                do { try await Task.sleep(nanoseconds:timeoutNanoseconds) } catch { return }
                request.finish(.failure(ChatTransferError(message:"The dropped files took too long to load. Try again.")))
            }
            let data:Data
            do {
                defer { timeout.cancel() }
                data = try await withTaskCancellationHandler(operation:{
                    try Task.checkCancellation()
                    return try await withCheckedThrowingContinuation { continuation in
                        guard request.install(continuation) else { return }
                        request.setProgress(provider.loadDataRepresentation(forTypeIdentifier:UTType.fileURL.identifier) { data,error in
                            if let error { request.finish(.failure(error)) }
                            else if let data { request.finish(.success(data)) }
                            else { request.finish(.failure(ChatAPIError.invalidResponse)) }
                        })
                    }
                },onCancel:{request.finish(.failure(CancellationError()))})
            }
            let file = try ChatAttachmentSelection.localReference(data)
            if known.insert(file.standardizedFileURL).inserted { files.append(file) }
        }
        let selectedFiles = try ChatAttachmentSelection.localFiles(files)
        let work = Task.detached(priority:.userInitiated) { () throws -> [URL] in
            try ChatAttachmentSelection.requireAvailable(selectedFiles)
            return selectedFiles
        }
        let result = try await withTaskCancellationHandler(operation:{try await work.value},onCancel:{work.cancel()})
        try Task.checkCancellation();return result
    }
}

/// Providers may complete after cancellation or invoke their completion more than
/// once. Resolve the continuation exactly once and cancel the owned Progress.
final class NativeFileDropRequest:@unchecked Sendable {
    private let lock = NSLock()
    private var continuation:CheckedContinuation<Data,Error>?
    private var result:Result<Data,Error>?
    private var progress:Progress?
    func install(_ continuation:CheckedContinuation<Data,Error>) -> Bool {
        lock.lock()
        if let result { lock.unlock();continuation.resume(with:result);return false }
        self.continuation = continuation;lock.unlock();return true
    }
    func setProgress(_ progress:Progress) {
        lock.lock();let settled = result
        if settled == nil { self.progress = progress };lock.unlock()
        if let settled,case .failure = settled { progress.cancel() }
    }
    func finish(_ value:Result<Data,Error>) {
        lock.lock();guard result == nil else { lock.unlock();return }
        result = value;let continuation = continuation,progress = progress
        self.continuation = nil;self.progress = nil;lock.unlock()
        if case .failure = value { progress?.cancel() }
        continuation?.resume(with:value)
    }
}

@MainActor private struct NativeConversationDropDelegate:DropDelegate {
    let model:NativeChatPreviewModel
    let inThread:Bool
    @Binding var targeted:Bool
    func validateDrop(info:DropInfo) -> Bool {
        let eligible = model.canReceiveConversationFileDrop(inThread:inThread),hasFiles = info.hasItemsConforming(to:NativeConversationFileDropReader.attachmentIdentifiers)
        #if DEBUG
        NativeConversationFileDropReader.trace("validate thread=\(inThread) eligible=\(eligible) files=\(hasFiles)")
        Logger(subsystem:"com.costwisegroup.synology-chat-native.api-preview",category:"native-file-drop").info("Drop validation thread=\(inThread,privacy:.public) eligible=\(eligible,privacy:.public) files=\(hasFiles,privacy:.public)")
        #endif
        return eligible && hasFiles
    }
    func dropEntered(info:DropInfo) {
        targeted = validateDrop(info:info)
    }
    func dropExited(info:DropInfo) { targeted = false }
    func dropUpdated(info:DropInfo) -> DropProposal? {
        targeted = validateDrop(info:info);return DropProposal(operation:targeted ? .copy : .forbidden)
    }
    func performDrop(info:DropInfo) -> Bool {
        targeted = false
        #if DEBUG
        NativeConversationFileDropReader.trace("perform thread=\(inThread)")
        #endif
        let accepted = model.receiveConversationFileDrop(info.itemProviders(for:[UTType.item.identifier]),inThread:inThread)
        #if DEBUG
        model.conversationFileDropDiagnostic = (inThread ? "Thread" : "Main") + " accepted: " + String(accepted)
        #endif
        return accepted
    }
}

private struct NativeConversationDropModifier:ViewModifier {
    @ObservedObject var model:NativeChatPreviewModel
    let inThread:Bool
    @State private var targeted = false
    func body(content:Content) -> some View {
        content.overlay {
            if targeted && model.canReceiveConversationFileDrop(inThread:inThread) {
                ZStack {
                    RoundedRectangle(cornerRadius:12).fill(NativeChatColors.canvas.opacity(0.94))
                    RoundedRectangle(cornerRadius:12).stroke(NativeChatColors.green,style:StrokeStyle(lineWidth:2,dash:[8,5]))
                    VStack(spacing:12) {
                        Image(systemName:"tray.and.arrow.down").font(.system(size:32))
                        Text(inThread ? "Drop files into this thread" : "Drop files into this conversation").font(.headline)
                        Text("Review files and captions before sending.").font(.callout).foregroundColor(NativeChatColors.muted)
                    }.foregroundColor(NativeChatColors.green).padding(24)
                }.padding(12).allowsHitTesting(false).accessibilityLabel("Drop files to review before sending")
            }
        }
        .onDrop(of:NativeConversationFileDropReader.attachmentIdentifiers,delegate:NativeConversationDropDelegate(model:model,inThread:inThread,targeted:$targeted))
        .onChange(of:model.selection) { _ in targeted = false }
        .onChange(of:model.connected) { _ in targeted = false }
    }
}
extension View {
    func nativeConversationFileDrop(model:NativeChatPreviewModel,inThread:Bool = false) -> some View {
        modifier(NativeConversationDropModifier(model:model,inThread:inThread))
    }
}
