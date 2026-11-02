import SwiftUI

/// Liquid Glass on iOS 26 and later, a tinted material before that.
struct GlassTile: ViewModifier {
    var isOn: Bool
    var tint: Color
    var cornerRadius: CGFloat = 26

    func body(content: Content) -> some View {
        glass(content)
            // A soft halo in the tint, so a switch that's on lights up the tiles around it.
            .shadow(color: isOn ? tint.opacity(0.45) : .clear, radius: 18)
            .animation(.easeInOut(duration: 0.3), value: isOn)
    }

    @ViewBuilder
    private func glass(_ content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(isOn ? .regular.tint(tint).interactive() : .regular.interactive(),
                                in: .rect(cornerRadius: cornerRadius))
        } else {
            content.background(isOn ? AnyShapeStyle(tint) : AnyShapeStyle(.regularMaterial),
                               in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

extension View {
    func glassTile(isOn: Bool = false, tint: Color = .accentColor, cornerRadius: CGFloat = 26) -> some View {
        modifier(GlassTile(isOn: isOn, tint: tint, cornerRadius: cornerRadius))
    }
}

/// A big on/off button: icon, name, and state. Used for every switch on the three tabs.
struct ControlButton: View {
    let title: String
    let systemImage: String
    let isOn: Bool
    var detail: String?
    var tint: Color = .accentColor
    /// Text and icon color when on. White suits dark tints; pass black for yellow.
    var onForeground: Color = .white
    /// Color lights show a chip with their last color (or an empty ring if not known yet).
    var swatch: LightScene?
    var showsSwatch = false
    var isBusy = false
    /// When set, a long press calls this instead of toggling.
    var onLongPress: (() -> Void)?
    let action: () -> Void

    @State private var longPressed = false

    var body: some View {
        Button {
            // A finished long press also ends in a tap; don't toggle for it.
            if longPressed { longPressed = false } else { action() }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: systemImage)
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                        .frame(width: 40, height: 40)
                        .background(isOn ? onForeground.opacity(0.2) : Color.primary.opacity(0.08), in: Circle())
                    Spacer()
                    if showsSwatch {
                        if let swatch {
                            LightSwatch(scene: swatch, size: 18)
                                .overlay(Circle().stroke(isOn ? onForeground : .clear, lineWidth: 2).padding(-2))
                        } else {
                            Circle().stroke(isOn ? onForeground.opacity(0.6) : Color.secondary, lineWidth: 1.5)
                                .frame(width: 18, height: 18)
                        }
                    }
                    if isBusy {
                        ProgressView().tint(isOn ? onForeground : .secondary)
                    }
                }
                Spacer(minLength: 0)
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(detail ?? (isOn ? "On" : "Off"))
                    .font(.subheadline)
                    .opacity(0.75)
                    .lineLimit(1)
            }
            .foregroundStyle(isOn ? onForeground : Color.primary)
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        .buttonStyle(.plain)
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
            guard let onLongPress else { return }
            longPressed = true
            onLongPress()
        }, including: onLongPress == nil ? .subviews : .all)
        .glassTile(isOn: isOn, tint: tint)
        .sensoryFeedback(.impact(weight: .medium), trigger: isOn)
        .accessibilityLabel(title)
        .accessibilityValue(detail ?? (isOn ? "On" : "Off"))
        .accessibilityActions {
            if let onLongPress {
                Button("Choose color", action: onLongPress)
            }
        }
    }
}
