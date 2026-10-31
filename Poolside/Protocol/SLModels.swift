import Foundation

struct Circuit: Identifiable, Equatable {
    /// Raw circuit id as the controller sends it (500 and up). Sent back as-is in commands.
    let id: Int
    let name: String
    let functionCode: Int
    let interfaceCode: Int

    var function: CircuitFunction { CircuitFunction(rawValue: functionCode) ?? .generic }
    var interface: CircuitInterface { CircuitInterface(rawValue: interfaceCode) ?? .invalid }
    var isLight: Bool { function.isLight || interface == .lights }
    var isBody: Bool { [.pool, .spa, .secondPool, .secondSpa].contains(function) }
}

struct ControllerConfig: Equatable {
    var isCelsius = false
    /// Setpoint limits indexed by BodyType raw value.
    var minSetPoint: [Int] = [40, 40]
    var maxSetPoint: [Int] = [104, 104]
    var hasSolar = false
    var hasIntelliBrite = false
    var circuits: [Circuit] = []

    static func decode(_ msg: SLMessage) throws -> ControllerConfig {
        var r = msg.reader
        var c = ControllerConfig()
        _ = try r.int32() // controller id
        for i in 0..<2 {
            c.minSetPoint[i] = Int(try r.uint8())
            c.maxSetPoint[i] = Int(try r.uint8())
        }
        c.isCelsius = try r.uint8() != 0
        _ = try r.uint8() // controller type
        _ = try r.uint8() // hardware type
        _ = try r.uint8() // controller data
        let equipFlags = try r.int32()
        c.hasSolar = equipFlags & 0x1 != 0
        c.hasIntelliBrite = equipFlags & 0x8 != 0
        _ = try r.string() // generic circuit name
        let count = try r.int32()
        for _ in 0..<max(0, count) {
            let id = try r.int32()
            let name = try r.string()
            _ = try r.uint8() // name index
            let function = Int(try r.uint8())
            let interface = Int(try r.uint8())
            _ = try r.uint8() // freeze
            _ = try r.uint8() // color set
            _ = try r.uint8() // color position
            _ = try r.uint8() // color stagger
            _ = try r.uint8() // device id
            _ = try r.uint16() // egg timer
            try r.skip(2)
            c.circuits.append(Circuit(id: id, name: name, functionCode: function, interfaceCode: interface))
        }
        // Color table, pump map and tab flags follow; nothing here needs them yet.
        return c
    }
}

struct BodyState: Equatable {
    var temperature = 0
    var heatStatus = 0
    var setPoint = 0
    var heatMode = 0

    var isHeating: Bool { heatStatus != 0 }
    var mode: HeatMode { HeatMode(rawValue: heatMode) ?? .off }
}

struct EquipmentState: Equatable {
    var airTemperature = 0
    var freezeMode = false
    var bodies: [BodyState] = [BodyState(), BodyState()]
    /// Circuit on/off keyed by raw circuit id.
    var circuitOn: [Int: Bool] = [:]
    var saltPPM = 0
    var pH = 0.0

    static func decode(_ msg: SLMessage) throws -> EquipmentState {
        var r = msg.reader
        var s = EquipmentState()
        _ = try r.int32() // panel mode
        s.freezeMode = try r.uint8() != 0
        _ = try r.uint8() // remotes
        _ = try r.uint8() // pool delay
        _ = try r.uint8() // spa delay
        _ = try r.uint8() // cleaner delay
        try r.skip(3)
        s.airTemperature = try r.int32()
        let rawBodyCount = try r.int32()
        let bodyCount = min(max(rawBodyCount, 0), 2)
        for _ in 0..<bodyCount {
            var type = try r.int32()
            if type < 0 || type > 1 { type = 0 }
            var b = BodyState()
            b.temperature = try r.int32()
            b.heatStatus = try r.int32()
            b.setPoint = try r.int32()
            _ = try r.int32() // cool setpoint
            b.heatMode = try r.int32()
            s.bodies[type] = b
        }
        let circuitCount = try r.int32()
        for _ in 0..<max(0, circuitCount) {
            let id = try r.int32()
            let state = try r.int32()
            try r.skip(4) // color set, position, stagger, delay
            s.circuitOn[id] = state != 0
        }
        s.pH = Double(try r.int32()) / 100
        _ = try r.int32() // ORP
        _ = try r.int32() // saturation
        s.saltPPM = try r.int32() * 50
        return s
    }
}

struct LocalGateway: Identifiable, Hashable {
    var id: String { "\(host):\(port)" }
    let host: String
    let port: UInt16
    let name: String
}

struct RemoteGateway {
    let found: Bool
    let licenseOK: Bool
    let host: String
    let port: UInt16
    let portOpen: Bool
    let relayOn: Bool

    static func decode(_ msg: SLMessage) throws -> RemoteGateway {
        var r = msg.reader
        let found = try r.uint8() != 0
        let license = try r.uint8() != 0
        let host = try r.string()
        let port = try r.uint16()
        let portOpen = try r.uint8() != 0
        let relayOn = try r.uint8() != 0
        return RemoteGateway(found: found, licenseOK: license, host: host, port: port,
                             portOpen: portOpen, relayOn: relayOn)
    }
}
