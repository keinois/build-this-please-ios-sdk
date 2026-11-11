import BuildThisPleaseCore
import Foundation
import Testing
@testable import BuildThisPleaseUI

@Suite("Implemented request ordering")
struct BoardModelTests {
    @Test("Request email validation matches the Worker")
    func requestEmailValidation() {
        #expect(RequestEmailValidator.isValid(""))
        #expect(RequestEmailValidator.isValid("support@example.com"))
        #expect(!RequestEmailValidator.isValid("a@b"))
        #expect(!RequestEmailValidator.isValid("two..dots@example.com"))
    }

    @Test("Mine is hidden until the installation creates a request")
    @MainActor
    func mineVisibilityFollowsOwnedRequests() {
        let model = BoardModel(client: MockBuildThisPleaseClient(tickets: []))
        #expect(!model.showsMineSection)

        model.created(ticket(id: "owned", implementedAt: nil, updatedAt: .now, status: .pending))

        #expect(model.showsMineSection)
        #expect(model.selectedSection == .mine)
    }

    @Test("Newest implementation appears first with updated date as fallback")
    func newestImplementationAppearsFirst() {
        let reference = Date(timeIntervalSince1970: 1_800_000_000)
        let tickets = [
            ticket(id: "older", implementedAt: reference.addingTimeInterval(-300), updatedAt: reference),
            ticket(id: "fallback", implementedAt: nil, updatedAt: reference.addingTimeInterval(-100)),
            ticket(id: "newest", implementedAt: reference, updatedAt: reference.addingTimeInterval(-500))
        ]

        #expect(tickets.sortedByImplementationRecency().map(\.id) == ["newest", "fallback", "older"])
    }

    @Test("Requests rank by votes then workflow progress")
    func requestsRankByVotesThenProgress() {
        let reference = Date(timeIntervalSince1970: 1_800_000_000)
        let tickets = [
            ticket(id: "one-vote", implementedAt: nil, updatedAt: reference, status: .inProgress, voteCount: 1),
            ticket(id: "review", implementedAt: nil, updatedAt: reference, status: .inReview, voteCount: 5),
            ticket(id: "progress", implementedAt: nil, updatedAt: reference, status: .inProgress, voteCount: 5),
            ticket(id: "planned", implementedAt: nil, updatedAt: reference, status: .planned, voteCount: 5),
            ticket(id: "most-votes", implementedAt: nil, updatedAt: reference, status: .inReview, voteCount: 8)
        ]

        #expect(tickets.sortedByRequestPriority().map(\.id) == [
            "most-votes", "progress", "planned", "review", "one-vote"
        ])
    }

    private func ticket(
        id: String,
        implementedAt: Date?,
        updatedAt: Date,
        status: BuildThisPleaseTicketStatus = .implemented,
        voteCount: Int? = nil
    ) -> BuildThisPleaseTicket {
        BuildThisPleaseTicket(
            id: id,
            title: id,
            description: "Description",
            status: status,
            updatedAt: updatedAt,
            implementedAt: implementedAt,
            voteCount: voteCount
        )
    }
}

@Suite("Cached board loading")
struct CachedBoardModelTests {
    @Test("Foreground restarts loading before a cancelled scene task finishes")
    @MainActor
    func foregroundRestartsCancelledLoad() async {
        let old = BuildThisPleaseTicket(id: "request", title: "Old", description: "Old", status: .inReview)
        let fresh = BuildThisPleaseTicket(id: "request", title: "Fresh", description: "Fresh", status: .inProgress)
        let snapshot = BuildThisPleaseRequestSnapshot(mine: .init(items: [], updatedAt: .now), implemented: .init(items: [], updatedAt: .now))
        let client = CachedBoardClient(items: [fresh], saved: snapshot, holdRequests: true, firstRequests: [old])
        let model = BoardModel(client: client)
        let previousScene = Task { await model.becameActive() }
        await client.waitUntilHeld()
        previousScene.cancel()

        await model.becameActive()

        #expect(await client.requestCalls == 2)
        #expect(model.requests == [fresh])
        #expect(model.hasLoadedCurrentSection)
        #expect(!model.isLoading)
        await client.release()
        await previousScene.value
        #expect(model.requests == [fresh])
        #expect(!model.isLoading)
    }

    @Test("An older load cannot finish or publish over a newer pending load")
    @MainActor
    func newerLoadOwnsLoadingState() async {
        let old = BuildThisPleaseTicket(id: "request", title: "Old", description: "Old", status: .inReview)
        let fresh = BuildThisPleaseTicket(id: "request", title: "Fresh", description: "Fresh", status: .inProgress)
        let snapshot = BuildThisPleaseRequestSnapshot(mine: .init(items: [], updatedAt: .now), implemented: .init(items: [], updatedAt: .now))
        let client = CachedBoardClient(items: [fresh], saved: snapshot, holdRequests: true, firstRequests: [old], holdLaterRequests: true)
        let model = BoardModel(client: client)
        let previous = Task { await model.load() }
        await client.waitUntilHeld()
        let completion = BoardLoadCompletion()
        let current = Task { await model.load(); completion.finished = true }
        // Also terminate on completion so the pre-fix dropped refresh fails
        // assertions rather than leaving this regression waiting for a call.
        while await client.requestCalls < 2 && !completion.finished { await Task.yield() }

        await client.releaseRequest(call: 1)
        await previous.value
        #expect(await client.requestCalls == 2)
        #expect(model.isLoading)
        #expect(model.requests.isEmpty)

        await client.releaseRequest(call: 2)
        await current.value
        #expect(model.requests == [fresh])
        #expect(model.hasLoadedCurrentSection)
        #expect(!model.isLoading)
    }

    @Test("Fast Requests publish independently, including successful empty lists", arguments: [false, true])
    @MainActor
    func publishesRequestsBeforeMine(empty: Bool) async {
        let items: [BuildThisPleaseTicket] = empty ? [] : [.init(id: "request", title: "Ready", description: "Ready", status: .inReview)]
        let client = CachedBoardClient(items: items, holdMine: true)
        let model = BoardModel(client: client)
        let loading = Task { await model.load() }
        await client.waitUntilHeld()
        while !model.loadedSections.contains(.requests) { await Task.yield() }
        #expect(model.isLoading)
        #expect(model.hasLoadedCurrentSection)
        #expect(model.requests == items)
        await client.release()
        await loading.value
    }

    @Test("Cached empty counts as loaded while a refresh is pending")
    @MainActor
    func cachedEmptyLoadedBeforeRefresh() async {
        let snapshot = BuildThisPleaseRequestSnapshot(requests: .init(items: [], updatedAt: .now.addingTimeInterval(-120)))
        let client = CachedBoardClient(items: [], saved: snapshot, holdMine: true)
        let model = BoardModel(client: client)
        let loading = Task { await model.load() }
        await client.waitUntilHeld()
        #expect(model.hasLoadedCurrentSection)
        #expect(model.requests.isEmpty)
        await client.release()
        await loading.value
    }

    @Test("A held saved snapshot cannot overwrite a completed manual refresh")
    @MainActor
    func manualRefreshWinsOverSavedSnapshot() async {
        let old = BuildThisPleaseTicket(id: "request", title: "Old", description: "Old", status: .inReview)
        let fresh = BuildThisPleaseTicket(id: "request", title: "Fresh", description: "Fresh", status: .inProgress)
        let snapshot = BuildThisPleaseRequestSnapshot(requests: .init(items: [old], updatedAt: .now), mine: .init(items: [], updatedAt: .now), implemented: .init(items: [], updatedAt: .now))
        let client = CachedBoardClient(items: [fresh], saved: snapshot, holdSnapshot: true)
        let model = BoardModel(client: client)
        let loading = Task { await model.load() }
        await client.waitUntilHeld()
        await model.refreshCurrentSection()
        #expect(model.requests == [fresh])
        await client.release()
        await loading.value
        #expect(model.requests == [fresh])
        #expect(await client.requestCalls == 1)
    }

    @Test("A failed manual refresh while restoration waits still displays offline cache")
    @MainActor
    func failedManualRefreshKeepsSavedSnapshot() async {
        let saved = BuildThisPleaseTicket(id: "saved", title: "Saved offline", description: "Saved", status: .inReview)
        let snapshot = BuildThisPleaseRequestSnapshot(requests: .init(items: [saved], updatedAt: .now), mine: .init(items: [], updatedAt: .now), implemented: .init(items: [], updatedAt: .now))
        let client = CachedBoardClient(items: [], saved: snapshot, failRequests: true, holdSnapshot: true)
        let model = BoardModel(client: client)
        let loading = Task { await model.load() }
        await client.waitUntilHeld()
        await model.refreshCurrentSection()
        #expect(model.errorMessage != nil)
        await client.release()
        await loading.value
        #expect(model.requests == [saved])
        #expect(model.hasLoadedCurrentSection)
        #expect(model.errorMessage != nil)
        #expect(await client.requestCalls == 1)
    }

    @Test("Restoration does not invalidate a manual refresh that was already running")
    @MainActor
    func existingManualRefreshRemainsAuthoritative() async {
        let old = BuildThisPleaseTicket(id: "request", title: "Old", description: "Old", status: .inReview)
        let fresh = BuildThisPleaseTicket(id: "request", title: "Fresh", description: "Fresh", status: .inProgress)
        let snapshot = BuildThisPleaseRequestSnapshot(requests: .init(items: [old], updatedAt: .now), mine: .init(items: [], updatedAt: .now), implemented: .init(items: [], updatedAt: .now))
        let client = CachedBoardClient(items: [fresh], saved: snapshot, holdRequests: true)
        let model = BoardModel(client: client)
        model.requests = [old]
        let refresh = Task { await model.refreshCurrentSection() }
        await client.waitUntilHeld()
        await model.load()
        #expect(model.requests == [old])
        #expect(await client.requestCalls == 1)
        await client.release()
        await refresh.value
        #expect(model.requests == [fresh])
    }

    @Test("An earlier list callback cannot overwrite a newer manual refresh")
    @MainActor
    func manualRefreshWinsOverEarlierList() async {
        let old = BuildThisPleaseTicket(id: "request", title: "Old", description: "Old", status: .inReview)
        let fresh = BuildThisPleaseTicket(id: "request", title: "Fresh", description: "Fresh", status: .inProgress)
        let snapshot = BuildThisPleaseRequestSnapshot(requests: .init(items: [old], updatedAt: .now.addingTimeInterval(-120)), mine: .init(items: [], updatedAt: .now), implemented: .init(items: [], updatedAt: .now))
        let client = CachedBoardClient(items: [fresh], saved: snapshot, holdRequests: true, firstRequests: [old])
        let model = BoardModel(client: client)
        let loading = Task { await model.load() }
        await client.waitUntilHeld()
        await model.refreshCurrentSection()
        #expect(model.requests == [fresh])
        await client.release()
        await loading.value
        #expect(model.requests == [fresh])
        #expect(await client.requestCalls == 2)
    }

    @Test("Detail status changes move visible rows while preserving existing Mine ownership")
    @MainActor
    func detailMovesVisibleMembership() async {
        let request = BuildThisPleaseTicket(id: "request", title: "Working", description: "Working", status: .inProgress)
        let shipped = BuildThisPleaseTicket(id: "request", title: "Shipped", description: "Done", status: .implemented)
        let snapshot = BuildThisPleaseRequestSnapshot(requests: .init(items: [request], updatedAt: .now), mine: .init(items: [request], updatedAt: .now), implemented: .init(items: [], updatedAt: .now))
        let client = CachedBoardClient(items: [], saved: snapshot, detail: shipped)
        let model = BoardModel(client: client)
        await model.load()
        let detail = TicketDetailModel(client: client, ticket: request, onTicketUpdated: model.replace)
        await detail.load()
        #expect(model.requests.isEmpty)
        #expect(model.implemented == [shipped])
        #expect(model.mine == [shipped])
        model.replace(request)
        #expect(model.requests == [request])
        #expect(model.implemented.isEmpty)
        #expect(model.mine == [request])
        let publicOnly = BuildThisPleaseTicket(id: "public", title: "Public", description: "Public", status: .inReview)
        model.replace(publicOnly)
        #expect(!model.mine.contains { $0.id == publicOnly.id })
    }

    @Test("Delayed source and destination lists preserve a newer detail status change")
    @MainActor
    func delayedListsPreserveDetailMembership() async {
        let request = BuildThisPleaseTicket(id: "request", title: "Working", description: "Working", status: .inProgress)
        let shipped = BuildThisPleaseTicket(id: "request", title: "Shipped", description: "Done", status: .implemented)
        let old = Date.now.addingTimeInterval(-120)
        let snapshot = BuildThisPleaseRequestSnapshot(requests: .init(items: [request], updatedAt: old), mine: .init(items: [request], updatedAt: .now), implemented: .init(items: [], updatedAt: old))
        let client = CachedBoardClient(items: [request], saved: snapshot, holdRequests: true, holdImplemented: true, detail: shipped)
        let model = BoardModel(client: client)
        let loading = Task { await model.load() }
        await client.waitUntilHeld(count: 2)
        let detail = TicketDetailModel(client: client, ticket: request, onTicketUpdated: model.replace)
        await detail.load()
        await client.release()
        await loading.value
        #expect(model.requests.isEmpty)
        #expect(model.implemented == [shipped])
        #expect(model.mine == [shipped])
    }

    @Test("A created Mine record survives its detail update and a delayed empty Mine response")
    @MainActor
    func createdOwnershipSurvivesDetailUpdate() async {
        let pending = BuildThisPleaseTicket(id: "created", title: "New", description: "New", status: .pending)
        let updated = BuildThisPleaseTicket(id: "created", title: "Reviewed", description: "Reviewed", status: .inReview)
        let client = CachedBoardClient(items: [], holdMine: true)
        let model = BoardModel(client: client)
        let loading = Task { await model.load() }
        await client.waitUntilHeld()
        model.created(pending)
        model.replace(updated)
        await client.release()
        await loading.value
        #expect(model.mine == [updated])
        #expect(model.requests == [updated])
    }

    @Test("Detail publication replaces a merged source and canonical duplicates while older lists finish", .timeLimit(.minutes(1)), arguments: [false, true])
    @MainActor
    func mergedDetailPublication(chained: Bool) async {
        let source = BuildThisPleaseTicket(id: "source", title: "Owned source", description: "Source", status: .inReview, voteCount: 1, hasVoted: true)
        let listedCanonical = BuildThisPleaseTicket(id: "canonical", title: "Canonical", description: "Destination", status: .planned, voteCount: 1, hasVoted: false)
        let canonical = BuildThisPleaseTicket(id: "canonical", title: "Canonical", description: "Destination", status: .planned, voteCount: 2, hasVoted: true)
        let old = Date.now.addingTimeInterval(-120)
        let snapshot = BuildThisPleaseRequestSnapshot(requests: .init(items: [source, listedCanonical], updatedAt: old), mine: .init(items: [source], updatedAt: old), implemented: .init(items: [], updatedAt: old))
        let client = CachedBoardClient(items: [source, listedCanonical], saved: snapshot, holdMine: true, holdRequests: true, holdImplemented: true, detail: canonical)
        let model = BoardModel(client: client)
        let loading = Task { await model.load() }
        defer { loading.cancel(); Task { await client.release() } }
        await client.waitUntilHeld(count: 3)
        // Match the navigation destination's callback, retaining the opened S ID.
        let detail = TicketDetailModel(client: client, ticket: source) { updated in
            model.replace(updated, replacingID: source.id)
        }
        await detail.load()
        #expect(model.requests == [canonical])
        #expect(model.mine == [canonical])
        let shipped = BuildThisPleaseTicket(id: chained ? "final" : canonical.id, title: "Shipped", description: "Done", status: .implemented)
        model.replace(shipped, replacingID: canonical.id)
        await client.release()
        await loading.value
        #expect(model.requests == [])
        #expect(model.mine == [shipped])
        #expect(model.implemented == [shipped])

        model.selectedSection = .mine
        let removal = Task { await model.refreshCurrentSection() }
        await client.waitUntilHeld()
        await client.release()
        await removal.value
        #expect(model.mine == [])
        model.replace(shipped)
        #expect(model.mine == [])
        #expect(model.selectedSection == .requests)
    }

    @Test("Failed refresh retains offline cached requests and successes still replace other lists")
    @MainActor
    func offlineCachedContent() async {
        let row = BuildThisPleaseTicket(id: "cached", title: "Saved", description: "Saved", status: .inReview)
        let snapshot = BuildThisPleaseRequestSnapshot(requests: .init(items: [row], updatedAt: .now.addingTimeInterval(-120)), mine: .init(items: [row], updatedAt: .now.addingTimeInterval(-120)))
        let client = CachedBoardClient(items: [], saved: snapshot, failRequests: true)
        let model = BoardModel(client: client)
        await model.load()
        #expect(model.requests == [row])
        #expect(model.mine.isEmpty)
        #expect(model.errorMessage != nil)
    }
}

@MainActor
private final class BoardLoadCompletion {
    var finished = false
}

private actor CachedBoardClient: BuildThisPleaseClientProtocol {
    let items: [BuildThisPleaseTicket]
    let saved: BuildThisPleaseRequestSnapshot?
    let holdMine: Bool
    let holdRequests: Bool
    let holdSnapshot: Bool
    let firstRequests: [BuildThisPleaseTicket]?
    let holdLaterRequests: Bool
    private(set) var requestCalls = 0
    let holdImplemented: Bool
    let failRequests: Bool
    let detail: BuildThisPleaseTicket?
    private let base = MockBuildThisPleaseClient()
    private var held: [String: CheckedContinuation<Void, Never>] = [:]
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    init(items: [BuildThisPleaseTicket], saved: BuildThisPleaseRequestSnapshot? = nil, holdMine: Bool = false, failRequests: Bool = false, holdRequests: Bool = false, holdImplemented: Bool = false, detail: BuildThisPleaseTicket? = nil, holdSnapshot: Bool = false, firstRequests: [BuildThisPleaseTicket]? = nil, holdLaterRequests: Bool = false) {
        self.items = items; self.saved = saved; self.holdMine = holdMine; self.failRequests = failRequests
        self.holdRequests = holdRequests; self.holdImplemented = holdImplemented; self.detail = detail
        self.holdSnapshot = holdSnapshot; self.firstRequests = firstRequests
        self.holdLaterRequests = holdLaterRequests
    }
    func cachedRequests() async -> BuildThisPleaseRequestSnapshot? {
        if holdSnapshot { await pause("snapshot") }
        return saved
    }
    func requests() async throws -> [BuildThisPleaseTicket] {
        requestCalls += 1
        let call = requestCalls
        let result = call == 1 ? firstRequests ?? items : items
        if failRequests { throw BuildThisPleaseError.offline }
        if holdRequests && (call == 1 || holdLaterRequests) { await pause("requests-\(call)") }
        return result
    }
    func myRequests() async throws -> [BuildThisPleaseTicket] {
        if holdMine { await pause("mine") }
        return []
    }
    func implementedRequests() async throws -> [BuildThisPleaseTicket] {
        if holdImplemented { await pause("implemented") }
        return []
    }
    private func pause(_ section: String) async {
        await withCheckedContinuation { continuation in
            held[section] = continuation
            let ready = waiters.filter { held.count >= $0.count }
            waiters.removeAll { held.count >= $0.count }
            ready.forEach { $0.continuation.resume() }
        }
    }
    func waitUntilHeld(count: Int = 1) async {
        if held.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
    func release() { let active = held.values; held.removeAll(); active.forEach { $0.resume() } }
    func releaseRequest(call: Int) { held.removeValue(forKey: "requests-\(call)")?.resume() }
    func configuration() async throws -> BuildThisPleaseConfigurationResponse { try await base.configuration() }
    func ticket(id: String) async throws -> BuildThisPleaseTicket {
        if let detail { return detail }
        return try await base.ticket(id: id)
    }
    func comments(ticketId: String) async throws -> [BuildThisPleaseComment] { [] }
    func createTicket(title: String, description: String, idempotencyKey: String) async throws -> BuildThisPleaseTicket { try await base.createTicket(title: title, description: description, idempotencyKey: idempotencyKey) }
    func setVote(ticketId: String, voted: Bool) async throws -> BuildThisPleaseTicket { try await base.setVote(ticketId: ticketId, voted: voted) }
    func createComment(ticketId: String, body: String, idempotencyKey: String) async throws -> BuildThisPleaseComment { try await base.createComment(ticketId: ticketId, body: body, idempotencyKey: idempotencyKey) }
    func updateComment(ticketId: String, commentId: String, body: String) async throws -> BuildThisPleaseComment { try await base.updateComment(ticketId: ticketId, commentId: commentId, body: body) }
    func updateSubscriptionStatus(_ status: BuildThisPleaseSubscriptionStatus) async throws { }
}
