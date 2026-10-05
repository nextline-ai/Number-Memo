import SwiftUI

private struct LiquidDroplet: Identifiable {
    let id = UUID()
    var x: CGFloat
    var y: CGFloat
    var vx: CGFloat
    var vy: CGFloat
    var radius: CGFloat
    var opacity: Double
}

public struct ChargingSplashAnimationView: View {
    @Binding var isTriggered: Bool

    @State private var startTime: Date? = nil
    @State private var droplets: [LiquidDroplet] = []

    public init(isTriggered: Binding<Bool>) {
        self._isTriggered = isTriggered
    }

    public var body: some View {
        GeometryReader { proxy in
            if isTriggered {
                TimelineView(.animation) { timeline in
                    let elapsed = startTime.map { timeline.date.timeIntervalSince($0) } ?? 0

                    Canvas { context, size in
                        // Strictly guard against invalid time or completion to prevent any flicker!
                        guard startTime != nil, elapsed > 0.01, elapsed < 2.0 else { return }

                        let centerX = size.width / 2
                        let bottom = size.height

                        // 1. Draw Central White Liquid Spurt / Geyser
                        let progress = min(1.0, elapsed / 0.5)
                        let retract = max(0.0, (elapsed - 0.7) / 1.0)
                        let currentHeight = (size.height * 0.55 * CGFloat(sin(progress * .pi / 2))) * (1.0 - CGFloat(retract))

                        if currentHeight > 10 {
                            var path = Path()
                            path.move(to: CGPoint(x: centerX - 24, y: bottom))
                            path.addCurve(
                                to: CGPoint(x: centerX, y: bottom - currentHeight),
                                control1: CGPoint(x: centerX - 18, y: bottom - currentHeight * 0.4),
                                control2: CGPoint(x: centerX - 8, y: bottom - currentHeight * 0.9)
                            )
                            path.addCurve(
                                to: CGPoint(x: centerX + 24, y: bottom),
                                control1: CGPoint(x: centerX + 8, y: bottom - currentHeight * 0.9),
                                control2: CGPoint(x: centerX + 18, y: bottom - currentHeight * 0.4)
                            )
                            path.closeSubpath()

                            let jetAlpha = max(0.0, 1.0 - (elapsed / 1.8))
                            context.fill(
                                path,
                                with: .color(Color.white.opacity(0.95 * jetAlpha))
                            )
                        }

                        // 2. Draw Dispersing Liquid Droplets
                        for d in droplets {
                            let dt = CGFloat(elapsed)
                            let curX = d.x + d.vx * dt
                            let curY = d.y + d.vy * dt + 0.5 * 850 * dt * dt
                            let curAlpha = max(0.0, d.opacity * (1.0 - (elapsed / 1.8)))

                            if curAlpha > 0 {
                                let rect = CGRect(
                                    x: curX - d.radius,
                                    y: curY - d.radius,
                                    width: d.radius * 2,
                                    height: d.radius * 2 * (1.0 + min(1.5, abs(d.vy) / 600))
                                )
                                context.fill(
                                    Path(ellipseIn: rect),
                                    with: .color(Color.white.opacity(curAlpha))
                                )
                            }
                        }
                    }
                    .onChange(of: elapsed) { _, newElapsed in
                        if newElapsed >= 2.0 {
                            isTriggered = false
                        }
                    }
                }
                .shadow(color: Color.white.opacity(0.7), radius: 10, x: 0, y: 0)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .onAppear {
                    spawnDroplets(screenSize: proxy.size)
                }
            }
        }
        .onChange(of: isTriggered) { _, newValue in
            if !newValue {
                startTime = nil
                droplets = []
            }
        }
    }

    private func spawnDroplets(screenSize: CGSize) {
        let centerX = screenSize.width / 2
        let bottom = screenSize.height

        var newDroplets: [LiquidDroplet] = []
        for _ in 0..<50 {
            let vx = CGFloat.random(in: -130...130)
            let vy = CGFloat.random(in: -950 ... -450)
            let r = CGFloat.random(in: 4...16)
            let xOffset = CGFloat.random(in: -16...16)
            newDroplets.append(
                LiquidDroplet(
                    x: centerX + xOffset,
                    y: bottom,
                    vx: vx,
                    vy: vy,
                    radius: r,
                    opacity: Double.random(in: 0.8...1.0)
                )
            )
        }
        self.droplets = newDroplets
        self.startTime = Date()
    }
}
