import SwiftUI

/// Duolingo palette + keycap 3D button style, ported from apps/web/public/index.html CSS variables.
enum DS {
    static let accent = Color(hex: 0x58cc02)
    static let accentHover = Color(hex: 0x61e002)
    static let accentActive = Color(hex: 0x58a700)
    static let orange = Color(hex: 0xff9600)
    static let blue = Color(hex: 0x1cb0f6)
    static let pink = Color(hex: 0xce82ff)
    static let red = Color(hex: 0xff4b4b)
    static let yellow = Color(hex: 0xffc800)
    static let gray = Color(hex: 0xafafaf)

    static let radiusSM: CGFloat = 12
    static let radiusMD: CGFloat = 16
    static let radiusLG: CGFloat = 20
    static let radiusPill: CGFloat = 9999
}

/// 3D keycap button: hard 4pt bottom shadow, pressed → pushed down into the shadow.
struct KeycapButtonStyle: ButtonStyle {
    var color: Color = DS.accent
    var radius: CGFloat = DS.radiusMD

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .font(.system(size: 15, weight: .bold))
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: radius).fill(color))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .stroke(color.opacity(0.6), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.25), radius: 0, x: 0, y: configuration.isPressed ? 0 : 4)
            .offset(y: configuration.isPressed ? 4 : 0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

struct DisplayFontModifier: ViewModifier {
    var size: CGFloat

    func body(content: Content) -> some View {
        content
            .font(.system(size: size, weight: .heavy, design: .rounded))
    }
}

extension View {
    func displayFont(_ size: CGFloat) -> some View {
        modifier(DisplayFontModifier(size: size))
    }
}
