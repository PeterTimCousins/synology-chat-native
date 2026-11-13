import Foundation

/// Shared local-reference and batch-size rules for picker, paste and drag input.
/// Availability is checked again immediately before upload because files can
/// disappear or change after the user reviews them.
enum ChatAttachmentSelection {
    static let maximumFiles = 100
    static let maximumReferenceBytes = 16_384
    static func localReference(_ data:Data) throws -> URL {
        guard !data.isEmpty,data.count <= maximumReferenceBytes,let text = String(data:data,encoding:.utf8),!text.contains("\0"),!text.lowercased().contains("%00"),
              let file = URL(string:text),file.isFileURL,file.path.hasPrefix("/"),!file.path.contains("\0"),
              file.host == nil || file.host == "" || file.host?.lowercased() == "localhost",
              file.user == nil,file.password == nil,file.port == nil,file.query == nil,file.fragment == nil else {
            throw ChatTransferError(message:"Choose saved local files. Web links and promised files are not attachments.")
        }
        return file
    }
    static func validateCount(inputCount:Int,additionCount:Int,existingCount:Int = 0) throws {
        guard inputCount >= 0,inputCount <= maximumFiles,additionCount >= 0,
              existingCount >= 0,existingCount <= maximumFiles,additionCount <= maximumFiles-existingCount else {
            throw ChatTransferError(message:"Review up to 100 files at once, including files already in this review. No files were added.")
        }
    }
    static func localFiles(_ files:[URL],existing:[URL] = [],existingCount:Int = 0) throws -> [URL] {
        try validateCount(inputCount:files.count,additionCount:0,existingCount:existingCount)
        // Validate every reference before deduplication; never keep only a valid prefix.
        for file in files { _ = try localReference(Data(file.absoluteString.utf8)) }
        var known = Set(existing.map(\.standardizedFileURL))
        let additions = files.filter { known.insert($0.standardizedFileURL).inserted }
        try validateCount(inputCount:files.count,additionCount:additions.count,existingCount:existingCount)
        return additions
    }
    static func requireAvailable(_ files:[URL]) throws {
        for file in files {
            try Task.checkCancellation()
            guard let values = try? file.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.isReadableKey]),
                  values.isRegularFile == true,values.isSymbolicLink != true,values.isReadable == true else {
                throw ChatTransferError(message:"A selected file is unavailable or unreadable. Choose saved files rather than folders or shortcuts.")
            }
        }
    }
}

/// This error can only be produced before a Post/create upload is handed to
/// URLSession. It must never classify an unknown post-dispatch outcome as safe.
struct ChatAttachmentPreflightFailure:LocalizedError {
    let message:String
    init(_ error:Error) {
        let detail = error is CancellationError ? "Attachment preparation stopped." :
            (error as? LocalizedError)?.errorDescription ?? "Could not prepare this attachment."
        message = detail + " This file was not sent."
    }
    var errorDescription:String? { message }
}
