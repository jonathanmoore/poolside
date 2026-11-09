import Foundation
import Network
import Observation

enum LinkKind {
    case local, remote
    var label: String { self == .local ? "Home WiFi" : "Remote" }
}

@MainActor
@Observable
final class PoolStore {
    enum Phase: Equatable {
        case idle
        case connecting(String)
        case connected
        case failed(String)
    }

    var login: SavedLogin?
    var phase: Phase = .idle
    var link: LinkKind?
    var config = ControllerConfig()
    var state = EquipmentState()
    var hasData = false
    var lastUpdate: Date?
    var busy: Set<Int> = []
    var notice: String?
    /// Last color picked per light id. The controller doesn't report it, so the app remembers.
    var lightColors: [Int: LightScene] = PoolStore.loadLightColors()
    var schedules: [Schedule] = []
    /// Every command sent this session, newest last. Shown in Settings > Equipment details.
    var commandLog: [String] = []
    var schedulesLoaded = false

    /// Sample data only: never connect. Set by the debug preview store.
    @ObservationIgnored var isDemo = false
    @ObservationIgnored private var client: ScreenLogicClient?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var isConnecting = false
    /// Which network the phone is on. Tells us when it leaves or joins WiFi.
    private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var path: NWPath?

    init() {
        login = LoginStore.load()
        pathMonitor.pathUpdateHandler = { [weak self] newPath in
            Task { @MainActor in self?.pathChanged(newPath) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "poolside.path"))
    }

    // MARK: - Session

    func signIn(_ newLogin: SavedLogin, password: String) async {
        LoginStore.save(newLogin)
        LoginStore.setPassword(password)
        login = newLogin
        hasData = false
        await connect()
    }

    func signOut() {
        disconnect()
        LoginStore.clear()
        login = nil
        hasData = false
        config = ControllerConfig()
        state = EquipmentState()
        schedules = []
        schedulesLoaded = false
        phase = .idle
    }

    func updateMode(_ mode: ConnectionMode) async {
        guard var current = login, current.mode != mode else { return }
        current.mode = mode
        login = current
        LoginStore.save(current)
        await connect()
    }

    func updateLocalAddress(_ host: String, port: UInt16) async {
        guard var current = login else { return }
        current.localHost = host.trimmingCharacters(in: .whitespaces)
        current.localPort = port
        login = current
        LoginStore.save(current)
        await connect()
    }

    /// App came to the foreground.
    func resume() {
        guard login != nil, client == nil, !isConnecting else { return }
        Task { await connect() }
    }

    /// App went to the background. The gateway only handles a few clients, so let go.
    func suspend() {
        disconnect()
        phase = .idle
    }

    func connect() async {
        guard let login, !isConnecting, !isDemo else { return }
        isConnecting = true
        defer { isConnecting = false }
        disconnect()
        phase = .connecting("Connecting…")
        do {
            let (newClient, kind) = try await openClient(login, password: LoginStore.password())
            phase = .connecting("Loading your equipment…")
            config = try await newClient.controllerConfig()
            state = try await newClient.equipmentState()
            client = newClient
            link = kind
            hasData = true
            lastUpdate = Date()
            phase = .connected
            newClient.connection.onClose = { [weak self] _ in
                Task { @MainActor in self?.connectionDropped() }
            }
            startPolling()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func openClient(_ login: SavedLogin, password: String?) async throws -> (ScreenLogicClient, LinkKind) {
        var localError: Error?
        let network = await currentPath()

        if let network, network.status != .satisfied, network.unsatisfiedReason == .cellularDenied {
            throw SLError.cellularOff
        }
        // Unknown counts as WiFi so a slow first reading never skips home.
        let onWiFi = network.map { $0.usesInterfaceType(.wifi) || $0.usesInterfaceType(.wiredEthernet) } ?? true
        if login.mode == .local && !onWiFi { throw SLError.notOnWiFi }

        // Away from home there's no point looking on the local network. Go straight to Pentair.
        if login.mode != .remote && onWiFi {
            phase = .connecting("Looking on your WiFi…")
            if !login.localHost.isEmpty {
                do {
                    let c = try await ScreenLogicClient.connect(host: login.localHost, port: login.localPort,
                                                                password: password, timeout: 3, localOnly: true)
                    return (c, .local)
                } catch {
                    localError = error
                }
            }
            let found = await SLDiscovery.search()
            let match = found.first(where: { $0.name.caseInsensitiveCompare(login.systemName) == .orderedSame })
                ?? (found.count == 1 ? found.first : nil)
            if let gateway = match, gateway.host != login.localHost || localError == nil {
                do {
                    let c = try await ScreenLogicClient.connect(host: gateway.host, port: gateway.port,
                                                                password: password, timeout: 4, localOnly: true)
                    rememberLocal(gateway)
                    return (c, .local)
                } catch {
                    localError = error
                }
            }
        }

        if login.mode != .local {
            phase = .connecting("Connecting through Pentair…")
            let remote = try await SLDispatcher.locate(systemName: login.systemName)
            guard remote.found, !remote.host.isEmpty else { throw SLError.remoteUnavailable }
            let c = try await ScreenLogicClient.connect(host: remote.host, port: remote.port,
                                                        password: password, timeout: 8)
            return (c, .remote)
        }

        throw localError ?? SLError.notFound
    }

    /// The monitor reports within a moment of starting. Don't hold up a connect for long if it hasn't.
    private func currentPath() async -> NWPath? {
        for _ in 0..<10 where path == nil {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return path
    }

    private func pathChanged(_ newPath: NWPath) {
        let old = path
        path = newPath
        guard let old, login != nil, !isDemo else { return }
        func wifi(_ p: NWPath) -> Bool {
            p.status == .satisfied && (p.usesInterfaceType(.wifi) || p.usesInterfaceType(.wiredEthernet))
        }
        let cameOnline = old.status != .satisfied && newPath.status == .satisfied
        let leftWiFi = wifi(old) && !wifi(newPath)
        let joinedWiFi = !wifi(old) && wifi(newPath)

        switch phase {
        case .failed:
            // Back online, or on a different kind of network: worth another try.
            if cameOnline || leftWiFi || joinedWiFi { Task { await connect() } }
        case .connected:
            if link == .local && leftWiFi {
                // Walked out of WiFi range. The home connection can hang for a while before it
                // notices, so switch to Pentair's server now.
                Task { await connect() }
            } else if link == .remote && joinedWiFi && login?.mode == .auto {
                // Got home. The local link is faster and doesn't depend on Pentair.
                Task { await connect() }
            }
        default:
            break
        }
    }

    private func rememberLocal(_ gateway: LocalGateway) {
        guard var current = login else { return }
        current.localHost = gateway.host
        current.localPort = gateway.port
        login = current
        LoginStore.save(current)
    }

    private func disconnect() {
        pollTask?.cancel()
        pollTask = nil
        client?.connection.onClose = nil
        client?.close()
        client = nil
        link = nil
    }

    private func connectionDropped() {
        guard client != nil else { return }
        disconnect()
        phase = .failed("Lost the connection to your pool.")
        Task { await connect() }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled, let self else { return }
                await self.refresh()
            }
        }
    }

    func refresh() async {
        guard let client else {
            await connect()
            return
        }
        do {
            state = try await client.equipmentState()
            lastUpdate = Date()
        } catch {
            connectionDropped()
        }
    }

    // MARK: - Equipment

    func circuit(for body: BodyType) -> Circuit? {
        let wanted: CircuitFunction = body == .pool ? .pool : .spa
        return config.circuits.first { $0.function == wanted }
    }

    func isOn(_ circuit: Circuit) -> Bool { state.circuitOn[circuit.id] ?? false }

    func isBodyOn(_ body: BodyType) -> Bool {
        guard let c = circuit(for: body) else { return false }
        return isOn(c)
    }

    func bodyState(_ body: BodyType) -> BodyState { state.bodies[body.rawValue] }

    var bodies: [BodyType] {
        BodyType.allCases.filter { circuit(for: $0) != nil || $0 == .pool }
    }

    var features: [Circuit] {
        config.circuits.filter { c in
            !c.isBody && !c.isLight && [.pool, .spa, .features].contains(c.interface)
        }
    }

    private func named(_ words: String...) -> Circuit? {
        config.circuits.first { c in
            let name = c.name.lowercased()
            return words.contains { name.contains($0) }
        }
    }

    var spillway: Circuit? {
        config.circuits.first { $0.function == .spillway } ?? named("spill")
    }
    var poolHigh: Circuit? { named("pool high", "high speed") }
    var airBlower: Circuit? { named("blower") }
    var fountains: Circuit? { named("fountain", "water feature") }
    var firePit: Circuit? { named("fire") }

    var lights: [Circuit] {
        config.circuits.filter { $0.isLight && $0.interface != .hidden && $0.interface != .invalid }
    }

    func isColorLight(_ c: Circuit) -> Bool {
        [.intelliBrite, .magicStream, .samLight, .salLight, .colorWheel, .photonGen].contains(c.function)
    }

    func lightColor(_ c: Circuit) -> LightScene? { lightColors[c.id] }

    /// Sends a color or show. The controller applies it to every color light, so all of them remember it.
    func setLightColor(_ scene: LightScene) async {
        for light in config.circuits where isColorLight(light) {
            lightColors[light.id] = scene
        }
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: lightColors.map { (String($0.key), $0.value.rawValue) }),
                                  forKey: "lightColors")
        await sendLights(scene)
    }

    private static func loadLightColors() -> [Int: LightScene] {
        let raw = UserDefaults.standard.dictionary(forKey: "lightColors") as? [String: Int] ?? [:]
        var out: [Int: LightScene] = [:]
        for (key, value) in raw {
            if let id = Int(key), let scene = LightScene(rawValue: value) { out[id] = scene }
        }
        return out
    }

    var hasColorLights: Bool {
        config.hasIntelliBrite || lights.contains { [.intelliBrite, .magicStream, .samLight, .salLight, .colorWheel, .photonGen].contains($0.function) }
    }

    var heatModes: [HeatMode] {
        config.hasSolar ? HeatMode.allCases : [.off, .heater]
    }

    func setPointRange(_ body: BodyType) -> ClosedRange<Int> {
        let low = config.minSetPoint[body.rawValue]
        let high = config.maxSetPoint[body.rawValue]
        if low > 0, high > low { return low...high }
        return config.isCelsius ? 4...40 : 40...104
    }

    // MARK: - Valves

    /// Where the controller should be turning the suction and return valves right now.
    /// ScreenLogic can't read valve positions, so this is worked out from the circuits.
    struct ValveExpectation: Equatable {
        enum Side: String { case pool = "Pool", spa = "Spa" }
        let mode: String
        let suction: Side
        let returnSide: Side
        let reason: String
    }

    enum WaterMode: String, CaseIterable, Identifiable {
        case pool = "Pool", spillover = "Spillover", spa = "Spa"
        var id: String { rawValue }
        var suction: ValveExpectation.Side { self == .spa ? .spa : .pool }
        var returnSide: ValveExpectation.Side { self == .pool ? .pool : .spa }
    }

    /// The circuit set to the Spillway function at the panel. Only this one tells the
    /// controller to turn the return valve to the spa while suction stays on the pool.
    /// A circuit that's only named "spillway" doesn't move any valve.
    var spillwayCircuit: Circuit? {
        config.circuits.first { $0.function == .spillway }
    }

    var waterMode: WaterMode {
        if let spa = circuit(for: .spa), isOn(spa) { return .spa }
        if let spill = spillwayCircuit, isOn(spill) { return .spillover }
        return .pool
    }

    var expectedValves: ValveExpectation {
        let mode = waterMode
        let reason: String
        switch mode {
        case .spa: reason = "The Spa circuit is on."
        case .spillover: reason = "The Spillway circuit is on, so water comes from the pool and returns to the spa to spill over."
        case .pool: reason = "Spa and Spillway are off."
        }
        return .init(mode: mode.rawValue, suction: mode.suction, returnSide: mode.returnSide, reason: reason)
    }

    /// Moves between Pool, Spillover and Spa. Each step leaves suction on the pool or both
    /// valves together, so it never sends suction to the spa with the return on the pool.
    func switchMode(to mode: WaterMode) async {
        let spa = circuit(for: .spa)
        let pool = circuit(for: .pool)
        let spill = spillwayCircuit
        switch mode {
        case .spa:
            if let spill, isOn(spill) { await setCircuit(spill, on: false) }
            if let spa { await setCircuit(spa, on: true) }
        case .spillover:
            guard let spill else { return }
            if let spa, isOn(spa) { await setCircuit(spa, on: false) }
            if let pool, !isOn(pool) { await setCircuit(pool, on: true) }
            await setCircuit(spill, on: true)
        case .pool:
            if let spill, isOn(spill) { await setCircuit(spill, on: false) }
            if let spa, isOn(spa) { await setCircuit(spa, on: false) }
            if let pool, !isOn(pool) { await setCircuit(pool, on: true) }
        }
    }

    // MARK: - Commands

    func toggle(_ circuit: Circuit) async {
        await setCircuit(circuit, on: !isOn(circuit))
    }

    func setCircuit(_ circuit: Circuit, on: Bool) async {
        guard let client else { return }
        log("Circuit \(circuit.id) \"\(circuit.name)\" (\(circuit.function)) \(on ? "ON" : "OFF")")
        state.circuitOn[circuit.id] = on
        busy.insert(circuit.id)
        defer { busy.remove(circuit.id) }
        await run { try await client.setCircuit(circuit.id, on: on) }
    }

    func setBody(_ body: BodyType, on: Bool) async {
        guard let c = circuit(for: body) else { return }
        await setCircuit(c, on: on)
    }

    func setHeatMode(_ body: BodyType, _ mode: HeatMode) async {
        guard let client else { return }
        log("Heat mode \(body.name) to \(mode.name)")
        state.bodies[body.rawValue].heatMode = mode.rawValue
        await run { try await client.setHeatMode(body, to: mode) }
    }

    func setSetPoint(_ body: BodyType, _ value: Int) async {
        guard let client else { return }
        log("Set point \(body.name) to \(value)")
        state.bodies[body.rawValue].setPoint = value
        await run { try await client.setSetPoint(body, to: value) }
    }

    func sendLights(_ scene: LightScene) async {
        guard let client else { return }
        log("Light scene \(scene.rawValue)")
        await run { try await client.sendLights(scene) }
    }

    // MARK: - Schedules

    /// Circuits a schedule can switch: everything the official app would show.
    var schedulableCircuits: [Circuit] {
        config.circuits.filter { $0.interface != .hidden && $0.interface != .invalid }
    }

    func circuitName(_ id: Int) -> String {
        config.circuits.first { $0.id == id }?.name ?? "Circuit \(id)"
    }

    func loadSchedules() async {
        guard let client else { return }
        do {
            let recurring = try await client.schedules(.recurring)
            let once = try await client.schedules(.runOnce)
            schedules = (recurring + once).sorted {
                ($0.startMinutes, circuitName($0.circuitId)) < ($1.startMinutes, circuitName($1.circuitId))
            }
            schedulesLoaded = true
            notice = nil
        } catch {
            notice = error.localizedDescription
        }
    }

    /// Saves an edit, or adds the schedule when `isNew`. Throws so the editor can stay open on failure.
    func saveSchedule(_ schedule: Schedule, isNew: Bool) async throws {
        guard let client else { throw SLError.closed }
        log("\(isNew ? "Add" : "Save") schedule for circuit \(schedule.circuitId) \"\(circuitName(schedule.circuitId))\"")
        var toSave = schedule
        if isNew {
            toSave.id = try await client.addSchedule(schedule.kind)
            do {
                try await client.setSchedule(toSave)
            } catch {
                // Don't leave an empty slot behind on the controller.
                try? await client.deleteSchedule(id: toSave.id)
                throw error
            }
        } else {
            try await client.setSchedule(toSave)
        }
        await loadSchedules()
    }

    func deleteSchedule(_ schedule: Schedule) async {
        guard let client else { return }
        log("Delete schedule \(schedule.id)")
        schedules.removeAll { $0.id == schedule.id }
        do {
            try await client.deleteSchedule(id: schedule.id)
            notice = nil
        } catch {
            notice = error.localizedDescription
        }
        await loadSchedules()
    }

    private func log(_ line: String) {
        let time = Date().formatted(date: .omitted, time: .standard)
        commandLog.append("\(time)  \(line)")
        if commandLog.count > 200 { commandLog.removeFirst(commandLog.count - 200) }
    }

    private func run(_ command: @escaping () async throws -> Void) async {
        do {
            try await command()
            notice = nil
        } catch {
            notice = error.localizedDescription
        }
        await refresh()
    }
}
