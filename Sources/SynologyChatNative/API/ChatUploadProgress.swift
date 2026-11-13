import Foundation

typealias ChatUploadProgressCallback = @Sendable (Int64, Int64) -> Void

/// Progress belongs to one upload, so queued callbacks cannot repaint a retry.
struct ChatUploadProgress: Equatable {
    let id: UUID
    private(set) var sent: Int64 = 0
    private(set) var total: Int64 = 0
    var fraction: Double? { total > 0 ? min(1, Double(sent) / Double(total)) : nil }
    var label: String {
        guard sent > 0 else { return "Preparing attachment…" }
        let amount = ByteCountFormatter.string(fromByteCount: sent, countStyle: .file)
        guard total > 0 else { return "Uploading " + amount }
        return "Uploading " + amount + " of " + ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }
    mutating func update(id: UUID, sent: Int64, total: Int64) {
        guard id == self.id, sent >= self.sent, sent >= 0 else { return }
        self.sent = sent
        if total > 0 { self.total = max(total, sent) }
    }
}
