import SwiftUI

/// The download arrow that ends the wordmark: a stem and a chevron, sitting on the baseline.
struct DropArrow: Shape {
    func path(in r: CGRect) -> Path {
        // One continuous outline: rounded-top stem flowing into a solid head.
        var p = Path()
        let w = r.width, h = r.height
        let half = w * 0.17
        let headTop = r.minY + h * 0.46
        p.move(to: CGPoint(x: r.midX - half, y: headTop))
        p.addLine(to: CGPoint(x: r.midX - half, y: r.minY + half))
        p.addArc(center: CGPoint(x: r.midX, y: r.minY + half), radius: half,
                 startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: r.midX + half, y: headTop))
        p.addLine(to: CGPoint(x: r.maxX, y: headTop))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: headTop))
        p.closeSubpath()
        return p
    }
}

/// "dwn" set tight in a heavy grotesk, followed by a lime arrow.
struct Wordmark: View {
    var size: CGFloat = 40
    var color: Color = Theme.text
    var arrowColor: Color = Theme.accent

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: size * 0.06) {
            Text("dwn")
                .font(.system(size: size, weight: .black))
                .tracking(-size * 0.055)
                .foregroundStyle(color)
            DropArrow()
                .fill(arrowColor)
                .frame(width: size * 0.36, height: size * 0.56)
                .alignmentGuide(.lastTextBaseline) { d in d[.bottom] }
        }
        .accessibilityLabel("Dwn")
    }
}

/// Square app mark: a rounded tile with the arrow, used in empty states and the icon.
struct LogoMark: View {
    var size: CGFloat = 56

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.08)], startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(Theme.strokeStrong))
            .overlay(
                DropArrow().fill(Theme.accent).frame(width: size * 0.34, height: size * 0.50)
            )
            .frame(width: size, height: size)
    }
}

/// The launch screen. The letters rise in one by one, the arrow drops into
/// place, then a baseline runs under the wordmark until the engine is ready.
struct SplashView: View {
    var status: String
    var failed: String?
    var onRetry: () -> Void
    var onShowLog: () -> Void

    @Local private var shown = [false, false, false]
    @Local private var arrowIn = false
    @Local private var lineIn = false
    @Local private var statusIn = false

    private let size: CGFloat = 68

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            RadialGradient(colors: [Theme.accent.opacity(0.07), .clear], center: .center, startRadius: 10, endRadius: 360)
                .opacity(arrowIn ? 1 : 0)
                .animation(.easeOut(duration: 1.2), value: arrowIn)

            VStack(spacing: 28) {
                HStack(alignment: .lastTextBaseline, spacing: size * 0.06) {
                    HStack(spacing: -size * 0.055) {
                        ForEach(Array("dwn".enumerated()), id: \.offset) { i, ch in
                            Text(String(ch))
                                .font(.system(size: size, weight: .black))
                                .foregroundStyle(Theme.text)
                                .opacity(shown[i] ? 1 : 0)
                                .offset(y: shown[i] ? 0 : size * 0.35)
                                .blur(radius: shown[i] ? 0 : 8)
                        }
                    }
                    DropArrow()
                        .fill(Theme.accent)
                        .frame(width: size * 0.36, height: size * 0.56)
                        .alignmentGuide(.lastTextBaseline) { d in d[.bottom] }
                        .offset(y: arrowIn ? 0 : -size * 1.1)
                        .opacity(arrowIn ? 1 : 0)
                        .scaleEffect(x: 1, y: arrowIn ? 1 : 1.35, anchor: .bottom)
                }

                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.raised).frame(width: 180, height: 3)
                    if failed == nil {
                        Capsule().fill(Theme.accent.opacity(0.75)).frame(width: 180, height: 3)
                            .overlay(Shimmer()).clipShape(Capsule())
                            .mask(alignment: .leading) {
                                Capsule().frame(width: lineIn ? 180 : 0, height: 3)
                            }
                    }
                }
                .opacity(lineIn ? 1 : 0)

                VStack(spacing: 12) {
                    if let failed {
                        Text(failed)
                            .font(.ui(13))
                            .foregroundStyle(Theme.text2)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 380)
                        HStack(spacing: 10) {
                            Button("Try Again", action: onRetry).buttonStyle(QuietButtonStyle())
                            Button("Show Engine Log", action: onShowLog).buttonStyle(QuietButtonStyle())
                        }
                    } else {
                        Text(status).font(.ui(13, .medium)).foregroundStyle(Theme.text3)
                    }
                }
                .opacity(statusIn ? 1 : 0)
                .frame(height: 70, alignment: .top)
            }
            .offset(y: 20)
        }
        .onAppear(perform: play)
    }

    private func play() {
        for i in 0..<3 {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.78).delay(0.08 + Double(i) * 0.09)) { shown[i] = true }
        }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.55).delay(0.48)) { arrowIn = true }
        withAnimation(.easeInOut(duration: 0.6).delay(0.8)) { lineIn = true }
        withAnimation(.easeOut(duration: 0.4).delay(1.0)) { statusIn = true }
    }
}
