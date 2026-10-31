import SwiftUI

/// Heat controls for one body. The target uses a wheel so 40° to 100° is one flick.
struct HeatSheet: View {
    let which: BodyType
    @Environment(PoolStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var target = 80
    @State private var startingTarget = 80
    @State private var mode: HeatMode = .off
    @State private var ready = false

    var body: some View {
        let reading = store.bodyState(which)

        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: Binding(
                        get: { store.isBodyOn(which) },
                        set: { value in Task { await store.setBody(which, on: value) } }
                    )) {
                        Label("\(which.name) running", systemImage: Theme.icon(for: which))
                    }
                    LabeledContent("Water now", value: "\(reading.temperature)°")
                    if reading.isHeating {
                        Label("Heating", systemImage: "flame.fill").foregroundStyle(.orange)
                    }
                }

                Section("Heat") {
                    Picker("Heat", selection: $mode) {
                        ForEach(store.heatModes) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Target") {
                    Picker("Target", selection: $target) {
                        ForEach(Array(store.setPointRange(which)), id: \.self) { value in
                            Text("\(value)°").tag(value)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(height: 160)
                }
            }
            .navigationTitle(which.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear {
            let range = store.setPointRange(which)
            target = min(max(reading.setPoint, range.lowerBound), range.upperBound)
            startingTarget = target
            mode = reading.mode
            ready = true
        }
        .onChange(of: mode) { _, newMode in
            guard ready, newMode != store.bodyState(which).mode else { return }
            Task { await store.setHeatMode(which, newMode) }
        }
        .onDisappear {
            guard target != startingTarget else { return }
            let value = target
            Task { await store.setSetPoint(which, value) }
        }
    }
}
