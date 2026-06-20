import SwiftUI

struct ServerProfilePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var appModel
    @State private var profiles: [ServerProfile] = []
    @State private var loadError: String?
    @State private var showAdd: Bool = false
    @State private var profileToEdit: ServerProfile?
    @State private var profileToDelete: ServerProfile?

    var body: some View {
        NavigationStack {
            List {
                Section("Profiles") {
                    if profiles.isEmpty {
                        Text("No profiles saved.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(profiles) { profile in
                        ServerProfileRow(
                            profile: profile,
                            isActive: profile.id == appModel.activeProfile.id,
                            onSelect: { switchTo(profile) }
                        )
                        .swipeActions {
                            Button {
                                profileToEdit = profile
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.orange)

                            if profile.id != appModel.activeProfile.id {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    profileToDelete = profile
                                }
                            }
                        }
                    }
                }

                Section {
                    Button("Add Profile", systemImage: "plus", action: { showAdd = true })
                }

                if let loadError {
                    Section {
                        Label(loadError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Servers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Dismiss")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: { dismiss() }).bold()
                }
            }
            .sheet(isPresented: $showAdd) {
                AddProfileSheet(onAdded: handleAdded)
            }
            .sheet(item: $profileToEdit) { profile in
                ProfileEditView(profile: profile, onSave: saveEdited)
            }
            .alert(
                "Delete Profile?",
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
            .task(reload)
        }
    }

    @Sendable
    private func reload() async {
        do {
            profiles = try appModel.profileStore.loadAll()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func switchTo(_ profile: ServerProfile) {
        Task {
            await appModel.switchProfile(profile)
            dismiss()
        }
    }

    private func delete(_ profile: ServerProfile) {
        guard profile.id != appModel.activeProfile.id else { return }
        do {
            try appModel.profileStore.delete(profile.id)
            profiles.removeAll { $0.id == profile.id }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func handleAdded(_ profile: ServerProfile) {
        do {
            try appModel.profileStore.save(profile)
            profiles.append(profile)
            profiles.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            loadError = error.localizedDescription
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
            loadError = error.localizedDescription
        }
    }
}
