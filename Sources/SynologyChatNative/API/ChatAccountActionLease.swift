import CryptoKit
import Darwin
import Foundation

/// Operation lifetime exclusion, separate from the brief journal-update lock.
/// Lease files contain no data. Kernel locks disappear when their process exits.
final class ChatAccountActionLease {
    private static let registryLock = NSLock()
    private static var heldMemoryKeys = Set<String>()
    private let stateLock = NSLock()
    private var descriptors:[Int32] = []
    private var memoryKeys:[String] = []

    init(directory:URL?,scope:String,keys:[String],memoryNamespace:String) throws {
        guard ChatNotificationAccountScope.isValid(scope),!keys.isEmpty,keys.count <= 128,
              keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 }) else { throw ChatAPIError.invalidResponse }
        let unique = Array(Set(keys)).sorted()
        do {
            if let directory {
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                guard try FileManager.default.attributesOfItem(atPath:directory.path)[.type] as? FileAttributeType == .typeDirectory else { throw ChatAPIError.invalidResponse }
                let folder = Darwin.open(directory.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard folder >= 0 else { throw ChatAPIError.connection }
                defer { Darwin.close(folder) }
                guard fchmod(folder,0o700) == 0 else { throw ChatAPIError.connection }
                for key in unique {
                    let filename = scope + "." + Self.digest(key) + ".lease"
                    let descriptor = openat(folder,filename,O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,0o600)
                    guard descriptor >= 0 else { throw ChatAPIError.connection }
                    var status = stat()
                    guard fstat(descriptor,&status) == 0, status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                          fchmod(descriptor,0o600) == 0 else {
                        Darwin.close(descriptor);throw ChatAPIError.invalidResponse
                    }
                    guard flock(descriptor,LOCK_EX | LOCK_NB) == 0 else {
                        Darwin.close(descriptor);throw ChatAPIError.connection
                    }
                    descriptors.append(descriptor)
                }
            } else {
                guard !memoryNamespace.isEmpty else { throw ChatAPIError.invalidResponse }
                let wanted = unique.map { memoryNamespace + ":" + scope + ":" + Self.digest($0) }
                Self.registryLock.lock();defer { Self.registryLock.unlock() }
                guard Self.heldMemoryKeys.isDisjoint(with:wanted) else { throw ChatAPIError.connection }
                Self.heldMemoryKeys.formUnion(wanted);memoryKeys = wanted
            }
        } catch { release();throw error }
    }
    private static func digest(_ key:String)->String {
        SHA256.hash(data:Data(key.utf8)).map { String(format:"%02x",$0) }.joined()
    }
    func release() {
        stateLock.lock()
        let files = descriptors,registered = memoryKeys
        descriptors = [];memoryKeys = []
        stateLock.unlock()
        for descriptor in files { _ = flock(descriptor,LOCK_UN);Darwin.close(descriptor) }
        if !registered.isEmpty {
            Self.registryLock.lock();Self.heldMemoryKeys.subtract(registered);Self.registryLock.unlock()
        }
    }
    deinit { release() }
}
