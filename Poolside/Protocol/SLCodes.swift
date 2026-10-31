import Foundation

/// Message ids. A request's answer is usually id + 1.
enum SLCode {
    static let loginFailure: UInt16 = 13
    static let challenge: UInt16 = 14
    static let ping: UInt16 = 16
    static let login: UInt16 = 27
    static let unknownCommand: UInt16 = 30
    static let badParameter: UInt16 = 31
    static let statusChanged: UInt16 = 12500
    static let setHeatSetPoint: UInt16 = 12528
    static let setCircuitState: UInt16 = 12530
    static let controllerConfig: UInt16 = 12532
    static let equipmentState: UInt16 = 12526
    static let setHeatMode: UInt16 = 12538
    static let lightCommand: UInt16 = 12556
    static let gatewayLookup: UInt16 = 18003
}

enum BodyType: Int, CaseIterable, Identifiable {
    case pool = 0
    case spa = 1
    var id: Int { rawValue }
    var name: String { self == .pool ? "Pool" : "Spa" }
}

enum HeatMode: Int, CaseIterable, Identifiable {
    case off = 0
    case solar = 1
    case solarPreferred = 2
    case heater = 3
    var id: Int { rawValue }
    var name: String {
        switch self {
        case .off: return "Off"
        case .solar: return "Solar"
        case .solarPreferred: return "Solar first"
        case .heater: return "Heater"
        }
    }
}

/// Circuit function codes from the controller config.
enum CircuitFunction: Int {
    case generic = 0, spa = 1, pool = 2, secondSpa = 3, secondPool = 4
    case masterCleaner = 5, cleaner = 6, light = 7, dimmer = 8, samLight = 9
    case salLight = 10, photonGen = 11, colorWheel = 12, valve = 13, spillway = 14
    case floorCleaner = 15, intelliBrite = 16, magicStream = 17, dimmer25 = 18

    var isLight: Bool {
        switch self {
        case .light, .dimmer, .samLight, .salLight, .photonGen, .colorWheel,
             .intelliBrite, .magicStream, .dimmer25: return true
        default: return false
        }
    }
}

/// Where the official app shows a circuit.
enum CircuitInterface: Int {
    case pool = 0, spa = 1, features = 2, syncSwim = 3, lights = 4, hidden = 5, invalid = 6
}

enum LightScene: Int, CaseIterable, Identifiable {
    case off = 0, on = 1, set = 2, sync = 3, swim = 4
    case party = 5, romance = 6, caribbean = 7, american = 8, sunset = 9, royal = 10
    case save = 11, recall = 12
    case blue = 13, green = 14, red = 15, white = 16, purple = 17
    var id: Int { rawValue }

    static let pickable: [LightScene] = [.party, .romance, .caribbean, .american, .sunset, .royal,
                                         .blue, .green, .red, .white, .purple]

    var name: String {
        switch self {
        case .off: return "Off"
        case .on: return "On"
        case .set: return "Set"
        case .sync: return "Sync"
        case .swim: return "Swim"
        case .party: return "Party"
        case .romance: return "Romance"
        case .caribbean: return "Caribbean"
        case .american: return "American"
        case .sunset: return "Sunset"
        case .royal: return "Royal"
        case .save: return "Save"
        case .recall: return "Recall"
        case .blue: return "Blue"
        case .green: return "Green"
        case .red: return "Red"
        case .white: return "White"
        case .purple: return "Purple"
        }
    }
}
