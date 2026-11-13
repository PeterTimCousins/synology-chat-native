import SwiftUI

struct NativeEncryptionUnlockView: View {
    @ObservedObject var model: NativeChatPreviewModel
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Unlock encrypted conversations", systemImage: "lock.open").font(.title2.weight(.semibold))
            Text("Enter the encryption password you set in Synology Chat. Unlocking happens on this Mac; the password and unlocked keys are kept only for this app session.")
                .foregroundColor(NativeChatColors.muted).fixedSize(horizontal: false, vertical: true)
            SecureField("Encryption password", text: $password).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Encryption password")
            if let error { Text(error).foregroundColor(.orange).font(.callout).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Cancel") { password = ""; dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Unlock") {
                    defer { password = "" }
                    do { try model.unlockEncryption(password: password); dismiss() }
                    catch { self.error = (error as? ChatCryptoError)?.errorDescription ?? "Could not unlock these conversations." }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(password.isEmpty)
            }
        }.padding(26).frame(width: 460).background(NativeChatColors.canvas)
            .foregroundColor(NativeChatColors.text).tint(NativeChatColors.green).nativeChatAppearance()
            .onDisappear { password = "" }
    }
}
