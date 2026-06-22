import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var appModel
    @State private var profiles: [ServerProfile] = []
    @State private var skills: [SkillInfo] = []
    @State private var toolsets: [ToolsetInfo] = []
    @State private var dashboardLoadError: String?
    @State private var profileLoadError: String?
    @State private var showAddProfile: Bool = false
    @State private var profileToEdit: ServerProfile?
    @State private var profileToDelete: ServerProfile?

    var body: some View {
        NavigationStack {
            List {
                profilesSection
                activeServerSection
                syncSection
                healthSection
                capabilitiesSection
                notificationsSection
                if !skills.isEmpty { skillsSection }
                if !toolsets.isEmpty { toolsetsSection }
                if !appModel.activeProfile.isDashboardConfigured { dashboardNotConfiguredSection }
                if let profileLoadError { errorSection(profileLoadError) }
                if let dashboardLoadError { errorSection(dashboardLoadError) }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: { dismiss() }).bold()
                }
            }
            .sheet(isPresented: $showAddProfile) {
                AddProfileSheet(onAdded: handleAdded)
            }
            .sheet(item: $profileToEdit) { profile in
                ProfileEditView(profile: profile, onSave: saveEdited)
            }
            .alert(
                "Delete Server?",
                isPresented: Binding(
                    get: { profileToDelete != nil },
                    set: { if !$0 { profileToDelete = nil } }
                ),
                presenting: profileToDelete
            ) { profile in
                Button("Delete", role: .destructive) { delete(profile) }
                Button("Cancel", role: .cancel) { profileToDelete = nil }
            } message: { profile in
                Text("Are you sure you want to delete \"\(profile.name)\"?")
            }
            .task {
                await reloadProfiles()
            }
            .task(id: appModel.activeProfile.id) {
                await loadDashboardMetadata()
            }
        }
    }

    private var profilesSection: some View {
        Section("Servers") {
            if profiles.isEmpty {
                Text("No servers saved.")
                    .foregroundStyle(.secondary)
            }
            ForEach(profiles) { profile in
                ServerProfileRow(
                    profile: profile,
                    isActive: profile.id == appModel.activeProfile.id,
                    onSelect: { switchTo(profile) }
                )
                .swipeActions {
                    Button("Edit", systemImage: "pencil") {
                        profileToEdit = profile
                    }
                    .tint(.orange)

                    if profile.id != appModel.activeProfile.id {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            profileToDelete = profile
                        }
                    }
                }
            }

            Button("Add Server", systemImage: "plus", action: { showAddProfile = true })
        }
    }

    private var activeServerSection: some View {
        Section("Active Server") {
            LabeledContent("Name", value: appModel.activeProfile.name)
            LabeledContent("URL", value: appModel.activeProfile.url.absoluteString)
            LabeledContent("Model", value: appModel.selectedModelID)
            if let adminURL = appModel.activeProfile.adminURL {
                LabeledContent("Dashboard", value: adminURL.absoluteString)
            }
        }
    }

    private var syncSection: some View {
        @Bindable var preferences = appModel.preferences

        return Section {
            Toggle(isOn: $preferences.iCloudSyncEnabled) {
                Label("iCloud Sync", systemImage: "icloud")
            }
        } footer: {
            Text("Syncs cached sessions and messages through iCloud on devices using the same Apple Account. Changes apply after restarting Talaria.")
        }
    }

    private var healthSection: some View {
        Section("Health") {
            if let health = appModel.serverHealth {
                LabeledContent("Status") {
                    HStack {
                        Image(systemName: "circle.fill")
                            .foregroundStyle(health.status == "ok" ? .green : .red)
                            .imageScale(.small)
                        Text(health.status)
                    }
                }
                if let platform = health.platform {
                    LabeledContent("Platform", value: platform)
                }
                if let version = health.version {
                    LabeledContent("Version", value: version)
                }
            } else {
                Text("Not connected").foregroundStyle(.secondary)
            }
        }
    }

    private var capabilitiesSection: some View {
        Section("Capabilities") {
            if let caps = appModel.capabilities {
                LabeledContent("Auth", value: caps.auth?.authType ?? "—")
                if let features = caps.features {
                    LabeledContent("Session Chat") {
                        Image(systemName: (features.sessionChat == true) ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle((features.sessionChat == true) ? .green : .secondary)
                    }
                    LabeledContent("Streaming") {
                        Image(systemName: (features.sessionChatStreaming == true) ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle((features.sessionChatStreaming == true) ? .green : .secondary)
                    }
                }
            } else {
                Text("Not loaded").foregroundStyle(.secondary)
            }
        }
    }

    private var skillsSection: some View {
        Section("Skills (\(skills.count))") {
            ForEach(skills) { skill in
                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.name).font(.callout.weight(.semibold))
                    if let desc = skill.description {
                        Text(desc).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var toolsetsSection: some View {
        Section("Toolsets (\(toolsets.count))") {
            ForEach(toolsets) { toolset in
                VStack(alignment: .leading, spacing: 2) {
                    Text(toolset.name).font(.callout.weight(.semibold))
                    if let desc = toolset.description {
                        Text(desc).font(.caption).foregroundStyle(.secondary)
                    }
                    if let tools = toolset.tools {
                        Text("\(tools.count) tools").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var notificationsSection: some View {
        Section {
            LabeledContent("Push") {
                if PushService.shared.isEnabled {
                    if PushService.shared.deviceTokenHex != nil {
                        Label("Registered", systemImage: "checkmark.circle.fill")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.green)
                    } else {
                        Text("Awaiting permission").foregroundStyle(.secondary)
                    }
                } else {
                    Text("Not configured").foregroundStyle(.secondary)
                }
            }

            Button {
                UIPasteboard.general.string = appModel.preferences.hermesSessionKey
                appModel.haptics.success()
            } label: {
                LabeledContent("Push Session Key") {
                    HStack(spacing: Spacing.xs) {
                        Text(appModel.preferences.hermesSessionKey)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "doc.on.doc")
                            .imageScale(.small)
                    }
                }
            }
            .tint(.primary)
        } header: {
            Text("Notifications")
        } footer: {
            Text("Set this as TALARIA_SESSION_KEY in the Hermes push hook so completion alerts reach this device. Tap to copy.")
        }
    }

    private var dashboardNotConfiguredSection: some View {
        Section {
            Label {
                Text("Hermes Dashboard isn't configured. Add the dashboard URL and admin credentials in your server profile to manage models, tools, skills, and attachments.")
            } icon: {
                Image(systemName: "slider.horizontal.3")
            }
            .foregroundStyle(.secondary)
        }
    }

    private func errorSection(_ message: String) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    @Sendable
    private func reloadProfiles() async {
        do {
            profiles = try appModel.profileStore.loadAll()
            profileLoadError = nil
        } catch {
            profileLoadError = error.localizedDescription
        }
    }

    private func loadDashboardMetadata() async {
        skills = []
        toolsets = []
        dashboardLoadError = nil
        guard appModel.activeProfile.isDashboardConfigured else { return }

        do {
            let client = appModel.client
            async let fetchedSkills = client.dashboardSkills()
            async let fetchedToolsets = client.dashboardToolsets()
            skills = try await fetchedSkills
            toolsets = try await fetchedToolsets
        } catch {
            dashboardLoadError = HermesError(error).pluginGuidanceDescription
        }
    }

    private func switchTo(_ profile: ServerProfile) {
        guard profile.id != appModel.activeProfile.id else { return }
        Task {
            await appModel.switchProfile(profile)
            await reloadProfiles()
        }
    }

    private func delete(_ profile: ServerProfile) {
        guard profile.id != appModel.activeProfile.id else { return }
        do {
            try appModel.profileStore.delete(profile.id)
            profiles.removeAll { $0.id == profile.id }
            profileToDelete = nil
        } catch {
            profileLoadError = error.localizedDescription
        }
    }

    private func handleAdded(_ profile: ServerProfile) {
        do {
            try appModel.profileStore.save(profile)
            profiles.append(profile)
            profiles.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            profileLoadError = error.localizedDescription
        }
    }

    private func saveEdited(_ profile: ServerProfile) {
        do {
            try appModel.profileStore.save(profile)
            if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
                profiles[idx] = profile
            } else {
                profiles.append(profile)
            }
            profiles.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if profile.id == appModel.activeProfile.id {
                Task { await appModel.switchProfile(profile) }
            }
        } catch {
            profileLoadError = error.localizedDescription
        }
    }
}
