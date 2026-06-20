import SwiftUI

struct ShimmerView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: Double = 0

    var body: some View {
        Capsule()
            .fill(.tertiary)
            .frame(height: 12)
            .opacity(reduceMotion ? (0.6 + 0.2 * phase) : 1.0)
            .overlay(alignment: .leading) {
                if !reduceMotion {
                    ShimmerOverlay(phase: phase)
                }
            }
            .clipShape(.capsule)
            .onAppear(perform: startAnimation)
    }

    private func startAnimation() {
        if reduceMotion {
            withAnimation(.easeInOut(duration: 1.0).repeatForever()) { phase = 1 }
        } else {
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1 }
        }
    }
}

private struct ShimmerOverlay: View {
    let phase: Double

    var body: some View {
        GeometryReader { proxy in
            LinearGradient(
                colors: [.clear, .secondary.opacity(0.4), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: proxy.size.width * 0.4)
            .offset(x: -proxy.size.width * 0.4 + (proxy.size.width * 1.4) * phase)
        }
    }
}
