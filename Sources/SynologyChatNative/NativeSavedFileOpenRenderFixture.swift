#if DEBUG
import AppKit

/// Lay out only alert objects owned by this isolated process. Never show an
/// alert, capture the desktop, access a real attachment or call Workspace.
@MainActor enum NativeSavedFileOpenRenderFixture {
    static func render(to directory: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let variants: [(String, String, NSAppearance.Name)] = [
                ("dark", "Meeting notes.pdf", .darkAqua),
                ("light", "Meeting notes.pdf", .aqua),
                ("long-name", "Project planning and review — a deliberately long downloaded filename.pdf\u{202e}.command", .darkAqua)
            ]
            for (name, filename, appearance) in variants {
                let review = ChatSavedFileOpening.Review(localURL: URL(fileURLWithPath: "/synthetic/" + filename),
                                                        displayName: ChatSavedFileOpening.displayName(filename))
                let alert = NativeSavedFileOpenPrompt.makeAlert(review)
                let window = alert.window
                window.appearance = NSAppearance(named: appearance)
                alert.layout()
                guard !window.isVisible, let view = window.contentView else { throw ChatAPIError.invalidResponse }
                view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ChatAPIError.invalidResponse }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard !window.isVisible, let png = bitmap.representation(using: .png, properties: [:]) else { throw ChatAPIError.invalidResponse }
                let file = directory.appendingPathComponent(name + ".png")
                try png.write(to: file, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
            print("Rendered three synthetic file-open reviews without presenting an alert.")
            return true
        } catch { print("File-open review rendering failed; no alert or file was opened."); return false }
    }
}
#endif
