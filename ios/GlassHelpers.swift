import SwiftUI

/// A reusable modifier that applies Apple's Liquid Glass effect when available,
/// and falls back to a material background on earlier systems.
struct GlassCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
        } else {
            content
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 18))
        }
    }
}

extension View {
    /// Apply a Liquid Glass-styled card background with automatic fallback.
    func glassCard() -> some View { self.modifier(GlassCardModifier()) }
}
