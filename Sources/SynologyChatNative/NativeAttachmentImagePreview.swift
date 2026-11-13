import AppKit
import Darwin
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Local review only. Never contacts a server or rewrites the selected original.
enum NativeAttachmentImageLoader {
    static let maximumBytes = 32 * 1024 * 1024
    static func supports(_ file:URL) -> Bool {
        file.isFileURL && UTType(filenameExtension:file.pathExtension)?.conforms(to:.image) == true
    }
    static func load(_ file:URL) -> CGImage? {
        guard supports(file),!Task.isCancelled else { return nil }
        // A selected path may change while review is open. Do not follow a new
        // symlink, block on a pipe, or read an unbounded replacement file.
        let fd = Darwin.open(file.path,O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd,&info) == 0,(info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0,info.st_size <= maximumBytes,
              let data = try? handle.read(upToCount:maximumBytes+1),!data.isEmpty,data.count <= maximumBytes,
              !Task.isCancelled,
              let source = CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
              let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }),type.conforms(to:.image),
              let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,height > 0,width <= 16000,height <= 16000,width <= 32000000 / height else { return nil }
        let image = CGImageSourceCreateThumbnailAtIndex(source,0,[
            kCGImageSourceCreateThumbnailFromImageAlways:true,
            kCGImageSourceCreateThumbnailWithTransform:true,
            kCGImageSourceThumbnailMaxPixelSize:640,
            kCGImageSourceShouldCacheImmediately:true
        ] as CFDictionary)
        return Task.isCancelled ? nil : image
    }
}

struct NativeAttachmentImagePreview:View {
    let file:URL
    var maximumHeight:CGFloat = 180
    var onRefresh:()->Void = {}
    @State private var image:CGImage?
    @State private var failed = false
    @State private var revision = UUID()
    var body:some View {
        Group {
            if let image {
                Image(image,scale:1,label:Text("Attachment preview: " + file.lastPathComponent)).resizable().scaledToFit().frame(maxWidth:.infinity,maxHeight:maximumHeight)
                    .accessibilityLabel("Attachment preview: " + file.lastPathComponent)
            } else if failed {
                HStack {
                    Text("Image preview unavailable. You can still attach the original file.").font(.caption).foregroundColor(NativeChatColors.muted)
                    Button("Retry preview") { onRefresh();revision = UUID() }
                }
            } else { ProgressView("Loading image preview…").frame(maxWidth:.infinity,minHeight:80) }
        }
        .frame(maxWidth:.infinity)
        .frame(height:maximumHeight)
        .background(NativeChatColors.canvas.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius:8))
        .task(id:revision) {
            image = nil;failed = false
            let work = Task.detached(priority:.utility) { NativeAttachmentImageLoader.load(file) }
            let result = await withTaskCancellationHandler(operation:{await work.value},onCancel:{work.cancel()})
            guard !Task.isCancelled else { return }
            image = result;failed = result == nil
        }
        .id(file)
    }
}
