import Foundation
import Testing
@testable import BuildThisPleaseCore

@Suite("Identity-preserving authentication recovery")
struct AuthenticationRecoveryTests {
    @Test("Expired legacy sessions rotate rejected native keys without creating another installation", arguments: [2, 3])
    func expiredSessionRetainsIdentity(code: Int) async throws {
        let fixture = try await RecoveryFixture.make(expired: true, code: code)
        #expect(try await fixture.client.requests().isEmpty)
        #expect(await fixture.transport.replacementCount == 1)
        #expect(await fixture.transport.registrationCount == 0)
        #expect(await fixture.credentials.value(for: fixture.keyName) == "replacement-key")
        let session = try #require(await fixture.credentials.value(for: fixture.sessionName))
        #expect(session.contains("original-installation"))
        #expect(!session.contains("original-session"))
        #expect(await fixture.credentials.value(for: fixture.pendingName) == nil)
    }

    @Test("A valid session with a rejected mutation key recovers before sending the original mutation")
    func validSessionMutation() async throws {
        let fixture = try await RecoveryFixture.make(expired: false, durableProof: true)
        _ = try await fixture.client.createTicket(title: "Preserved request", description: "Same installation", idempotencyKey: "stable-request-id")
        #expect(await fixture.transport.replacementCount == 1)
        #expect(await fixture.transport.businessMutationCount == 1)
        #expect(await fixture.transport.businessIdempotencyKeys == ["stable-request-id"])
        #expect(await fixture.transport.registrationCount == 0)
    }

    @Test("Healthy existing sessions enroll a persisted recovery credential using full App Attest")
    func enrollsExistingSession() async throws {
        let fixture = try await RecoveryFixture.make(expired: false, rejectOldKey: false)
        #expect(try await fixture.client.myRequests().isEmpty)
        #expect(await fixture.transport.enrollmentCount == 1)
        #expect(await fixture.transport.enrollmentHadAssertion)
        #expect(await fixture.transport.replacementCount == 0)
        let stored = try #require(await fixture.credentials.value(for: fixture.recoveryName))
        #expect(stored.contains("\"enrolled\":true"))
    }

    @Test("An existing identity without recovery proof never falls back to registration")
    func missingProofPreservesIdentity() async throws {
        let fixture = try await RecoveryFixture.make(includeSession: false)
        await #expect(throws: (any Error).self) { try await fixture.client.requests() }
        #expect(await fixture.credentials.value(for: fixture.keyName) == "original-key")
        #expect(await fixture.attestation.generatedKeyCount == 0)
        #expect(await fixture.transport.registrationCount == 0)
    }

    @Test("Backend refusal retains the original credentials and durable pending operation")
    func deniedProofPreservesIdentity() async throws {
        let fixture = try await RecoveryFixture.make(expired: true)
        await fixture.transport.setDenyProof(true)
        await #expect(throws: BuildThisPleaseError.self) { try await fixture.client.requests() }
        #expect(await fixture.credentials.value(for: fixture.keyName) == "original-key")
        #expect(await fixture.credentials.value(for: fixture.sessionName)?.contains("original-session") == true)
        #expect(await fixture.credentials.value(for: fixture.pendingName) != nil)
        #expect(await fixture.transport.registrationCount == 0)
    }

    @Test("Lost replacement responses resume after relaunch using the same operation, key, and attestation")
    func lostResponseResumes() async throws {
        let fixture = try await RecoveryFixture.make(expired: true)
        await fixture.transport.setLoseNextCompletion(true)
        await #expect(throws: URLError.self) { try await fixture.client.requests() }
        #expect(await fixture.credentials.value(for: fixture.keyName) == "original-key")
        let relaunched = fixture.newClient()
        #expect(try await relaunched.requests().isEmpty)
        #expect(await fixture.attestation.generatedKeyCount == 1)
        #expect(await fixture.attestation.attestationHashes.count == 1)
        #expect(await fixture.transport.completionOperationIds.count == 2)
        #expect(Set(await fixture.transport.completionOperationIds).count == 1)
        #expect(Set(await fixture.transport.completionObjects).count == 1)
        #expect(await fixture.transport.registrationCount == 0)
    }

    @Test("Transient Apple attestation failures retry the same key and client data hash")
    func transientAppleFailureResumes() async throws {
        let fixture = try await RecoveryFixture.make(expired: true)
        await fixture.attestation.setFailAttestationOnce(true)
        await #expect(throws: NSError.self) { try await fixture.client.requests() }
        #expect(try await fixture.newClient().requests().isEmpty)
        #expect(await fixture.attestation.generatedKeyCount == 1)
        #expect(await fixture.transport.challengeCount == 1)
        let hashes = await fixture.attestation.attestationHashes
        #expect(hashes.count == 2)
        #expect(Set(hashes).count == 1)
    }

    @Test("Partial Keychain commit failures resume before mixing a new session and old key")
    func partialCredentialWriteResumes() async throws {
        let fixture = try await RecoveryFixture.make(expired: true)
        await fixture.credentials.failNextSet(for: fixture.keyName)
        await #expect(throws: BuildThisPleaseError.self) { try await fixture.client.requests() }
        #expect(await fixture.credentials.value(for: fixture.keyName) == "original-key")
        #expect(await fixture.credentials.value(for: fixture.pendingName) != nil)
        #expect(try await fixture.newClient().requests().isEmpty)
        #expect(await fixture.credentials.value(for: fixture.keyName) == "replacement-key")
        #expect(await fixture.credentials.value(for: fixture.pendingName) == nil)
        #expect(await fixture.attestation.generatedKeyCount == 1)
    }

    @Test("Concurrent reads and mutations perform one replacement and serialize assertion traffic")
    func concurrentOperations() async throws {
        let fixture = try await RecoveryFixture.make(expired: true)
        async let requests = fixture.client.requests()
        async let mine = fixture.client.myRequests()
        async let implemented = fixture.client.implementedRequests()
        async let first = fixture.client.setVote(ticketId: "ticket", voted: true)
        async let second = fixture.client.setVote(ticketId: "ticket", voted: false)
        async let installationId = fixture.client.installationIdentifier()
        let (_, _, _, _, _, identity) = try await (requests, mine, implemented, first, second, installationId)
        #expect(identity == "original-installation")
        #expect(await fixture.transport.replacementCount == 1)
        #expect(await fixture.attestation.maxConcurrentAssertions == 1)
        #expect(await fixture.transport.businessMutationCount == 2)
    }

    @Test("Recovery preserves the selected identity namespace and leaves other credentials intact")
    func preservesIdentityNamespace() async throws {
        let fixture = try await RecoveryFixture.make(identityNamespace: "  account-a  ")
        let otherPrefix = sha256(Data((fixture.config.projectKey + "\naccount-b").utf8)).base64URLEncodedString.prefix(16).description
        let legacyPrefix = sha256(Data(fixture.config.projectKey.utf8)).base64URLEncodedString.prefix(16).description
        try await fixture.credentials.set("other-account-key", for: "\(otherPrefix).appAttestKeyId")
        try await fixture.credentials.set("legacy-key", for: "\(legacyPrefix).appAttestKeyId")
        #expect(try await fixture.client.installationIdentifier() == "original-installation")
        #expect(await fixture.credentials.value(for: fixture.keyName) == "replacement-key")
        #expect(await fixture.credentials.value(for: fixture.recoveryName)?.contains("original-installation") == true)
        #expect(await fixture.credentials.value(for: "\(otherPrefix).appAttestKeyId") == "other-account-key")
        #expect(await fixture.credentials.value(for: "\(legacyPrefix).appAttestKeyId") == "legacy-key")
        #expect(await fixture.credentials.value(for: "\(otherPrefix).recoveryCredential") == nil)
        #expect(await fixture.credentials.value(for: "\(legacyPrefix).recoveryCredential") == nil)
        #expect(await fixture.transport.registrationCount == 0)
    }

    @Test("Notification and identity-link operations share recovered authentication")
    func notificationAndIdentityOperations() async throws {
        let fixture = try await RecoveryFixture.make(expired: true)
        async let notices = fixture.client.notifications()
        async let following = fixture.client.following(ticketId: "ticket")
        async let preferences = fixture.client.notificationPreferences()
        async let read: Void = fixture.client.markNotificationsRead(ids: ["notice"])
        async let follow: Void = fixture.client.setFollowing(ticketId: "ticket", following: true)
        async let link: Void = fixture.client.linkUserIdentity(token: "host-signed-proof")
        async let update = fixture.client.updateNotificationPreferences(emailEnabled: true)
        let (page, isFollowing, currentPreferences, _, _, _, updated) = try await (notices, following, preferences, read, follow, link, update)
        #expect(page.items.isEmpty)
        #expect(isFollowing)
        #expect(currentPreferences.emailEnabled)
        #expect(updated.emailEnabled)
        #expect(await fixture.transport.replacementCount == 1)
        #expect(await fixture.transport.registrationCount == 0)
        #expect(await fixture.attestation.maxConcurrentAssertions == 1)
        #expect(await fixture.transport.businessMutationCount == 4)
    }

    @Test("A server-expired session is renewed with the original key before retrying")
    func serverExpiredSession() async throws {
        let fixture = try await RecoveryFixture.make(expired: false, durableProof: true, rejectOldKey: false)
        await fixture.transport.setRejectNextSession(true)
        #expect(try await fixture.client.requests().isEmpty)
        #expect(await fixture.transport.sessionRecoveryCount == 1)
        #expect(await fixture.transport.replacementCount == 0)
        #expect(await fixture.transport.registrationCount == 0)
    }

    @Test("An unacknowledged saved enrollment proof remains usable if the legacy session bridge is closed")
    func lostEnrollmentResponseProof() async throws {
        let fixture = try await RecoveryFixture.make(expired: true)
        try await fixture.credentials.set(#"{"token":"unacknowledged-proof","installationId":"original-installation","enrolled":false}"#, for: fixture.recoveryName)
        await fixture.transport.setDenyOriginalSession(true)
        #expect(try await fixture.client.requests().isEmpty)
        #expect(await fixture.transport.replacementCount == 1)
        #expect(await fixture.transport.challengeAuthorizations == ["Bearer original-session", "Bearer unacknowledged-proof"])
    }

    @Test("New registrations persist attestation progress and recovery proof before submitting")
    func initialRegistrationRetainsProgress() async throws {
        let fixture = try await RecoveryFixture.make(includeSession: false, includeKey: false, rejectOldKey: false)
        await fixture.attestation.setFailAttestationOnce(true)
        await #expect(throws: NSError.self) { try await fixture.client.requests() }
        #expect(try await fixture.newClient().requests().isEmpty)
        #expect(await fixture.attestation.generatedKeyCount == 1)
        #expect(Set(await fixture.attestation.attestationHashes).count == 1)
        #expect(await fixture.transport.registrationHadRecoveryHash)
        #expect(await fixture.credentials.value(for: "\(fixture.prefix).pendingRegistration") == nil)
    }

    @Test("Lost registration responses recover the just-registered key instead of registering again")
    func lostRegistrationResponse() async throws {
        let fixture = try await RecoveryFixture.make(includeSession: false, includeKey: false, rejectOldKey: false)
        await fixture.transport.setLoseRegistrationResponse(true)
        await #expect(throws: URLError.self) { try await fixture.client.requests() }
        #expect(try await fixture.newClient().requests().isEmpty)
        #expect(await fixture.attestation.generatedKeyCount == 1)
        #expect(await fixture.transport.registrationCount == 1)
        #expect(await fixture.transport.sessionRecoveryCount == 1)
    }

    @Test("An unsaved attestation object never strands a replacement after an already-attested key error")
    func lostAttestationObjectWrite() async throws {
        let fixture = try await RecoveryFixture.make(expired: true)
        await fixture.attestation.setRejectRepeatedAttestation(true)
        await fixture.credentials.failNextSet(for: fixture.pendingName, containing: "attestationObject")
        await #expect(throws: BuildThisPleaseError.self) { try await fixture.client.requests() }
        #expect(await fixture.transport.replacementCount == 0)
        #expect(try await fixture.newClient().requests().isEmpty)
        #expect(await fixture.attestation.generatedKeyCount == 2)
        #expect(await fixture.transport.replacementCount == 1)
        #expect(await fixture.credentials.value(for: fixture.keyName) == "replacement-key-2")
        #expect(await fixture.transport.registrationCount == 0)
    }

    @Test("An explicitly expired uncompleted replacement retries with a new operation on the same identity")
    func expiredReplacementChallenge() async throws {
        let fixture = try await RecoveryFixture.make(expired: true)
        await fixture.transport.setExpireNextCompletion(true)
        #expect(try await fixture.client.requests().isEmpty)
        #expect(await fixture.attestation.generatedKeyCount == 2)
        #expect(Set(await fixture.transport.completionOperationIds).count == 2)
        #expect(await fixture.credentials.value(for: fixture.sessionName)?.contains("original-installation") == true)
        #expect(await fixture.transport.registrationCount == 0)
    }

    @Test("A failed initial attestation-object write retries only the never-submitted registration")
    func lostInitialAttestationWrite() async throws {
        let fixture = try await RecoveryFixture.make(includeSession: false, includeKey: false, rejectOldKey: false)
        await fixture.attestation.setRejectRepeatedAttestation(true)
        await fixture.credentials.failNextSet(for: "\(fixture.prefix).pendingRegistration", containing: "attestationObject")
        await #expect(throws: BuildThisPleaseError.self) { try await fixture.client.requests() }
        #expect(await fixture.transport.registrationCount == 0)
        #expect(try await fixture.newClient().requests().isEmpty)
        #expect(await fixture.attestation.generatedKeyCount == 2)
        #expect(await fixture.transport.registrationCount == 1)
    }

    @Test("An initial Apple outage past registration expiry safely retries an explicitly unregistered key")
    func expiredInitialAppleOutage() async throws {
        let fixture = try await RecoveryFixture.make(includeSession: false, includeKey: false, rejectOldKey: false)
        await fixture.attestation.setFailAttestationOnce(true)
        await #expect(throws: NSError.self) { try await fixture.client.requests() }
        try await fixture.expirePendingRegistrationChallenge()
        await fixture.transport.setUnknownRecoveryKey(true)
        #expect(try await fixture.newClient().requests().isEmpty)
        #expect(await fixture.attestation.generatedKeyCount == 2)
        #expect(await fixture.transport.registrationCount == 1)
        #expect(await fixture.credentials.value(for: "\(fixture.prefix).pendingRegistration") == nil)
    }

    @Test("An expired accepted registration with a lost response recovers the original installation")
    func expiredAcceptedRegistrationResponse() async throws {
        let fixture = try await RecoveryFixture.make(includeSession: false, includeKey: false, rejectOldKey: false)
        await fixture.transport.setLoseRegistrationResponse(true)
        await #expect(throws: URLError.self) { try await fixture.client.requests() }
        try await fixture.expirePendingRegistrationChallenge()
        #expect(try await fixture.newClient().requests().isEmpty)
        #expect(await fixture.attestation.generatedKeyCount == 1)
        #expect(await fixture.transport.registrationCount == 1)
        #expect(await fixture.transport.sessionRecoveryCount == 1)
        #expect(await fixture.credentials.value(for: fixture.sessionName)?.contains("original-installation") == true)
    }

    @Test("An expired initial registration with an uncertain network result preserves its pending key")
    func expiredInitialNetworkUnknown() async throws {
        let fixture = try await RecoveryFixture.make(includeSession: false, includeKey: false, rejectOldKey: false)
        await fixture.attestation.setFailAttestationOnce(true)
        await #expect(throws: NSError.self) { try await fixture.client.requests() }
        try await fixture.expirePendingRegistrationChallenge()
        let pendingName = "\(fixture.prefix).pendingRegistration"
        let original = await fixture.credentials.value(for: pendingName)
        await fixture.transport.setFailRecoveryChallenge(true)
        await #expect(throws: URLError.self) { try await fixture.newClient().requests() }
        #expect(await fixture.attestation.generatedKeyCount == 1)
        #expect(await fixture.transport.registrationCount == 0)
        #expect(await fixture.credentials.value(for: pendingName) == original)
    }

    @Test("An expired pending initial registration cannot replace any established local identity")
    func expiredInitialPreservesEstablishedCredentials() async throws {
        let fixture = try await RecoveryFixture.make(includeSession: false, includeKey: false, rejectOldKey: false)
        await fixture.attestation.setFailAttestationOnce(true)
        await #expect(throws: NSError.self) { try await fixture.client.requests() }
        try await fixture.expirePendingRegistrationChallenge()
        try await fixture.credentials.set("original-key", for: fixture.keyName)
        await fixture.transport.setUnknownRecoveryKey(true)
        await #expect(throws: BuildThisPleaseError.self) { try await fixture.newClient().requests() }
        #expect(await fixture.attestation.generatedKeyCount == 1)
        #expect(await fixture.credentials.value(for: fixture.keyName) == "original-key")
        #expect(await fixture.transport.registrationCount == 0)
    }

    @Test("A registered key with failed server recovery-hash storage is explicitly enrolled before future recovery")
    func incompleteRegistrationHashEnrollment() async throws {
        let fixture = try await RecoveryFixture.make(includeSession: false, includeKey: false, rejectOldKey: false)
        await fixture.transport.setFailRegistrationHashWrite(true)
        await fixture.transport.setRequireConfirmedRecoveryProof(true)
        await #expect(throws: BuildThisPleaseError.self) { try await fixture.client.requests() }
        #expect(try await fixture.newClient().requests().isEmpty)
        #expect(await fixture.transport.enrollmentCount == 1)
        #expect(await fixture.transport.enrollmentHadAssertion)
        #expect(await fixture.credentials.value(for: fixture.recoveryName)?.contains("\"enrolled\":true") == true)
        await fixture.attestation.rejectKey("replacement-key")
        _ = try await fixture.newClient().createTicket(title: "Still mine", description: "Same identity after a later key loss", idempotencyKey: "preserved-owner")
        #expect(await fixture.transport.replacementCount == 1)
        #expect(await fixture.transport.registrationCount == 1)
        #expect(await fixture.transport.businessMutationCount == 1)
        #expect(await fixture.credentials.value(for: fixture.sessionName)?.contains("original-installation") == true)
    }

    @Test("Initial registration credential-write failures retain the pending identity until a consistent commit", arguments: ["session", "appAttestKeyId", "recoveryCredential"])
    func initialCredentialCommitFailures(suffix: String) async throws {
        let fixture = try await RecoveryFixture.make(includeSession: false, includeKey: false, rejectOldKey: false)
        await fixture.credentials.failNextSet(for: "\(fixture.prefix).\(suffix)")
        await #expect(throws: BuildThisPleaseError.self) { try await fixture.client.requests() }
        #expect(await fixture.credentials.value(for: "\(fixture.prefix).pendingRegistration") != nil)
        #expect(try await fixture.newClient().requests().isEmpty)
        #expect(await fixture.attestation.generatedKeyCount == 1)
        #expect(await fixture.transport.registrationCount == 1)
        #expect(await fixture.transport.enrollmentCount == 1)
        #expect(await fixture.credentials.value(for: fixture.keyName) == "replacement-key")
        #expect(await fixture.credentials.value(for: "\(fixture.prefix).pendingRegistration") == nil)
    }

    @Test("A failed confirmation keeps enrollment pending with the established identity for retry")
    func recoveredEnrollmentFailureKeepsProof() async throws {
        let fixture = try await RecoveryFixture.make(includeSession: false, includeKey: false, rejectOldKey: false)
        await fixture.transport.setLoseRegistrationResponse(true)
        await #expect(throws: URLError.self) { try await fixture.client.requests() }
        await fixture.transport.setFailEnrollmentOnce(true)
        await #expect(throws: URLError.self) { try await fixture.newClient().requests() }
        #expect(await fixture.credentials.value(for: fixture.recoveryName)?.contains("\"enrolled\":false") == true)
        #expect(await fixture.credentials.value(for: fixture.keyName) == "replacement-key")
        #expect(await fixture.credentials.value(for: fixture.sessionName)?.contains("original-installation") == true)
        #expect(try await fixture.newClient().requests().isEmpty)
        #expect(await fixture.transport.registrationCount == 1)
        #expect(await fixture.credentials.value(for: fixture.recoveryName)?.contains("\"enrolled\":true") == true)
    }

    @Test("Key replacement retires a matching interrupted registration before completing cleanup", arguments: ["none", "pendingRegistration", "pendingKeyReplacement"])
    func interruptedRegistrationSurvivesLaterKeyLoss(cleanupFailure: String) async throws {
        let fixture = try await RecoveryFixture.make(includeSession: false, includeKey: false, rejectOldKey: false)
        let registrationName = "\(fixture.prefix).pendingRegistration"
        await fixture.credentials.failNextRemove(for: registrationName)
        await #expect(throws: BuildThisPleaseError.self) { try await fixture.client.requests() }
        #expect(await fixture.credentials.value(for: registrationName) != nil)
        #expect(await fixture.credentials.value(for: fixture.recoveryName)?.contains("\"enrolled\":true") == true)
        await fixture.attestation.rejectKey("replacement-key")

        if cleanupFailure != "none" {
            await fixture.credentials.failNextRemove(for: "\(fixture.prefix).\(cleanupFailure)")
            await #expect(throws: BuildThisPleaseError.self) {
                try await fixture.newClient().createTicket(title: "Still mine", description: "Retry after cleanup", idempotencyKey: "same-owner")
            }
            #expect(await fixture.credentials.value(for: fixture.pendingName) != nil)
            #expect(await fixture.transport.businessMutationCount == 0)
            #expect(try await fixture.newClient().requests().isEmpty)
        }
        _ = try await fixture.newClient().createTicket(title: "Still mine", description: "Retry after cleanup", idempotencyKey: "same-owner")
        #expect(try await fixture.newClient().requests().isEmpty)
        _ = try await fixture.newClient().setVote(ticketId: "ticket", voted: true)
        #expect(try await fixture.newClient().installationIdentifier() == "original-installation")
        #expect(await fixture.credentials.value(for: registrationName) == nil)
        #expect(await fixture.credentials.value(for: fixture.pendingName) == nil)
        #expect(await fixture.credentials.value(for: fixture.keyName) == "replacement-key-2")
        #expect(await fixture.transport.registrationCount == 1)
        #expect(await fixture.attestation.generatedKeyCount == 2)
        #expect(await fixture.transport.businessMutationCount == 2)
        #expect(Set(await fixture.transport.completionOperationIds).count == 1)
    }

    @Test("A read can recover a lost key after an interrupted registration commit")
    func readRecoversInterruptedRegistration() async throws {
        let fixture = try await RecoveryFixture.make(includeSession: false, includeKey: false, rejectOldKey: false)
        let registrationName = "\(fixture.prefix).pendingRegistration"
        await fixture.credentials.failNextRemove(for: registrationName)
        await #expect(throws: BuildThisPleaseError.self) { try await fixture.client.requests() }
        await fixture.attestation.rejectKey("replacement-key")
        #expect(try await fixture.newClient().requests().isEmpty)
        #expect(try await fixture.newClient().installationIdentifier() == "original-installation")
        #expect(await fixture.credentials.value(for: registrationName) == nil)
        #expect(await fixture.credentials.value(for: fixture.keyName) == "replacement-key-2")
        #expect(await fixture.transport.registrationCount == 1)
        #expect(await fixture.transport.replacementCount == 1)
    }

    @Test("Replacement cleanup preserves a pending registration with a different recovery proof")
    func replacementPreservesUnrelatedRegistration() async throws {
        let fixture = try await RecoveryFixture.make(expired: true, durableProof: true)
        await fixture.transport.setLoseNextCompletion(true)
        await #expect(throws: URLError.self) { try await fixture.client.requests() }
        let registrationName = "\(fixture.prefix).pendingRegistration"
        let unrelated = #"{"keyId":"original-key","recoveryToken":"another-registration-proof","registrationAttempted":true}"#
        try await fixture.credentials.set(unrelated, for: registrationName)
        #expect(try await fixture.newClient().requests().isEmpty)
        #expect(await fixture.credentials.value(for: registrationName) == unrelated)
        #expect(await fixture.credentials.value(for: fixture.keyName) == "replacement-key")
        // The inconsistent record remains a conflict rather than being silently ignored.
        await #expect(throws: BuildThisPleaseError.self) { try await fixture.newClient().requests() }
        #expect(await fixture.transport.registrationCount == 0)
    }

    @Test("Interrupted recovered registration can replace a lost key before enrollment acknowledgement", arguments: [false, true])
    func unacknowledgedRegistrationProofRecovers(requireDurableProof: Bool) async throws {
        let fixture = try await RecoveryFixture.make(includeSession: false, includeKey: false, rejectOldKey: false)
        let registrationName = "\(fixture.prefix).pendingRegistration"
        await fixture.transport.setLoseRegistrationResponse(true)
        await #expect(throws: URLError.self) { try await fixture.client.requests() }
        await fixture.credentials.failNextRemove(for: registrationName)
        await #expect(throws: BuildThisPleaseError.self) { try await fixture.newClient().requests() }
        #expect(await fixture.credentials.value(for: registrationName) != nil)
        #expect(await fixture.credentials.value(for: fixture.recoveryName)?.contains("\"enrolled\":false") == true)
        await fixture.transport.setRequireConfirmedRecoveryProof(requireDurableProof)
        await fixture.attestation.rejectKey("replacement-key")

        // Exercise read-first recovery after relaunch, including a backend that
        // requires the saved token because it already accepted registration.
        #expect(try await fixture.newClient().requests().isEmpty)
        _ = try await fixture.newClient().createTicket(title: "Same owner", description: "Acknowledgement was interrupted", idempotencyKey: "same-installation")
        _ = try await fixture.newClient().setVote(ticketId: "ticket", voted: true)
        #expect(try await fixture.newClient().requests().isEmpty)
        #expect(try await fixture.newClient().installationIdentifier() == "original-installation")
        #expect(await fixture.credentials.value(for: registrationName) == nil)
        #expect(await fixture.credentials.value(for: fixture.pendingName) == nil)
        #expect(await fixture.credentials.value(for: fixture.keyName) == "replacement-key-2")
        #expect(await fixture.credentials.value(for: fixture.recoveryName)?.contains("\"enrolled\":true") == true)
        #expect(await fixture.transport.registrationCount == 1)
        #expect(await fixture.transport.replacementCount == 1)
        #expect(await fixture.attestation.generatedKeyCount == 2)
        #expect(await fixture.transport.businessMutationCount == 2)
        #expect(await fixture.transport.challengeAuthorizations.count == (requireDurableProof ? 2 : 1))
    }

    @Test("A submitted initial registration cannot overwrite another active key")
    func submittedInitialPreservesDifferentActiveKey() async throws {
        let fixture = try await RecoveryFixture.make(includeSession: false, includeKey: false, rejectOldKey: false)
        await fixture.transport.setLoseRegistrationResponse(true)
        await #expect(throws: URLError.self) { try await fixture.client.requests() }
        try await fixture.credentials.set("another-established-key", for: fixture.keyName)
        await #expect(throws: BuildThisPleaseError.self) { try await fixture.newClient().requests() }
        #expect(await fixture.credentials.value(for: fixture.keyName) == "another-established-key")
        #expect(await fixture.transport.registrationCount == 1)
    }

    @Test("A mismatched server identity never replaces saved credentials")
    func rejectsWrongInstallation() async throws {
        let fixture = try await RecoveryFixture.make(expired: true)
        await fixture.transport.setWrongInstallation(true)
        await #expect(throws: BuildThisPleaseError.self) { try await fixture.client.requests() }
        #expect(await fixture.credentials.value(for: fixture.keyName) == "original-key")
        #expect(await fixture.credentials.value(for: fixture.sessionName)?.contains("original-session") == true)
        #expect(await fixture.credentials.value(for: fixture.pendingName) != nil)
    }
}

private struct RecoveryFixture: Sendable {
    let config: BuildThisPleaseConfiguration
    let credentials: RecoveryCredentials
    let attestation: RecoveryProvider
    let transport: ReplacementTransport
    let client: BuildThisPleaseClient
    let prefix: String
    var keyName: String { "\(prefix).appAttestKeyId" }
    var sessionName: String { "\(prefix).session" }
    var recoveryName: String { "\(prefix).recoveryCredential" }
    var pendingName: String { "\(prefix).pendingKeyReplacement" }

    static func make(expired: Bool = true, includeSession: Bool = true, includeKey: Bool = true, code: Int = 3, durableProof: Bool = false, rejectOldKey: Bool = true, identityNamespace: String? = nil) async throws -> Self {
        let projectKey = "btp_pk_replacement_fixture"
        let config = try BuildThisPleaseConfiguration(projectKey: projectKey, environment: .production(baseURL: URL(string: "https://feedback.example.test")!), identityNamespace: identityNamespace, bundleIdentifier: "com.example.host")
        let prefix = sha256(Data((projectKey + (config.identityNamespace.map { "\n" + $0 } ?? "")).utf8)).base64URLEncodedString.prefix(16).description
        let credentials = RecoveryCredentials()
        if includeKey { try await credentials.set("original-key", for: "\(prefix).appAttestKeyId") }
        if includeSession {
            let expiration = expired ? "2000-01-01T00:00:00Z" : "2099-01-01T00:00:00Z"
            try await credentials.set("{\"token\":\"original-session\",\"installationId\":\"original-installation\",\"expiresAt\":\"\(expiration)\"}", for: "\(prefix).session")
        }
        if durableProof {
            try await credentials.set(#"{"token":"original-durable-proof","installationId":"original-installation","enrolled":true}"#, for: "\(prefix).recoveryCredential")
        }
        let attestation = RecoveryProvider(code: code, rejectOldKey: rejectOldKey)
        let transport = ReplacementTransport()
        let client = BuildThisPleaseClient(configuration: config, transport: transport, credentialStore: credentials, attestationProvider: attestation)
        return Self(config: config, credentials: credentials, attestation: attestation, transport: transport, client: client, prefix: prefix)
    }
    func expirePendingRegistrationChallenge() async throws {
        let key = "\(prefix).pendingRegistration"
        let value = try #require(await credentials.value(for: key))
        var pending = try #require(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
        var challenge = try #require(pending["challenge"] as? [String: Any])
        challenge["expiresAt"] = "2000-01-01T00:00:00Z"
        pending["challenge"] = challenge
        let data = try JSONSerialization.data(withJSONObject: pending, options: [.sortedKeys])
        try await credentials.set(String(decoding: data, as: UTF8.self), for: key)
    }
    func newClient() -> BuildThisPleaseClient { BuildThisPleaseClient(configuration: config, transport: transport, credentialStore: credentials, attestationProvider: attestation) }
}

private actor RecoveryCredentials: BuildThisPleaseCredentialStore {
    private var values: [String: String] = [:]
    private var failedKey: String?
    private var failedValueSubstring: String?
    private var failedRemovalKey: String?
    func value(for key: String) -> String? { values[key] }
    func set(_ value: String, for key: String) throws {
        if key == failedKey, failedValueSubstring == nil || value.contains(failedValueSubstring!) {
            failedKey = nil
            failedValueSubstring = nil
            throw BuildThisPleaseError.invalidResponse
        }
        values[key] = value
    }
    func removeValue(for key: String) throws {
        if key == failedRemovalKey {
            failedRemovalKey = nil
            throw BuildThisPleaseError.invalidResponse
        }
        values[key] = nil
    }
    func failNextSet(for key: String, containing substring: String? = nil) { failedKey = key; failedValueSubstring = substring }
    func failNextRemove(for key: String) { failedRemovalKey = key }
}

private actor RecoveryProvider: BuildThisPleaseAttestationProvider {
    nonisolated let isSupported = true
    let code: Int
    let rejectOldKey: Bool
    private(set) var generatedKeyCount = 0
    private(set) var attestationHashes: [Data] = []
    private(set) var maxConcurrentAssertions = 0
    private var activeAssertions = 0
    private var failAttestationOnce = false
    private var rejectRepeatedAttestation = false
    private var attestedKeys: Set<String> = []
    private var rejectedKeys: Set<String> = []
    init(code: Int, rejectOldKey: Bool) { self.code = code; self.rejectOldKey = rejectOldKey; self.rejectedKeys = rejectOldKey ? ["original-key"] : [] }
    func rejectKey(_ key: String) { rejectedKeys.insert(key) }
    func setFailAttestationOnce(_ value: Bool) { failAttestationOnce = value }
    func setRejectRepeatedAttestation(_ value: Bool) { rejectRepeatedAttestation = value }
    func generateKey() -> String {
        generatedKeyCount += 1
        return generatedKeyCount == 1 ? "replacement-key" : "replacement-key-\(generatedKeyCount)"
    }
    func attestKey(_ keyId: String, clientDataHash: Data) throws -> Data {
        attestationHashes.append(clientDataHash)
        if failAttestationOnce { failAttestationOnce = false; throw NSError(domain: "com.apple.devicecheck.error", code: 4) }
        if rejectRepeatedAttestation, attestedKeys.contains(keyId) { throw NSError(domain: "com.apple.devicecheck.error", code: 3) }
        attestedKeys.insert(keyId)
        return Data("attestation-evidence".utf8)
    }
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        if rejectedKeys.contains(keyId) { throw NSError(domain: "com.apple.devicecheck.error", code: code) }
        activeAssertions += 1
        maxConcurrentAssertions = max(maxConcurrentAssertions, activeAssertions)
        defer { activeAssertions -= 1 }
        try await Task.sleep(for: .milliseconds(2))
        return Data("assertion-evidence".utf8)
    }
}

private actor ReplacementTransport: BuildThisPleaseTransport {
    private(set) var sessionRecoveryCount = 0
    private(set) var registrationHadRecoveryHash = false
    private(set) var challengeAuthorizations: [String] = []
    private(set) var replacementCount = 0
    private(set) var registrationCount = 0
    private(set) var challengeCount = 0
    private(set) var enrollmentCount = 0
    private(set) var enrollmentHadAssertion = false
    private(set) var businessMutationCount = 0
    private(set) var businessIdempotencyKeys: [String] = []
    private(set) var completionOperationIds: [String] = []
    private(set) var completionObjects: [String] = []
    private var failRegistrationHashWrite = false
    private var requireConfirmedRecoveryProof = false
    private var serverRecoveryHash: String?
    private var failEnrollmentOnce = false
    private var unknownRecoveryKey = false
    private var failRecoveryChallenge = false
    private var expireNextCompletion = false
    private var rejectNextSession = false
    private var denyOriginalSession = false
    private var loseRegistrationResponse = false
    private var denyProof = false
    private var loseNextCompletion = false
    private var wrongInstallation = false
    func setFailRegistrationHashWrite(_ value: Bool) { failRegistrationHashWrite = value }
    func setRequireConfirmedRecoveryProof(_ value: Bool) { requireConfirmedRecoveryProof = value }
    func setFailEnrollmentOnce(_ value: Bool) { failEnrollmentOnce = value }
    func setUnknownRecoveryKey(_ value: Bool) { unknownRecoveryKey = value }
    func setFailRecoveryChallenge(_ value: Bool) { failRecoveryChallenge = value }
    func setExpireNextCompletion(_ value: Bool) { expireNextCompletion = value }
    func setRejectNextSession(_ value: Bool) { rejectNextSession = value }
    func setDenyOriginalSession(_ value: Bool) { denyOriginalSession = value }
    func setLoseRegistrationResponse(_ value: Bool) { loseRegistrationResponse = value }
    func setDenyProof(_ value: Bool) { denyProof = value }
    func setLoseNextCompletion(_ value: Bool) { loseNextCompletion = value }
    func setWrongInstallation(_ value: Bool) { wrongInstallation = value }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path
        let input = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]) ?? [:]
        var status = 200
        let body: String
        if rejectNextSession, request.httpMethod == "GET" {
            rejectNextSession = false
            let error = #"{"error":{"code":"installation_session_invalid","message":"The session expired."}}"#
            return (Data(error.utf8), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }
        switch path {
        case "/v1/attestation/recovery/challenges", "/v1/attestation/assertions/challenges":
            if path == "/v1/attestation/recovery/challenges", failRecoveryChallenge { throw URLError(.networkConnectionLost) }
            if path == "/v1/attestation/recovery/challenges", unknownRecoveryKey {
                let error = #"{"error":{"code":"attestation_key_not_registered","message":"The key was not registered."}}"#
                return (Data(error.utf8), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
            }
            body = #"{"challengeId":"assertion-challenge","challengeHash":"challenge-hash","requestHash":"request-hash"}"#
        case "/v1/attestation/challenges":
            body = #"{"challengeId":"registration-challenge","challenge":"registration-nonce","expiresAt":"2099-01-01T00:00:00Z"}"#
        case "/v1/attestation/recoveries":
            sessionRecoveryCount += 1
            body = sessionBody()
        case "/v1/installations/recovery-credential":
            enrollmentCount += 1
            if failEnrollmentOnce { failEnrollmentOnce = false; throw URLError(.networkConnectionLost) }
            serverRecoveryHash = input["recoveryTokenHash"] as? String
            enrollmentHadAssertion = request.value(forHTTPHeaderField: "X-BTP-App-Attest-Assertion") != nil
            body = #"{"installationId":"original-installation"}"#
        case "/v1/attestation/key-replacements/challenges":
            let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
            challengeAuthorizations.append(authorization)
            let proof = authorization.hasPrefix("Bearer ") ? String(authorization.dropFirst(7)) : ""
            let confirmedProof = sha256(Data(proof.utf8)).base64URLEncodedString == serverRecoveryHash
            if denyProof || (denyOriginalSession && authorization == "Bearer original-session") || (requireConfirmedRecoveryProof && !confirmedProof) {
                status = 401
                body = #"{"error":{"code":"key_replacement_proof_invalid","message":"Proof refused."}}"#
            } else {
                challengeCount += 1
                let operation = input["operationId"] as! String
                body = "{\"operationId\":\"\(operation)\",\"challengeId\":\"\(operation)\",\"installationId\":\"original-installation\",\"challenge\":\"replacement-challenge\",\"expiresAt\":\"2099-01-01T00:00:00Z\"}"
            }
        case "/v1/attestation/key-replacements":
            completionOperationIds.append(input["operationId"] as! String)
            completionObjects.append(input["attestationObject"] as! String)
            replacementCount += 1
            if expireNextCompletion {
                expireNextCompletion = false
                body = #"{"error":{"code":"key_replacement_challenge_expired","message":"The pending challenge expired."}}"#
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
            }
            if loseNextCompletion { loseNextCompletion = false; throw URLError(.networkConnectionLost) }
            body = sessionBody(installationId: wrongInstallation ? "other-installation" : "original-installation")
        case "/v1/attestation/registrations", "/v1/development/sessions":
            registrationCount += 1
            registrationHadRecoveryHash = (input["recoveryTokenHash"] as? String)?.count == 43
            if failRegistrationHashWrite {
                failRegistrationHashWrite = false
                let error = #"{"error":{"code":"fixture_recovery_hash_write_failed","message":"Recovery hash storage failed after the key registered."}}"#
                return (Data(error.utf8), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
            }
            serverRecoveryHash = input["recoveryTokenHash"] as? String
            if loseRegistrationResponse { loseRegistrationResponse = false; throw URLError(.networkConnectionLost) }
            body = sessionBody()
        case "/v1/me/notifications":
            body = #"{"items":[],"unreadCount":0,"nextCursor":null}"#
        case "/v1/me/notification-preferences":
            if request.httpMethod != "GET" { businessMutationCount += 1 }
            body = #"{"emailEnabled":true,"emailVerified":false,"verificationPending":false,"localNotificationsEnabled":false,"identityLinked":false}"#
        case "/v1/tickets/ticket/follow":
            if request.httpMethod != "GET" { businessMutationCount += 1 }
            body = #"{"following":true}"#
        case "/v1/me/notifications/read", "/v1/me/identity-link":
            businessMutationCount += 1
            body = "{}"
        default:
            if request.httpMethod != "GET" {
                businessMutationCount += 1
                if let idempotency = request.value(forHTTPHeaderField: "Idempotency-Key") { businessIdempotencyKeys.append(idempotency) }
                body = #"{"ticket":{"id":"ticket","title":"Fixture","description":"Preserved","status":"pending","commentsLocked":false,"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","voteCount":1,"hasVoted":true}}"#
            } else { body = #"{"items":[],"nextCursor":null}"# }
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    private func sessionBody(installationId: String = "original-installation") -> String {
        "{\"installationId\":\"\(installationId)\",\"sessionToken\":\"replacement-session\",\"expiresAt\":\"2099-01-01T00:00:00Z\"}"
    }
}
