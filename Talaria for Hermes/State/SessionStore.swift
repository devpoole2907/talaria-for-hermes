import Foundation
import Observation

@MainActor
@Observable
final class SessionStore {
    var sessions: [Session] = []
    var loading: Bool = false
    var lastError: HermesError?

    private let client: HermesClient

    init(client: HermesClient) {
        self.client = client
    }

    func refresh() async {
        loading = true
        defer { loading = false }
        do {
            let response = try await client.listSessions(limit: 50, offset: 0)
            sessions = response.data.sorted { lhs, rhs in
                let l = lhs.lastActive ?? lhs.startedAt ?? 0
                let r = rhs.lastActive ?? rhs.startedAt ?? 0
                return l > r
            }
        } catch {
            lastError = HermesError(error)
        }
    }

    func create(title: String? = nil) async throws -> Session {
        let new = try await client.createSession(title: title)
        sessions.insert(new, at: 0)
        return new
    }

    func session(id: String) -> Session? {
        sessions.first { $0.id == id }
    }

    @discardableResult
    func refreshSession(id: String) async throws -> Session {
        let refreshed = try await client.getSession(id: id)
        upsert(refreshed)
        return refreshed
    }

    func updateModel(_ modelID: String, for sessionID: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].model = modelID
    }

    func rename(_ session: Session, title: String) async throws -> Session {
        let updated = try await client.updateSession(id: session.id, title: title)
        upsert(updated)
        return updated
    }

    func delete(_ session: Session) async throws {
        try await client.deleteSession(id: session.id)
        sessions.removeAll { $0.id == session.id }
    }

    func bumpLastActive(for sessionID: String) {
        if let index = sessions.firstIndex(where: { $0.id == sessionID }) {
            let s = sessions[index]
            // Simulate a fresh lastActive so the session floats to the top
            // The next refresh will pull the real value from server
            sessions.remove(at: index)
            sessions.insert(s, at: 0)
        }
    }

    func clear() {
        sessions = []
    }

    private func upsert(_ session: Session) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0)
        }
    }
}
