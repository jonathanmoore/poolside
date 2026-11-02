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

    /// The heater is switched on and the controller says it's firing right now.
    /// (Heat on with the water already at target is "ready", not heating.)
    var isHeating: Bool { heatMode != 0 && heatStatus != 0 }
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

enum ScheduleKind: Int {
    case recurring = 0
    case runOnce = 1
}

/// Days a schedule runs. Bit 0 is Monday through bit 6, Sunday.
struct Weekdays: OptionSet, Hashable {
    let rawValue: Int

    static let monday = Weekdays(rawValue: 1 << 0)
    static let tuesday = Weekdays(rawValue: 1 << 1)
    static let wednesday = Weekdays(rawValue: 1 << 2)
    static let thursday = Weekdays(rawValue: 1 << 3)
    static let friday = Weekdays(rawValue: 1 << 4)
    static let saturday = Weekdays(rawValue: 1 << 5)
    static let sunday = Weekdays(rawValue: 1 << 6)

    static let weekdays: Weekdays = [.monday, .tuesday, .wednesday, .thursday, .friday]
    static let weekend: Weekdays = [.saturday, .sunday]
    static let everyDay: Weekdays = [.weekdays, .weekend]

    /// Sunday first, the way US calendars lay out a week.
    static let ordered: [(day: Weekdays, short: String, letter: String)] = [
        (.sunday, "Sun", "S"), (.monday, "Mon", "M"), (.tuesday, "Tue", "T"),
        (.wednesday, "Wed", "W"), (.thursday, "Thu", "T"), (.friday, "Fri", "F"),
        (.saturday, "Sat", "S"),
    ]

    var summary: String {
        let days = intersection(.everyDay)
        if days == .everyDay { return "Every day" }
        if days == .weekdays { return "Weekdays" }
        if days == .weekend { return "Weekends" }
        if days.isEmpty { return "No days" }
        return Weekdays.ordered.filter { days.contains($0.day) }.map(\.short).joined(separator: ", ")
    }
}

/// One controller schedule: turn a circuit on at `startMinutes` and off at `stopMinutes`.
struct Schedule: Identifiable, Equatable {
    /// Raw schedule id as the controller sends it (700 and up). Sent back as-is.
    var id: Int
    var kind: ScheduleKind
    /// Raw circuit id, same numbering as `Circuit.id`.
    var circuitId: Int
    /// Minutes past midnight.
    var startMinutes: Int
    var stopMinutes: Int
    var days: Weekdays
    // Not edited by the app yet; kept so an edit sends back what was there.
    var flags = 0
    var heatCommand = 4
    var heatSetPoint = 70

    /// Start and stop one minute apart wraps the clock: the controller's way to say "all day".
    var isAllDay: Bool { (startMinutes + 1440 - 1) % 1440 == stopMinutes }

    static func decodeList(_ msg: SLMessage, kind: ScheduleKind) throws -> [Schedule] {
        var r = msg.reader
        let count = try r.int32()
        var list: [Schedule] = []
        for _ in 0..<max(0, count) {
            let id = try r.int32()
            let circuit = try r.int32()
            let start = try r.int32()
            let stop = try r.int32()
            let days = try r.int32()
            let flags = try r.int32()
            let heatCommand = try r.int32()
            let heatSetPoint = try r.int32()
            list.append(Schedule(id: id, kind: kind, circuitId: circuit, startMinutes: start,
                                 stopMinutes: stop, days: Weekdays(rawValue: days), flags: flags,
                                 heatCommand: heatCommand, heatSetPoint: heatSetPoint))
        }
        return list
    }
}
