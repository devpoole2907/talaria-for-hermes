import SwiftUI

struct RootView: View {
    @State private var preferences: AppPreferences
    @State private var profileStore: ServerProfileStore
    @State private var appModel: AppModel?
    @State private var configuredProfile: ServerProfile?
    @State private var isInWelcomeFlow: Bool
    @State private var setupTarget: SetupTarget?

    /// Shared persistence repository, built once from preferences so the same
    /// ModelContainer is used across the whole app lifecycle.
    private let repository: ChatRepository?

    init() {
        let preferences = AppPreferences()
        let profileStore = ServerProfileStore()
        let persistenceController = try? PersistenceController(iCloudSyncEnabled: preferences.iCloudSyncEnabled)
        let repository = persistenceController.map { ChatRepository(container: $0.container) }
        self.repository = repository
        _preferences = State(initialValue: preferences)
        _profileStore = State(initialValue: profileStore)

        // Resolve the active profile synchronously (it's a local keychain read) and
        // build the AppModel up front, so the very first frame is the real Sessions
        // UI rather than a full-screen launch gate. `start()` (the network health +
        // session fetch) then runs in `.task`, surfaced as the inline spinner inside
        // the Sessions screen.
        let profiles = (try? profileStore.loadAll()) ?? []
        let active: ServerProfile?
        if let id = preferences.activeProfileID, let match = profiles.first(where: { $0.id == id }) {
            active = match
        } else {
            active = profiles.first
        }
        if let active {
            _appModel = State(initialValue: AppModel(profile: active, preferences: preferences, profileStore: profileStore, repository: repository))
            _configuredProfile = State(initialValue: active)
            _isInWelcomeFlow = State(initialValue: false)
        } else {
            _appModel = State(initialValue: nil)
            _configuredProfile = State(initialValue: nil)
            _isInWelcomeFlow = State(initialValue: true)
        }
        _setupTarget = State(initialValue: nil)
    }

    var body: some View {
        #if DEBUG
        if DebugHarness.isLongChatScenario {
            DebugHarness.longChatRootView
        } else {
            standardBody
        }
        #else
        standardBody
        #endif
    }

    private var standardBody: some View {
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
        .task { await appModel?.start() }
        .task {
            // Only once a profile exists (not on the welcome screen) so the push
            // permission prompt lands after the app is actually set up.
            guard appModel != nil else { return }
            PushService.shared.configure(sessionKey: preferences.hermesSessionKey)
            await PushService.shared.requestAuthorizationAndRegister()
        }
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

    private func completeSetup(_ profile: ServerProfile) throws {
        try profileStore.save(profile)
        preferences.activeProfileID = profile.id
        let model = AppModel(profile: profile, preferences: preferences, profileStore: profileStore, repository: repository)
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
        let model = AppModel(profile: profile, preferences: preferences, profileStore: profileStore, repository: repository)
        withAnimation {
            configuredProfile = profile
            appModel = model
        }
        Task {
            await model.start()
        }
    }
}
