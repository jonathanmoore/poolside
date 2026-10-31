import Foundation
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

    @ObservationIgnored private var client: ScreenLogicClient?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var isConnecting = false

    init() {
        login = LoginStore.load()
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
        guard let login, !isConnecting else { return }
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

        if login.mode != .remote {
            phase = .connecting("Looking on your WiFi…")
            if !login.localHost.isEmpty {
                do {
                    let c = try await ScreenLogicClient.connect(host: login.localHost, port: login.localPort,
                                                                password: password, timeout: 3)
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
                                                                password: password, timeout: 4)
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

    var lights: [Circuit] {
        config.circuits.filter { $0.isLight && $0.interface != .hidden && $0.interface != .invalid }
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

    // MARK: - Commands

    func toggle(_ circuit: Circuit) async {
        await setCircuit(circuit, on: !isOn(circuit))
    }

    func setCircuit(_ circuit: Circuit, on: Bool) async {
        guard let client else { return }
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
        state.bodies[body.rawValue].heatMode = mode.rawValue
        await run { try await client.setHeatMode(body, to: mode) }
    }

    func setSetPoint(_ body: BodyType, _ value: Int) async {
        guard let client else { return }
        state.bodies[body.rawValue].setPoint = value
        await run { try await client.setSetPoint(body, to: value) }
    }

    func sendLights(_ scene: LightScene) async {
        guard let client else { return }
        await run { try await client.sendLights(scene) }
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
