import Foundation
import os
import Testing
@testable import BuildThisPleaseCore

@Suite("Request cache")
struct RequestCacheTests {
    @Test("Disk restores without networking, failed refresh keeps data, and empty responses replace it")
    func diskRestorationAndEmptyReplacement() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = InMemoryBuildThisPleaseCredentialStore()
        let network = CacheTransport(tickets: [ticket()])
        let client = try makeClient(network, credentials, directory)
        try await client.preloadRequests()
        #expect(await network.listCalls == 3)
        let offline = CacheTransport(tickets: [], offline: true)
        let restored = try makeClient(offline, credentials, directory)
        let snapshot = try #require(await restored.cachedRequests())
        #expect(snapshot.requests?.items.map(\.id) == ["request"])
        #expect(await offline.listCalls == 0)
        await #expect(throws: BuildThisPleaseError.self) { try await restored.requests() }
        #expect(await restored.cachedRequests()?.requests?.items.count == 1)
        await network.setTickets([])
        #expect(try await client.requests().isEmpty)
        let empty = try makeClient(offline, credentials, directory)
        #expect(await empty.cachedRequests()?.requests?.items == [])
    }

    @Test("Fresh preloads avoid duplicate startup and board requests; concurrent readers coalesce")
    func coalescesStartupRequests() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let network = CacheTransport(tickets: [ticket()], holdRequests: true)
        let client = try makeClient(network, InMemoryBuildThisPleaseCredentialStore(), directory)
        let startup = Task { try await client.preloadRequests() }
        await network.waitUntilHeld()
        let screen = Task { try await client.requests() }
        await Task.yield()
        await network.release()
        try await startup.value
        #expect(try await screen.value.count == 1)
        #expect(await network.requestsCalls == 1)
        try await client.preloadRequests()
        #expect(await network.listCalls == 3)
    }

    @Test("Concrete list downloads complete Mine and Implemented while Requests is held", .timeLimit(.minutes(1)))
    func independentConcreteDownloads() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let network = CacheTransport(tickets: [ticket()], holdRequests: true)
        let client = try makeClient(network, InMemoryBuildThisPleaseCredentialStore(), directory)
        let startup = Task { try await client.preloadRequests() }
        await network.waitUntilHeld()
        await network.waitUntilOtherListsCompleted()
        while true {
            let snapshot = await client.cachedRequests()
            if snapshot?.mine != nil && snapshot?.implemented != nil { break }
            await Task.yield()
        }
        let partial = try #require(await client.cachedRequests())
        #expect(partial.requests == nil)
        #expect(partial.mine?.items.count == 1)
        #expect(partial.implemented?.items.count == 1)
        await network.release()
        try await startup.value
        #expect(await client.cachedRequests()?.requests?.items.count == 1)
    }

    @Test("Parallel rejected list tokens recover one App Attest session and reuse it", .timeLimit(.minutes(1)))
    func parallelUnauthorizedListsShareRecovery() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = "btp_pk_parallel401_fixture"
        let credentials = InMemoryBuildThisPleaseCredentialStore()
        let prefix = sha256(Data(project.utf8)).base64URLEncodedString.prefix(16)
        await credentials.set(#"{"token":"old-token","installationId":"parallel-installation","expiresAt":"2099-01-01T00:00:00Z"}"#, for: "\(prefix).session")
        await credentials.set("parallel-app-attest-key", for: "\(prefix).appAttestKeyId")
        await credentials.set(#"{"token":"recovery-proof","installationId":"parallel-installation","enrolled":true}"#, for: "\(prefix).recoveryCredential")
        let network = ParallelRejectedListTransport()
        let client = BuildThisPleaseClient(
            configuration: try .init(projectKey: project, environment: .production(baseURL: URL(string: "https://feedback.example.test")!), bundleIdentifier: "com.example.parallel"),
            transport: network, credentialStore: credentials, attestationProvider: ParallelListAttestationProvider(), requestCacheDirectory: directory
        )
        try await client.preloadRequests()
        #expect(await network.recoveryCount == 1)
        #expect(await network.recoveryChallengeCount == 1)
        #expect(await network.oldTokenRequests == 3)
        #expect(await network.newTokenRequests == 3)
        #expect(await client.cachedRequests()?.requests?.items == [])
        #expect(await client.cachedRequests()?.mine?.items == [])
        #expect(await client.cachedRequests()?.implemented?.items == [])
    }

    @Test("Account, URL, environment, bundle, project and installation isolate disk snapshots")
    func scopeIsolation() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = InMemoryBuildThisPleaseCredentialStore()
        let network = CacheTransport(tickets: [ticket()])
        let client = try makeClient(network, credentials, directory, namespace: "account-a")
        _ = try await client.requests()
        let offline = CacheTransport(tickets: [], offline: true)
        #expect(await (try makeClient(offline, credentials, directory, namespace: "account-b")).cachedRequests() == nil)
        #expect(await (try makeClient(offline, credentials, directory, namespace: "account-a", baseURL: "https://other.example.test")).cachedRequests() == nil)
        #expect(await (try makeClient(offline, credentials, directory, namespace: "account-a", staging: true)).cachedRequests() == nil)
        #expect(await (try makeClient(offline, credentials, directory, namespace: "account-a", bundle: "com.example.other")).cachedRequests() == nil)
        #expect(await (try makeClient(offline, credentials, directory, namespace: "account-a", project: "btp_pk_other")).cachedRequests() == nil)
        let prefix = sha256(Data("btp_pk_cache_fixture\naccount-a".utf8)).base64URLEncodedString.prefix(16)
        await credentials.set(#"{"token":"new-token","installationId":"replacement","expiresAt":"2099-01-01T00:00:00Z"}"#, for: "\(prefix).session")
        #expect(await (try makeClient(offline, credentials, directory, namespace: "account-a")).cachedRequests() == nil)
    }

    @Test("Logout clearing works before cache restoration without credentials and keeps other accounts")
    func clearUnopenedScope() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = InMemoryBuildThisPleaseCredentialStore()
        let network = CacheTransport(tickets: [ticket()])
        let accountA = try makeClient(network, credentials, directory, namespace: "a")
        let accountB = try makeClient(network, credentials, directory, namespace: "b")
        _ = try await accountA.requests()
        _ = try await accountB.requests()
        let unopened = try makeClient(network, InMemoryBuildThisPleaseCredentialStore(), directory, namespace: "a")
        await unopened.clearRequestCache()
        #expect(await (try makeClient(network, credentials, directory, namespace: "a")).cachedRequests() == nil)
        #expect(await (try makeClient(network, credentials, directory, namespace: "b")).cachedRequests()?.requests?.items.count == 1)
    }

    @Test("Clearing while a GET is held cannot resurrect memory or disk")
    func clearDuringGET() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = InMemoryBuildThisPleaseCredentialStore()
        let network = CacheTransport(tickets: [ticket()], holdRequests: true)
        let client = try makeClient(network, credentials, directory)
        let fetch = Task { try await client.requests() }
        await network.waitUntilHeld()
        await client.clearRequestCache()
        await network.release()
        await #expect(throws: CancellationError.self) { try await fetch.value }
        #expect(await client.cachedRequests() == nil)
        let restored = try makeClient(network, credentials, directory)
        #expect(await restored.cachedRequests() == nil)
    }

    @Test("Successful create, vote and detail responses update saved lists")
    func mutationsUpdateDisk() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = InMemoryBuildThisPleaseCredentialStore()
        let network = CacheTransport(tickets: [ticket()])
        let client = try makeClient(network, credentials, directory)
        try await client.preloadRequests()
        let voted = try await client.setVote(ticketId: "request", voted: true)
        #expect(voted.hasVoted == true)
        #expect(await client.cachedRequests()?.requests?.items.first?.hasVoted == true)
        let created = try await client.createTicket(title: "New", description: "New", idempotencyKey: "create")
        #expect(await client.cachedRequests()?.mine?.items.contains(where: { $0.id == created.id }) == true)
        await network.setTickets([ticket(title: "Updated")])
        _ = try await client.ticket(id: "request")
        let restored = try makeClient(CacheTransport(tickets: [], offline: true), credentials, directory)
        #expect(await restored.cachedRequests()?.requests?.items.first?.title == "Updated")
    }

    @Test("Overlapping vote and unvote publish in mutation order to memory, disk and delayed refreshes", .timeLimit(.minutes(1)))
    func overlappingVotesPublishInOrder() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = InMemoryBuildThisPleaseCredentialStore()
        let network = CacheTransport(tickets: [ticket()])
        let client = try makeClient(network, credentials, directory)
        _ = try await client.requests()
        await network.holdNextRequests()
        let refresh = Task { try await client.requests() }
        defer {
            refresh.cancel()
            Task { await network.release() }
        }
        await network.waitUntilHeld()

        let observer = TicketPublicationControl()
        await client.setRequestCacheTestHooks(.init(
            didQueueOperation: { observer.didQueue() },
            didCompleteOperation: { observer.didComplete() },
            beforePublishingTicket: { await observer.beforePublishing($0) }
        ))
        var queued = observer.queued.makeAsyncIterator()
        var publishing = observer.publishing.makeAsyncIterator()
        let vote = Task { try await client.setVote(ticketId: "request", voted: true) }
        defer {
            vote.cancel()
            Task { await observer.release() }
        }
        _ = try #require(await queued.next())
        guard let releasedQueueBeforePublication = await publishing.next() else { throw CancellationError() }
        let unvote = Task { try await client.setVote(ticketId: "request", voted: false) }
        defer { unvote.cancel() }
        _ = try #require(await queued.next())

        // If publication has escaped the queue, force the later response to be
        // fully cached first. This reproduces stale overwrite without timing or
        // task-priority assumptions; a correctly queued publication blocks it.
        if releasedQueueBeforePublication { _ = try await unvote.value }
        await observer.release()
        #expect(try await vote.value.hasVoted == true)
        #expect(try await unvote.value.hasVoted == false)
        await client.setRequestCacheTestHooks(nil)
        #expect(!releasedQueueBeforePublication)
        #expect(await client.cachedRequests()?.requests?.items.first?.hasVoted == false)
        let restored = try makeClient(CacheTransport(tickets: [], offline: true), credentials, directory)
        #expect(await restored.cachedRequests()?.requests?.items.first?.hasVoted == false)

        await network.release()
        #expect(try await refresh.value.first?.hasVoted == false)
        #expect(await client.cachedRequests()?.requests?.items.first?.hasVoted == false)
        let afterRefresh = try makeClient(CacheTransport(tickets: [], offline: true), credentials, directory)
        #expect(await afterRefresh.cachedRequests()?.requests?.items.first?.hasVoted == false)
    }

    @Test("A detail queued behind a vote publishes the newer detail response", .timeLimit(.minutes(1)))
    func detailQueuedBehindMutation() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = InMemoryBuildThisPleaseCredentialStore()
        let network = CacheTransport(tickets: [ticket()])
        let client = try makeClient(network, credentials, directory)
        _ = try await client.requests()
        let observer = TicketPublicationControl()
        await client.setRequestCacheTestHooks(.init(
            didQueueOperation: { observer.didQueue() },
            didCompleteOperation: { observer.didComplete() },
            beforePublishingTicket: { await observer.beforePublishing($0) }
        ))
        var queued = observer.queued.makeAsyncIterator()
        var publishing = observer.publishing.makeAsyncIterator()
        let vote = Task { try await client.setVote(ticketId: "request", voted: true) }
        defer {
            vote.cancel()
            Task { await observer.release() }
        }
        _ = try #require(await queued.next())
        _ = try #require(await publishing.next() != nil)
        await network.setTickets([ticket(title: "New detail")])
        let detail = Task { try await client.ticket(id: "request") }
        defer { detail.cancel() }
        _ = try #require(await queued.next())
        await observer.release()
        _ = try await vote.value
        #expect(try await detail.value.title == "New detail")
        #expect(await client.cachedRequests()?.requests?.items.first?.title == "New detail")
        let restored = try makeClient(CacheTransport(tickets: [], offline: true), credentials, directory)
        #expect(await restored.cachedRequests()?.requests?.items.first?.title == "New detail")
    }

    @Test("A replacement installation clears old viewer state and loads its fresh lists")
    func installationChangeDuringLoad() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = InMemoryBuildThisPleaseCredentialStore()
        let original = try makeClient(CacheTransport(tickets: [ticket(title: "Old account")]), credentials, directory)
        try await original.preloadRequests()
        let prefix = sha256(Data("btp_pk_cache_fixture".utf8)).base64URLEncodedString.prefix(16)
        await credentials.set(#"{"token":"expired","installationId":"cache-installation","expiresAt":"2000-01-01T00:00:00Z"}"#, for: "\(prefix).session")
        let replacement = try makeClient(CacheTransport(tickets: [ticket(title: "Replacement")], installation: "replacement"), credentials, directory)
        #expect(await replacement.cachedRequests()?.requests?.items.first?.title == "Old account")
        #expect(try await replacement.requests().first?.title == "Replacement")
        #expect(await replacement.cachedRequests()?.requests?.items.first?.title == "Replacement")
        #expect(await replacement.cachedRequests()?.mine == nil)
    }

    @Test("Create before Mine loads persists an incomplete snapshot and preloading fills it")
    func createdPartialMine() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = InMemoryBuildThisPleaseCredentialStore()
        let network = CacheTransport(tickets: [ticket()])
        let client = try makeClient(network, credentials, directory)
        let created = try await client.createTicket(title: "New", description: "New", idempotencyKey: "new")
        let saved = try #require(await client.cachedRequests()?.mine)
        #expect(saved.items.map(\.id) == [created.id])
        #expect(!saved.isComplete)
        #expect(!saved.isFresh())
        let restored = try makeClient(network, credentials, directory)
        #expect(await restored.cachedRequests()?.mine?.items.map(\.id) == [created.id])
        try await restored.preloadRequests()
        #expect(await restored.cachedRequests()?.mine?.isComplete == true)
    }

    @Test("Detail status changes move rows into already-loaded destination lists")
    func detailMovesMembership() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let network = CacheTransport(tickets: [ticket()])
        let client = try makeClient(network, InMemoryBuildThisPleaseCredentialStore(), directory)
        try await client.preloadRequests()
        let implemented = BuildThisPleaseTicket(id: "request", title: "Shipped", description: "Done", status: .implemented)
        await network.setTickets([implemented])
        _ = try await client.ticket(id: "request")
        #expect(await client.cachedRequests()?.requests?.items == [])
        #expect(await client.cachedRequests()?.implemented?.items.first?.status == .implemented)
        #expect(await client.cachedRequests()?.mine?.items.first?.status == .implemented)
        await network.setTickets([ticket()])
        _ = try await client.ticket(id: "request")
        #expect(await client.cachedRequests()?.implemented?.items == [])
        #expect(await client.cachedRequests()?.requests?.items.map(\.id) == ["request"])
    }

    @Test("A delayed refresh and vote preserve new server rows, removals and the latest vote")
    func refreshMutationRace() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = BuildThisPleaseTicket(id: "removed", title: "Removed", description: "Old", status: .inReview)
        let network = CacheTransport(tickets: [ticket(), old])
        let client = try makeClient(network, InMemoryBuildThisPleaseCredentialStore(), directory)
        _ = try await client.requests()
        let added = BuildThisPleaseTicket(id: "added", title: "Added", description: "New", status: .planned)
        await network.setTickets([ticket(), added])
        await network.holdNextRequests()
        let refresh = Task { try await client.requests() }
        await network.waitUntilHeld()
        let vote = Task { try await client.setVote(ticketId: "request", voted: true) }
        _ = try await vote.value
        #expect(await client.cachedRequests()?.requests?.items.first(where: { $0.id == "request" })?.hasVoted == true)
        await network.release()
        _ = try await refresh.value
        let saved = try #require(await client.cachedRequests()?.requests)
        #expect(Set(saved.items.map(\.id)) == ["request", "added"])
        #expect(saved.items.first(where: { $0.id == "request" })?.hasVoted == true)
    }

    @Test("Merged detail identities replace cached sources, preserve Mine and survive older lists and disk reopening", .timeLimit(.minutes(1)), arguments: [false, true], [false, true])
    func mergedDetailReplacesCachedSource(canonicalAlreadyListed: Bool, chained: Bool) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = InMemoryBuildThisPleaseCredentialStore()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let source = BuildThisPleaseTicket(id: "source", title: "Owned source", description: "Source", status: .inReview, createdAt: date, updatedAt: date, voteCount: 1, hasVoted: true, voteLocked: true)
        let listedCanonical = BuildThisPleaseTicket(id: "canonical", title: "Canonical", description: "Destination", status: .planned, createdAt: date, updatedAt: date, voteCount: 1, hasVoted: false, voteLocked: false)
        let canonical = BuildThisPleaseTicket(id: "canonical", title: "Canonical", description: "Destination", status: .planned, createdAt: date, updatedAt: date, voteCount: 2, hasVoted: true, voteLocked: true)
        let network = CanonicalCacheTransport(requests: canonicalAlreadyListed ? [source, listedCanonical] : [source], mine: [source])
        let client = try makeClient(network, credentials, directory)
        try await client.preloadRequests()

        await network.holdLists()
        let requests = Task { try await client.requests() }
        let mine = Task { try await client.myRequests() }
        let implemented = Task { try await client.implementedRequests() }
        defer {
            requests.cancel(); mine.cancel(); implemented.cancel()
            Task { await network.releaseLists() }
        }
        await network.waitUntilHeld(count: 3)
        // The real detail endpoint returns C without an alias back to requested S.
        await network.setDetail(canonical, requestedID: source.id)
        #expect(try await client.ticket(id: source.id) == canonical)
        #expect(await client.cachedRequests()?.requests?.items == [canonical])
        #expect(await client.cachedRequests()?.mine?.items == [canonical])

        let shipped = BuildThisPleaseTicket(id: chained ? "final" : canonical.id, title: "Shipped", description: "Done", status: .implemented, createdAt: date, updatedAt: date)
        await network.setDetail(shipped, requestedID: canonical.id)
        _ = try await client.ticket(id: canonical.id)
        #expect(await client.cachedRequests()?.requests?.items == [])
        #expect(await client.cachedRequests()?.mine?.items == [shipped])
        #expect(await client.cachedRequests()?.implemented?.items == [shipped])

        await network.releaseLists()
        #expect(try await requests.value == [])
        #expect(try await mine.value == [shipped])
        #expect(try await implemented.value == [shipped])
        let restored = try makeClient(CacheTransport(tickets: [], offline: true), credentials, directory)
        #expect(await restored.cachedRequests()?.requests?.items == [])
        #expect(await restored.cachedRequests()?.mine?.items == [shipped])
        #expect(await restored.cachedRequests()?.implemented?.items == [shipped])

        // A list started after those changes remains authoritative about removal.
        await network.setMine([])
        #expect(try await client.myRequests() == [])
        await network.setDetail(shipped, requestedID: shipped.id)
        _ = try await client.ticket(id: shipped.id)
        #expect(await client.cachedRequests()?.mine?.items == [])
        #expect(await network.listCalls == 7)
        #expect(await network.detailCalls == 3)
    }

    @Test("A mutation completing after logout cannot restore cleared cache")
    func clearDuringMutation() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = InMemoryBuildThisPleaseCredentialStore()
        let network = CacheTransport(tickets: [ticket()])
        let client = try makeClient(network, credentials, directory)
        _ = try await client.requests()
        await network.holdNextMutation()
        let mutation = Task { try await client.setVote(ticketId: "request", voted: true) }
        await network.waitUntilHeld()
        await client.clearRequestCache()
        await network.release()
        _ = try await mutation.value
        #expect(await client.cachedRequests() == nil)
        #expect(await (try makeClient(network, credentials, directory)).cachedRequests() == nil)
    }

    @Test("Cancelling a screen waiter leaves the shared launch preload running")
    func waiterCancellation() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let network = CacheTransport(tickets: [ticket()], holdRequests: true)
        let client = try makeClient(network, InMemoryBuildThisPleaseCredentialStore(), directory)
        let launch = Task { try await client.preloadRequests() }
        await network.waitUntilHeld()
        let screen = Task { try await client.requests() }
        screen.cancel()
        await network.release()
        try await launch.value
        await #expect(throws: CancellationError.self) { try await screen.value }
        #expect(await client.cachedRequests()?.requests?.items.count == 1)
        #expect(await network.listCalls == 3)
    }

    @Test("Expired, corrupt and oversized disk entries are discarded")
    func rejectsInvalidDiskEntries() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RequestCacheDiskStore(directory: directory)
        let expired = BuildThisPleaseRequestSnapshot(requests: .init(items: [ticket()], updatedAt: .now.addingTimeInterval(-8 * 24 * 60 * 60)))
        await store.write(expired, key: "expired")
        #expect(await store.read(key: "expired") == nil)
        try Data("broken".utf8).write(to: directory.appendingPathComponent("broken.json"))
        #expect(await store.read(key: "broken") == nil)
        try Data(repeating: 0, count: RequestCacheDiskStore.maximumBytes + 1).write(to: directory.appendingPathComponent("oversized.json"))
        #expect(await store.read(key: "oversized") == nil)
    }

    private func temporaryDirectory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("btp-cache-test-" + UUID().uuidString, isDirectory: true) }
    private func ticket(title: String = "Request") -> BuildThisPleaseTicket { .init(id: "request", title: title, description: "Details", status: .inReview, voteCount: 1, hasVoted: false) }
    private func makeClient(_ transport: any BuildThisPleaseTransport, _ credentials: InMemoryBuildThisPleaseCredentialStore, _ directory: URL, namespace: String? = nil, baseURL: String = "https://feedback.example.test", staging: Bool = false, bundle: String = "com.example.cache", project: String = "btp_pk_cache_fixture") throws -> BuildThisPleaseClient {
        let url = URL(string: baseURL)!
        return BuildThisPleaseClient(configuration: try .init(projectKey: project, environment: staging ? .staging(baseURL: url) : .local(baseURL: url), identityNamespace: namespace, bundleIdentifier: bundle), transport: transport, credentialStore: credentials, attestationProvider: CacheAttestationProvider(), requestCacheDirectory: directory)
    }
}

private actor CanonicalCacheTransport: BuildThisPleaseTransport {
    private let requests: [BuildThisPleaseTicket]
    private var mine: [BuildThisPleaseTicket]
    private var details: [String: BuildThisPleaseTicket] = [:]
    private var holdsLists = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var listCalls = 0
    private(set) var detailCalls = 0

    init(requests: [BuildThisPleaseTicket], mine: [BuildThisPleaseTicket]) { self.requests = requests; self.mine = mine }
    func setDetail(_ ticket: BuildThisPleaseTicket, requestedID: String) { details[requestedID] = ticket }
    func setMine(_ tickets: [BuildThisPleaseTicket]) { mine = tickets }
    func holdLists() { holdsLists = true }
    func waitUntilHeld(count: Int) async {
        if held.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
    func releaseLists() { holdsLists = false; let active = held; held.removeAll(); active.forEach { $0.resume() } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path
        let data: Data
        if path == "/v1/development/sessions" {
            data = Data(#"{"installationId":"cache-installation","sessionToken":"cache-session","expiresAt":"2099-01-01T00:00:00Z"}"#.utf8)
        } else if ["/v1/tickets", "/v1/me/tickets", "/v1/implemented"].contains(path) {
            listCalls += 1
            let items = path == "/v1/tickets" ? requests : path == "/v1/me/tickets" ? mine : []
            if holdsLists {
                await withCheckedContinuation { continuation in
                    held.append(continuation)
                    let ready = waiters.filter { held.count >= $0.count }
                    waiters.removeAll { held.count >= $0.count }
                    ready.forEach { $0.continuation.resume() }
                }
            }
            data = try JSONCoding.encoder().encode(BuildThisPleasePage(items: items, nextCursor: nil))
        } else {
            detailCalls += 1
            let ticket = try #require(details[request.url!.lastPathComponent])
            struct Envelope: Encodable { let ticket: BuildThisPleaseTicket }
            data = try JSONCoding.encoder().encode(Envelope(ticket: ticket))
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private struct CacheAttestationProvider: BuildThisPleaseAttestationProvider {
    let isSupported = false
    func generateKey() async throws -> String { throw BuildThisPleaseError.appAttestUnavailable }
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data { throw BuildThisPleaseError.appAttestUnavailable }
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data { throw BuildThisPleaseError.appAttestUnavailable }
}

private actor CacheTransport: BuildThisPleaseTransport {
    private var tickets: [BuildThisPleaseTicket]
    private let offline: Bool
    private let installation: String
    private var holdRequests: Bool
    private var holdMutation = false
    private var held: CheckedContinuation<Void, Never>?
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []
    private var completedOtherLists: Set<String> = []
    private var otherListWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var listCalls = 0
    private(set) var requestsCalls = 0
    init(tickets: [BuildThisPleaseTicket], offline: Bool = false, holdRequests: Bool = false, installation: String = "cache-installation") { self.tickets = tickets; self.offline = offline; self.holdRequests = holdRequests; self.installation = installation }
    func setTickets(_ tickets: [BuildThisPleaseTicket]) { self.tickets = tickets }
    func holdNextRequests() { holdRequests = true }
    func holdNextMutation() { holdMutation = true }
    func waitUntilHeld() async { if held != nil { return }; await withCheckedContinuation { heldWaiters.append($0) } }
    func waitUntilOtherListsCompleted() async {
        if completedOtherLists.count == 2 { return }
        await withCheckedContinuation { otherListWaiters.append($0) }
    }
    func release() { holdRequests = false; holdMutation = false; held?.resume(); held = nil }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard !offline else { throw BuildThisPleaseError.offline }
        let path = request.url!.path
        let data: Data
        if path == "/v1/development/sessions" { data = Data("{\"installationId\":\"\(installation)\",\"sessionToken\":\"cache-session\",\"expiresAt\":\"2099-01-01T00:00:00Z\"}".utf8) }
        else if request.httpMethod == "GET" && ["/v1/tickets", "/v1/me/tickets", "/v1/implemented"].contains(path) {
            listCalls += 1
            let responseTickets = tickets
            if path == "/v1/tickets" {
                requestsCalls += 1
                if holdRequests { await withCheckedContinuation { continuation in held = continuation; heldWaiters.forEach { $0.resume() }; heldWaiters.removeAll() } }
            }
            data = try JSONCoding.encoder().encode(BuildThisPleasePage(items: responseTickets, nextCursor: nil))
        } else {
            if holdMutation { await withCheckedContinuation { continuation in held = continuation; heldWaiters.forEach { $0.resume() }; heldWaiters.removeAll() } }
            let ticket: BuildThisPleaseTicket
            if path.hasSuffix("/vote") {
                let old = tickets[0]
                let voted = request.httpMethod == "PUT"
                ticket = .init(id: old.id, title: old.title, description: old.description, status: old.status, voteCount: voted ? 2 : 1, hasVoted: voted)
            } else if request.httpMethod == "POST" { ticket = .init(id: "created", title: "New", description: "New", status: .pending) }
            else { ticket = tickets[0] }
            struct Envelope: Encodable { let ticket: BuildThisPleaseTicket }
            data = try JSONCoding.encoder().encode(Envelope(ticket: ticket))
        }
        if request.httpMethod == "GET" && ["/v1/me/tickets", "/v1/implemented"].contains(path) {
            completedOtherLists.insert(path)
            if completedOtherLists.count == 2 { otherListWaiters.forEach { $0.resume() }; otherListWaiters.removeAll() }
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private final class TicketPublicationControl: Sendable {
    private let completedOperations = OSAllocatedUnfairLock(initialState: 0)
    private let publicationGate = TicketPublicationGate()
    let queued: AsyncStream<Void>
    let publishing: AsyncStream<Bool>
    private let queueEvents: AsyncStream<Void>.Continuation
    private let publicationEvents: AsyncStream<Bool>.Continuation

    init() {
        (queued, queueEvents) = AsyncStream.makeStream()
        (publishing, publicationEvents) = AsyncStream.makeStream()
    }

    func didQueue() { queueEvents.yield(()) }
    func didComplete() { completedOperations.withLock { $0 += 1 } }
    func beforePublishing(_ ticket: BuildThisPleaseTicket) async {
        guard ticket.hasVoted == true else { return }
        publicationEvents.yield(completedOperations.withLock { $0 > 0 })
        await publicationGate.wait()
    }
    func release() async { await publicationGate.release() }
}

private actor TicketPublicationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        await withTaskCancellationHandler {
            guard !released else { return }
            await withCheckedContinuation { continuation = $0 }
        } onCancel: {
            Task { await self.release() }
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private struct ParallelListAttestationProvider: BuildThisPleaseAttestationProvider {
    let isSupported = true
    func generateKey() async throws -> String { throw BuildThisPleaseError.attestationFailed }
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data { throw BuildThisPleaseError.attestationFailed }
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data { Data(repeating: 7, count: 64) }
}

private actor ParallelRejectedListTransport: BuildThisPleaseTransport {
    private(set) var recoveryCount = 0
    private(set) var recoveryChallengeCount = 0
    private(set) var oldTokenRequests = 0
    private(set) var newTokenRequests = 0
    private var oldWaiters: [CheckedContinuation<Void, Never>] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path
        let body: String
        var status = 200
        switch path {
        case "/v1/attestation/recovery/challenges":
            recoveryChallengeCount += 1
            body = #"{"challengeId":"parallel-challenge","challengeHash":"challenge-hash","requestHash":"request-hash"}"#
        case "/v1/attestation/recoveries":
            recoveryCount += 1
            body = #"{"sessionToken":"new-token","installationId":"parallel-installation","expiresAt":"2099-01-01T00:00:00Z"}"#
        case "/v1/tickets", "/v1/me/tickets", "/v1/implemented":
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer old-token" {
                oldTokenRequests += 1
                if oldTokenRequests < 3 { await withCheckedContinuation { oldWaiters.append($0) } }
                else { oldWaiters.forEach { $0.resume() }; oldWaiters.removeAll() }
                status = 401
                body = #"{"error":{"code":"installation_session_invalid","message":"Expired"}}"#
            } else {
                newTokenRequests += 1
                body = #"{"items":[],"nextCursor":null}"#
            }
        default: throw BuildThisPleaseError.invalidResponse
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
