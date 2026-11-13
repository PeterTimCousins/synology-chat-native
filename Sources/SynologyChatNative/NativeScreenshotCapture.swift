import Foundation
import CoreGraphics

/// The system picker owns region/window selection. Capture never reads or changes the clipboard.
enum NativeScreenshotCapture {
    static var hasAccess:Bool {CGPreflightScreenCaptureAccess()}
    static func capture() async throws -> Data? {
        let operation = NativeScreenshotOperation()
        return try await withTaskCancellationHandler(operation:{try await operation.run()},onCancel:{operation.cancel()})
    }
}
private final class NativeScreenshotOperation:@unchecked Sendable {
    private let lock = NSLock()
    private var process:Process?
    private var cancelled = false
    private var finished = false
    func cancel() {
        lock.lock();cancelled = true;let running = process;lock.unlock()
        if running?.isRunning == true {running?.terminate()}
    }
    func run() async throws -> Data? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("native-chat-capture-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let file = folder.appendingPathComponent("capture.png")
        let hadAccess = CGPreflightScreenCaptureAccess()
        return try await withCheckedThrowingContinuation {continuation in
            let child = Process();child.executableURL = URL(fileURLWithPath:"/usr/sbin/screencapture")
            child.arguments = ["-i","-x","-t","png",file.path]
            child.standardOutput = FileHandle.nullDevice;child.standardError = FileHandle.nullDevice
            func complete(_ result:Result<Data?,Error>) {
                self.lock.lock();guard !self.finished else {self.lock.unlock();return};self.finished = true;self.process = nil;let wasCancelled = self.cancelled;self.lock.unlock()
                try? FileManager.default.removeItem(at:folder)
                continuation.resume(with:wasCancelled ? .failure(CancellationError()) : result)
            }
            child.terminationHandler = {process in
                guard process.terminationStatus == 0,FileManager.default.fileExists(atPath:file.path) else {
                    if !hadAccess && !CGPreflightScreenCaptureAccess() {complete(.failure(ChatTransferError(message:"Screen capture needs Screen Recording access. Allow this app in System Settings, then try again.")))} else {complete(.success(nil))};return
                }
                do {
                    let values = try file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
                    guard values.isRegularFile == true,values.isSymbolicLink != true,let size = values.fileSize,size > 0,size <= 128*1024*1024 else {throw ChatTransferError(message:"This screenshot is too large to attach. Capture a smaller area.")}
                    complete(.success(try Data(contentsOf:file)))
                } catch {complete(.failure(error))}
            }
            lock.lock()
            if cancelled {lock.unlock();complete(.failure(CancellationError()));return}
            process = child
            do {try child.run();lock.unlock()}
            catch {lock.unlock();complete(.failure(ChatTransferError(message:"Could not open macOS screenshot selection. Check Screen Recording access in System Settings.")))}
        }
    }
}

import AppKit
import SwiftUI

struct NativeScreenshotReviewImage:View {
    let file:URL
    @State private var image:NSImage?
    @State private var failed = false
    var body:some View {
        ZStack {
            if let image {Image(nsImage:image).resizable().scaledToFit().frame(maxWidth:.infinity,maxHeight:240).accessibilityLabel("Screenshot preview")}
            else if failed {Text("Screenshot preview unavailable. Remove it and capture again.").font(.caption).foregroundColor(.orange)}
            else {ProgressView("Loading screenshot preview…").frame(height:100)}
        }
            .task(id:file) {
                let work = Task.detached(priority:.userInitiated) {()->NSImage? in
                    guard let values = try? file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey]),values.isRegularFile == true,values.isSymbolicLink != true,(values.fileSize ?? Int.max) <= 128*1024*1024,let bytes = try? Data(contentsOf:file,options:.mappedIfSafe) else {return nil}
                    return NativeImagePreview.decode(bytes)
                }
                let result = await withTaskCancellationHandler(operation:{await work.value},onCancel:{work.cancel()})
                guard !Task.isCancelled else {return};image = result;failed = result == nil
            }
    }
}
