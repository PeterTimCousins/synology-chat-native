import AppKit
import ImageIO
import UniformTypeIdentifiers

enum NativeComposerAttachmentInput {
    case none, files([URL]), image(Data, String), items([NativeComposerAttachmentItem]), invalid(String)
}

enum NativeComposerAttachmentItem: Sendable {
    case file(URL), image(Data, String)
}

enum NativeComposerAttachmentReader {
    static let maximumImageBytes = 128 * 1024 * 1024
    static let imageTypes:[(NSPasteboard.PasteboardType,String)] = [(.png,"png"),(.init("public.jpeg"),"jpg"),(.init("com.compuserve.gif"),"gif"),(.tiff,"tiff")]
    static let promiseTypes:[NSPasteboard.PasteboardType] = [.init("com.apple.pasteboard.promised-file-content-type"),.init("com.apple.pasteboard.promised-file-url"),.init("NSFilesPromisePboardType")]
    static var types:[NSPasteboard.PasteboardType] { [.fileURL] + imageTypes.map(\.0) + promiseTypes }
    static func hasAttachment(_ pasteboard:NSPasteboard) -> Bool { pasteboard.availableType(from:types) != nil }
    /// Called only for an explicit paste/drop, never as a background clipboard monitor.
    static func read(_ pasteboard:NSPasteboard) -> NativeComposerAttachmentInput {
        guard hasAttachment(pasteboard) else { return .none }
        do {
            guard let items = pasteboard.pasteboardItems, !items.isEmpty else { throw ChatAPIError.invalidResponse }
            try ChatAttachmentSelection.validateCount(inputCount: items.count, additionCount: 0)
            var imageBytes = 0
            let selection = try items.map { item -> NativeComposerAttachmentItem in
                // A saved image often also advertises raster data. Keep the
                // original file and never stage both representations.
                if item.types.contains(.fileURL) {
                    guard let data = item.data(forType: .fileURL) else { throw ChatAPIError.invalidResponse }
                    return .file(try ChatAttachmentSelection.localReference(data))
                }
                guard let (type, format) = imageTypes.first(where: { item.types.contains($0.0) }),
                      let data = item.data(forType: type), !data.isEmpty,
                      data.count <= maximumImageBytes - imageBytes else {
                    throw ChatTransferError(message: "Every pasted item must be a saved local file or supported image. Clipboard images must total at most 128 MB. No files were added.")
                }
                imageBytes += data.count
                return .image(data, format)
            }
            let files = selection.compactMap { item -> URL? in if case .file(let file) = item { return file }; return nil }
            if files.count == selection.count { return .files(try ChatAttachmentSelection.localFiles(files)) }
            if selection.count == 1, case .image(let data, let format) = selection[0] { return .image(data, format) }
            return .items(selection)
        } catch { return .invalid((error as? LocalizedError)?.errorDescription ?? "Could not read this selection. Save the items locally and attach them instead.") }
    }
    /// Prepare the complete ordered selection before handing ownership to a
    /// review. Failed/cancelled batches delete only images created by this read.
    static func prepare(_ items: [NativeComposerAttachmentItem]) throws -> NativeConversationDropAttachments {
        try ChatAttachmentSelection.validateCount(inputCount: items.count, additionCount: 0)
        guard !items.isEmpty else { throw ChatAPIError.invalidResponse }
        var files: [URL] = [], generated: Set<URL> = [], imageBytes = 0
        do {
            for item in items {
                try Task.checkCancellation()
                switch item {
                case .file(let file):
                    _ = try ChatAttachmentSelection.localReference(Data(file.absoluteString.utf8))
                    files.append(file)
                case .image(let data, let format):
                    guard !data.isEmpty, data.count <= maximumImageBytes - imageBytes else {
                        throw ChatTransferError(message: "Clipboard images must total at most 128 MB. No files were added.")
                    }
                    imageBytes += data.count
                    let file = try writeImage(data, format: format)
                    generated.insert(file); files.append(file)
                }
            }
            let complete = try ChatAttachmentSelection.localFiles(files)
            try ChatAttachmentSelection.requireAvailable(complete)
            try Task.checkCancellation()
            return .init(files: complete, generatedImageFiles: generated)
        } catch {
            for file in generated { removeImage(file) }
            throw error
        }
    }
    static func writeImage(_ data:Data,format:String,basename:String = "Pasted image") throws -> URL {
        try Task.checkCancellation()
        guard ["Pasted image","Screenshot"].contains(basename) else {throw ChatAPIError.invalidResponse}
        guard data.count <= maximumImageBytes,let source = CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,height > 0,width <= 16000,height <= 16000,width <= 32000000 / height else {
            throw ChatTransferError(message:"Could not prepare this image. Save it as a file and attach it instead.")
        }
        let expected:[String:String] = ["png":UTType.png.identifier,"jpg":UTType.jpeg.identifier,"gif":UTType.gif.identifier,"tiff":UTType.tiff.identifier]
        guard expected[format] == type else { throw ChatTransferError(message:"The clipboard image format is not supported.") }
        if basename == "Screenshot",NativeImagePreview.decode(data) == nil {throw ChatTransferError(message:"Could not read the captured image. Capture it again before sending.")}
        let output:Data
        let ext:String
        if format == "tiff" {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:max(width,height),kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else { throw ChatAPIError.invalidResponse }
            let encoded = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(encoded,UTType.png.identifier as CFString,1,nil) else { throw ChatAPIError.invalidResponse }
            CGImageDestinationAddImage(destination,image,nil)
            guard CGImageDestinationFinalize(destination) else { throw ChatAPIError.invalidResponse }
            output = encoded as Data;ext = "png"
        } else { output = data;ext = format }
        try Task.checkCancellation()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("native-chat-paste-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let file = folder.appendingPathComponent(basename+"."+ext)
        do {
            guard FileManager.default.createFile(atPath:file.path,contents:output,attributes:[.posixPermissions:0o600]) else { throw ChatAPIError.invalidResponse }
            try Task.checkCancellation();return file
        } catch { try? FileManager.default.removeItem(at:folder);throw error }
    }
    static func removeImage(_ file:URL) {
        let folder = file.deletingLastPathComponent()
        guard file.isFileURL,folder.lastPathComponent.hasPrefix("native-chat-paste-"),(file.lastPathComponent.hasPrefix("Pasted image.") || file.lastPathComponent == "Screenshot.png") else { return }
        try? FileManager.default.removeItem(at:folder)
    }
}
