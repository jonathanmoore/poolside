import SwiftUI

struct SettingsView: View {
    @Environment(PoolStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var mode: ConnectionMode = .auto
    @State private var host = ""
    @State private var port = "80"
    @State private var password = ""
    @State private var confirmSignOut = false

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

                Section("Remote password") {
                    SecureField("Remote password", text: $password)
                        .textContentType(.password)
                        .submitLabel(.done)
                        .onSubmit(savePassword)
                    // Always enabled on purpose: flipping it from disabled to enabled on the first
                    // keystroke redraws this section and knocks the keyboard out of the field.
                    Button("Update password", action: savePassword)
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

    private func savePassword() {
        guard !password.isEmpty else { return }
        LoginStore.setPassword(password)
        password = ""
        Task { await store.connect() }
    }
}
