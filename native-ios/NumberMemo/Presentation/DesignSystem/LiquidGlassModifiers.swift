import SwiftUI

public struct GlassSurfaceModifier: ViewModifier {
    public var cornerRadius: CGFloat
    public var isInteractive: Bool

    public init(cornerRadius: CGFloat = 16, isInteractive: Bool = false) {
        self.cornerRadius = cornerRadius
        self.isInteractive = isInteractive
    }

    public func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
                .glassEffect(isInteractive ? .regular.interactive() : .regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                )
        }
    }
}

public struct GlassCapsuleModifier: ViewModifier {
    public var isInteractive: Bool

    public init(isInteractive: Bool = false) {
        self.isInteractive = isInteractive
    }

    public func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
                .glassEffect(isInteractive ? .regular.interactive() : .regular, in: .capsule)
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                )
        }
    }
}

public struct GlassCircleModifier: ViewModifier {
    public var isInteractive: Bool

    public init(isInteractive: Bool = false) {
        self.isInteractive = isInteractive
    }

    public func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
                .glassEffect(isInteractive ? .regular.interactive() : .regular, in: .circle)
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
                .overlay(
                    Circle()
                        .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                )
        }
    }
}

public extension View {
    func glassSurface(cornerRadius: CGFloat = 16, isInteractive: Bool = false) -> some View {
        modifier(GlassSurfaceModifier(cornerRadius: cornerRadius, isInteractive: isInteractive))
    }

    func glassCapsule(isInteractive: Bool = false) -> some View {
        modifier(GlassCapsuleModifier(isInteractive: isInteractive))
    }

    func glassCircle(isInteractive: Bool = false) -> some View {
        modifier(GlassCircleModifier(isInteractive: isInteractive))
    }
}

public extension Color {
    init(argb: Int64) {
        let a = Double((argb >> 24) & 0xFF) / 255.0
        let r = Double((argb >> 16) & 0xFF) / 255.0
        let g = Double((argb >> 8) & 0xFF) / 255.0
        let b = Double(argb & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

public struct LiquidGlassTitleCapsule: View {
    public let title: String

    public init(_ title: String) {
        self.title = title
    }

    public var body: some View {
        Text(title)
            .font(.system(size: 15, weight: .bold))
            .foregroundColor(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .fixedSize()
    }
}

