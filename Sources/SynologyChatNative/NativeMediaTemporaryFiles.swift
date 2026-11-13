import Foundation
import Darwin

/// Per-process leases let a later launch remove abandoned media while preserving
/// files used by another running instance of the same app.
final class NativeMediaTemporaryFiles {
    static let shared = NativeMediaTemporaryFiles()
    private let lock = NSLock()
    private var leases:[URL:Int32] = [:]
    private let root:URL
    private let prefix:String
    private let marker:[UInt8]
    private let acceptsFilename:(String)->Bool
    init(root:URL = FileManager.default.temporaryDirectory,namespace:String = Bundle.main.bundleIdentifier ?? "native-tests",purpose:String = "media",acceptsFilename:@escaping (String)->Bool = { $0.hasPrefix("attachment.") && NativeDocumentKind.forFilename($0)?.isMedia == true }) {
        self.root = root
        let safe = namespace.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
        let safePurpose = purpose.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        prefix = "native-chat-"+safePurpose+"-v1-"+safe+"-"
        marker = Array(("SynologyChatNative "+safePurpose+" cache v1\n").utf8);self.acceptsFilename = acceptsFilename
        cleanAbandoned()
    }
    func create(extension suffix:String) throws -> URL {
        try create(filename:"attachment."+suffix)
    }
    func create(filename:String) throws -> URL {
        guard filename != ".lease",ChatMultipartBody.safeFilename(filename) == filename,acceptsFilename(filename) else { throw ChatAPIError.invalidResponse }
        lock.lock();defer { lock.unlock() }
        let folder = root.appendingPathComponent(prefix+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let lease = folder.appendingPathComponent(".lease")
        let fd = Darwin.open(lease.path,O_CREAT|O_EXCL|O_RDWR|O_NOFOLLOW,0o600)
        guard fd >= 0 else { try? FileManager.default.removeItem(at:folder);throw ChatAPIError.invalidResponse }
        guard flock(fd,LOCK_EX|LOCK_NB) == 0,marker.withUnsafeBytes({ Darwin.write(fd,$0.baseAddress,marker.count) }) == marker.count else {
            Darwin.close(fd);try? FileManager.default.removeItem(at:folder);throw ChatAPIError.invalidResponse
        }
        let file = folder.appendingPathComponent(filename)
        leases[file] = fd;return file
    }
    func remove(_ file:URL) {
        lock.lock();defer { lock.unlock() }
        guard let fd = leases.removeValue(forKey:file) else { return }
        try? FileManager.default.removeItem(at:file.deletingLastPathComponent());Darwin.close(fd)
    }
    func removeAll() {
        lock.lock();defer { lock.unlock() }
        for (file,fd) in leases { try? FileManager.default.removeItem(at:file.deletingLastPathComponent());Darwin.close(fd) }
        leases.removeAll()
    }
    func cleanAbandoned() {
        lock.lock();defer { lock.unlock() }
        guard let folders = try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:[.isSymbolicLinkKey,.isDirectoryKey]) else { return }
        for folder in folders where folder.lastPathComponent.hasPrefix(prefix) {
            guard let values = try? folder.resourceValues(forKeys:[.isSymbolicLinkKey,.isDirectoryKey]),values.isDirectory == true,values.isSymbolicLink != true,
                  let names = try? FileManager.default.contentsOfDirectory(atPath:folder.path),names.contains(".lease"),
                  names.allSatisfy({ $0 == ".lease" || acceptsFilename($0) }) else { continue }
            let fd = Darwin.open(folder.appendingPathComponent(".lease").path,O_RDWR|O_NOFOLLOW)
            guard fd >= 0 else { continue };defer { Darwin.close(fd) }
            var info = stat(),bytes = [UInt8](repeating:0,count:marker.count)
            guard fstat(fd,&info) == 0,info.st_uid == getuid(),info.st_size == marker.count,
                  flock(fd,LOCK_EX|LOCK_NB) == 0,Darwin.read(fd,&bytes,bytes.count) == marker.count,bytes == marker else { continue }
            try? FileManager.default.removeItem(at:folder)
        }
    }
    deinit { for (file,fd) in leases { try? FileManager.default.removeItem(at:file.deletingLastPathComponent());Darwin.close(fd) } }
}
