import SwiftUI

/// A big round dial for the heat target. Drag the knob (or anywhere on the ring) around a
/// 270° arc; the new target is sent when you let go.
struct TempDial: View {
    let range: ClosedRange<Int>
    /// The controller's current target. Shown whenever the dial isn't being dragged.
    let target: Int
    let water: Int
    let isHeating: Bool
    let heatOn: Bool
    let colors: [Color]
    let onCommit: (Int) -> Void

    @State private var dragValue: Int?
    /// What you let go on, shown until the controller reports it (so the knob doesn't bounce back).
    @State private var committed: Int?

    private let start = 135.0
    private let sweep = 270.0

    var body: some View {
        let value = clamp(dragValue ?? committed ?? target)
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let line = size * 0.085
            let radius = (size - line) / 2 - 6
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let fraction = self.fraction(value)

            ZStack {
                Arc(start: start, sweep: sweep, radius: radius)
                    .stroke(Color.primary.opacity(0.1), style: StrokeStyle(lineWidth: line, lineCap: .round))

                Arc(start: start, sweep: sweep * fraction, radius: radius)
                    .stroke(AngularGradient(colors: colors, center: .center,
                                            startAngle: .degrees(start), endAngle: .degrees(start + sweep)),
                            style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .animation(.snappy(duration: 0.25), value: fraction)
                    .opacity(heatOn ? 1 : 0.45)

                // Where the water is now: a small marker riding on the track.
                if range.contains(water) {
                    Circle()
                        .fill(Color(.systemBackground))
                        .frame(width: line * 0.55, height: line * 0.55)
                        .overlay(Circle().stroke(Color.primary.opacity(0.7), lineWidth: 2.5))
                        .position(point(self.fraction(water), radius: radius, center: center))
                        .accessibilityHidden(true)
                }

                Circle()
                    .fill(.white)
                    .frame(width: line * 1.25, height: line * 1.25)
                    .overlay(Circle().stroke(Color.black.opacity(0.08), lineWidth: 1))
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                    .scaleEffect(dragValue == nil ? 1 : 1.18)
                    // Animates the angle, not x/y, so the knob always slides along the ring.
                    .modifier(OnRing(fraction: fraction, start: start, sweep: sweep, radius: radius, center: center))
                    .animation(.snappy(duration: 0.25), value: fraction)

                VStack(spacing: size * 0.012) {
                    Text(dragValue != nil ? "Set to" : (heatOn ? "Heat to" : "Heat off · set to"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(dragValue != nil ? AnyShapeStyle(colors.last ?? .accentColor) : AnyShapeStyle(.secondary))
                    Text("\(value)°")
                        .font(.system(size: size * 0.25, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(value)))
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        Image(systemName: isHeating ? "flame.fill" : "drop.fill")
                            .foregroundStyle(isHeating ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                            .symbolEffect(.pulse, isActive: isHeating)
                        Text("Now")
                            .foregroundStyle(.secondary)
                        Text("\(water)°")
                            .monospacedDigit()
                    }
                    .font(.headline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.primary.opacity(0.07), in: Capsule())
                }
            }
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        var next = valueAt(drag.location, center: center)
                        // Crossing the gap at the bottom would flip between min and max. Stay at the end instead.
                        if let current = dragValue, abs(next - current) > (range.upperBound - range.lowerBound) / 2 {
                            next = current
                        }
                        dragValue = next
                    }
                    .onEnded { _ in
                        if let picked = dragValue, picked != target {
                            committed = picked
                            onCommit(picked)
                            // Give up waiting if the controller never confirms.
                            Task {
                                try? await Task.sleep(nanoseconds: 10_000_000_000)
                                if committed == picked { committed = nil }
                            }
                        }
                        dragValue = nil
                    }
            )
        }
        .aspectRatio(1, contentMode: .fit)
        .onChange(of: target) { _, now in
            if now == committed { committed = nil }
        }
        .sensoryFeedback(.selection, trigger: dragValue)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Target temperature")
        .accessibilityValue("\(value) degrees, water \(water) degrees")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onCommit(clamp(target + 1))
            case .decrement: onCommit(clamp(target - 1))
            @unknown default: break
            }
        }
    }

    private func clamp(_ v: Int) -> Int { min(max(v, range.lowerBound), range.upperBound) }

    private func fraction(_ v: Int) -> Double {
        let span = Double(range.upperBound - range.lowerBound)
        return span > 0 ? Double(v - range.lowerBound) / span : 0
    }

    private func point(_ fraction: Double, radius: CGFloat, center: CGPoint) -> CGPoint {
        let angle = (start + sweep * fraction) * .pi / 180
        return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
    }

    /// Maps a touch to a value. Touches in the gap at the bottom snap to the nearer end.
    private func valueAt(_ location: CGPoint, center: CGPoint) -> Int {
        let degrees = atan2(location.y - center.y, location.x - center.x) * 180 / .pi
        var along = (degrees - start).truncatingRemainder(dividingBy: 360)
        if along < 0 { along += 360 }
        if along > sweep {
            along = along > sweep + (360 - sweep) / 2 ? 0 : sweep
        }
        let span = Double(range.upperBound - range.lowerBound)
        return clamp(range.lowerBound + Int((along / sweep * span).rounded()))
    }
}

/// Places a view on the ring by angle. Being Animatable, SwiftUI interpolates the angle,
/// so movement follows the arc instead of cutting across the middle.
private struct OnRing: ViewModifier, Animatable {
    var fraction: Double
    let start: Double
    let sweep: Double
    let radius: CGFloat
    let center: CGPoint

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func body(content: Content) -> some View {
        let angle = (start + sweep * fraction) * .pi / 180
        content.position(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
    }
}

private struct Arc: Shape {
    let start: Double
    var sweep: Double
    let radius: CGFloat

    var animatableData: Double {
        get { sweep }
        set { sweep = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: radius,
                 startAngle: .degrees(start), endAngle: .degrees(start + sweep), clockwise: false)
        return p
    }
}
