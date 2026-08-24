import SwiftUI

extension Color {
    static let soomViolet = Color(red: 0.37, green: 0.32, blue: 1.00)
    static let soomVioletSoft = Color(red: 0.92, green: 0.91, blue: 1.00)
    static let soomCoral = Color(red: 1.00, green: 0.35, blue: 0.25)
    static let soomCanvas = Color(red: 0.965, green: 0.965, blue: 0.975)
    static let soomControl = Color(red: 0.94, green: 0.94, blue: 0.95)
}

struct SOOMMark: View {
    var color: Color = .soomViolet
    var showsRecordingDot = true

    var body: some View {
        Canvas { context, size in
            let diameter = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let lineWidth = diameter * 0.15
            var outer = Path()
            outer.addArc(
                center: center,
                radius: diameter * 0.34,
                startAngle: .degrees(-48),
                endAngle: .degrees(154),
                clockwise: false
            )
            context.stroke(outer, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            var inner = Path()
            inner.addArc(
                center: center,
                radius: diameter * 0.20,
                startAngle: .degrees(132),
                endAngle: .degrees(326),
                clockwise: false
            )
            context.stroke(inner, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            context.fill(
                Path(ellipseIn: CGRect(
                    x: center.x - diameter * 0.055,
                    y: center.y - diameter * 0.055,
                    width: diameter * 0.11,
                    height: diameter * 0.11
                )),
                with: .color(color)
            )

            if showsRecordingDot {
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: size.width * 0.73,
                        y: size.height * 0.08,
                        width: diameter * 0.16,
                        height: diameter * 0.16
                    )),
                    with: .color(Color.soomCoral)
                )
            }
        }
        .accessibilityHidden(true)
    }
}

struct SOOMWordmark: View {
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 7 : 9) {
            SOOMMark()
                .frame(width: compact ? 24 : 30, height: compact ? 24 : 30)
            Text("SOOM")
                .font((compact ? Font.headline : Font.title3).weight(.bold))
                .tracking(-0.4)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("SOOM")
    }
}

struct SOOMCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(.black.opacity(0.06)))
            .shadow(color: .black.opacity(0.12), radius: 22, y: 10)
    }
}

extension View {
    func soomCard() -> some View { modifier(SOOMCardModifier()) }
}
