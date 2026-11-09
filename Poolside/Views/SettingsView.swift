import SwiftUI
import UIKit

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
                    NavigationLink("Valves") { ValveDebugView() }
                    NavigationLink("Equipment details") { EquipmentDetailsView() }
                } header: {
                    Text("Debug")
                } footer: {
                    Text("Valves shows which side the suction and return should be on, with a guarded Pool/Spa switch. Equipment details lists every circuit and every command Poolside has sent.")
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

/// Read-only view of the controller's circuits and of what Poolside has sent. For tracking down
/// problems like a valve that didn't move: compare what's on after Pentair's app vs. Poolside.
struct EquipmentDetailsView: View {
    @Environment(PoolStore.self) private var store
    @State private var copied = false

    var body: some View {
        List {
            Section {
                ForEach(store.config.circuits) { c in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.name)
                            Text("id \(c.id) · function \(String(describing: c.function)) (\(c.functionCode)) · \(String(describing: c.interface))")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(store.isOn(c) ? "ON" : "off")
                            .font(.caption.monospaced().bold())
                            .foregroundStyle(store.isOn(c) ? .green : .secondary)
                    }
                }
            } header: {
                Text("Circuits")
            } footer: {
                if let last = store.lastUpdate {
                    Text("Updated \(last.formatted(date: .omitted, time: .standard))")
                }
            }

            Section("Commands sent this session") {
                if store.commandLog.isEmpty {
                    Text("None yet").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(store.commandLog.enumerated().reversed()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced())
                    }
                }
            }
        }
        .navigationTitle("Equipment details")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(copied ? "Copied" : "Copy") {
                    UIPasteboard.general.string = report
                    copied = true
                }
            }
        }
    }

    private var report: String {
        var lines = ["Poolside equipment details \(Date().formatted())", "", "Circuits:"]
        for c in store.config.circuits {
            lines.append("\(c.id)  \(c.name)  function=\(c.function)(\(c.functionCode))  interface=\(c.interface)(\(c.interfaceCode))  \(store.isOn(c) ? "ON" : "off")")
        }
        lines.append("")
        lines.append("Commands sent:")
        lines.append(contentsOf: store.commandLog.isEmpty ? ["none"] : store.commandLog)
        return lines.joined(separator: "\n")
    }
}

/// Shows which side the controller should be turning each valve to, so you can check it at the pad.
/// The switch moves between whole modes on purpose: Poolside never turns one valve by hand.
struct ValveDebugView: View {
    @Environment(PoolStore.self) private var store
    @State private var confirmTo: PoolStore.WaterMode?
    @State private var watchUntil: Date?
    @State private var cameFrom: PoolStore.WaterMode = .pool

    var body: some View {
        let expected = store.expectedValves
        let current = store.waterMode
        List {
            Section {
                LabeledContent("Mode", value: expected.mode)
                LabeledContent("Suction", value: expected.suction.rawValue)
                LabeledContent("Return", value: expected.returnSide.rawValue)
                if current == .spillover {
                    LabeledContent("Spillover returns to", value: store.spilloverReturnMode.rawValue)
                }
            } header: {
                Text("Expected now")
            } footer: {
                Text("\(expected.reason) Poolside can't see the valves. These are the sides the controller should turn them to. Check they match at the pad.")
            }

            Section("Controller delays") {
                LabeledContent("Pool delay", value: store.state.poolDelay ? "Active" : "Off")
                LabeledContent("Spa delay", value: store.state.spaDelay ? "Active" : "Off")
            }

            Section {
                if let until = watchUntil {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let left = max(0, Int(until.timeIntervalSince(context.date)))
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Watch both actuators").font(.headline)
                            Text(left > 0
                                 ? "They take about 30 seconds to turn. \(left)s left."
                                 : "Is suction on the \(expected.suction.rawValue.lowercased()) side and return on the \(expected.returnSide.rawValue.lowercased()) side?")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("Both turned") { watchUntil = nil }
                    Button("Switch back to \(cameFrom.rawValue)", role: .destructive) {
                        watchUntil = nil
                        Task { await store.switchMode(to: cameFrom) }
                    }
                } else {
                    ForEach(PoolStore.WaterMode.allCases.filter { $0 != current }) { mode in
                        Button("Switch to \(mode.rawValue)") { confirmTo = mode }
                            .disabled(store.phase != .connected || !available(mode))
                    }
                }
            } header: {
                Text("Switch")
            } footer: {
                Text(switchFooter)
            }
        }
        .navigationTitle("Valves")
        .confirmationDialog(confirmTo.map { "Switch to \($0.rawValue)?" } ?? "",
                            isPresented: Binding(get: { confirmTo != nil }, set: { if !$0 { confirmTo = nil } }),
                            titleVisibility: .visible) {
            if let mode = confirmTo {
                Button("Switch to \(mode.rawValue)") {
                    confirmTo = nil
                    cameFrom = current
                    watchUntil = Date().addingTimeInterval(60)
                    Task { await store.switchMode(to: mode) }
                }
            }
            Button("Cancel", role: .cancel) { confirmTo = nil }
        } message: {
            if let mode = confirmTo {
                Text("Suction should go to the \(mode.suction.rawValue.lowercased()) side and return to the \(mode.returnSide.rawValue.lowercased()) side. Stand where you can see both actuators first.")
            }
        }
    }

    private func available(_ mode: PoolStore.WaterMode) -> Bool {
        switch mode {
        case .spa: return store.circuit(for: .spa) != nil
        case .spillover: return store.spillwayCircuit != nil
        case .pool: return true
        }
    }

    private var switchFooter: String {
        var text = "Pool turns Spa and Spillway off and makes sure Pool is on. Spillover keeps suction on the pool, sends the return to the spa and turns Pool High on. Leaving Spillover turns Pool High back off if Spillover turned it on. Spa turns both valves to the spa. If suction ends up on the spa with the return on the pool, tap Switch back right away."
        if store.spillwayCircuit != nil, store.poolHigh == nil {
            text += "\n\nNo Pool High circuit was found, so Spillover can't raise the pump speed. Set the Spillway circuit's pump speed at the panel instead."
        }
        if store.spillwayCircuit == nil {
            text += "\n\nSpillover is off because no circuit on this controller has the Spillway function. Set one up at the EasyTouch panel or in Pentair's app, then reconnect."
        }
        return text
    }
}
