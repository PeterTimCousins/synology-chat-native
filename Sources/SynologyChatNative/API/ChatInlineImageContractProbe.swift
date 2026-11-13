#if DEBUG
import Foundation
import ImageIO

/// Read only, pinned to the already-created synthetic image in the two owned accounts.
@MainActor enum ChatInlineImageContractProbe {
    static func run(receipt: URL) async -> Bool {
        do {
            guard !FileManager.default.fileExists(atPath:receipt.path) else { return false }
            let account = try OfficialChatSessionLoader.load()
            let api = try ChatAPIClient(session:account.session)
            try await api.discover()
            let users = try await api.users(), channels = try await api.channels()
            let target = try ChatPeterProbeTarget.resolve(username:account.username,users:users,channels:channels,
                                                         members:await api.members(channelID:93))
            let post = try await api.post(channelID:93,postID:399431958768)
            guard post.channel_id == 93, post.creator_id == 10, post.type == "file",
                  post.file_props?.is_image == true, post.file_props?.name == "native-animated-viewer.gif",
                  post.message == "Native animated image viewer test — synthetic colours only.",
                  (post.delete_at ?? 0) == 0 else { throw ChatAPIError.invalidResponse }
            var representations: [[String:Any]] = []
            for size in [ChatAPIClient.ImagePreviewSize.medium,.large] {
                let data = try await api.thumbnail(postID:post.id,size:size)
                guard let source = CGImageSourceCreateWithData(data as CFData,nil),
                      let image = NativeInlineImagePreview.decode(data) else { throw ChatAPIError.invalidResponse }
                representations.append(["size":size.rawValue,"bytes":data.count,
                    "type":CGImageSourceGetType(source) as String? ?? "unknown",
                    "source_frames":CGImageSourceGetCount(source),
                    "inline_frames":NativeInlineImagePreview.frameCount(image),
                    "width":image.size.width,"height":image.size.height,
                    "cache_cost":NativeInlineImagePreview.memoryCost(image,encodedBytes:data.count)])
            }
            let report: [String:Any] = ["scope":"Read-only existing synthetic image768 in verified ownedDM93",
                "owner_id":target.ownerID,"members":[6,10],"post_id":post.id,
                "representations":representations,"writes":0,"raw_images_saved":false]
            try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:receipt,options:.withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:receipt.path)
            print("Read-only synthetic image thumbnail contract recorded; no raw images or credentials retained.")
            return true
        } catch {
            print("Synthetic image contract check failed; no message or file changes attempted.")
            return false
        }
    }
}
#endif
