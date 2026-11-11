import Foundation

public protocol BuildThisPleaseClientProtocol: Sendable {
    func notifications(cursor: String?) async throws -> BuildThisPleaseNotificationPage
    func markNotificationsRead(ids: [String]) async throws
    func notificationPreferences() async throws -> BuildThisPleaseNotificationPreferences
    func updateNotificationPreferences(email: String?, emailEnabled: Bool?, localNotificationsEnabled: Bool?) async throws -> BuildThisPleaseNotificationPreferences
    func following(ticketId: String) async throws -> Bool
    func setFollowing(ticketId: String, following: Bool) async throws
    func configuration() async throws -> BuildThisPleaseConfigurationResponse
    func cachedRequests() async -> BuildThisPleaseRequestSnapshot?
    func preloadRequests() async throws
    func clearRequestCache() async
    func requests() async throws -> [BuildThisPleaseTicket]
    func myRequests() async throws -> [BuildThisPleaseTicket]
    func implementedRequests() async throws -> [BuildThisPleaseTicket]
    func ticket(id: String) async throws -> BuildThisPleaseTicket
    func comments(ticketId: String) async throws -> [BuildThisPleaseComment]
    func createTicket(title: String, description: String, idempotencyKey: String) async throws -> BuildThisPleaseTicket
    func createTicket(title: String, description: String, email: String?, idempotencyKey: String) async throws -> BuildThisPleaseTicket
    func setVote(ticketId: String, voted: Bool) async throws -> BuildThisPleaseTicket
    func createComment(ticketId: String, body: String, idempotencyKey: String) async throws -> BuildThisPleaseComment
    func updateComment(ticketId: String, commentId: String, body: String) async throws -> BuildThisPleaseComment
    func updateSubscriptionStatus(_ status: BuildThisPleaseSubscriptionStatus) async throws
}

public extension BuildThisPleaseClientProtocol {
    func cachedRequests() async -> BuildThisPleaseRequestSnapshot? { nil }
    func clearRequestCache() async {}
    func preloadRequests() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { _ = try await self.requests() }
            group.addTask { _ = try await self.myRequests() }
            group.addTask { _ = try await self.implementedRequests() }
            // Wait for every list, including successes after another list fails.
            var firstError: (any Error)?
            while let result = await group.nextResult() { if case .failure(let error) = result, firstError == nil { firstError = error } }
            if let firstError { throw firstError }
        }
    }

    func notifications(cursor: String? = nil) async throws -> BuildThisPleaseNotificationPage { .init(items: [], unreadCount: 0, nextCursor: nil) }
    func markNotificationsRead(ids: [String]) async throws {}
    func notificationPreferences() async throws -> BuildThisPleaseNotificationPreferences { .init() }
    func updateNotificationPreferences(email: String?, emailEnabled: Bool?, localNotificationsEnabled: Bool?) async throws -> BuildThisPleaseNotificationPreferences { throw BuildThisPleaseError.invalidResponse }
    func following(ticketId: String) async throws -> Bool { false }
    func setFollowing(ticketId: String, following: Bool) async throws { throw BuildThisPleaseError.invalidResponse }
    func createTicket(title: String, description: String, email: String?, idempotencyKey: String) async throws -> BuildThisPleaseTicket {
        try await createTicket(title: title, description: description, idempotencyKey: idempotencyKey)
    }
}

public actor BuildThisPleaseClient: BuildThisPleaseClientProtocol {
    private struct Session: Codable, Sendable { let token: String; let installationId: String; let expiresAt: Date }
    private struct SessionEnvelope: Decodable { let sessionToken: String; let installationId: String; let expiresAt: Date }
    private struct TicketEnvelope: Decodable, Sendable { let ticket: BuildThisPleaseTicket }
    private struct CommentEnvelope: Decodable, Sendable { let comment: BuildThisPleaseComment }
    private struct CommentPage: Decodable, Sendable { let items: [BuildThisPleaseComment] }
    private struct RegistrationChallenge: Codable, Sendable {
        let challengeId: String
        let challenge: String
        // Optional only to decode pending state saved by an older SDK.
        let expiresAt: Date?
    }
    private struct AssertionChallenge: Decodable { let challengeId: String; let challengeHash: String; let requestHash: String }
    private struct RegistrationBody: Encodable { let challengeId: String; let keyId: String; let attestationObject: String; let recoveryTokenHash: String }
    private struct RecoveryChallengeBody: Encodable { let keyId: String }
    private struct RecoveryBody: Encodable { let challengeId: String; let keyId: String; let assertionObject: String }
    private struct TicketBody: Encodable { let title: String; let description: String; let email: String?; let appVersion: String? }
    private struct CommentBody: Encodable { let body: String }
    private struct SubscriptionBody: Encodable { let status: BuildThisPleaseSubscriptionStatus; let observedAt: Date }
    private struct UserIdentityBody: Encodable {
        let revenueCatAppUserID: String?
        let userEmail: String?

        enum CodingKeys: String, CodingKey {
            case revenueCatAppUserID = "revenueCatAppUserId"
            case userEmail
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(revenueCatAppUserID, forKey: .revenueCatAppUserID)
            try container.encode(userEmail, forKey: .userEmail)
        }
    }
    private struct AssertionChallengeBody: Encodable { let method: String; let path: String; let bodyHash: String }
    private struct RegistrationChallengeBody: Encodable {
        let bundleId: String
        let environment: String
        let appVersion: String?
        let osVersion: String
        let subscriptionStatus: BuildThisPleaseSubscriptionStatus
        let revenueCatAppUserId: String?
        let userEmail: String?
    }

    private var config: BuildThisPleaseConfiguration
    private let transport: any BuildThisPleaseTransport
    private let credentials: any BuildThisPleaseCredentialStore
    private let attestation: any BuildThisPleaseAttestationProvider
    private let credentialPrefix: String
    private var memorySession: Session?
    private let requestCacheDisk: RequestCacheDiskStore
    private let requestCacheScope: String
    private var requestSnapshot: BuildThisPleaseRequestSnapshot?
    private var requestCacheKey: String?
    private var cacheRestored = false
    private var cacheGeneration = 0
    private var cacheClearGeneration = 0
    private var requestRevision = 0
    private var cachedTicketChanges: [String: (revision: Int, ticket: BuildThisPleaseTicket, replacedIDs: Set<String>, preservesMine: Bool)] = [:]
    private var requestFlights: [RequestList: (id: UUID, task: Task<[BuildThisPleaseTicket], Error>)] = [:]
    // Queue session establishment/recovery and complete mutation operations so a
    // mutation never pairs an old session with a replacement key or reorders counters.
    // Request-list downloads use a session acquired here, then release the queue.
    private var operationTail: Task<Void, Never>?
    // Internal gates let concurrency tests hold publication independently of transport.
    struct RequestCacheTestHooks: Sendable {
        let didQueueOperation: @Sendable () -> Void
        let didCompleteOperation: @Sendable () -> Void
        let beforePublishingTicket: @Sendable (BuildThisPleaseTicket) async -> Void
    }
    private var requestCacheTestHooks: RequestCacheTestHooks?
    func setRequestCacheTestHooks(_ hooks: RequestCacheTestHooks?) { requestCacheTestHooks = hooks }

    private struct RecoveryCredential: Codable, Sendable {
        let token: String
        let installationId: String
        var enrolled: Bool
    }
    private struct PendingRegistration: Codable, Sendable {
        let keyId: String
        let recoveryToken: String
        var challenge: RegistrationChallenge?
        var attestationObject: String?
        var registrationAttempted = false
    }
    private struct ReplacementChallenge: Codable, Sendable {
        let operationId: String
        let challengeId: String
        let installationId: String
        let challenge: String
        let expiresAt: Date
    }
    private struct PendingReplacement: Codable, Sendable {
        let operationId: String
        let installationId: String
        let oldKeyId: String
        var oldProof: String
        var fallbackProof: String?
        let newKeyId: String
        let replacementRecoveryToken: String
        var challenge: ReplacementChallenge?
        var attestationObject: String?
    }
    private struct InstallationEnvelope: Decodable { let installationId: String }
    private struct RecoveryCredentialBody: Encodable { let recoveryTokenHash: String }
    private struct ReplacementChallengeBody: Encodable {
        let operationId: String
        let installationId: String
        let oldKeyId: String
        let newKeyId: String
        let replacementRecoveryTokenHash: String
    }
    private struct ReplacementBody: Encodable {
        let operationId: String
        let installationId: String
        let keyId: String
        let attestationObject: String
        let replacementRecoveryToken: String
    }

    public init(
        configuration: BuildThisPleaseConfiguration,
        transport: any BuildThisPleaseTransport = URLSessionBuildThisPleaseTransport(),
        credentialStore: any BuildThisPleaseCredentialStore = KeychainBuildThisPleaseCredentialStore(),
        attestationProvider: any BuildThisPleaseAttestationProvider = DeviceCheckAttestationProvider(),
        requestCacheDirectory: URL? = nil
    ) {
        self.config = configuration
        self.transport = transport
        self.credentials = credentialStore
        self.attestation = attestationProvider
        self.requestCacheDisk = requestCacheDirectory.map { RequestCacheDiskStore(directory: $0) } ?? .shared
        let environment: String
        switch configuration.environment { case .production: environment = "production"; case .staging: environment = "staging"; case .local: environment = "local" }
        self.requestCacheScope = [configuration.environment.baseURL.absoluteString, environment, configuration.projectKey, configuration.bundleIdentifier, configuration.identityNamespace ?? ""].joined(separator: "\n")
        self.credentialPrefix = sha256(Data((configuration.projectKey + (configuration.identityNamespace.map { "\n" + $0 } ?? "")).utf8)).base64URLEncodedString.prefix(16).description
    }

    public func configuration() async throws -> BuildThisPleaseConfigurationResponse {
        try await get("/v1/config")
    }

    /// Reads local saved requests without establishing a session or making a network request.
    public func cachedRequests() async -> BuildThisPleaseRequestSnapshot? {
        await restoreRequestCache()
        requestSnapshot = requestSnapshot?.unexpired()
        return requestSnapshot
    }

    /// Refreshes missing or older-than-one-minute lists. Call from a retained host app task.
    public func preloadRequests() async throws {
        let snapshot = await cachedRequests()
        try Task.checkCancellation()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for section in RequestList.allCases where snapshot?.list(section)?.isFresh() != true {
                group.addTask { _ = try await self.requestList(section) }
            }
            var firstError: (any Error)?
            while let result = await group.nextResult() {
                if case .failure(let error) = result, firstError == nil { firstError = error }
            }
            try Task.checkCancellation()
            if let firstError { throw firstError }
        }
    }

    /// Clear at logout after cancelling host tasks, before replacing an account-scoped client.
    public func clearRequestCache() async {
        cacheGeneration += 1
        cacheClearGeneration += 1
        requestRevision += 1
        requestSnapshot = nil
        cachedTicketChanges.removeAll()
        cacheRestored = true
        let flights = requestFlights.values.map(\.task)
        requestFlights.removeAll()
        flights.forEach { $0.cancel() }
        // Remove all installation snapshots in this account scope, even if Keychain
        // is temporarily unavailable or this client has never restored its cache.
        await requestCacheDisk.removeScope(prefix: requestCacheScopePrefix)
    }

    public func requests() async throws -> [BuildThisPleaseTicket] { try await requestList(.requests) }
    public func myRequests() async throws -> [BuildThisPleaseTicket] { try await requestList(.mine) }
    public func implementedRequests() async throws -> [BuildThisPleaseTicket] { try await requestList(.implemented) }

    private func savedRequestCacheKey() async -> String? {
        if let memorySession { return cacheKey(installationID: memorySession.installationId) }
        guard let session: Session = try? await readCredential(sessionCredential) else { return nil }
        return cacheKey(installationID: session.installationId)
    }

    private var requestCacheScopePrefix: String { sha256(Data(requestCacheScope.utf8)).base64URLEncodedString }

    private func cacheKey(installationID: String) -> String {
        requestCacheScopePrefix + "-" + sha256(Data(installationID.utf8)).base64URLEncodedString
    }

    private func restoreRequestCache() async {
        guard !cacheRestored else { return }
        let generation = cacheGeneration
        let key = await savedRequestCacheKey()
        let saved = if let key { await requestCacheDisk.read(key: key) } else { nil as BuildThisPleaseRequestSnapshot? }
        guard generation == cacheGeneration, !cacheRestored else { return }
        requestCacheKey = key
        requestSnapshot = saved
        cacheRestored = true
    }

    private func requestList(_ section: RequestList) async throws -> [BuildThisPleaseTicket] {
        try Task.checkCancellation()
        await restoreRequestCache()
        try Task.checkCancellation()
        let flight: (id: UUID, task: Task<[BuildThisPleaseTicket], Error>)
        if let existing = requestFlights[section] { flight = existing }
        else {
            let generation = cacheGeneration
            let revision = requestRevision
            let id = UUID()
            // This finite shared operation belongs to the client, not its first UI waiter.
            // Cancelling a screen must not cancel launch preloading; clear cancels all flights.
            let clearGeneration = cacheClearGeneration
            let task = Task { try await self.fetchRequestList(section, generation: generation, revision: revision, clearGeneration: clearGeneration) }
            flight = (id, task)
            requestFlights[section] = flight
        }
        do {
            let items = try await flight.task.value
            if requestFlights[section]?.id == flight.id { requestFlights[section] = nil }
            try Task.checkCancellation()
            return items
        } catch {
            if requestFlights[section]?.id == flight.id { requestFlights[section] = nil }
            throw error
        }
    }

    private func fetchRequestList(_ section: RequestList, generation: Int, revision: Int, clearGeneration: Int, mayRetryIdentityChange: Bool = true) async throws -> [BuildThisPleaseTicket] {
        let page = try await getRequestList(section.path)
        try Task.checkCancellation()
        guard clearGeneration == cacheClearGeneration else { throw CancellationError() }
        if generation != cacheGeneration {
            // Establishing a genuinely different installation clears old viewer state.
            // Retry its authorized list once; explicit logout clearing never retries.
            guard mayRetryIdentityChange else { throw CancellationError() }
            return try await fetchRequestList(section, generation: cacheGeneration, revision: requestRevision, clearGeneration: clearGeneration, mayRetryIdentityChange: false)
        }
        // Preserve newer local writes while still accepting server additions and removals.
        var items = page.items
        for change in cachedTicketChanges.values.sorted(by: { $0.revision < $1.revision }) where change.revision > revision {
            items = merging(change.ticket, replacing: change.replacedIDs, into: items, section: section, preservesMine: change.preservesMine)
        }
        requestSnapshot = (requestSnapshot ?? .init()).replacing(section, with: .init(items: items, updatedAt: .now))
        await persistRequestCache()
        guard generation == cacheGeneration else { throw CancellationError() }
        return requestSnapshot?.list(section)?.items ?? page.items
    }

    private func persistRequestCache() async {
        guard let snapshot = requestSnapshot, let session = memorySession else { return }
        let key = cacheKey(installationID: session.installationId)
        requestCacheKey = key
        await requestCacheDisk.write(snapshot, key: key)
    }

    private func merging(_ ticket: BuildThisPleaseTicket, replacing ids: Set<String>, into items: [BuildThisPleaseTicket], section: RequestList, preservesMine: Bool) -> [BuildThisPleaseTicket] {
        let wasPresent = items.contains { matches($0, ids: ids) }
        var result = items.filter { !matches($0, ids: ids) }
        let belongs: Bool = switch section {
        case .requests: [.inReview, .planned, .inProgress].contains(ticket.status)
        case .implemented: ticket.status == .implemented
        case .mine: wasPresent || preservesMine
        }
        if belongs { result.insert(ticket, at: 0) }
        return result
    }

    private func matches(_ ticket: BuildThisPleaseTicket, ids: Set<String>) -> Bool {
        ids.contains(ticket.id) || ticket.canonicalTicketId.map(ids.contains) == true
    }

    private func cacheTicket(_ ticket: BuildThisPleaseTicket, replacingID: String? = nil, created: Bool = false, generation: Int) async {
        await requestCacheTestHooks?.beforePublishingTicket(ticket)
        guard generation == cacheGeneration else { return }
        // Detail(S) can return C without an alias in C's wire representation.
        // Retain the requested identity, including earlier S -> C -> D changes,
        // so an older list cannot restore any of those source rows.
        var replacedIDs: Set<String> = [ticket.id]
        if let replacingID { replacedIDs.insert(replacingID) }
        for change in cachedTicketChanges.values where !change.replacedIDs.isDisjoint(with: replacedIDs) {
            replacedIDs.formUnion(change.replacedIDs)
        }
        let preservesMine = created || requestSnapshot?.mine?.items.contains { matches($0, ids: replacedIDs) } == true
        cachedTicketChanges = cachedTicketChanges.filter { $0.value.replacedIDs.isDisjoint(with: replacedIDs) }
        requestRevision += 1
        cachedTicketChanges[ticket.id] = (requestRevision, ticket, replacedIDs, preservesMine)
        var snapshot = requestSnapshot ?? .init()
        for section in RequestList.allCases {
            guard let list = snapshot.list(section) else { continue }
            let items = merging(ticket, replacing: replacedIDs, into: list.items, section: section, preservesMine: preservesMine)
            snapshot = snapshot.replacing(section, with: .init(items: items, updatedAt: list.updatedAt, isComplete: list.isComplete))
        }
        if created && snapshot.mine == nil { snapshot = snapshot.replacing(.mine, with: .init(items: [ticket], updatedAt: .now, isComplete: false)) }
        requestSnapshot = snapshot
        await persistRequestCache()
    }

    public func ticket(id: String) async throws -> BuildThisPleaseTicket {
        await restoreRequestCache()
        let generation = cacheGeneration
        return try await serialized { client in
            let revision = client.requestRevision
            let envelope: TicketEnvelope = try await client.getAuthenticated("/v1/tickets/\(id)")
            guard generation == client.cacheGeneration else { throw CancellationError() }
            if let newer = client.cachedTicketChanges.values.first(where: { $0.replacedIDs.contains(id) && $0.revision > revision }) { return newer.ticket }
            await client.cacheTicket(envelope.ticket, replacingID: id, generation: generation)
            return envelope.ticket
        }
    }

    public func comments(ticketId: String) async throws -> [BuildThisPleaseComment] {
        let page: CommentPage = try await get("/v1/tickets/\(ticketId)/comments")
        return page.items
    }

    public func createTicket(title: String, description: String, idempotencyKey: String = UUID().uuidString) async throws -> BuildThisPleaseTicket {
        try await createTicket(title: title, description: description, email: nil, idempotencyKey: idempotencyKey)
    }

    public func createTicket(title: String, description: String, email: String?, idempotencyKey: String = UUID().uuidString) async throws -> BuildThisPleaseTicket {
        await restoreRequestCache()
        let generation = cacheGeneration
        let body = TicketBody(title: title, description: description, email: Self.normalizedOptional(email)?.lowercased(), appVersion: Self.normalizedOptional(config.appVersion))
        return try await mutateTicket("POST", path: "/v1/tickets", bodyData: try JSONCoding.encoder().encode(body), idempotencyKey: idempotencyKey, created: true, generation: generation)
    }

    public func setVote(ticketId: String, voted: Bool) async throws -> BuildThisPleaseTicket {
        await restoreRequestCache()
        let generation = cacheGeneration
        return try await mutateTicket(voted ? "PUT" : "DELETE", path: "/v1/tickets/\(ticketId)/vote", bodyData: Data(), replacingID: ticketId, generation: generation)
    }

    private func mutateTicket(_ method: String, path: String, bodyData: Data, idempotencyKey: String? = nil, replacingID: String? = nil, created: Bool = false, generation: Int) async throws -> BuildThisPleaseTicket {
        try await serialized { client in
            let envelope: TicketEnvelope = try await client.mutateAuthenticated(method, path: path, bodyData: bodyData, idempotencyKey: idempotencyKey)
            // Publish before releasing the queue, so a later response cannot be
            // overwritten by an earlier caller resuming after task completion.
            await client.cacheTicket(envelope.ticket, replacingID: replacingID, created: created, generation: generation)
            return envelope.ticket
        }
    }

    public func createComment(ticketId: String, body: String, idempotencyKey: String = UUID().uuidString) async throws -> BuildThisPleaseComment {
        let envelope: CommentEnvelope = try await mutate("POST", path: "/v1/tickets/\(ticketId)/comments", body: CommentBody(body: body), idempotencyKey: idempotencyKey)
        return envelope.comment
    }

    public func updateComment(ticketId: String, commentId: String, body: String) async throws -> BuildThisPleaseComment {
        let envelope: CommentEnvelope = try await mutate("PATCH", path: "/v1/tickets/\(ticketId)/comments/\(commentId)", body: CommentBody(body: body))
        return envelope.comment
    }

    public func updateSubscriptionStatus(_ status: BuildThisPleaseSubscriptionStatus) async throws {
        config.subscriptionStatus = status
        let _: EmptyResponse = try await mutate("PATCH", path: "/v1/installations/me/subscription-status", body: SubscriptionBody(status: status, observedAt: .now))
    }

    public func updateUserIdentity(revenueCatAppUserID: String?, email: String? = nil) async throws {
        let normalizedID = Self.normalizedOptional(revenueCatAppUserID)
        let normalizedEmail = Self.normalizedOptional(email)?.lowercased()
        let body = UserIdentityBody(revenueCatAppUserID: normalizedID, userEmail: normalizedEmail)
        let _: EmptyResponse = try await mutate("PATCH", path: "/v1/installations/me/user-identity", body: body)
        config.revenueCatAppUserID = normalizedID
        config.userEmail = normalizedEmail
    }

    public func notifications(cursor: String? = nil) async throws -> BuildThisPleaseNotificationPage {
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "limit", value: "100")] + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
        return try await get("/v1/me/notifications" + (components.string ?? ""))
    }
    public func markNotificationsRead(ids: [String]) async throws {
        struct Body: Encodable { let ids: [String] }
        let _: EmptyResponse = try await mutate("PATCH", path: "/v1/me/notifications/read", body: Body(ids: ids))
    }
    public func notificationPreferences() async throws -> BuildThisPleaseNotificationPreferences { try await get("/v1/me/notification-preferences") }
    public func updateNotificationPreferences(email: String? = nil, emailEnabled: Bool? = nil, localNotificationsEnabled: Bool? = nil) async throws -> BuildThisPleaseNotificationPreferences {
        struct Body: Encodable { let email: String?; let emailEnabled: Bool?; let localNotificationsEnabled: Bool? }
        return try await mutate("PATCH", path: "/v1/me/notification-preferences", body: Body(email: email, emailEnabled: emailEnabled, localNotificationsEnabled: localNotificationsEnabled))
    }
    public func following(ticketId: String) async throws -> Bool {
        struct Body: Decodable, Sendable { let following: Bool }
        let body: Body = try await get("/v1/tickets/\(ticketId)/follow")
        return body.following
    }
    public func setFollowing(ticketId: String, following: Bool) async throws {
        struct Body: Codable, Sendable { let following: Bool }
        let _: Body = try await mutate("PUT", path: "/v1/tickets/\(ticketId)/follow", body: Body(following: following))
    }
    /// Ask the authenticated host backend to sign a five-minute proof bound to this installation.
    public func installationIdentifier() async throws -> String {
        try await serialized { client in try await client.validSession().installationId }
    }
    public func linkUserIdentity(token: String) async throws {
        struct Body: Encodable { let token: String }
        let _: EmptyResponse = try await mutate("POST", path: "/v1/me/identity-link", body: Body(token: token))
    }

    private func serialized<Response: Sendable>(
        _ operation: @escaping @Sendable (isolated BuildThisPleaseClient) async throws -> Response
    ) async throws -> Response {
        let previous = operationTail
        let hooks = requestCacheTestHooks
        let task = Task {
            if let previous { await previous.value }
            try Task.checkCancellation()
            defer { hooks?.didCompleteOperation() }
            return try await operation(self)
        }
        operationTail = Task { _ = try? await task.value }
        hooks?.didQueueOperation()
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func get<Response: Decodable & Sendable>(_ path: String) async throws -> Response {
        try await serialized { client in try await client.getAuthenticated(path) }
    }

    private func getAuthenticated<Response: Decodable & Sendable>(_ path: String) async throws -> Response {
        do {
            let session = try await validSession()
            return try await perform("GET", path: path, bodyData: nil, token: session.token)
        } catch where Self.isInvalidSession(error) {
            let session = try await validSession(forceRefresh: true)
            return try await perform("GET", path: path, bodyData: nil, token: session.token)
        }
    }

    /// List GETs need a session token but no App Attest assertion. Serialize only
    /// session work, allowing unrelated lists to publish while one endpoint is slow.
    private func getRequestList(_ path: String) async throws -> BuildThisPleasePage<BuildThisPleaseTicket> {
        let session = try await requestListSession()
        try Task.checkCancellation()
        do {
            return try await perform("GET", path: path, bodyData: nil, token: session.token)
        } catch where Self.isInvalidSession(error) {
            let refreshed = try await requestListSession(replacingRejectedToken: session.token)
            try Task.checkCancellation()
            return try await perform("GET", path: path, bodyData: nil, token: refreshed.token)
        }
    }

    private func requestListSession(replacingRejectedToken rejectedToken: String? = nil) async throws -> Session {
        try await serialized { client in
            let current = try await client.validSession()
            // Another GET or mutation may already have recovered this rejected token.
            // Reuse that session instead of repeatedly invalidating parallel retries.
            guard let rejectedToken, current.token == rejectedToken else { return current }
            return try await client.validSession(forceRefresh: true)
        }
    }

    private func mutate<Response: Decodable & Sendable, Body: Encodable>(_ method: String, path: String, body: Body, idempotencyKey: String? = nil) async throws -> Response {
        try await mutate(method, path: path, bodyData: try JSONCoding.encoder().encode(body), idempotencyKey: idempotencyKey)
    }

    private func mutate<Response: Decodable & Sendable>(_ method: String, path: String, bodyData: Data, idempotencyKey: String? = nil) async throws -> Response {
        try await serialized { client in
            try await client.mutateAuthenticated(method, path: path, bodyData: bodyData, idempotencyKey: idempotencyKey)
        }
    }

    private func mutateAuthenticated<Response: Decodable & Sendable>(_ method: String, path: String, bodyData: Data, idempotencyKey: String? = nil) async throws -> Response {
        var session: Session?
        do {
            let established = try await validSession()
            session = established
            return try await mutateOnce(method, path: path, bodyData: bodyData, idempotencyKey: idempotencyKey, session: established)
        } catch {
            if Self.isInvalidSession(error) {
                let refreshed = try await validSession(forceRefresh: true)
                return try await mutateOnce(method, path: path, bodyData: bodyData, idempotencyKey: idempotencyKey, session: refreshed)
            }
            // The only automatic key replacement trigger is a native assertion
            // failure, before the business request has been sent.
            guard Self.isInvalidAssertionKey(error) else { throw error }
            let replacement = try await replaceKey(existingSession: session)
            return try await mutateOnce(method, path: path, bodyData: bodyData, idempotencyKey: idempotencyKey, session: replacement)
        }
    }

    private func mutateOnce<Response: Decodable>(_ method: String, path: String, bodyData: Data, idempotencyKey: String? = nil, session: Session) async throws -> Response {
        var headers: [String: String] = [:]
        if let idempotencyKey { headers["Idempotency-Key"] = idempotencyKey }
        if attestation.isSupported {
            guard let keyId = try await credentials.value(for: keyIdCredential) else { throw BuildThisPleaseError.attestationFailed }
            let bodyHash = sha256(bodyData).base64URLEncodedString
            let challengeBody = AssertionChallengeBody(method: method, path: path, bodyHash: bodyHash)
            let challenge: AssertionChallenge = try await perform("POST", path: "/v1/attestation/assertions/challenges", bodyData: try JSONCoding.encoder().encode(challengeBody), token: session.token)
            let canonical = Data("BuildThisPlease/v1\n\(challenge.challengeHash)\n\(challenge.requestHash)".utf8)
            let assertion: Data
            do { assertion = try await attestation.generateAssertion(keyId, clientDataHash: sha256(canonical)) }
            catch where Self.isUnusableNativeKey(error) { throw InvalidAssertionKey(underlying: error) }
            headers["X-BTP-Attest-Challenge-ID"] = challenge.challengeId
            headers["X-BTP-App-Attest-Assertion"] = assertion.base64URLEncodedString
        }
        return try await perform(method, path: path, bodyData: bodyData, token: session.token, extraHeaders: headers)
    }

    private struct InvalidAssertionKey: Error { let underlying: any Error }
    private static func isInvalidAssertionKey(_ error: any Error) -> Bool { error is InvalidAssertionKey }
    private static func isInvalidSession(_ error: any Error) -> Bool {
        guard case BuildThisPleaseError.server(let code, _, let status) = error else { return false }
        return status == 401 && code == "installation_session_invalid"
    }
    private static func isUnusableNativeKey(_ error: any Error) -> Bool {
        let native = error as NSError
        return native.domain == "com.apple.devicecheck.error" && [2, 3].contains(native.code)
    }

    private func validSession(forceRefresh: Bool = false) async throws -> Session {
        // A persisted replacement always wins, including after a crash between
        // writing the new session and writing its matching key.
        if let pending: PendingReplacement = try await readCredential(pendingReplacementCredential) {
            return try await resumeReplacement(pending)
        }
        if let pending: PendingRegistration = try await readCredential(pendingRegistrationCredential) {
            do {
                let session = try await resumeRegistration(pending)
                return try await ensureRecoveryCredential(session)
            } catch {
                // A failed final deletion can leave a completed registration here.
                // Replace a lost native key only when every committed credential
                // still matches that registration and its saved recovery proof.
                // A lost acknowledgement can leave enrolled=false; the backend
                // still validates the saved session or fallback token on replacement.
                guard Self.isInvalidAssertionKey(error),
                      let session = try await committedRegistrationSession(pending) else { throw error }
                return try await replaceKey(existingSession: session)
            }
        }
        if !forceRefresh, let memorySession, memorySession.expiresAt.timeIntervalSinceNow > 60 {
            return try await ensureRecoveryCredential(memorySession)
        }
        let stored: Session? = try await readCredential(sessionCredential)
        if !forceRefresh, let stored, stored.expiresAt.timeIntervalSinceNow > 60 {
            memorySession = stored
            return try await ensureRecoveryCredential(stored)
        }
        let session: Session
        if !attestation.isSupported {
            guard config.environment.permitsDevelopmentBypass else { throw BuildThisPleaseError.appAttestUnavailable }
            let envelope: SessionEnvelope = try await perform("POST", path: "/v1/development/sessions", bodyData: try JSONCoding.encoder().encode(registrationChallengeBody()), token: nil)
            session = Self.session(envelope)
            try await persistSession(session)
        } else if let keyId = try await credentials.value(for: keyIdCredential) {
            do {
                session = try await recoverSession(keyId: keyId)
                if let stored, stored.installationId != session.installationId { throw BuildThisPleaseError.invalidResponse }
                if let recovery: RecoveryCredential = try await readCredential(recoveryCredential), recovery.installationId != session.installationId { throw BuildThisPleaseError.invalidResponse }
                try await persistSession(session)
            } catch {
                guard Self.isInvalidAssertionKey(error) else { throw error }
                return try await replaceKey(existingSession: stored)
            }
        } else {
            // Never silently create another identity if any original proof remains.
            let recovery: RecoveryCredential? = try await readCredential(recoveryCredential)
            guard stored == nil, recovery == nil else { throw BuildThisPleaseError.attestationFailed }
            let pending = PendingRegistration(keyId: try await attestation.generateKey(), recoveryToken: Self.randomToken())
            try await writeCredential(pending, key: pendingRegistrationCredential)
            session = try await resumeRegistration(pending)
        }
        return try await ensureRecoveryCredential(session)
    }

    private func ensureRecoveryCredential(_ session: Session) async throws -> Session {
        guard attestation.isSupported else { return session }
        var recovery: RecoveryCredential
        if let stored: RecoveryCredential = try await readCredential(recoveryCredential) {
            guard stored.installationId == session.installationId else { throw BuildThisPleaseError.invalidResponse }
            if stored.enrolled { return session }
            recovery = stored
        } else {
            recovery = RecoveryCredential(token: Self.randomToken(), installationId: session.installationId, enrolled: false)
            // Save the secret before enrollment. A lost response can be retried.
            try await writeCredential(recovery, key: recoveryCredential)
        }
        let body = RecoveryCredentialBody(recoveryTokenHash: sha256(Data(recovery.token.utf8)).base64URLEncodedString)
        let envelope: InstallationEnvelope
        do {
            envelope = try await mutateOnce("POST", path: "/v1/installations/recovery-credential", bodyData: try JSONCoding.encoder().encode(body), session: session)
        } catch {
            guard Self.isInvalidAssertionKey(error) else { throw error }
            return try await replaceKey(existingSession: session)
        }
        guard envelope.installationId == session.installationId else { throw BuildThisPleaseError.invalidResponse }
        recovery.enrolled = true
        try await writeCredential(recovery, key: recoveryCredential)
        return session
    }

    private struct ExpiredInitialRegistration: Error {}

    private func hasEstablishedIdentity() async throws -> Bool {
        if memorySession != nil { return true }
        // Even malformed saved credentials are evidence of an existing identity.
        // Never replace an initial registration over any of them.
        for key in [keyIdCredential, sessionCredential, recoveryCredential, pendingReplacementCredential] {
            if try await credentials.value(for: key) != nil { return true }
        }
        return false
    }

    private func resumeRegistration(_ original: PendingRegistration, allowRestart: Bool = true) async throws -> Session {
        do {
            return try await continueRegistration(original)
        } catch {
            let unsavedAttestation = error is InvalidPendingAttestationKey && !original.registrationAttempted && original.attestationObject == nil
            let expiredAndUnregistered = error is ExpiredInitialRegistration
            guard allowRestart, unsavedAttestation || expiredAndUnregistered else { throw error }
            guard try await !hasEstablishedIdentity() else { throw BuildThisPleaseError.attestationFailed }
            // No request can have been submitted without a saved attestation.
            // Expired requests additionally require an explicit server lookup
            // proving that this initial key has not established an installation.
            let restarted = PendingRegistration(keyId: try await attestation.generateKey(), recoveryToken: original.recoveryToken)
            try await writeCredential(restarted, key: pendingRegistrationCredential)
            return try await resumeRegistration(restarted, allowRestart: false)
        }
    }

    private func registeredInitialSession(_ pending: PendingRegistration) async throws -> Session? {
        do {
            let recovered = try await recoverSession(keyId: pending.keyId)
            // A crash can leave both pending registration and partial active
            // credentials. They must refer to this same installation.
            if let stored: Session = try await readCredential(sessionCredential), stored.installationId != recovered.installationId { throw BuildThisPleaseError.invalidResponse }
            if let recovery: RecoveryCredential = try await readCredential(recoveryCredential), recovery.installationId != recovered.installationId { throw BuildThisPleaseError.invalidResponse }
            // The registration may have stored its key before recovery-token
            // enrollment or session issuance failed. A recovered key proves
            // identity, not that enrollment completed; confirm it explicitly.
            try await finishRegistration(pending, session: recovered, recoveryEnrolled: false)
            return recovered
        } catch let error as BuildThisPleaseError {
            guard case .server(let code, _, _) = error, code == "attestation_key_not_registered" else { throw error }
            return nil
        }
    }

    private func continueRegistration(_ original: PendingRegistration) async throws -> Session {
        var pending = original
        if try await hasEstablishedIdentity() {
            // Only a partial commit of this already-submitted registration can
            // legitimately coexist with active identity credentials.
            guard pending.registrationAttempted else { throw BuildThisPleaseError.attestationFailed }
            if let keyId = try await credentials.value(for: keyIdCredential), keyId != pending.keyId { throw BuildThisPleaseError.invalidResponse }
        }
        let challengeExpired = pending.challenge?.expiresAt.map { $0 <= .now } ?? false
        if pending.registrationAttempted || challengeExpired {
            // A lost accepted response must recover the original installation,
            // even when its now-used registration challenge has expired.
            if let recovered = try await registeredInitialSession(pending) { return recovered }
            guard try await !hasEstablishedIdentity() else { throw BuildThisPleaseError.attestationFailed }
            if challengeExpired { throw ExpiredInitialRegistration() }
        }
        if pending.challenge == nil {
            pending.challenge = try await perform("POST", path: "/v1/attestation/challenges", bodyData: try JSONCoding.encoder().encode(registrationChallengeBody()), token: nil)
            try await writeCredential(pending, key: pendingRegistrationCredential)
        }
        guard let challenge = pending.challenge else { throw BuildThisPleaseError.invalidResponse }
        if pending.attestationObject == nil {
            let object: Data
            do { object = try await attestation.attestKey(pending.keyId, clientDataHash: sha256(Data(challenge.challenge.utf8))) }
            catch where Self.isUnusableNativeKey(error) { throw InvalidPendingAttestationKey() }
            pending.attestationObject = object.base64URLEncodedString
            try await writeCredential(pending, key: pendingRegistrationCredential)
        }
        guard let object = pending.attestationObject else { throw BuildThisPleaseError.invalidResponse }
        pending.registrationAttempted = true
        try await writeCredential(pending, key: pendingRegistrationCredential)
        let registration = RegistrationBody(challengeId: challenge.challengeId, keyId: pending.keyId, attestationObject: object, recoveryTokenHash: sha256(Data(pending.recoveryToken.utf8)).base64URLEncodedString)
        let envelope: SessionEnvelope
        do {
            envelope = try await perform("POST", path: "/v1/attestation/registrations", bodyData: try JSONCoding.encoder().encode(registration), token: nil)
        } catch let error as BuildThisPleaseError {
            guard case .server(let code, _, _) = error, code == "attestation_challenge_invalid" else { throw error }
            // This response also covers a used challenge. Never infer absence
            // of an installation from it; look up and recover this key first.
            if let recovered = try await registeredInitialSession(pending) { return recovered }
            throw ExpiredInitialRegistration()
        }
        let session = Self.session(envelope)
        try await finishRegistration(pending, session: session)
        return session
    }

    private func finishRegistration(_ pending: PendingRegistration, session: Session, recoveryEnrolled: Bool = true) async throws {
        try await persistSession(session)
        try await credentials.set(pending.keyId, for: keyIdCredential)
        try await writeCredential(RecoveryCredential(token: pending.recoveryToken, installationId: session.installationId, enrolled: recoveryEnrolled), key: recoveryCredential)
        // With all active credentials durable, enrolled=false becomes the
        // pending enrollment phase. validSession confirms it using a full
        // assertion before returning any business result, and retries it after
        // failures without ever creating another installation.
        try await credentials.removeValue(for: pendingRegistrationCredential)
    }

    private func committedRegistrationSession(_ pending: PendingRegistration) async throws -> Session? {
        guard pending.registrationAttempted,
              try await credentials.value(for: keyIdCredential) == pending.keyId,
              let session: Session = try await readCredential(sessionCredential),
              let recovery: RecoveryCredential = try await readCredential(recoveryCredential),
              recovery.installationId == session.installationId,
              recovery.token == pending.recoveryToken else { return nil }
        return session
    }

    private func replaceKey(existingSession: Session?) async throws -> Session {
        if let pending: PendingReplacement = try await readCredential(pendingReplacementCredential) { return try await resumeReplacement(pending) }
        guard let oldKeyId = try await credentials.value(for: keyIdCredential) else { throw BuildThisPleaseError.attestationFailed }
        let recovery: RecoveryCredential? = try await readCredential(recoveryCredential)
        let installationId = existingSession?.installationId ?? recovery?.installationId
        let proof = recovery?.enrolled == true ? recovery?.token : existingSession?.token
        guard let installationId, let proof else { throw BuildThisPleaseError.attestationFailed }
        if let recovery, recovery.installationId != installationId { throw BuildThisPleaseError.invalidResponse }
        // An enrollment response can be lost after the backend accepted the saved
        // token. Keep that alternative proof without assuming enrollment succeeded.
        let fallbackProof = recovery?.enrolled == false ? recovery?.token : nil
        let pending = PendingReplacement(operationId: UUID().uuidString.lowercased(), installationId: installationId, oldKeyId: oldKeyId, oldProof: proof, fallbackProof: fallbackProof, newKeyId: try await attestation.generateKey(), replacementRecoveryToken: Self.randomToken())
        try await writeCredential(pending, key: pendingReplacementCredential)
        return try await resumeReplacement(pending)
    }

    private struct InvalidPendingAttestationKey: Error {}

    private func resumeReplacement(_ original: PendingReplacement, allowRestart: Bool = true) async throws -> Session {
        do {
            return try await continueReplacement(original)
        } catch {
            let expired: Bool
            if case BuildThisPleaseError.server(let code, _, _) = error { expired = code == "key_replacement_challenge_expired" }
            else { expired = false }
            guard allowRestart, expired || error is InvalidPendingAttestationKey else { throw error }
            // An explicit expiry is returned only for an uncompleted operation;
            // completed operations remain idempotently resumable. A native key
            // error here is wrapped only when no attestation object was saved,
            // so the completion request could not have been sent. Both cases
            // can safely retry with a new key while keeping the original identity.
            let restarted = PendingReplacement(operationId: UUID().uuidString.lowercased(), installationId: original.installationId, oldKeyId: original.oldKeyId, oldProof: original.oldProof, fallbackProof: original.fallbackProof, newKeyId: try await attestation.generateKey(), replacementRecoveryToken: Self.randomToken())
            try await writeCredential(restarted, key: pendingReplacementCredential)
            return try await resumeReplacement(restarted, allowRestart: false)
        }
    }

    private func continueReplacement(_ original: PendingReplacement) async throws -> Session {
        var pending = original
        if pending.challenge == nil {
            let body = ReplacementChallengeBody(operationId: pending.operationId, installationId: pending.installationId, oldKeyId: pending.oldKeyId, newKeyId: pending.newKeyId, replacementRecoveryTokenHash: sha256(Data(pending.replacementRecoveryToken.utf8)).base64URLEncodedString)
            let challenge: ReplacementChallenge
            do {
                challenge = try await perform("POST", path: "/v1/attestation/key-replacements/challenges", bodyData: try JSONCoding.encoder().encode(body), token: pending.oldProof)
            } catch let error as BuildThisPleaseError {
                guard case .server(let code, _, _) = error, code == "key_replacement_proof_invalid", let alternative = pending.fallbackProof else { throw error }
                pending.oldProof = alternative
                pending.fallbackProof = nil
                try await writeCredential(pending, key: pendingReplacementCredential)
                challenge = try await perform("POST", path: "/v1/attestation/key-replacements/challenges", bodyData: try JSONCoding.encoder().encode(body), token: pending.oldProof)
            }
            guard challenge.operationId == pending.operationId, challenge.challengeId == pending.operationId, challenge.installationId == pending.installationId else { throw BuildThisPleaseError.invalidResponse }
            pending.challenge = challenge
            try await writeCredential(pending, key: pendingReplacementCredential)
        }
        guard let challenge = pending.challenge else { throw BuildThisPleaseError.invalidResponse }
        if pending.attestationObject == nil {
            // In particular, DCError.serverUnavailable must retain this same key
            // and hash. Never replace the pending challenge on a retry.
            let object: Data
            do { object = try await attestation.attestKey(pending.newKeyId, clientDataHash: sha256(Data(challenge.challenge.utf8))) }
            catch where Self.isUnusableNativeKey(error) { throw InvalidPendingAttestationKey() }
            pending.attestationObject = object.base64URLEncodedString
            try await writeCredential(pending, key: pendingReplacementCredential)
        }
        guard let object = pending.attestationObject else { throw BuildThisPleaseError.invalidResponse }
        let body = ReplacementBody(operationId: pending.operationId, installationId: pending.installationId, keyId: pending.newKeyId, attestationObject: object, replacementRecoveryToken: pending.replacementRecoveryToken)
        let envelope: SessionEnvelope = try await perform("POST", path: "/v1/attestation/key-replacements", bodyData: try JSONCoding.encoder().encode(body), token: pending.oldProof)
        guard envelope.installationId == pending.installationId else { throw BuildThisPleaseError.invalidResponse }
        let session = Self.session(envelope)
        // Pending state stays in Keychain until every replacement credential is
        // durable, making crashes or partial write failures resumable.
        try await persistSession(session)
        try await credentials.set(pending.newKeyId, for: keyIdCredential)
        try await writeCredential(RecoveryCredential(token: pending.replacementRecoveryToken, installationId: pending.installationId, enrolled: true), key: recoveryCredential)
        if let registration: PendingRegistration = try await readCredential(pendingRegistrationCredential),
           registration.registrationAttempted, registration.keyId == pending.oldKeyId,
           registration.recoveryToken == pending.oldProof || registration.recoveryToken == pending.fallbackProof {
            // Keep the replacement journal until this matching old registration
            // is retired too, so a crash or deletion failure can retry cleanup.
            try await credentials.removeValue(for: pendingRegistrationCredential)
        }
        try await credentials.removeValue(for: pendingReplacementCredential)
        return session
    }

    private func recoverSession(keyId: String) async throws -> Session {
        let challenge: AssertionChallenge = try await perform("POST", path: "/v1/attestation/recovery/challenges", bodyData: try JSONCoding.encoder().encode(RecoveryChallengeBody(keyId: keyId)), token: nil)
        let canonical = Data("BuildThisPlease/v1\n\(challenge.challengeHash)\n\(challenge.requestHash)".utf8)
        let assertion: Data
        do { assertion = try await attestation.generateAssertion(keyId, clientDataHash: sha256(canonical)) }
        catch where Self.isUnusableNativeKey(error) { throw InvalidAssertionKey(underlying: error) }
        let body = RecoveryBody(challengeId: challenge.challengeId, keyId: keyId, assertionObject: assertion.base64URLEncodedString)
        let envelope: SessionEnvelope = try await perform("POST", path: "/v1/attestation/recoveries", bodyData: try JSONCoding.encoder().encode(body), token: nil)
        return Self.session(envelope)
    }

    private static func session(_ envelope: SessionEnvelope) -> Session {
        Session(token: envelope.sessionToken, installationId: envelope.installationId, expiresAt: envelope.expiresAt)
    }
    private static func randomToken() -> String {
        var random = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) }).base64URLEncodedString
    }
    private func persistSession(_ session: Session) async throws {
        let newKey = cacheKey(installationID: session.installationId)
        if let oldKey = requestCacheKey, oldKey != newKey {
            cacheGeneration += 1
            requestRevision += 1
            requestSnapshot = nil
            cachedTicketChanges.removeAll()
            await requestCacheDisk.remove(key: oldKey)
        }
        requestCacheKey = newKey
        try await writeCredential(session, key: sessionCredential)
        memorySession = session
    }
    private func readCredential<Value: Decodable>(_ key: String) async throws -> Value? {
        guard let value = try await credentials.value(for: key) else { return nil }
        // A malformed saved credential is evidence of an existing identity. Fail
        // closed rather than interpreting it as a first installation.
        return try JSONCoding.decoder().decode(Value.self, from: Data(value.utf8))
    }
    private func writeCredential<Value: Encodable>(_ value: Value, key: String) async throws {
        let encoded = try JSONCoding.encoder().encode(value)
        try await credentials.set(String(decoding: encoded, as: UTF8.self), for: key)
    }

    private func registrationChallengeBody() -> RegistrationChallengeBody {
        RegistrationChallengeBody(
            bundleId: config.bundleIdentifier,
            environment: config.environment.attestationEnvironment,
            appVersion: config.appVersion,
            osVersion: config.osVersion,
            subscriptionStatus: config.subscriptionStatus,
            revenueCatAppUserId: config.revenueCatAppUserID,
            userEmail: config.userEmail
        )
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func perform<Response: Decodable>(
        _ method: String,
        path: String,
        bodyData: Data?,
        token: String?,
        extraHeaders: [String: String] = [:]
    ) async throws -> Response {
        guard let url = URL(string: path, relativeTo: config.environment.baseURL)?.absoluteURL else {
            throw BuildThisPleaseError.invalidConfiguration(
                String(localized: "The API URL is invalid.", bundle: .module)
            )
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = bodyData
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.projectKey, forHTTPHeaderField: "X-BuildThisPlease-Project-Key")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (name, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            if let envelope = try? JSONCoding.decoder().decode(APIErrorEnvelope.self, from: data) {
                throw BuildThisPleaseError.server(code: envelope.error.code, message: envelope.error.message, status: response.statusCode)
            }
            throw BuildThisPleaseError.invalidResponse
        }
        if Response.self == EmptyResponse.self { return EmptyResponse() as! Response }
        do { return try JSONCoding.decoder().decode(Response.self, from: data) }
        catch { throw BuildThisPleaseError.invalidResponse }
    }

    private var sessionCredential: String { "\(credentialPrefix).session" }
    private var keyIdCredential: String { "\(credentialPrefix).appAttestKeyId" }
    private var recoveryCredential: String { "\(credentialPrefix).recoveryCredential" }
    private var pendingReplacementCredential: String { "\(credentialPrefix).pendingKeyReplacement" }
    private var pendingRegistrationCredential: String { "\(credentialPrefix).pendingRegistration" }
}

private struct EmptyResponse: Decodable, Sendable {}
