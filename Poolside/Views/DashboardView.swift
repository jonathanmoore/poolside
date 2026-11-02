import SwiftUI

enum PoolTab: String, CaseIterable, Identifiable {
    case pool, spa, lights
    var id: String { rawValue }

    var title: String {
        switch self {
        case .pool: return "Pool"
        case .spa: return "Spa"
        case .lights: return "Lights"
        }
    }

    var icon: String {
        switch self {
        case .pool: return "figure.pool.swim"
        case .spa: return "water.waves"
        case .lights: return "lightbulb.fill"
        }
    }

}

enum Palette {
    static let blue = Color(red: 0.0, green: 0.55, blue: 0.9)
    static let warm = Color(red: 0.95, green: 0.42, blue: 0.22)
    static let fire = Color(red: 0.88, green: 0.16, blue: 0.14)

    static let coolDial = [Color(red: 0.3, green: 0.8, blue: 1), Color(red: 0.0, green: 0.55, blue: 0.95),
                           Color(red: 0.2, green: 0.35, blue: 0.95)]
    static let warmDial = [Color.yellow, .orange, Color(red: 1, green: 0.35, blue: 0.3), Color(red: 1, green: 0.2, blue: 0.5)]

    /// System background with a faint wash at the top: blue, or the warm glow while heating.
    static func background(warm: Bool) -> some View {
        let wash = warm ? Palette.warm : Palette.blue
        return ZStack {
            Color(.systemGroupedBackground)
            LinearGradient(colors: [wash.opacity(0.24), wash.opacity(0.0)],
                           startPoint: .top, endPoint: .center)
        }
    }
}

/// SF Symbols fill their space unevenly (the swimmer is wide and short, the waves tall and heavy).
/// This draws each one into the same box, scaled to cover the same area at the same weight,
/// so the three tab icons look balanced.
enum TabIcon {
    private static let box = CGSize(width: 34, height: 28)
    private static let area: CGFloat = 30 * 22
    /// Optical touch-ups: dense shapes look bigger than sparse ones of the same size.
    private static let weight: [String: CGFloat] = ["water.waves": 0.88, "lightbulb.fill": 1.05,
                                                    "lightbulb.max.fill": 1.15]

    private static var cache: [String: Image] = [:]

    /// Cached so redraws hand the tab bar the same image; a new one makes the tabs rebuild.
    static func image(_ name: String) -> Image {
        if let hit = cache[name] { return hit }
        let made = draw(name)
        cache[name] = made
        return made
    }

    private static func draw(_ name: String) -> Image {
        let probe = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        guard let base = UIImage(systemName: name, withConfiguration: probe) else {
            return Image(systemName: name)
        }
        let size = base.size
        let target = area * (weight[name] ?? 1)
        let scale = min(sqrt(target / (size.width * size.height)), box.width / size.width, box.height / size.height)
        let config = UIImage.SymbolConfiguration(pointSize: 20 * scale, weight: .semibold)
        let symbol = UIImage(systemName: name, withConfiguration: config) ?? base
        let drawn = UIGraphicsImageRenderer(size: box).image { _ in
            let s = symbol.size
            symbol.draw(in: CGRect(x: (box.width - s.width) / 2, y: (box.height - s.height) / 2,
                                   width: s.width, height: s.height))
        }
        return Image(uiImage: drawn.withRenderingMode(.alwaysTemplate))
    }
}

/// Three tabs, Pool, Spa and Lights, behind a glass tab bar.
struct DashboardView: View {
    @AppStorage("tab") private var tab: PoolTab = .pool
    @Environment(PoolStore.self) private var store
    /// Lives here, above the tabs, so a tab rebuilding can't tear down the open sheet.
    @State private var showSettings = false

    /// The Lights tab shows a glowing bulb while any light is on.
    private func icon(for which: PoolTab) -> String {
        which == .lights && store.lights.contains(where: store.isOn) ? "lightbulb.max.fill" : which.icon
    }

    var body: some View {
        TabView(selection: $tab) {
            ForEach(PoolTab.allCases) { which in
                TabScreen(tab: which, onSettings: { showSettings = true })
                    .tabItem { TabIcon.image(icon(for: which)).accessibilityLabel(which.title) }
                    .tag(which)
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }
}

/// One tab: gradient background, title, status, then the tab's controls.
private struct TabScreen: View {
    let tab: PoolTab
    var onSettings: () -> Void = {}
    @Environment(PoolStore.self) private var store
    @State private var showSchedule = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        header
                        StatusStrip()
                    }
                    if store.hasData {
                        switch tab {
                        case .pool: BodyControls(which: .pool)
                        case .spa: BodyControls(which: .spa)
                        case .lights: LightsControls()
                        }
                    } else {
                        ConnectingPlaceholder()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background { Palette.background(warm: isWarm).ignoresSafeArea() }
            .animation(.easeInOut(duration: 0.6), value: isWarm)
            .refreshable { await store.refresh() }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showSchedule) { ScheduleView() }
            #if DEBUG
            .onAppear {
                if ProcessInfo.processInfo.arguments.contains("-openSchedule") { showSchedule = true }
            }
            #endif
        }
    }

    /// Pool and spa glow warm only while their heater is actually running. Lights stays blue.
    private var isWarm: Bool {
        switch tab {
        case .pool: return store.bodyState(.pool).isHeating
        case .spa: return store.bodyState(.spa).isHeating
        case .lights: return false
        }
    }

    /// Title on the left, schedule and settings in one glass capsule on the right.
    private var header: some View {
        HStack(alignment: .center) {
            Text(tab.title)
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            Spacer()
            HStack(spacing: 0) {
                Button { showSchedule = true } label: {
                    Image(systemName: "calendar.badge.clock")
                        .frame(width: 48, height: 44)
                }
                .disabled(!store.hasData)
                .accessibilityLabel("Schedule")
                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                        .frame(width: 48, height: 44)
                }
                .accessibilityLabel("Settings")
            }
            .font(.title3)
            .foregroundStyle(.primary)
            .buttonStyle(.plain)
            .padding(.horizontal, 4)
            .glassTile(cornerRadius: 22)
        }
        .padding(.top, 8)
    }
}

/// Pool or spa: the temperature dial, then the body's switches.
private struct BodyControls: View {
    let which: BodyType
    @Environment(PoolStore.self) private var store


    /// Pool gets the spillway and high speed; the spa gets the air blower.
    private var extras: [Circuit] {
        which == .pool
            ? [store.spillway, store.poolHigh].compactMap { $0 }
            : [store.airBlower].compactMap { $0 }
    }

    var body: some View {
        let reading = store.bodyState(which)
        let heatOn = reading.mode != .off
        let heating = reading.isHeating
        let tint = heating ? Palette.warm : Palette.blue

        VStack(spacing: 20) {
            TempDial(range: store.setPointRange(which), target: reading.setPoint,
                     water: reading.temperature, isHeating: reading.isHeating, heatOn: heatOn,
                     colors: heating ? Palette.warmDial : Palette.coolDial) { value in
                Task { await store.setSetPoint(which, value) }
            }
            .frame(maxWidth: 340)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
            .padding(.bottom, -36) // tuck the buttons into the gap under the dial

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                      spacing: 12) {
                if let circuit = store.circuit(for: which) {
                    ControlButton(title: which.name, systemImage: Theme.icon(for: which),
                                  isOn: store.isOn(circuit), detail: store.isOn(circuit) ? "Running" : "Off",
                                  tint: tint, isBusy: store.busy.contains(circuit.id)) {
                        Task { await store.toggle(circuit) }
                    }
                }
                ControlButton(title: "Heater", systemImage: "flame.fill", isOn: heatOn,
                              detail: heatOn ? (heating ? "Heating" : "On · ready") : "Off",
                              tint: heating ? Palette.warm : Palette.blue) {
                    Task { await store.setHeatMode(which, heatOn ? .off : .heater) }
                }
                ForEach(extras) { circuit in
                    ControlButton(title: circuit.name, systemImage: Theme.icon(for: circuit),
                                  isOn: store.isOn(circuit), tint: tint,
                                  isBusy: store.busy.contains(circuit.id)) {
                        Task { await store.toggle(circuit) }
                    }
                }
            }
        }
    }
}

/// Lights tab: each light, then the fire pit, in one 2x2 grid.
private struct LightsControls: View {
    @Environment(PoolStore.self) private var store
    @State private var colorFor: Circuit?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                  spacing: 12) {
            ForEach(store.lights) { light in
                let canColor = store.isColorLight(light)
                ControlButton(title: light.name, systemImage: store.isOn(light) ? "lightbulb.max.fill" : "lightbulb",
                              isOn: store.isOn(light), tint: Palette.blue,
                              swatch: canColor ? store.lightColor(light) : nil,
                              showsSwatch: canColor,
                              isBusy: store.busy.contains(light.id),
                              onLongPress: canColor ? { colorFor = light } : nil) {
                    Task { await store.toggle(light) }
                }
            }
            if let firePit = store.firePit {
                ControlButton(title: firePit.name, systemImage: "flame.fill", isOn: store.isOn(firePit),
                              tint: Palette.fire, isBusy: store.busy.contains(firePit.id)) {
                    Task { await store.toggle(firePit) }
                }
            }
        }
        }
        .sheet(item: $colorFor) { light in
            LightColorCard(light: light)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }
}

/// Color choices for a color light. The controller sets every color light at once.
private struct LightColorCard: View {
    let light: Circuit
    @Environment(PoolStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private let solids: [LightScene] = [.white, .blue, .green, .red, .purple]
    private let shows: [LightScene] = [.party, .romance, .caribbean, .american, .sunset, .royal]
    private let columns = [GridItem(.adaptive(minimum: 72), spacing: 12)]

    var body: some View {
        let others = store.config.circuits.filter { store.isColorLight($0) && $0.id != light.id }.map(\.name)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(light.name) color").font(.title2.bold())
                    if !others.isEmpty {
                        Text("Your controller changes all color lights together, so \(others.joined(separator: " and ")) will match.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                section("Colors", solids)
                section("Shows", shows)
            }
            .padding(20)
        }
    }

    private func section(_ title: String, _ scenes: [LightScene]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(scenes) { scene in
                    let selected = store.lightColor(light) == scene
                    Button {
                        Task { await store.setLightColor(scene) }
                        dismiss()
                    } label: {
                        VStack(spacing: 6) {
                            LightSwatch(scene: scene, size: 44)
                                .overlay {
                                    Circle().stroke(Color.primary, lineWidth: selected ? 3 : 0).padding(-5)
                                }
                            Text(scene.name)
                                .font(.caption)
                                .foregroundStyle(.primary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }
}

/// A round color chip. Shows are drawn as a ring of their colors.
struct LightSwatch: View {
    let scene: LightScene
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let ring = Theme.showColors(for: scene) {
                Circle().fill(AngularGradient(colors: ring + [ring[0]], center: .center))
            } else {
                Circle().fill(Theme.color(for: scene))
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 1))
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
                    Label("Freeze", systemImage: "snowflake").foregroundStyle(.cyan)
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
                .background(Color.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
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
        case .connected: return store.link?.label ?? "Connected"
        case .connecting(let step): return step
        case .failed: return "Offline"
        case .idle: return "Paused"
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
        .frame(maxWidth: .infinity, minHeight: 300)
    }
}

#if DEBUG
#Preview("Light") {
    DashboardView().environment(PoolStore.preview)
}

#Preview("Dark") {
    DashboardView().environment(PoolStore.preview).preferredColorScheme(.dark)
}

#Preview("Lights") {
    TabScreenPreview(tab: .lights)
}

private struct TabScreenPreview: View {
    let tab: PoolTab
    var body: some View {
        TabScreen(tab: tab)
            .environment(PoolStore.preview)
    }
}
#endif
