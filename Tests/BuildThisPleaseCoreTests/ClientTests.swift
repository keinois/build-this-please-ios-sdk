import Foundation
import Testing
@testable import BuildThisPleaseCore

@Suite("BuildThisPlease client contract")
struct ClientTests {
    @Test("Ticket submission sends the host app version", arguments: ["2.4.1", nil] as [String?])
    func submitsAppVersion(appVersion: String?) async throws {
        let transport = TicketVersionTransport()
        let configuration = try BuildThisPleaseConfiguration(
            projectKey: "btp_pk_version_fixture",
            environment: .local(baseURL: URL(string: "http://feedback.example.test")!),
            bundleIdentifier: "com.example.host",
            appVersion: appVersion
        )
        let client = BuildThisPleaseClient(configuration: configuration, transport: transport,
            credentialStore: InMemoryBuildThisPleaseCredentialStore(), attestationProvider: UnsupportedAttestationProvider())
        _ = try await client.createTicket(title: "Version context", description: "Capture the host version.")
        let data = try #require(await transport.ticketBody)
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(payload["appVersion"] == appVersion)
        #expect(payload["title"] == "Version context")
    }

    @Test("Implemented models omit vote data")
    func implementedOmitsVoteData() async throws {
        let client = MockBuildThisPleaseClient()
        let items = try await client.implementedRequests()
        let item = try #require(items.first)
        #expect(item.status == .implemented)
        #expect(item.voteCount == nil)
        #expect(item.hasVoted == nil)
    }

    @Test("Mock ticket creation starts pending")
    func creationStartsPending() async throws {
        let client: any BuildThisPleaseClientProtocol = MockBuildThisPleaseClient(tickets: [])
        let ticket = try await client.createTicket(title: "Offline mode", description: "Keep the latest requests available.", idempotencyKey: "draft-1")
        #expect(ticket.status == .pending)
        #expect(try await client.myRequests().map(\.id) == [ticket.id])
    }

    @Test("Users can edit their own mock conversation messages")
    func editsOwnComment() async throws {
        let client = MockBuildThisPleaseClient()
        let original = try #require(await client.comments(ticketId: "review").first { $0.id == "comment-user" })
        #expect(original.isMine)
        #expect(original.isApproved)
        let edited = try await client.updateComment(ticketId: "review", commentId: original.id, body: "Updated message")
        #expect(edited.body == "Updated message")
        #expect(edited.isEdited)
        #expect(!edited.isApproved)
        #expect(edited.createdAt == original.createdAt)
        #expect(try await client.comments(ticketId: "review").contains(edited))
    }

    @Test("Comment ownership is decoded independently from author kind")
    func decodesCommentOwnership() throws {
        let data = Data(#"{"id":"other-user","ticketId":"review","author":"user","body":"Hello","isEdited":false,"isHidden":false,"isApproved":true,"isMine":false,"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}"#.utf8)
        let comment = try JSONCoding.decoder().decode(BuildThisPleaseComment.self, from: data)

        #expect(comment.author == .user)
        #expect(!comment.isMine)
    }

    @Test("Users cannot edit another installation's mock message")
    func rejectsEditingAnotherInstallationsComment() async throws {
        let client = MockBuildThisPleaseClient()

        await #expect(throws: BuildThisPleaseError.self) {
            try await client.updateComment(ticketId: "review", commentId: "comment-other-user", body: "Changed")
        }
    }

    @Test("Subscription states round-trip", arguments: BuildThisPleaseSubscriptionStatus.allCases)
    func subscriptionRoundTrip(_ status: BuildThisPleaseSubscriptionStatus) throws {
        let data = try JSONEncoder().encode(status)
        #expect(try JSONDecoder().decode(BuildThisPleaseSubscriptionStatus.self, from: data) == status)
    }

    @Test("Optional support identity is normalized")
    func normalizesSupportIdentity() throws {
        let configuration = try BuildThisPleaseConfiguration(
            projectKey: "btp_pk_identity_fixture",
            environment: .local(baseURL: URL(string: "http://feedback.example.test")!),
            revenueCatAppUserID: "  customer-123  ",
            userEmail: "  User@Example.COM ",
            bundleIdentifier: "com.example.host"
        )
        #expect(configuration.revenueCatAppUserID == "customer-123")
        #expect(configuration.userEmail == "user@example.com")
    }

    @Test("A failed identity update does not change later registration metadata")
    func failedIdentityUpdateDoesNotChangeRegistrationMetadata() async throws {
        let transport = FailedIdentityUpdateTransport()
        let configuration = try BuildThisPleaseConfiguration(
            projectKey: "btp_pk_identity_failure_fixture",
            environment: .local(baseURL: URL(string: "http://feedback.example.test")!),
            revenueCatAppUserID: "original-user",
            userEmail: "original@example.com",
            bundleIdentifier: "com.example.host"
        )
        let client = BuildThisPleaseClient(
            configuration: configuration,
            transport: transport,
            credentialStore: InMemoryBuildThisPleaseCredentialStore(),
            attestationProvider: UnsupportedAttestationProvider()
        )

        await #expect(throws: BuildThisPleaseError.self) {
            try await client.updateUserIdentity(revenueCatAppUserID: "replacement-user", email: "replacement@example.com")
        }
        #expect(try await client.requests().isEmpty)
        let registrations = await transport.registrationMetadata
        #expect(registrations.count == 2)
        #expect(registrations.allSatisfy {
            $0.revenueCatAppUserId == "original-user" && $0.userEmail == "original@example.com"
        })
    }

    @Test("An expired session is recovered with the existing App Attest key")
    func recoversExpiredSession() async throws {
        let projectKey = "btp_pk_recovery_fixture"
        let credentials = InMemoryBuildThisPleaseCredentialStore()
        let prefix = sha256(Data(projectKey.utf8)).base64URLEncodedString.prefix(16)
        await credentials.set("existing-app-attest-key-identifier", for: "\(prefix).appAttestKeyId")
        let transport = RecoveryTransport()
        let configuration = try BuildThisPleaseConfiguration(
            projectKey: projectKey,
            environment: .production(baseURL: URL(string: "https://feedback.example.test")!),
            bundleIdentifier: "com.example.host"
        )
        let client = BuildThisPleaseClient(
            configuration: configuration,
            transport: transport,
            credentialStore: credentials,
            attestationProvider: RecoveryAttestationProvider()
        )

        #expect(try await client.requests().isEmpty)
        #expect(await transport.paths == [
            "/v1/attestation/recovery/challenges",
            "/v1/attestation/recoveries",
            "/v1/attestation/assertions/challenges",
            "/v1/installations/recovery-credential",
            "/v1/tickets?limit=100"
        ])
    }

    @Test("A rejected recovery preserves the existing identity, including local development")
    func replacesStaleLocalAttestationKey() async throws {
        let projectKey = "btp_pk_local_recovery_fixture"
        let credentials = InMemoryBuildThisPleaseCredentialStore()
        let prefix = sha256(Data(projectKey.utf8)).base64URLEncodedString.prefix(16)
        let keyCredential = "\(prefix).appAttestKeyId"
        await credentials.set("stale-app-attest-key-identifier", for: keyCredential)
        let transport = InvalidLocalRecoveryTransport()
        let configuration = try BuildThisPleaseConfiguration(
            projectKey: projectKey,
            environment: .local(baseURL: URL(string: "http://feedback.example.test")!),
            bundleIdentifier: "com.example.host"
        )
        let client = BuildThisPleaseClient(
            configuration: configuration,
            transport: transport,
            credentialStore: credentials,
            attestationProvider: LocalRecoveryFallbackAttestationProvider()
        )

        await #expect(throws: BuildThisPleaseError.self) { try await client.requests() }
        #expect(await credentials.value(for: keyCredential) == "stale-app-attest-key-identifier")
        #expect(await transport.paths == [
            "/v1/attestation/recovery/challenges",
            "/v1/attestation/recoveries"
        ])
    }

    @Test("Concurrent initial loads establish one installation session")
    func concurrentLoadsShareSessionCreation() async throws {
        let transport = ConcurrentLoadTransport()
        let configuration = try BuildThisPleaseConfiguration(
            projectKey: "btp_pk_concurrent_fixture",
            environment: .local(baseURL: URL(string: "http://feedback.example.test")!),
            bundleIdentifier: "com.example.host"
        )
        let client = BuildThisPleaseClient(
            configuration: configuration,
            transport: transport,
            credentialStore: InMemoryBuildThisPleaseCredentialStore(),
            attestationProvider: UnsupportedAttestationProvider()
        )

        async let requests = client.requests()
        async let mine = client.myRequests()
        async let implemented = client.implementedRequests()
        _ = try await (requests, mine, implemented)

        #expect(await transport.sessionRequestCount == 1)
    }
}

private struct RecoveryAttestationProvider: BuildThisPleaseAttestationProvider {
    let isSupported = true
    func generateKey() async throws -> String { throw BuildThisPleaseError.attestationFailed }
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data { throw BuildThisPleaseError.attestationFailed }
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data { Data(repeating: 7, count: 64) }
}

private struct LocalRecoveryFallbackAttestationProvider: BuildThisPleaseAttestationProvider {
    let isSupported = true
    func generateKey() async throws -> String { "replacement-app-attest-key-identifier" }
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data { Data(repeating: 6, count: 64) }
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data { Data(repeating: 7, count: 64) }
}

private struct UnsupportedAttestationProvider: BuildThisPleaseAttestationProvider {
    let isSupported = false
    func generateKey() async throws -> String { throw BuildThisPleaseError.appAttestUnavailable }
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data { throw BuildThisPleaseError.appAttestUnavailable }
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data { throw BuildThisPleaseError.appAttestUnavailable }
}

private actor ConcurrentLoadTransport: BuildThisPleaseTransport {
    private(set) var sessionRequestCount = 0

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body: String
        let status: Int
        if request.url!.path == "/v1/development/sessions" {
            sessionRequestCount += 1
            try await Task.sleep(for: .milliseconds(100))
            body = #"{"installationId":"00000000-0000-4000-8000-000000000003","sessionToken":"shared-session-token","expiresAt":"2099-01-01T00:00:00Z"}"#
            status = 201
        } else {
            body = #"{"items":[],"nextCursor":null}"#
            status = 200
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

private actor FailedIdentityUpdateTransport: BuildThisPleaseTransport {
    struct RegistrationMetadata: Decodable {
        let revenueCatAppUserId: String?
        let userEmail: String?
    }

    private(set) var registrationMetadata: [RegistrationMetadata] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body: String
        let status: Int
        switch request.url!.path {
        case "/v1/development/sessions":
            registrationMetadata.append(try JSONDecoder().decode(RegistrationMetadata.self, from: request.httpBody ?? Data()))
            body = #"{"installationId":"00000000-0000-4000-8000-000000000004","sessionToken":"expired-session-token","expiresAt":"2000-01-01T00:00:00Z"}"#
            status = 201
        case "/v1/installations/me/user-identity":
            body = #"{"error":{"code":"identity_update_failed","message":"The identity could not be stored.","requestId":"fixture"}}"#
            status = 503
        default:
            body = #"{"items":[],"nextCursor":null}"#
            status = 200
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

private actor RecoveryTransport: BuildThisPleaseTransport {
    private(set) var paths: [String] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path + (request.url!.query.map { "?\($0)" } ?? "")
        paths.append(path)
        let body: String
        switch request.url!.path {
        case "/v1/attestation/recovery/challenges", "/v1/attestation/assertions/challenges":
            body = #"{"challengeId":"00000000-0000-4000-8000-000000000001","challengeHash":"fixture-challenge-hash","requestHash":"fixture-request-hash"}"#
        case "/v1/installations/recovery-credential":
            body = #"{"installationId":"00000000-0000-4000-8000-000000000002"}"#
        case "/v1/attestation/recoveries":
            body = #"{"installationId":"00000000-0000-4000-8000-000000000002","sessionToken":"recovered-session-token","expiresAt":"2099-01-01T00:00:00Z"}"#
        default:
            body = #"{"items":[],"nextCursor":null}"#
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: request.url!.path.contains("attestation") ? 201 : 200, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

private actor InvalidLocalRecoveryTransport: BuildThisPleaseTransport {
    private(set) var paths: [String] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path + (request.url!.query.map { "?\($0)" } ?? "")
        paths.append(path)
        let body: String
        let status: Int
        switch request.url!.path {
        case "/v1/attestation/recovery/challenges":
            body = #"{"challengeId":"00000000-0000-4000-8000-000000000001","challengeHash":"fixture-challenge-hash","requestHash":"fixture-request-hash"}"#
            status = 201
        case "/v1/attestation/recoveries":
            body = #"{"error":{"code":"invalid_assertion","message":"The assertion signature is invalid.","requestId":"fixture"}}"#
            status = 401
        case "/v1/attestation/challenges":
            body = #"{"challengeId":"00000000-0000-4000-8000-000000000002","challenge":"replacement-challenge"}"#
            status = 201
        case "/v1/attestation/registrations":
            body = #"{"installationId":"00000000-0000-4000-8000-000000000003","sessionToken":"replacement-session-token","expiresAt":"2099-01-01T00:00:00Z"}"#
            status = 201
        default:
            body = #"{"items":[],"nextCursor":null}"#
            status = 200
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

private actor TicketVersionTransport: BuildThisPleaseTransport {
    private(set) var ticketBody: Data?

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body: String
        if request.url!.path == "/v1/development/sessions" {
            body = #"{"installationId":"version-installation","sessionToken":"version-session","expiresAt":"2099-01-01T00:00:00Z"}"#
        } else {
            ticketBody = request.httpBody
            body = #"{"ticket":{"id":"version-ticket","title":"Version context","description":"Capture the host version.","status":"pending","commentsLocked":false,"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}}"#
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
    }
}
