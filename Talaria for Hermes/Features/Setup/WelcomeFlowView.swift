import SwiftUI

enum WelcomeStep: Hashable {
    case services
}

enum SetupTarget: Identifiable {
    case hermes

    var id: String {
        switch self {
        case .hermes: "hermes"
        }
    }
}

struct WelcomeServicesState {
    var hermes: Bool

    var hasAny: Bool {
        hermes
    }
}

struct WelcomeFlowView: View {
    @Binding var isInWelcomeFlow: Bool
    @Binding var setupTarget: SetupTarget?
    let configuredServices: WelcomeServicesState

    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var welcomePath: [WelcomeStep] = []

    var body: some View {
        NavigationStack(path: $welcomePath) {
            introScreen
                .navigationDestination(for: WelcomeStep.self) { step in
                    switch step {
                    case .services:
                        serviceSelectionScreen
                    }
                }
        }
    }

    private var introScreen: some View {
        VStack(spacing: 32) {
            VStack(spacing: 12) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)

                Text("Welcome to Talaria")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Your iOS home for Hermes Agent.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 16) {
                featureRow(icon: "bubble.left.and.bubble.right", color: .accentColor,
                           title: "Hermes Agent", description: "Chat with your configured local agent")
                featureRow(icon: "waveform.path.ecg", color: .blue,
                           title: "Live Streaming", description: "Watch responses, reasoning, and tools as they run")
                featureRow(icon: "wrench.and.screwdriver", color: .orange,
                           title: "Tool Calls", description: "Follow agent actions without leaving the conversation")
                featureRow(icon: "cpu", color: .purple,
                           title: "Model Switching", description: "Move between configured providers and models")
                featureRow(icon: "rectangle.stack", color: .green,
                           title: "Sessions", description: "Keep chats organized and resume them later")
                featureRow(icon: "command", color: .pink,
                           title: "Slash Commands", description: "Prefill common Hermes commands from the composer")
            }
            .padding(.horizontal, 8)
        }
        .padding(32)
        .frame(maxWidth: hSizeClass == .regular ? 600 : 440)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .prominentBottomButton("Get Started") {
            welcomePath.append(.services)
        }
    }

    private var serviceSelectionScreen: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 10) {
                    Text("Choose Your Services")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .multilineTextAlignment(.center)

                    Text("Set up Hermes, then continue into the app.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 12) {
                    setupRow(icon: "sparkles.rectangle.stack", color: .accentColor,
                             title: "Hermes", description: "Connect to your API server and dashboard",
                             isConfigured: configuredServices.hermes) { setupTarget = .hermes }
                }
            }
            .padding(32)
            .frame(maxWidth: hSizeClass == .regular ? 600 : 440)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .prominentBottomButton("Go", isDisabled: !configuredServices.hasAny) {
            withAnimation { isInWelcomeFlow = false }
        }
        .navigationTitle("Choose Services")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func featureRow(icon: String, color: Color, title: String, description: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func setupRow(
        icon: String,
        color: Color,
        title: String,
        description: String,
        isConfigured: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(color)
                    .frame(width: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: isConfigured ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isConfigured ? Color.green : Color.secondary.opacity(0.4))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}
