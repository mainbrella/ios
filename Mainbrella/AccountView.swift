import SwiftUI
import GoogleSignInSwift

struct AccountView: View {
    @EnvironmentObject private var store: AppStore
    @State private var email = ""
    @State private var password = ""
    @FocusState private var focusedField: Field?
    private enum Field { case email, password }

    var body: some View {
        Form {
            if store.usesAPIKey {
                Section {
                    Text("Building websites requires a Google or email account.")
                    Button("Remove saved key", role: .destructive) { store.disconnect() }
                } footer: {
                    Text("Remove the API key saved by an earlier version, then sign in to build.")
                }
            } else if store.connected {
                Section {
                    if let user = store.user {
                        if !user.name.isEmpty { LabeledContent("Name", value: user.name) }
                        if let email = user.email { LabeledContent("Email", value: email) }
                    } else {
                        LabeledContent("Status", value: "Signed in")
                    }
                    Link("Manage billing", destination: ServiceURLs.website.appendingPathComponent("dashboard/"))
                }
                Section {
                    if let message = store.authenticationError { errorMessage(message) }
                    Button(store.authenticationBusy ? "Signing out…" : "Sign out") {
                        Task { await store.signOut() }
                    }
                }.disabled(store.authenticationBusy)
            } else {
                Section {
                    GoogleSignInButton(scheme: .dark, style: .wide, state: .normal) {
                        focusedField = nil
                        Task { if await store.signInWithGoogle() { password = "" } }
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("google-sign-in")
                }
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Email").font(.subheadline)
                        TextField("you@example.com", text: $email)
                            .textContentType(.username).keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityLabel("Email").accessibilityIdentifier("login-email")
                            .focused($focusedField, equals: .email).submitLabel(.next)
                            .onSubmit { focusedField = .password }
                    }.frame(minHeight: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Password").font(.subheadline)
                        SecureField("Password", text: $password)
                            .textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityLabel("Password").accessibilityIdentifier("login-password")
                            .focused($focusedField, equals: .password).submitLabel(.go)
                            .onSubmit { if canSubmitEmail { submitEmail() } }
                    }.frame(minHeight: 44)
                    Button("Continue with email", action: submitEmail)
                        .frame(minHeight: 44).disabled(!canSubmitEmail)
                        .accessibilityIdentifier("email-sign-in")
                } footer: {
                    Text("Use your existing account, or enter a new email and a password with at least 8 characters to create one.")
                }
                if store.authenticationBusy || store.authenticationError != nil {
                    Section {
                        if store.authenticationBusy { ProgressView("Signing in…") }
                        if let message = store.authenticationError { errorMessage(message) }
                    }
                }
            }
        }
        .disabled(store.authenticationBusy || (!store.connected && store.loading))
        .scrollContentBackground(.hidden).scrollDismissesKeyboard(.interactively)
        .frame(maxWidth: 680).frame(maxWidth: .infinity).background(Theme.background)
        .navigationTitle(store.usesAPIKey ? "Sign in to build" : store.connected ? "Account" : "Sign in to Mainbrella")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }

    private var canSubmitEmail: Bool {
        let value = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return !store.loading && !store.authenticationBusy && value.count <= 254
            && value.range(of: "^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$", options: .regularExpression) != nil
            && !password.isEmpty && password.utf16.count <= 128
    }

    private func submitEmail() {
        focusedField = nil
        Task { if await store.signInWithEmail(email: email, password: password) { password = "" } }
    }

    private func errorMessage(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.subheadline).foregroundStyle(.orange)
            .accessibilityIdentifier("authentication-error")
    }
}
