import SwiftUI

struct SignInView: View {
    @Environment(PoolStore.self) private var store
    @State private var systemName = ""
    @State private var password = ""
    @State private var mode: ConnectionMode = .auto
    @State private var localHost = ""
    @State private var found: [LocalGateway] = []
    @State private var searching = false
    @State private var searched = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Pentair: 12-34-56", text: $systemName)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    SecureField("Remote password", text: $password)
                        .textContentType(.password)
                } header: {
                    Text("Your system")
                } footer: {
                    Text("The system name is on the ScreenLogic adapter and in the official app. The password is the remote access password. You only need it away from home.")
                }

                Section("Connect") {
                    Picker("Connect", selection: $mode) {
                        ForEach(ConnectionMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    Button {
                        Task { await search() }
                    } label: {
                        HStack {
                            Label("Find it on my WiFi", systemImage: "wifi")
                            Spacer()
                            if searching { ProgressView() }
                        }
                    }
                    .disabled(searching)

                    ForEach(found) { gateway in
                        Button {
                            systemName = gateway.name
                            localHost = gateway.host
                        } label: {
                            VStack(alignment: .leading) {
                                Text(gateway.name)
                                Text(gateway.host).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if searched && found.isEmpty && !searching {
                        Text("Nothing answered. Type the adapter's IP address below, or connect Away.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    TextField("Adapter IP on WiFi (optional)", text: $localHost)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section {
                    Button {
                        Task { await signIn() }
                    } label: {
                        HStack {
                            Spacer()
                            if case .connecting = store.phase {
                                ProgressView()
                            } else {
                                Text("Connect").bold()
                            }
                            Spacer()
                        }
                    }
                    .disabled(systemName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("Poolside")
        }
    }

    private func search() async {
        searching = true
        found = await SLDiscovery.search(timeout: 3)
        searching = false
        searched = true
        if found.count == 1, let only = found.first {
            systemName = only.name
            localHost = only.host
        }
    }

    private func signIn() async {
        var login = SavedLogin(systemName: SavedLogin.normalizedName(systemName), mode: mode)
        if let match = found.first(where: { $0.host == localHost }) {
            login.localHost = match.host
            login.localPort = match.port
        } else {
            login.localHost = localHost.trimmingCharacters(in: .whitespaces)
        }
        await store.signIn(login, password: password)
    }
}
