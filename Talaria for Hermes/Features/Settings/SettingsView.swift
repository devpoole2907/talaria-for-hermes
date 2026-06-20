import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var appModel
    @State private var skills: [SkillInfo] = []
    @State private var toolsets: [ToolsetInfo] = []
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            List {
                profileSection
                healthSection
                capabilitiesSection
                if !skills.isEmpty { skillsSection }
                if !toolsets.isEmpty { toolsetsSection }
                if let loadError { errorSection(loadError) }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: { dismiss() }).bold()
                }
            }
            .task {
                do {
                    let client = appModel.client
                    async let fetchedSkills = client.dashboardSkills()
                    async let fetchedToolsets = client.dashboardToolsets()
                    skills = try await fetchedSkills
                    toolsets = try await fetchedToolsets
                } catch {
                    loadError = error.localizedDescription
                }
            }
        }
    }

    private var profileSection: some View {
        Section("Server") {
            LabeledContent("Name", value: appModel.activeProfile.name)
            LabeledContent("URL", value: appModel.activeProfile.url.absoluteString)
            LabeledContent("Model", value: appModel.selectedModelID)
            if let adminURL = appModel.activeProfile.adminURL {
                LabeledContent("Dashboard", value: adminURL.absoluteString)
            }
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

    private func errorSection(_ message: String) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }
}
