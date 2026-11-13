import AppKit
import SwiftUI

/// Use Control–Command to keep image zoom separate from interface zoom and
/// macOS accessibility Zoom. Both the shifted plus and unshifted equals work.
enum NativeImageViewerKeys {
    enum Action: Equatable { case zoomIn, zoomOut, fit, actualSize }

    static func action(characters: String?, modifiers: NSEvent.ModifierFlags) -> Action? {
        let relevant = modifiers.intersection([.command, .control, .option, .shift])
        let primary: NSEvent.ModifierFlags = [.control, .command]
        guard relevant == primary || relevant == primary.union(.shift) else { return nil }
        switch characters {
        case "+", "=": return .zoomIn
        case "-": return .zoomOut
        case "0" where !relevant.contains(.shift): return .fit
        case "1" where !relevant.contains(.shift): return .actualSize
        default: return nil
        }
    }

    static func canHandle(enabled: Bool, applicationActive: Bool, matchingWindow: Bool,
                          windowKey: Bool, coveredBySheet: Bool, editable: Bool, markedText: Bool) -> Bool {
        enabled && applicationActive && matchingWindow && windowKey && !coveredBySheet && !editable && !markedText
    }

    static func editingState(_ responder: NSResponder?) -> (editable: Bool, markedText: Bool) {
        let editable = (responder as? NSTextView)?.isEditable == true || (responder as? NSTextField)?.isEditable == true
        let marked = (responder as? NSTextInputClient)?.hasMarkedText() == true
        return (editable, marked)
    }
}

struct NativeImageViewerKeysView: NSViewRepresentable {
    let enabled: Bool
    let action: (NativeImageViewerKeys.Action) -> Void

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView(); view.parent = self; view.install(); return view
    }
    func updateNSView(_ view: KeyView, context: Context) { view.parent = self }
    static func dismantleNSView(_ view: KeyView, coordinator: ()) { view.uninstall(); view.parent = nil }

    final class KeyView: NSView {
        var parent: NativeImageViewerKeysView?
        private var monitor: Any?
        var isMonitoring: Bool { monitor != nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let parent = self.parent, let window = self.window,
                      let action = NativeImageViewerKeys.action(characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags) else { return event }
                let editing = NativeImageViewerKeys.editingState(window.firstResponder)
                guard NativeImageViewerKeys.canHandle(enabled: parent.enabled, applicationActive: NSApp.isActive,
                    matchingWindow: event.window === window, windowKey: NSApp.keyWindow === window,
                    coveredBySheet: window.attachedSheet != nil, editable: editing.editable, markedText: editing.markedText) else { return event }
                parent.action(action)
                return nil
            }
        }
        func uninstall() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
