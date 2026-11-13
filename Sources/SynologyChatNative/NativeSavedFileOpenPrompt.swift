import AppKit

/// An explicit local user review; no attachment or server event presents it.
@MainActor final class NativeSavedFileOpenPrompt {
    private struct Pending {
        let id: UUID
        let alert: NSAlert
        let parent: NSWindow
        let continuation: CheckedContinuation<ChatSavedFileOpening.Decision, Never>
    }
    private var pending: Pending?

    func confirm(_ review: ChatSavedFileOpening.Review) async -> ChatSavedFileOpening.Decision {
        let id = UUID()
        return await withTaskCancellationHandler(operation: {
            guard !Task.isCancelled else { return .cancel }
            return await withCheckedContinuation { continuation in
                let key = NSApp?.keyWindow
                guard pending == nil, let parent = key ?? NSApp?.mainWindow,
                      parent.isVisible, !parent.isMiniaturized, parent.attachedSheet == nil else {
                    continuation.resume(returning: .cancel); return
                }
                let alert = Self.makeAlert(review)
                pending = .init(id: id, alert: alert, parent: parent, continuation: continuation)
                alert.beginSheetModal(for: parent) { [weak self] response in
                    Task { @MainActor in
                        let decision: ChatSavedFileOpening.Decision
                        switch response {
                        case .alertFirstButtonReturn: decision = .reveal
                        case .alertSecondButtonReturn: decision = .open
                        default: decision = .cancel
                        }
                        self?.finish(id: id, decision: decision)
                    }
                }
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.cancel(id: id) } })
    }
    static func makeAlert(_ review: ChatSavedFileOpening.Review,language:NativeInterfaceLanguage = .system,
                          bundle:Bundle = NativeLocalizedStrings.resourceBundle) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = NativeLocalizedStrings.object("Open “%@”?",review.displayName,language:language,bundle:bundle)
        alert.informativeText = NativeLocalizedStrings.text("Opening a downloaded file may run a program. Only open it if you trust its source.",language:language,bundle:bundle)
        alert.addButton(withTitle: NativeLocalizedStrings.text("Show in Folder",language:language,bundle:bundle))
        alert.addButton(withTitle: NativeLocalizedStrings.text("Open",language:language,bundle:bundle))
        alert.addButton(withTitle: NativeLocalizedStrings.text("Cancel",language:language,bundle:bundle))
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""
        alert.buttons[2].keyEquivalent = "\u{1b}"
        return alert
    }
    func cancel() { if let id = pending?.id { cancel(id: id) } }
    private func cancel(id: UUID) {
        guard let current = pending, current.id == id else { return }
        pending = nil
        current.parent.endSheet(current.alert.window, returnCode: .cancel)
        current.alert.window.orderOut(nil)
        current.continuation.resume(returning: .cancel)
    }
    private func finish(id: UUID, decision: ChatSavedFileOpening.Decision) {
        guard let current = pending, current.id == id else { return }
        pending = nil
        current.continuation.resume(returning: decision)
    }
}
