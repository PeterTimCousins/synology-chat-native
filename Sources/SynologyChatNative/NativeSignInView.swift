import SwiftUI

struct NativeSignInView: View {
    let onSignIn: (ChatAccount, String?) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var address = UserDefaults.standard.string(forKey: Defaults.chatURL) ?? ""
    @State private var username = ""
    @State private var password = ""
    @State private var otp = ""
    @State private var asGuest = false
    @State private var challenge: ChatSignInChallenge?
    @State private var remember = false
    @State private var working = false
    @State private var error: String?
    private var identity: ChatSignInIdentity { .init(address: address, username: username, asGuest: asGuest) }
    private var requiresOTP: Bool { challenge?.identity == identity }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Connect to your Synology").font(.title2.weight(.semibold))
                Text("Your messages stay on your server. Sign in directly to use the native client.")
                    .foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Server address").font(.caption).foregroundColor(.secondary)
                    TextField("HTTPS address or QuickConnect ID", text: $address).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Server address")
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(asGuest ? "Guest email or username" : "Username").font(.caption).foregroundColor(.secondary)
                    TextField(asGuest ? "Guest email or username" : "Username", text: $username).textFieldStyle(.roundedBorder)
                        .accessibilityLabel(asGuest ? "Guest email or username" : "Username")
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Password").font(.caption).foregroundColor(.secondary)
                    SecureField("Password", text: $password).textFieldStyle(.roundedBorder).accessibilityLabel("Password")
                }
                if requiresOTP {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Verification code").font(.caption).foregroundColor(.secondary)
                        TextField("Verification code", text: $otp).textFieldStyle(.roundedBorder).accessibilityLabel("Verification code")
                    }
                }
                Toggle("Sign in as a guest", isOn: $asGuest)
                if asGuest {
                    Text("Use your existing guest account from a Chat invitation. The guest_ account prefix is added automatically.")
                        .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Keep me signed in on this Mac", isOn: $remember)
                Text("Saves the session in macOS Keychain. Your password and verification code are never stored.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Remove saved sign-in") {
                    Task {
                        working = true
                        defer { working = false }
                        do { try await ChatAccountKeychain.removeAsync(); self.error = NativeLocalizedStrings.text("Saved sign-in removed from this Mac.") }
                        catch { self.error = NativeLocalizedStrings.text("Could not remove the saved sign-in from Keychain.") }
                    }
                }.buttonStyle(.link).font(.caption)
            }.disabled(working)
            if let error { Text(error).foregroundColor(.orange).font(.callout).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Use saved sign-in") {
                    Task {
                        working = true
                        defer { working = false }
                        do {
                            guard let account = try await ChatAccountKeychain.loadAsync() else { self.error = NativeLocalizedStrings.text("There is no saved sign-in on this Mac."); return }
                            await onSignIn(account, nil)
                        } catch { self.error = NativeLocalizedStrings.text("Could not read the saved sign-in from Keychain.") }
                    }
                }.disabled(working)
                Spacer()
                Button("Cancel") { password = ""; otp = ""; dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                Button(working ? "Signing in…" : "Sign in") { Task { await signIn() } }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(working || address.isEmpty || username.isEmpty || password.isEmpty || (requiresOTP && otp.isEmpty))
            }
        }.padding(28).frame(width: 440).nativeChatAppearance()
            .onChange(of: identity) { _ in
                challenge = nil; otp = ""; password = ""; error = nil
            }
            .onChange(of: password) { _ in
                if requiresOTP { challenge = nil; otp = ""; error = nil }
            }
            .onDisappear { password = ""; otp = ""; challenge = nil }
    }

    @MainActor private func signIn() async {
        working = true
        error = nil
        defer { working = false }
        let attempt = identity
        let verificationCode = challenge?.verificationCode(otp, for: attempt) ?? ""
        do {
            let account = try await ChatAuthentication().signIn(address: attempt.address, username: attempt.username, password: password, otp: verificationCode, asGuest: attempt.asGuest)
            password = ""; otp = ""
            let warning = await ChatSavedSignInPreference.apply(account: account, remember: remember)
            await onSignIn(account, warning)
        } catch ChatSignInError.otpRequired {
            guard identity == attempt else { return }
            challenge = .init(identity: attempt)
            self.error = ChatSignInError.otpRequired.errorDescription
        } catch ChatSignInError.otpInvalid {
            guard identity == attempt else { return }
            challenge = .init(identity: attempt)
            otp = ""
            self.error = ChatSignInError.otpInvalid.errorDescription
        } catch {
            self.error = (error as? ChatSignInError)?.errorDescription ?? (error as? ChatQuickConnectError)?.errorDescription
                ?? NativeLocalizedStrings.text("Sign-in failed. Check your server address and try again.")
        }
    }
}
