import SwiftUI

struct RootView: View {
    @State private var preferences = AppPreferences()
    @State private var profileStore = ServerProfileStore()
    @State private var appModel: AppModel?
    @State private var configuredProfile: ServerProfile?
    @State private var isInWelcomeFlow = false
    @State private var setupTarget: SetupTarget?

    var body: some View {
        Group {
            if let appModel, !isInWelcomeFlow {
                LoadedRootView(appModel: appModel)
            } else if isInWelcomeFlow {
                welcomeScreen
            } else {
                LaunchScreenView()
            }
        }
        .sheet(item: $setupTarget) { target in
            switch target {
            case .hermesAPI:
                SetupView(onComplete: completeSetup)
            case .hermesDashboard:
                if let profile = configuredProfile ?? appModel?.activeProfile {
                    DashboardSetupView(profile: profile, onComplete: completeDashboardSetup)
                }
            }
        }
        .task(loadInitial)
    }

    private var welcomeScreen: some View {
        WelcomeFlowView(
            isInWelcomeFlow: $isInWelcomeFlow,
            setupTarget: $setupTarget,
            configuredServices: WelcomeServicesState(
                hermesAPI: configuredProfile != nil || appModel != nil,
                hermesDashboard: (configuredProfile ?? appModel?.activeProfile)?.isDashboardConfigured == true
            )
        )
    }

    @Sendable
    private func loadInitial() async {
        let profiles = (try? profileStore.loadAll()) ?? []
        guard let profile = resolveActive(among: profiles) else {
            withAnimation { isInWelcomeFlow = true }
            return
        }
        let model = AppModel(profile: profile, preferences: preferences, profileStore: profileStore)
        withAnimation {
            configuredProfile = profile
            appModel = model
        }
        await model.start()
    }

    private func resolveActive(among profiles: [ServerProfile]) -> ServerProfile? {
        if let id = preferences.activeProfileID, let match = profiles.first(where: { $0.id == id }) {
            return match
        }
        return profiles.first
    }

    private func completeSetup(_ profile: ServerProfile) throws {
        try profileStore.save(profile)
        preferences.activeProfileID = profile.id
        let model = AppModel(profile: profile, preferences: preferences, profileStore: profileStore)
        withAnimation {
            configuredProfile = profile
            appModel = model
        }
        Task {
            await model.start()
        }
    }

    private func completeDashboardSetup(_ profile: ServerProfile) throws {
        try profileStore.save(profile)
        preferences.activeProfileID = profile.id
        let model = AppModel(profile: profile, preferences: preferences, profileStore: profileStore)
        withAnimation {
            configuredProfile = profile
            appModel = model
        }
        Task {
            await model.start()
        }
    }
}
