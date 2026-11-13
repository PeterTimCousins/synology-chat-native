import AppKit
import QuickLookUI
import SwiftUI

enum NativeOfficePreviewFormat {
    static let supportedExtensions: Set<String> = ["doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "rtf"]
    static func validate(_ data: Data, filename: String) throws -> String {
        let suffix = (filename as NSString).pathExtension.lowercased()
        guard supportedExtensions.contains(suffix), !data.isEmpty, data.count <= NativeDocumentKind.quickLook.limit else {
            throw ChatTransferError(message: "This document cannot be previewed here. Save the original to open it.")
        }
        let valid: Bool
        if suffix == "rtf" { valid = data.starts(with: Array("{\\rtf".utf8)) }
        else if ["doc", "xls", "ppt"].contains(suffix) { valid = data.starts(with: [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1]) }
        else { valid = data.count >= 22 && data.starts(with: [0x50, 0x4b, 0x03, 0x04]) }
        guard valid else { throw ChatTransferError(message: "This file does not match its document format. Save the original to open it.") }
        return suffix
    }
}

/// Only authenticated, bounded original bytes reach this object. It never gives
/// Quick Look a remote URL, session token or cookie. Encrypted attachments are
/// excluded by the model because system preview caches are outside our control.
@MainActor final class NativeOfficePreview {
    private static let files = NativeMediaTemporaryFiles(purpose: "office-preview", acceptsFilename: {
        $0.hasPrefix("attachment.") && NativeOfficePreviewFormat.supportedExtensions.contains(($0 as NSString).pathExtension.lowercased())
    })
    let file: URL
    let title: String
    private let files: NativeMediaTemporaryFiles
    private var disposed = false
    private let views = NSHashTable<QLPreviewView>.weakObjects()
    private init(file: URL, title: String, files: NativeMediaTemporaryFiles) { self.file = file; self.title = title; self.files = files }

    static func load(_ data: Data, filename: String, files: NativeMediaTemporaryFiles? = nil) throws -> NativeOfficePreview {
        try Task.checkCancellation()
        let suffix = try NativeOfficePreviewFormat.validate(data, filename: filename)
        let store = files ?? Self.files
        let file = try store.create(extension: suffix)
        do {
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            try Task.checkCancellation()
            return .init(file: file, title: String(filename.prefix(512)), files: store)
        } catch { store.remove(file); throw error }
    }

    func attach(_ view: QLPreviewView) {
        guard !disposed else { view.close(); return }
        views.add(view); view.shouldCloseWithWindow = false
        view.previewItem = NativeOfficePreviewItem(url: file, title: title)
    }
    func detach(_ view: QLPreviewView) {
        guard views.contains(view) else { return }
        views.remove(view); view.previewItem = nil; view.close()
    }
    func dispose() {
        guard !disposed else { return }; disposed = true
        for view in views.allObjects { view.previewItem = nil; view.close() }
        views.removeAllObjects(); files.remove(file)
    }
    deinit { files.remove(file) }
}

private final class NativeOfficePreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?
    init(url: URL, title: String) { previewItemURL = url; previewItemTitle = title }
}

struct NativeOfficePreviewView: View {
    let document: NativeOfficePreview
    var body: some View {
        VStack(spacing: 0) {
            NativeOfficePreviewHost(document: document)
            Text("Preview provided by macOS. If this format is unavailable, save the original to open it.")
                .font(.caption).foregroundColor(NativeChatColors.muted).padding(10)
        }
    }
}

private struct NativeOfficePreviewHost: NSViewRepresentable {
    let document: NativeOfficePreview
    func makeNSView(context: Context) -> NativeOfficePreviewContainer { NativeOfficePreviewContainer(document: document) }
    func updateNSView(_ view: NativeOfficePreviewContainer, context: Context) { }
    static func dismantleNSView(_ view: NativeOfficePreviewContainer, coordinator: ()) { view.close() }
}

private final class NativeOfficePreviewContainer: NSView {
    let document: NativeOfficePreview
    private var preview: QLPreviewView?
    init(document: NativeOfficePreview) {
        self.document = document; super.init(frame: .zero)
        if let view = QLPreviewView(frame: bounds, style: .normal) {
            preview = view; view.autoresizingMask = [.width, .height]; addSubview(view)
            document.attach(view); setAccessibilityLabel("Office document preview")
        } else {
            let label = NSTextField(labelWithString: "The document preview is unavailable. Save the original to open it.")
            label.frame = NSRect(x: 20, y: 20, width: 540, height: 24); addSubview(label)
        }
    }
    required init?(coder: NSCoder) { fatalError("Not supported") }
    func close() { if let preview { document.detach(preview) }; preview = nil }
}
