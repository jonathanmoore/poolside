import Foundation
import Network

enum SLError: LocalizedError {
    case timeout(String)
    case connectionFailed(String)
    case loginFailed
    case rejected(UInt16)
    case notFound
    case remoteUnavailable
    case closed

    var errorDescription: String? {
        switch self {
        case .timeout(let what): return "Timed out waiting for \(what)."
        case .connectionFailed(let why): return "Couldn't connect: \(why)"
        case .loginFailed: return "The pool controller turned down the password."
        case .rejected(let code): return "The pool controller rejected that command (\(code))."
        case .notFound: return "Couldn't find your pool controller."
        case .remoteUnavailable: return "Pentair's server doesn't know this system, or remote access is off."
        case .closed: return "The connection closed."
        }
    }
}

/// One TCP connection to a ScreenLogic gateway (or Pentair's dispatcher).
/// All state lives on `queue`; NWConnection delivers its callbacks there too.
final class SLConnection: @unchecked Sendable {
    private struct Pending {
        let token: UUID
        let accepts: Set<UInt16>
        let continuation: CheckedContinuation<SLMessage, Error>
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "poolside.connection")
    private var buffer = Data()
    private var pending: [Pending] = []
    private var isClosed = false

    /// Called on the connection queue when the gateway pushes a status change.
    var onPush: ((SLMessage) -> Void)?
    /// Called on the connection queue once, when the connection drops.
    var onClose: ((Error?) -> Void)?

    init(host: String, port: UInt16) {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.connectionTimeout = 8
        let params = NWParameters(tls: nil, tcp: tcp)
        connection = NWConnection(host: NWEndpoint.Host(host),
                                  port: NWEndpoint.Port(rawValue: port) ?? 80,
                                  using: params)
    }

    func open(timeout: TimeInterval) async throws {
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                var resumed = false
                let finish: (Result<Void, Error>) -> Void = { result in
                    guard !resumed else { return }
                    resumed = true
                    cont.resume(with: result)
                }
                connection.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        finish(.success(()))
                        self?.receiveLoop()
                    case .waiting(let error):
                        finish(.failure(SLError.connectionFailed(error.localizedDescription)))
                    case .failed(let error):
                        finish(.failure(SLError.connectionFailed(error.localizedDescription)))
                        self?.handleClosed(error)
                    case .cancelled:
                        finish(.failure(SLError.closed))
                        self?.handleClosed(nil)
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) {
                    finish(.failure(SLError.timeout("the pool controller")))
                }
            }
        } catch {
            close()
            throw error
        }
    }

    func close() {
        queue.async { self.connection.cancel() }
    }

    func sendRaw(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: SLError.connectionFailed(error.localizedDescription))
                } else {
                    cont.resume()
                }
            })
        }
    }

    /// Sends a message and waits for the reply. The reply id defaults to `id + 1`.
    func request(_ id: UInt16, _ payload: Data = Data(), expect: Set<UInt16>? = nil,
                 timeout: TimeInterval = 8) async throws -> SLMessage {
        let accepts = expect ?? [id &+ 1]
        let token = UUID()
        let bytes = SLMessage(id: id, payload: payload).encoded()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<SLMessage, Error>) in
            queue.async {
                if self.isClosed {
                    cont.resume(throwing: SLError.closed)
                    return
                }
                self.pending.append(Pending(token: token, accepts: accepts, continuation: cont))
                self.connection.send(content: bytes, completion: .contentProcessed { error in
                    if let error {
                        self.fail(token, SLError.connectionFailed(error.localizedDescription))
                    }
                })
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    self.fail(token, SLError.timeout("message \(id)"))
                }
            }
        }
    }

    // MARK: - Queue-only helpers

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                while let message = SLMessage.take(from: &self.buffer) {
                    self.dispatch(message)
                }
            }
            if let error {
                self.handleClosed(error)
            } else if isComplete {
                self.handleClosed(nil)
            } else {
                self.receiveLoop()
            }
        }
    }

    private func dispatch(_ message: SLMessage) {
        if let index = pending.firstIndex(where: { $0.accepts.contains(message.messageId) }) {
            pending.remove(at: index).continuation.resume(returning: message)
            return
        }
        switch message.messageId {
        case SLCode.loginFailure, SLCode.unknownCommand, SLCode.badParameter:
            guard !pending.isEmpty else { return }
            let error: SLError = message.messageId == SLCode.loginFailure
                ? .loginFailed : .rejected(message.messageId)
            pending.removeFirst().continuation.resume(throwing: error)
        case SLCode.statusChanged, SLCode.scheduleChanged:
            onPush?(message)
        default:
            break
        }
    }

    private func fail(_ token: UUID, _ error: Error) {
        guard let index = pending.firstIndex(where: { $0.token == token }) else { return }
        pending.remove(at: index).continuation.resume(throwing: error)
    }

    private func handleClosed(_ error: Error?) {
        guard !isClosed else { return }
        isClosed = true
        let waiting = pending
        pending.removeAll()
        waiting.forEach { $0.continuation.resume(throwing: SLError.closed) }
        onClose?(error)
        connection.cancel()
    }
}

/// A logged-in session with a ScreenLogic gateway.
final class ScreenLogicClient: @unchecked Sendable {
    let connection: SLConnection
    private(set) var challenge = ""

    private init(connection: SLConnection) {
        self.connection = connection
    }

    static func connect(host: String, port: UInt16, password: String?,
                        timeout: TimeInterval = 6) async throws -> ScreenLogicClient {
        let connection = SLConnection(host: host, port: port)
        try await connection.open(timeout: timeout)
        let client = ScreenLogicClient(connection: connection)
        do {
            try await client.login(password: password)
        } catch {
            connection.close()
            throw error
        }
        return client
    }

    func close() { connection.close() }

    private func login(password: String?) async throws {
        try await connection.sendRaw(Data("CONNECTSERVERHOST\r\n\r\n".utf8))
        var reader = try await connection.request(SLCode.challenge).reader
        challenge = try reader.string()

        var w = ByteWriter()
        w.int32(348)        // schema
        w.int32(0)          // connection type
        w.string("Android") // client version
        let encrypted = password.flatMap { SLPassword.encrypt(password: $0, challenge: challenge) }
        w.array(encrypted ?? Data(count: 16))
        w.int32(2)          // process id
        let reply = try await connection.request(SLCode.login, w.data,
                                                 expect: [SLCode.login + 1, SLCode.loginFailure])
        if reply.messageId == SLCode.loginFailure { throw SLError.loginFailed }
    }

    func controllerConfig() async throws -> ControllerConfig {
        var w = ByteWriter()
        w.int32(0)
        w.int32(0)
        let reply = try await connection.request(SLCode.controllerConfig, w.data)
        return try ControllerConfig.decode(reply)
    }

    func equipmentState() async throws -> EquipmentState {
        var w = ByteWriter()
        w.int32(0)
        let reply = try await connection.request(SLCode.equipmentState, w.data)
        return try EquipmentState.decode(reply)
    }

    func setCircuit(_ circuitId: Int, on: Bool) async throws {
        var w = ByteWriter()
        w.int32(0)
        w.int32(circuitId)
        w.int32(on ? 1 : 0)
        _ = try await connection.request(SLCode.setCircuitState, w.data)
    }

    func setSetPoint(_ body: BodyType, to temperature: Int) async throws {
        var w = ByteWriter()
        w.int32(0)
        w.int32(body.rawValue)
        w.int32(temperature)
        _ = try await connection.request(SLCode.setHeatSetPoint, w.data)
    }

    func setHeatMode(_ body: BodyType, to mode: HeatMode) async throws {
        var w = ByteWriter()
        w.int32(0)
        w.int32(body.rawValue)
        w.int32(mode.rawValue)
        _ = try await connection.request(SLCode.setHeatMode, w.data)
    }

    func sendLights(_ scene: LightScene) async throws {
        var w = ByteWriter()
        w.int32(0)
        w.int32(scene.rawValue)
        _ = try await connection.request(SLCode.lightCommand, w.data)
    }

    // MARK: Schedules

    func schedules(_ kind: ScheduleKind) async throws -> [Schedule] {
        var w = ByteWriter()
        w.int32(0)
        w.int32(kind.rawValue)
        let reply = try await connection.request(SLCode.getSchedules, w.data)
        return try Schedule.decodeList(reply, kind: kind)
    }

    /// Makes an empty schedule slot and returns its raw id. Fill it with `setSchedule`.
    func addSchedule(_ kind: ScheduleKind) async throws -> Int {
        var w = ByteWriter()
        w.int32(0)
        w.int32(kind.rawValue)
        var r = try await connection.request(SLCode.addSchedule, w.data).reader
        return try r.int32()
    }

    func setSchedule(_ s: Schedule) async throws {
        var w = ByteWriter()
        w.int32(0)
        w.int32(s.id)
        w.int32(s.circuitId)
        w.int32(s.startMinutes)
        w.int32(s.stopMinutes)
        w.int32(s.days.rawValue)
        w.int32(s.flags)
        w.int32(s.heatCommand)
        w.int32(s.heatSetPoint)
        _ = try await connection.request(SLCode.setSchedule, w.data)
    }

    func deleteSchedule(id: Int) async throws {
        var w = ByteWriter()
        w.int32(0)
        w.int32(id)
        _ = try await connection.request(SLCode.deleteSchedule, w.data)
    }

    func ping() async throws {
        _ = try await connection.request(SLCode.ping)
    }
}

/// Pentair's dispatcher tells us where a system is reachable from outside the house.
enum SLDispatcher {
    static let host = "screenlogicserver.pentair.com"
    static let port: UInt16 = 500

    static func locate(systemName: String) async throws -> RemoteGateway {
        let connection = SLConnection(host: host, port: port)
        try await connection.open(timeout: 8)
        defer { connection.close() }
        var w = ByteWriter()
        w.string(systemName)
        w.string(systemName)
        let reply = try await connection.request(SLCode.gatewayLookup, w.data)
        return try RemoteGateway.decode(reply)
    }
}
