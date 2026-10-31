import SwiftUI

struct DashboardView: View {
    @Environment(PoolStore.self) private var store
    @State private var heatTarget: BodyType?
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    StatusStrip()

                    if store.hasData {
                        HStack(spacing: 12) {
                            ForEach(store.bodies) { which in
                                BodyTile(which: which) { heatTarget = which }
                            }
                        }

                        if !store.features.isEmpty {
                            SectionHeader(title: "Features")
                            FeatureGrid(circuits: store.features)
                        }

                        if !store.lights.isEmpty {
                            SectionHeader(title: "Lights")
                            LightsSection()
                        }
                    } else {
                        ConnectingPlaceholder()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground))
            .refreshable { await store.refresh() }
            .navigationTitle(store.login?.shortName ?? "Pool")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(item: $heatTarget) { which in
                HeatSheet(which: which)
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }
}

private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .padding(.bottom, -14)
    }
}

/// Connection, freshness and air temperature in one line.
struct StatusStrip: View {
    @Environment(PoolStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                Text(statusText)
                if store.hasData {
                    Text("·")
                    Text("Air \(store.state.airTemperature)°")
                }
                if store.state.freezeMode {
                    Label("Freeze", systemImage: "snowflake").foregroundStyle(.blue)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if case .failed(let message) = store.phase {
                HStack {
                    Text(message).font(.footnote)
                    Spacer()
                    Button("Retry") { Task { await store.connect() } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(12)
                .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }
            if let notice = store.notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var dotColor: Color {
        switch store.phase {
        case .connected: return .green
        case .connecting: return .yellow
        case .failed: return .red
        case .idle: return .gray
        }
    }

    private var statusText: String {
        switch store.phase {
        case .connected:
            return store.link?.label ?? "Connected"
        case .connecting(let step):
            return step
        case .failed:
            return "Offline"
        case .idle:
            return "Paused"
        }
    }
}

private struct ConnectingPlaceholder: View {
    @Environment(PoolStore.self) private var store

    var body: some View {
        VStack(spacing: 16) {
            if case .failed = store.phase {
                Image(systemName: "wifi.exclamationmark").font(.largeTitle)
                Text("Can't reach your pool right now.")
            } else {
                ProgressView()
                Text("Getting your pool…")
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 240)
    }
}

/// Pool or spa: big water temp, heating flame, tap for heat controls.
struct BodyTile: View {
    let which: BodyType
    let onTap: () -> Void
    @Environment(PoolStore.self) private var store

    var body: some View {
        let reading = store.bodyState(which)
        let on = store.isBodyOn(which)

        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: Theme.icon(for: which))
                    Text(which.name).font(.headline)
                    Spacer()
                    if reading.isHeating {
                        Image(systemName: "flame.fill").symbolEffect(.pulse)
                    }
                }
                Text("\(reading.temperature)°")
                    .font(.system(size: 54, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .opacity(on ? 1 : 0.55)
                Text(caption(reading, on: on))
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .opacity(0.85)
            }
            .foregroundStyle(on ? Color.white : Color.primary)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? AnyShapeStyle(Theme.gradient(for: which)) : AnyShapeStyle(Theme.tile),
                        in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(which.name), \(reading.temperature) degrees, \(on ? "on" : "off")")
        .accessibilityHint("Opens heat controls")
    }

    private func caption(_ reading: BodyState, on: Bool) -> String {
        let heat = reading.mode == .off ? "Heat off" : "Heat to \(reading.setPoint)°"
        return on ? heat : "Off · \(heat.lowercased())"
    }
}

/// Control Center style toggles for every auxiliary circuit.
struct FeatureGrid: View {
    let circuits: [Circuit]
    @Environment(PoolStore.self) private var store
    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(circuits) { circuit in
                CircuitTile(circuit: circuit)
            }
        }
    }
}

struct CircuitTile: View {
    let circuit: Circuit
    @Environment(PoolStore.self) private var store

    var body: some View {
        let on = store.isOn(circuit)
        Button {
            Task { await store.toggle(circuit) }
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: Theme.icon(for: circuit))
                    .font(.title3)
                    .frame(width: 36, height: 36)
                    .background(on ? Color.white.opacity(0.25) : Color.secondary.opacity(0.15), in: Circle())
                Text(circuit.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(on ? "On" : "Off")
                    .font(.caption)
                    .opacity(0.8)
            }
            .foregroundStyle(on ? Color.white : Color.primary)
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
            .background(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Theme.tile),
                        in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if store.busy.contains(circuit.id) {
                    ProgressView().padding(10)
                }
            }
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: on)
        .accessibilityLabel(circuit.name)
        .accessibilityValue(on ? "On" : "Off")
    }
}

struct LightsSection: View {
    @Environment(PoolStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Button {
                    Task { await store.sendLights(.on) }
                } label: {
                    Label("All on", systemImage: "lightbulb.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    Task { await store.sendLights(.off) }
                } label: {
                    Label("All off", systemImage: "lightbulb.slash").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)

            if store.hasColorLights {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(LightScene.pickable) { scene in
                            Button {
                                Task { await store.sendLights(scene) }
                            } label: {
                                HStack(spacing: 6) {
                                    Circle().fill(Theme.color(for: scene)).frame(width: 10, height: 10)
                                    Text(scene.name).font(.subheadline.weight(.medium))
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(Theme.tile, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            FeatureGrid(circuits: store.lights)
        }
    }
}
