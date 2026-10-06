import SwiftUI
import GoogleSignInSwift

struct AccountView: View {
    @EnvironmentObject private var store: AppStore
    @State private var email = ""
    @State private var password = ""
    @State private var token = ""
    @State private var showAPIKey = false
    @FocusState private var focusedField: Field?
    private enum Field { case email, password }

    var body: some View {
        Form {
            if store.connected {
                Section {
                    if let user = store.user {
                        if !user.name.isEmpty { LabeledContent("Name", value: user.name) }
                        if let email = user.email { LabeledContent("Email", value: email) }
                    } else {
                        LabeledContent("Status", value: store.usesAPIKey ? "Connected with API key" : "Signed in")
                    }
                    LabeledContent("Live updates", value: store.liveState.rawValue)
                    Link("Manage account and plan", destination: ServiceURLs.website.appendingPathComponent("dashboard/"))
                }
                Section {
                    Label("Share to Mainbrella", systemImage: "square.and.arrow.up")
                    Text("In Safari, Photos, or another app, share a link, text, or one image to a running workspace.")
                        .font(.subheadline).foregroundStyle(Theme.muted)
                }
                Section {
                    if let message = store.authenticationError { errorMessage(message) }
                    if store.usesAPIKey {
                        Button("Remove saved key", role: .destructive) { store.disconnect() }
                    } else {
                        Button(store.authenticationBusy ? "Signing out…" : "Sign out") {
                            Task { await store.signOut() }
                        }
                    }
                }.disabled(store.loading || store.previewBusy || store.authenticationBusy)
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
                Section {
                    DisclosureGroup("Use an API key", isExpanded: $showAPIKey) {
                        SecureField("Paste your API key", text: $token)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityLabel("API key")
                        Button(store.loading ? "Connecting…" : "Connect") {
                            Task { if await store.connect(token: token) { token = "" } }
                        }.disabled(store.loading || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Link("Create an API key", destination: ServiceURLs.apiKeys)
                    }
                }
                .foregroundStyle(Theme.muted)
            }
        }
        .disabled(store.authenticationBusy || (!store.connected && store.loading))
        .scrollContentBackground(.hidden).scrollDismissesKeyboard(.interactively)
        .frame(maxWidth: 680).frame(maxWidth: .infinity).background(Theme.background)
        .navigationTitle(store.connected ? "Account" : "Sign in to Mainbrella")
        .navigationBarTitleDisplayMode(.inline)
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
