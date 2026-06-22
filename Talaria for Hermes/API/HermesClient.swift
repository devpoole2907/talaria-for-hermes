import Foundation
import OSLog

@MainActor
final class HermesClient {
    let baseURL: URL
    let apiKey: String
    let sessionKey: String

    private let adminBaseURL: URL?
    private let adminUsername: String?
    private let adminPassword: String?
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private var adminLoggedIn = false

    private static let log = Logger(subsystem: "ai.talaria.client.ios", category: "HermesClient")

    init(
        baseURL: URL,
        apiKey: String,
        sessionKey: String,
        adminURL: URL? = nil,
        adminUsername: String? = nil,
        adminPassword: String? = nil
    ) {
        self.baseURL = Self.normalised(baseURL)
        self.apiKey = apiKey
        self.sessionKey = sessionKey
        self.adminBaseURL = adminURL.map(Self.normalised)
        self.adminUsername = adminUsername
        self.adminPassword = adminPassword

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)

        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = dec

        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        self.encoder = enc
    }

    // MARK: - Discovery

    func health() async throws -> HealthInfo {
        try await get("/health")
    }

    func capabilities() async throws -> Capabilities {
        try await get("/v1/capabilities")
    }

    func models() async throws -> [ModelInfo] {
        let response: ModelListResponse = try await get("/v1/models")
        return response.data
    }

    func skills() async throws -> [SkillInfo] {
        let response: ListResponse<SkillInfo> = try await get("/v1/skills")
        return response.data
    }

    func toolsets() async throws -> [ToolsetInfo] {
        let response: ListResponse<ToolsetInfo> = try await get("/v1/toolsets")
        return response.data
    }

    // MARK: - Hermes dashboard admin (via the Talaria plugin facade)
    //
    // These go through the Talaria plugin's /admin/* endpoints rather than the
    // raw dashboard routes. The plugin delegates to the dashboard's own handlers
    // in-process, so the responses are byte-identical (decoders unchanged) — but
    // the path the app depends on is stable and version-resilient. A missing or
    // outdated plugin surfaces as .notFound (404) / HTTP 501, which callers use
    // to show a "plugin not configured" state. See HermesPlugin.adminPath.

    func dashboardCurrentModel() async throws -> HermesDashboardModel {
        try await adminRootGet(HermesPlugin.adminPath("model/info"))
    }

    func dashboardModelCatalog() async throws -> HermesModelCatalogResponse {
        try await adminRootGet(HermesPlugin.adminPath("model/options"))
    }

    func dashboardConfig() async throws -> HermesDashboardConfigResponse {
        try await adminRootGet(HermesPlugin.adminPath("config"))
    }

    func dashboardSkills() async throws -> [SkillInfo] {
        try await adminRootGet(HermesPlugin.adminPath("skills"))
    }

    func dashboardToolsets() async throws -> [ToolsetInfo] {
        try await adminRootGet(HermesPlugin.adminPath("toolsets"))
    }

    func switchDashboardModel(modelID: String, provider: String?) async throws -> HermesModelAssignmentResponse {
        struct Body: Encodable {
            let scope: String
            let provider: String
            let model: String
        }

        let pinnedProvider = provider?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return try await adminRootPost(
            HermesPlugin.adminPath("model/set"),
            body: Body(
                scope: "main",
                provider: pinnedProvider.isEmpty ? "auto" : pinnedProvider,
                model: modelID
            )
        )
    }

    // MARK: - Sessions

    func listSessions(limit: Int = 50, offset: Int = 0) async throws -> SessionListResponse {
        var components = URLComponents(url: baseURL.appending(path: "/api/sessions"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "offset", value: "\(offset)"),
        ]
        guard let url = components.url else { throw HermesError.invalidURL }
        return try await performDecode(method: .get, url: url, body: Optional<EmptyBody>.none)
    }

    func createSession(title: String? = nil) async throws -> Session {
        struct Body: Encodable { let title: String? }
        let envelope: SessionEnvelope = try await post("/api/sessions", body: Body(title: title))
        return envelope.session
    }

    func getSession(id: String) async throws -> Session {
        let raw = try await performRequest(method: .get, path: "/api/sessions/\(id)", body: Optional<EmptyBody>.none)
        return try tolerantDecodeSession(raw)
    }

    func updateSession(id: String, title: String) async throws -> Session {
        struct Body: Encodable { let title: String }
        let raw = try await performRequest(method: .patch, path: "/api/sessions/\(id)", body: Body(title: title))
        return try tolerantDecodeSession(raw)
    }

    func deleteSession(id: String) async throws {
        _ = try await performRequest(method: .delete, path: "/api/sessions/\(id)", body: Optional<EmptyBody>.none)
    }

    func messages(sessionID: String) async throws -> [HermesMessage] {
        let response: MessageListResponse = try await get("/api/sessions/\(sessionID)/messages")
        return response.data
    }

    // MARK: - Attachments (Talaria plugin, dashboard surface)

    /// Uploads a document to the Talaria plugin, which stores it on the Hermes
    /// host and returns its absolute on-disk path. The caller references that
    /// path in a chat turn so the agent's `read_file` / `web_extract` tools can
    /// read it. Requires the dashboard admin credentials (same as model admin).
    func uploadAttachment(
        data: Data,
        filename: String,
        contentType: String?,
        sessionID: String?
    ) async throws -> TalariaAttachment {
        guard let adminBaseURL else { throw HermesError.invalidURL }
        try await ensureAdminLogin()

        let boundary = "talaria.\(UUID().uuidString)"
        var request = URLRequest(url: adminBaseURL.appending(path: HermesPlugin.path("attachments")))
        request.httpMethod = HTTPMethod.post.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(
            boundary: boundary,
            fileField: "file",
            filename: filename,
            contentType: contentType ?? "application/octet-stream",
            fileData: data,
            textFields: sessionID.map { ["session_id": $0] } ?? [:]
        )

        let respData = try await performAdminRawRequest(request)
        do {
            return try decoder.decode(TalariaAttachment.self, from: respData)
        } catch {
            throw HermesError.decoding(String(describing: error))
        }
    }

    /// Reads memory configuration from the Talaria plugin's `/memory` endpoint.
    func pluginMemoryInfo() async throws -> PluginMemoryInfo {
        try await adminRootGet(HermesPlugin.path("memory"))
    }

    /// Deletes a previously uploaded attachment by its plugin id.
    func deleteAttachment(id: String) async throws {
        guard let adminBaseURL else { throw HermesError.invalidURL }
        try await ensureAdminLogin()
        var request = URLRequest(url: adminBaseURL.appending(path: HermesPlugin.path("attachments/\(id)")))
        request.httpMethod = HTTPMethod.delete.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        _ = try await performAdminRawRequest(request)
    }

    // MARK: - Runs API

    /// Creates a new run. Passes `conversationHistory` (role+content pairs) as
    /// context since the Runs handler does NOT auto-load session history. The
    /// history is context-only and is not re-persisted to the session.
    func createRun(
        sessionID: String,
        input: String,
        model: String?,
        conversationHistory: [[String: String]]
    ) async throws -> String {
        struct Body: Encodable {
            let input: String
            let sessionId: String
            let model: String?
            let conversationHistory: [[String: String]]
        }
        let handle: RunHandle = try await send(
            .post,
            "/v1/runs",
            body: Body(
                input: input,
                sessionId: sessionID,
                model: model,
                conversationHistory: conversationHistory
            )
        )
        return handle.runId
    }

    /// Creates a new run with multipart (text + images) input.
    /// The Runs API likely accepts the same array-form `input` as session chat;
    /// this overload forwards the HermesChatInput directly.
    /// TODO: verify image_url part support against the live Runs handler.
    func createRunMultimodal(
        sessionID: String,
        input: HermesChatInput,
        model: String?,
        conversationHistory: [[String: String]]
    ) async throws -> String {
        struct Body: Encodable {
            let input: HermesChatInput
            let sessionId: String
            let model: String?
            let conversationHistory: [[String: String]]
        }
        let handle: RunHandle = try await send(
            .post,
            "/v1/runs",
            body: Body(
                input: input,
                sessionId: sessionID,
                model: model,
                conversationHistory: conversationHistory
            )
        )
        return handle.runId
    }

    /// Returns a live SSE stream of events for a Runs API run.
    /// Each emitted event's name is in the JSON data field ("event": "<name>").
    func runEvents(runID: String) -> AsyncThrowingStream<HermesStreamEvent, Error> {
        RunEventStream.events(baseURL: baseURL, apiKey: apiKey, runID: runID)
    }

    /// Polls the current status of a run (started/running/waiting_for_approval/completed/…).
    func runStatus(runID: String) async throws -> RunHandle {
        try await get("/v1/runs/\(runID)")
    }

    // MARK: - Runs control

    func stopRun(runID: String) async throws {
        _ = try await performRequest(method: .post, path: "/v1/runs/\(runID)/stop", body: Optional<EmptyBody>.none)
    }

    /// Posts an approval choice for a paused run. Choice values:
    /// "once" | "session" | "always" | "deny".
    func approveRun(runID: String, choice: String) async throws {
        struct Body: Encodable { let choice: String }
        _ = try await performRequest(method: .post, path: "/v1/runs/\(runID)/approval", body: Body(choice: choice))
    }

    /// Legacy session-stream approval signature kept for backward compat; maps to the new choice-based body.
    func approveRun(runID: String, approvalID: String, decision: String) async throws {
        try await approveRun(runID: runID, choice: decision)
    }

    // MARK: - Streaming (nonisolated factories)

    func sessionChatStream(sessionID: String, input: HermesChatInput) -> AsyncThrowingStream<HermesStreamEvent, Error> {
        HermesEventStream.make(
            baseURL: baseURL,
            apiKey: apiKey,
            sessionKey: sessionKey,
            sessionID: sessionID,
            input: input
        )
    }

    func chatCompletionStream(messages: [HermesMessage], model: String) -> AsyncThrowingStream<String, Error> {
        ChatCompletionStream.make(
            baseURL: baseURL,
            apiKey: apiKey,
            messages: messages,
            model: model
        )
    }

    // MARK: - URL building

    func buildURL(path: String) throws -> URL {
        baseURL.appending(path: path)
    }

    // MARK: - Helpers

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try await send(.get, path, body: Optional<EmptyBody>.none)
    }

    private func post<Body: Encodable, T: Decodable>(_ path: String, body: Body) async throws -> T {
        try await send(.post, path, body: body)
    }

    private func adminRootGet<T: Decodable>(_ path: String) async throws -> T {
        try await adminRootSend(.get, path, body: Optional<EmptyBody>.none)
    }

    private func adminRootPost<Body: Encodable, T: Decodable>(_ path: String, body: Body) async throws -> T {
        try await adminRootSend(.post, path, body: body)
    }

    private func send<Body: Encodable, T: Decodable>(_ method: HTTPMethod, _ path: String, body: Body?) async throws -> T {
        let data = try await performRequest(method: method, path: path, body: body)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw HermesError.decoding(String(describing: error))
        }
    }

    private func performDecode<Body: Encodable, T: Decodable>(method: HTTPMethod, url: URL, body: Body?) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
        }
        let data = try await executeRequest(request)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw HermesError.decoding(String(describing: error))
        }
    }

    private func performRequest<Body: Encodable>(method: HTTPMethod, path: String, body: Body?) async throws -> Data {
        let url = baseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
        }
        return try await executeRequest(request)
    }

    private func adminRootSend<Body: Encodable, T: Decodable>(_ method: HTTPMethod, _ path: String, body: Body?) async throws -> T {
        let data = try await performAdminRootRequest(method: method, path: path, body: body)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw HermesError.decoding(String(describing: error))
        }
    }

    private func performAdminRootRequest<Body: Encodable>(method: HTTPMethod, path: String, body: Body?) async throws -> Data {
        try await performAdminPathRequest(method: method, path: path, body: body)
    }

    private func performAdminPathRequest<Body: Encodable>(method: HTTPMethod, path: String, body: Body?) async throws -> Data {
        guard let adminBaseURL else { throw HermesError.invalidURL }
        try await ensureAdminLogin()

        let url = adminBaseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
        }
        do {
            return try await executeRequest(request)
        } catch HermesError.unauthorized where adminLoggedIn {
            adminLoggedIn = false
            try await ensureAdminLogin()
            return try await executeRequest(request)
        }
    }

    /// Runs a fully-formed admin request, transparently re-logging-in once on a
    /// stale cookie. Mirrors the retry in ``performAdminPathRequest`` but for
    /// requests whose body is already set (e.g. multipart uploads).
    private func performAdminRawRequest(_ request: URLRequest) async throws -> Data {
        do {
            return try await executeRequest(request)
        } catch HermesError.unauthorized where adminLoggedIn {
            adminLoggedIn = false
            try await ensureAdminLogin()
            return try await executeRequest(request)
        }
    }

    /// Builds a `multipart/form-data` body with optional text fields and one
    /// file part. CRLF line endings throughout, per the multipart spec.
    private static func multipartBody(
        boundary: String,
        fileField: String,
        filename: String,
        contentType: String,
        fileData: Data,
        textFields: [String: String]
    ) -> Data {
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }

        for (name, value) in textFields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(contentType)\r\n\r\n")
        body.append(fileData)
        append("\r\n")
        append("--\(boundary)--\r\n")
        return body
    }

    private func ensureAdminLogin() async throws {
        guard !adminLoggedIn else { return }
        guard let adminBaseURL,
              let username = adminUsername?.trimmingCharacters(in: .whitespacesAndNewlines),
              let password = adminPassword,
              !username.isEmpty,
              !password.isEmpty
        else { return }

        struct Body: Encodable {
            let provider: String
            let username: String
            let password: String
        }

        var request = URLRequest(url: adminBaseURL.appending(path: "/auth/password-login"))
        request.httpMethod = HTTPMethod.post.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(Body(provider: "basic", username: username, password: password))
        _ = try await executeRequest(request)
        adminLoggedIn = true
    }

    private func executeRequest(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw HermesError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw HermesError.invalidResponse
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401, 403:
            throw HermesError.unauthorized
        case 404:
            throw HermesError.notFound
        case 429:
            throw HermesError.rateLimited
        default:
            let body = String(data: data, encoding: .utf8)
            throw HermesError.httpStatus(http.statusCode, body)
        }
    }

    private func tolerantDecodeSession(_ data: Data) throws -> Session {
        // Try envelope first, then bare Session
        if let envelope = try? decoder.decode(SessionEnvelope.self, from: data) {
            return envelope.session
        }
        do {
            return try decoder.decode(Session.self, from: data)
        } catch {
            throw HermesError.decoding(String(describing: error))
        }
    }

    // MARK: - URL normalisation

    private static func normalised(_ url: URL) -> URL {
        var str = url.absoluteString
        // Strip trailing /v1 or /v1/ — we append full paths from root
        while str.hasSuffix("/") { str.removeLast() }
        if str.hasSuffix("/v1") { str = String(str.dropLast(3)) }
        return URL(string: str) ?? url
    }

    private struct EmptyBody: Encodable {}
}
