import Foundation
import Darwin
import Combine

/// Local text import only. Never rewrites the selected file or contacts a server.
enum NativeSnippetFileReader {
    static func load(_ file:URL) throws -> NativeSnippetDraft {
        try Task.checkCancellation()
        guard file.isFileURL,(file.host == nil || file.host == "" || file.host == "localhost"),!file.path.contains("\0") else { throw ChatTransferError(message:"Choose a local text file.") }
        let scoped = file.startAccessingSecurityScopedResource();defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        let fd = Darwin.open(file.path,O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ChatTransferError(message:"The selected file could not be opened. Choose a regular text file.") }
        let handle = FileHandle(fileDescriptor:fd,closeOnDealloc:true);defer { try? handle.close() }
        var before = stat()
        guard fstat(fd,&before) == 0,(before.st_mode & S_IFMT) == S_IFREG else { throw ChatTransferError(message:"Choose a regular text file, rather than a folder, link or pipe.") }
        guard before.st_size > 0,before.st_size <= NativeSnippetDraft.maximumBytes else { throw ChatTransferError(message:"Choose a nonempty text file up to1MiB.") }
        var bytes = Data()
        while bytes.count <= NativeSnippetDraft.maximumBytes {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount:min(65536,NativeSnippetDraft.maximumBytes+1-bytes.count)) ?? Data()
            if chunk.isEmpty { break };bytes.append(chunk)
        }
        var after = stat()
        guard fstat(fd,&after) == 0,before.st_dev == after.st_dev,before.st_ino == after.st_ino,before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              bytes.count == Int(before.st_size),bytes.count <= NativeSnippetDraft.maximumBytes else { throw ChatTransferError(message:"The file changed or could not be read completely. Choose it again.") }
        try Task.checkCancellation()
        let text:String?
        if bytes.starts(with:[0xff,0xfe]) { text = String(data:bytes.dropFirst(2),encoding:.utf16LittleEndian) }
        else if bytes.starts(with:[0xfe,0xff]) { text = String(data:bytes.dropFirst(2),encoding:.utf16BigEndian) }
        else { text = String(data:bytes.starts(with:[0xef,0xbb,0xbf]) ? bytes.dropFirst(3) : bytes,encoding:.utf8) }
        guard let text,!text.contains("\0") else { throw ChatTransferError(message:"Choose valid UTF-8 text, or UTF-16 text with a byte-order mark. Binary files cannot be imported as snippets.") }
        let draft = try NativeSnippetDraft(filename:file.lastPathComponent,content:text).validated()
        try Task.checkCancellation();return draft
    }
    static func read(_ file:URL) async throws -> NativeSnippetDraft {
        let work = Task.detached(priority:.userInitiated) { try load(file) }
        return try await withTaskCancellationHandler(operation:{ try await work.value },onCancel:{ work.cancel() })
    }
}

struct NativeSnippetImportProposal:Identifiable {
    let id = UUID()
    let original:NativeSnippetDraft
    let imported:NativeSnippetDraft
    var replacesCurrentCode:Bool { !original.content.isEmpty || original.filename != NativeSnippetDraft().filename }
    func applying(to current:NativeSnippetDraft) throws -> NativeSnippetDraft {
        guard current.hasSameBytes(as:original) else { throw ChatTransferError(message:"The snippet changed while the file was being reviewed. Import it again; your current draft is unchanged.") }
        let imported = try imported.validated()
        var result = current;result.filename = imported.filename;result.content = imported.content;return result
    }
}

@MainActor final class NativeSnippetImportController:ObservableObject {
    typealias Reader = @Sendable (URL) async throws -> NativeSnippetDraft
    @Published private(set) var busy = false
    @Published private(set) var pending:NativeSnippetImportProposal?
    @Published private(set) var failure:String?
    private let read:Reader
    private var request = UUID()
    private var task:Task<Void,Never>?
    init(read:@escaping Reader = { try await NativeSnippetFileReader.read($0) }) { self.read = read }
    func cancel() { request = UUID();task?.cancel();task = nil;busy = false;pending = nil;failure = nil }
    func dismissReview() { pending = nil }
    func report(_ error:Error) { cancel();if (error as NSError).code != NSUserCancelledError { failure = error.localizedDescription } }
    func prepare(_ file:URL,original:NativeSnippetDraft,isCurrent:@escaping @MainActor ()->Bool) {
        cancel();guard isCurrent() else { return }
        let expected = request;busy = true
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if expected == self.request { self.busy = false;self.task = nil } }
            do {
                let imported = try await self.read(file);try Task.checkCancellation()
                guard expected == self.request,isCurrent() else { return }
                self.pending = .init(original:original,imported:try imported.validated())
            } catch { if expected == self.request,!Task.isCancelled,isCurrent() { self.failure = error.localizedDescription } }
        }
    }
    func adopt(_ expectedID:UUID,to current:NativeSnippetDraft,isCurrent:@MainActor ()->Bool) throws -> NativeSnippetDraft {
        guard !busy,let pending else { let error = ChatTransferError(message:"Choose a text file to import first.");failure = error.message;throw error }
        guard pending.id == expectedID else { let error = ChatTransferError(message:"The imported file changed. Review the current file before using it.");failure = error.message;throw error }
        guard isCurrent() else { cancel();throw CancellationError() }
        do { let next = try pending.applying(to:current);self.pending = nil;failure = nil;return next }
        catch { self.pending = nil;failure = error.localizedDescription;throw error }
    }
}
