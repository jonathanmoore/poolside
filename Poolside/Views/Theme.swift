import SwiftUI

enum Theme {
    static let pool = LinearGradient(colors: [Color(red: 0.05, green: 0.55, blue: 0.85),
                                              Color(red: 0.0, green: 0.75, blue: 0.75)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)
    static let spa = LinearGradient(colors: [Color(red: 0.93, green: 0.42, blue: 0.27),
                                             Color(red: 0.85, green: 0.25, blue: 0.45)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing)
    static let tile = Color(.secondarySystemGroupedBackground)
    static let corner: CGFloat = 22

    static func gradient(for body: BodyType) -> LinearGradient {
        body == .pool ? pool : spa
    }

    static func icon(for body: BodyType) -> String {
        body == .pool ? "figure.pool.swim" : "bathtub.fill"
    }

    /// Best-guess symbol from what the circuit is called and what it does.
    static func icon(for circuit: Circuit) -> String {
        if circuit.isLight { return "lightbulb.fill" }
        let name = circuit.name.lowercased()
        switch circuit.function {
        case .cleaner, .masterCleaner, .floorCleaner: return "sparkles"
        case .valve: return "arrow.triangle.branch"
        case .spillway: return "drop.fill"
        default: break
        }
        if name.contains("clean") { return "sparkles" }
        if name.contains("blower") || name.contains("air") { return "wind" }
        if name.contains("water") || name.contains("fountain") || name.contains("fall") || name.contains("spill") {
            return "drop.fill"
        }
        if name.contains("high") || name.contains("low") || name.contains("pump") || name.contains("speed") {
            return "fan.fill"
        }
        if name.contains("heat") { return "flame.fill" }
        return "power"
    }

    static func color(for scene: LightScene) -> Color {
        switch scene {
        case .party: return .pink
        case .romance: return .red.opacity(0.8)
        case .caribbean: return .teal
        case .american: return .indigo
        case .sunset: return .orange
        case .royal: return .purple
        case .blue: return .blue
        case .green: return .green
        case .red: return .red
        case .white: return .gray
        case .purple: return .purple
        default: return .accentColor
        }
    }
}
