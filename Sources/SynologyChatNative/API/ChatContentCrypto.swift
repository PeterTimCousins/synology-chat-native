import Foundation
import Sodium
import Security

enum ChatCryptoError: LocalizedError {
    case invalidEncoding, invalidKey, authenticationFailed, operationFailed
    var errorDescription: String? {
        switch self {
        case .invalidEncoding: return "The encrypted content has an invalid format."
        case .invalidKey: return "The encryption key has an invalid format."
        case .authenticationFailed: return "Could not unlock this content. Check the encryption password or key."
        case .operationFailed: return "The encryption operation could not finish."
        }
    }
}

/// Wire formats recovered from Synology's Encrypt.Sodium adapter. This layer never
/// writes keys to the server or disk and does not initialize an account key pair.
enum ChatContentCrypto {
    private static let sodium = Sodium()

    static func generateChannelKey() throws -> Data {
        var bytes = [UInt8](repeating:0,count:32)
        guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes) == errSecSuccess else { throw ChatCryptoError.operationFailed }
        return Data(bytes)
    }

    static func decodeBase64(_ value: String) throws -> Data {
        // The server's legacy encoder inserts CRLF after 76 Base64 characters.
        let compact = value.filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: compact) else { throw ChatCryptoError.invalidEncoding }
        return data
    }

    static func unlockPrivateKey(_ wrapped: String, password: String) throws -> Data {
        guard let key = sodium.genericHash.hash(message: Array(password.utf8), outputLength: 32) else {
            throw ChatCryptoError.operationFailed
        }
        let plain = try open(try decodeBase64(wrapped), key: Data(key))
        guard let text = String(data: plain, encoding: .utf8) else { throw ChatCryptoError.invalidEncoding }
        let privateKey = try decodeBase64(text)
        try validateKey(privateKey)
        return privateKey
    }

    static func wrapPrivateKey(_ privateKey: Data, password: String) throws -> String {
        try validateKey(privateKey)
        guard let key = sodium.genericHash.hash(message: Array(password.utf8), outputLength: 32) else {
            throw ChatCryptoError.operationFailed
        }
        return try seal(Data(privateKey.base64EncodedString().utf8), key: Data(key)).base64EncodedString()
    }

    static func unwrapChannelKey(_ wrapped: String, publicKey: Data, privateKey: Data) throws -> Data {
        try validateKey(publicKey); try validateKey(privateKey)
        let sealed = try decodeBase64(wrapped)
        guard sealed.count >= 48,
              let plain = sodium.box.open(anonymousCipherText: Array(sealed), recipientPublicKey: Array(publicKey), recipientSecretKey: Array(privateKey)) else {
            throw ChatCryptoError.authenticationFailed
        }
        guard let text = String(bytes: plain, encoding: .utf8) else { throw ChatCryptoError.invalidEncoding }
        let key = try decodeBase64(text)
        try validateKey(key)
        return key
    }

    static func wrapChannelKey(_ channelKey: Data, publicKey: Data) throws -> String {
        try validateKey(channelKey); try validateKey(publicKey)
        guard let sealed = sodium.box.seal(message: Array(channelKey.base64EncodedString().utf8), recipientPublicKey: Array(publicKey)) else {
            throw ChatCryptoError.operationFailed
        }
        return Data(sealed).base64EncodedString()
    }

    static func encryptMessage(_ message: String, key: Data) throws -> String {
        try seal(Data(message.utf8), key: key).base64EncodedString()
    }
    static func decryptMessage(_ message: String, key: Data) throws -> String {
        let plain = try open(try decodeBase64(message), key: key)
        guard let text = String(data: plain, encoding: .utf8) else { throw ChatCryptoError.invalidEncoding }
        return text
    }
    static func encryptFilename(_ filename: String, key: Data) throws -> String {
        try seal(Data(filename.utf8), key: key).map { String(format: "%02x", $0) }.joined()
    }
    static func decryptFilename(_ filename: String, key: Data) throws -> String {
        let chars = Array(filename.utf8)
        guard chars.count.isMultiple(of: 2), chars.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw ChatCryptoError.invalidEncoding
        }
        var bytes = Data()
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let value = UInt8(String(bytes: chars[i...i+1], encoding: .utf8)!, radix: 16) else { throw ChatCryptoError.invalidEncoding }
            bytes.append(value)
        }
        let plain = try open(bytes, key: key)
        guard let text = String(data: plain, encoding: .utf8) else { throw ChatCryptoError.invalidEncoding }
        return text
    }
    static func encryptAttachment(_ data: Data, key: Data) throws -> Data { try seal(data, key: key) }
    static func decryptAttachment(_ data: Data, key: Data) throws -> Data { try open(data, key: key) }

    private static func validateKey(_ key: Data) throws {
        guard key.count == 32 else { throw ChatCryptoError.invalidKey }
    }
    private static func seal(_ data: Data, key: Data) throws -> Data {
        try validateKey(key)
        guard let sealed: [UInt8] = sodium.secretBox.seal(message: Array(data), secretKey: Array(key)) else {
            throw ChatCryptoError.operationFailed
        }
        return Data(sealed)
    }
    private static func open(_ data: Data, key: Data) throws -> Data {
        try validateKey(key)
        guard data.count >= 40 else { throw ChatCryptoError.invalidEncoding }
        guard let plain = sodium.secretBox.open(nonceAndAuthenticatedCipherText: Array(data), secretKey: Array(key)) else {
            throw ChatCryptoError.authenticationFailed
        }
        return Data(plain)
    }
}
