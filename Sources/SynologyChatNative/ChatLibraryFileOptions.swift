import Foundation

struct ChatLibraryFileOptions: Equatable {
    enum Sort: String, CaseIterable, Identifiable {
        case newest = "create_at", name = "file_name"
        var id: String { rawValue }
        var title: String { self == .newest ? "Newest first" : "File name" }
    }
    enum Category: String, CaseIterable, Identifiable {
        case all = "", images = "image"
        var id: String { rawValue }
        var title: String { self == .all ? "All files" : "Images" }
    }
    var sort: Sort = .newest
    var category: Category = .all
    func includes(_ post: ChatPost) -> Bool {
        post.type == "file" && (category != .images || post.file_props?.is_image == true)
    }
    func ordered(_ posts: [ChatPost]) -> [ChatPost] {
        if sort == .name, posts.contains(where: { $0.file_props?.name == nil }) { return posts }
        return posts.enumerated().sorted { first, second in
            let left = first.element, right = second.element
            if sort == .name {
                let order = (left.file_props?.name ?? "").localizedCompare(right.file_props?.name ?? "")
                if order != .orderedSame { return order == .orderedAscending }
            } else if left.create_at != right.create_at { return left.create_at > right.create_at }
            return first.offset < second.offset
        }.map(\.element)
    }
}
