import SwiftUI

struct SettingsView: View {
    @Environment(PoolStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var mode: ConnectionMode = .auto
    @State private var host = ""
    @State private var port = "80"
    @State private var password = ""
    @State private var showPassword = false
    @State private var hasSavedPassword = LoginStore.password() != nil
    @State private var passwordStatus: PasswordStatus = .idle
    @FocusState private var passwordFocused: Bool
    @State private var confirmSignOut = false

    private enum PasswordStatus: Equatable {
        case idle, saving
        case saved(String)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("System") {
                    LabeledContent("Name", value: store.login?.systemName ?? "")
                    LabeledContent("Connected", value: store.link?.label ?? "No")
                }

                Section {
                    Picker("Connect", selection: $mode) {
                        ForEach(ConnectionMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: mode) { _, newMode in
                        Task { await store.updateMode(newMode) }
                    }
                } header: {
                    Text("Connection")
                } footer: {
                    Text("Auto tries your home WiFi first, then Pentair's remote server.")
                }

                Section("Home WiFi") {
                    TextField("Adapter IP", text: $host)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                    Button("Save and reconnect") {
                        Task { await store.updateLocalAddress(host, port: UInt16(port) ?? 80) }
                    }
                }

                Section {
                    HStack {
                        Group {
                            if showPassword {
                                TextField(passwordPlaceholder, text: $password)
                            } else {
                                SecureField(passwordPlaceholder, text: $password)
                            }
                        }
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($passwordFocused)
                        .submitLabel(.done)
                        .onSubmit(savePassword)

                        Button {
                            showPassword.toggle()
                            passwordFocused = true
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(showPassword ? "Hide password" : "Show password")
                    }
                    // Only disabled while saving. Flipping it on the first keystroke would redraw
                    // this section and knock the keyboard out of the field.
                    Button(action: savePassword) {
                        HStack {
                            Text(passwordStatus == .saving ? "Saving and reconnecting…" : "Update password")
                            Spacer()
                            if passwordStatus == .saving { ProgressView() }
                        }
                    }
                    .disabled(passwordStatus == .saving)
                } header: {
                    Text("Remote password")
                } footer: {
                    passwordFooter
                }
                .sensoryFeedback(trigger: passwordStatus) { _, new in
                    switch new {
                    case .saved: return .success
                    case .failed: return .error
                    default: return nil
                    }
                }

                Section {
                    Button("Reconnect") { Task { await store.connect() } }
                    Button("Sign out", role: .destructive) { confirmSignOut = true }
                }

                Section {
                    Text("Personal use. Speaks Pentair's ScreenLogic protocol as documented by the open source node-screenlogic and screenlogicpy projects. Not made by or affiliated with Pentair.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Sign out of this pool?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    store.signOut()
                    dismiss()
                }
            }
        }
        .onAppear {
            mode = store.login?.mode ?? .auto
            host = store.login?.localHost ?? ""
            port = String(store.login?.localPort ?? 80)
        }
    }

    private var passwordPlaceholder: String {
        hasSavedPassword ? "Saved. Type a new one to replace it" : "Remote password"
    }

    @ViewBuilder private var passwordFooter: some View {
        switch passwordStatus {
        case .saved(let message):
            Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .idle, .saving:
            Text(hasSavedPassword
                 ? "A password is saved on this phone. You only need it away from home."
                 : "No password saved. You only need it away from home.")
        }
    }

    private func savePassword() {
        let value = password
        guard !value.isEmpty else {
            passwordFocused = true
            return
        }
        passwordFocused = false
        LoginStore.setPassword(value)
        password = ""
        showPassword = false
        hasSavedPassword = true
        passwordStatus = .saving
        Task {
            await store.connect()
            switch store.phase {
            case .connected where store.link == .remote:
                passwordStatus = .saved("Saved, and it works through Pentair's server.")
            case .connected:
                passwordStatus = .saved("Saved. You're on home WiFi, so it gets used next time you're away.")
            case .failed(let message):
                passwordStatus = .failed("Saved, but couldn't connect. \(message)")
            default:
                passwordStatus = .saved("Saved.")
            }
        }
    }
}
