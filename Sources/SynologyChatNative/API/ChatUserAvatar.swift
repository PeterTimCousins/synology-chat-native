import Foundation

enum ChatAvatarSize:String,CaseIterable { case small = "S",medium = "M",large = "L" }

extension ChatAPIClient {
    /// The URL is always derived from the discovered NAS endpoint, never a profile-supplied URL.
    func avatarData(userID:Int64,size:ChatAvatarSize,version:Int64) async throws -> Data {
        guard userID > 0,version >= 0,version <= 9007199254740991 else { throw ChatAPIError.invalidResponse }
        let request = try requestForCall(api:"SYNO.Chat.User.Avatar",method:"get",version:1,parameters:["user_id":.integer(userID),"type":.string(size.rawValue),"v":.integer(version)])
        try Task.checkCancellation()
        let (stream,response) = try await network.bytes(for:request)
        guard let http = response as? HTTPURLResponse,http.statusCode == 200,
              ["image/png","image/jpeg","image/gif","image/webp"].contains(http.mimeType ?? ""),response.expectedContentLength <= 2*1024*1024 else { throw ChatAPIError.invalidResponse }
        var result = Data();result.reserveCapacity(Int(max(0,min(response.expectedContentLength,2*1024*1024))))
        for try await byte in stream {
            guard result.count < 2*1024*1024 else { throw ChatAPIError.invalidResponse }
            result.append(byte)
            if result.count & 4095 == 0 { try Task.checkCancellation() }
        }
        try Task.checkCancellation();guard !result.isEmpty else { throw ChatAPIError.invalidResponse };return result
    }
}
