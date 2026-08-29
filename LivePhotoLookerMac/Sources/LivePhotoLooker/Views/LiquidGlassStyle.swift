import SwiftUI

/// A shared sampling container keeps nearby Liquid Glass elements visually coherent
/// on macOS 26 while remaining a no-op wrapper on earlier systems.
struct MotionGlassContainer<Content: View>: View {
    let spacing: CGFloat
    private let content: Content

    init(spacing: CGFloat = 8, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

extension View {
    /// Native Liquid Glass on macOS 26, with a material/highlight fallback for
    /// the macOS 13 deployment target.
    @ViewBuilder
    func motionGlassSurface(
        cornerRadius: CGFloat,
        shadowOpacity: Double = 0.085,
        shadowRadius: CGFloat = 12,
        shadowY: CGFloat = 5
    ) -> some View {
        if #available(macOS 26.0, *) {
            self
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
                .shadow(
                    color: .black.opacity(shadowOpacity),
                    radius: shadowRadius,
                    x: 0,
                    y: shadowY
                )
        } else {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.52),
                                Color.white.opacity(0.12),
                                Color.primary.opacity(0.10)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                }
                .shadow(
                    color: .black.opacity(shadowOpacity),
                    radius: shadowRadius,
                    x: 0,
                    y: shadowY
                )
        }
    }

    @ViewBuilder
    func motionGlassCapsule(tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            if let tint {
                self.glassEffect(.regular.tint(tint), in: .capsule)
            } else {
                self.glassEffect(.regular, in: .capsule)
            }
        } else {
            self
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.34), lineWidth: 0.8)
                }
        }
    }
}

struct MotionWorkspaceBackground: View {
    var body: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)

            LinearGradient(
                colors: [
                    Color.blue.opacity(0.075),
                    Color.clear,
                    Color.purple.opacity(0.045)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [Color.cyan.opacity(0.10), Color.clear],
                center: .topTrailing,
                startRadius: 12,
                endRadius: 560
            )

            RadialGradient(
                colors: [Color.orange.opacity(0.055), Color.clear],
                center: .bottomLeading,
                startRadius: 18,
                endRadius: 520
            )
        }
        .ignoresSafeArea()
    }
}
