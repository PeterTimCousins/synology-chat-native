import SwiftUI

typealias NativeMessageEditorHostingChange = @MainActor (UUID,Bool)->Void

private struct NativeMessageEditorHostingKey:EnvironmentKey {
    static let defaultValue:NativeMessageEditorHostingChange? = nil
}

private struct NativeContainedMessageActionsKey:EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    /// A native row may retain its already-open editor while offscreen. The
    /// hosting reader supplies and validates the row's scoped capability.
    var nativeMessageEditorHostingChanged:NativeMessageEditorHostingChange? {
        get { self[NativeMessageEditorHostingKey.self] }
        set { self[NativeMessageEditorHostingKey.self] = newValue }
    }
    /// Per-row native hosts must keep their action targets inside their bounds.
    var nativeContainedMessageActions:Bool {
        get { self[NativeContainedMessageActionsKey.self] }
        set { self[NativeContainedMessageActionsKey.self] = newValue }
    }
}
