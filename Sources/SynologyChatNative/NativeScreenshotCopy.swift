import Foundation

enum NativeScreenshotCopy {
    static func stage(_ source:URL,to destination:URL)throws->URL {
        try Task.checkCancellation()
        guard source.isFileURL,destination.isFileURL,source.resolvingSymlinksInPath() != destination.resolvingSymlinksInPath() else {throw ChatTransferError(message:"Choose a different location for the screenshot copy.")}
        let values = try source.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        guard values.isRegularFile == true,values.isSymbolicLink != true,let size = values.fileSize,size > 0,size <= 128*1024*1024 else {throw ChatTransferError(message:"This screenshot is no longer available. Capture it again.")}
        try checkDestination(destination)
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".native-chat-screenshot-save-"+UUID().uuidString+".png")
        do {try FileManager.default.copyItem(at:source,to:staged);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:staged.path);try Task.checkCancellation();return staged}
        catch {try? FileManager.default.removeItem(at:staged);throw error}
    }
    static func commit(_ staged:URL,to destination:URL)throws {
        try Task.checkCancellation();try checkDestination(destination)
        if FileManager.default.fileExists(atPath:destination.path) {_ = try FileManager.default.replaceItemAt(destination,withItemAt:staged)}
        else {try FileManager.default.moveItem(at:staged,to:destination)}
    }
    private static func checkDestination(_ destination:URL)throws {
        if let attrs = try? FileManager.default.attributesOfItem(atPath:destination.path),attrs[.type] as? FileAttributeType != .typeRegular {throw ChatTransferError(message:"Choose a regular file location for the screenshot copy.")}
    }
}
