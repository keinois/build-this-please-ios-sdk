import Foundation
import Testing
@testable import BuildThisPleaseCore

#if canImport(UserNotifications)
@Suite("Background completion synchronization")
struct NotificationSyncTests {
    @Test("All pages are delivered once, including backlogs larger than the old deduplication window")
    func paginatedDelivery() async throws {
        let client = PagedNotificationClient(count: 1005)
        let delivery = RecordingNotificationDelivery()
        let namespace = UUID().uuidString
        defer { UserDefaults.standard.removeObject(forKey: "BuildThisPlease.notifications." + Data(namespace.utf8).base64EncodedString()) }
        let sync = BuildThisPleaseNotificationSync(client: client, namespace: namespace, delivery: delivery)
        #expect(try await sync.synchronize(inBackground: true) == 1005)
        #expect(await delivery.posted.count == 1005)
        #expect(await client.requestedCursors.count == 11)
        #expect(await client.followingRequests.isEmpty)
        let restored = BuildThisPleaseNotificationSync(client: client, namespace: namespace, delivery: delivery)
        #expect(try await restored.synchronize(inBackground: true) == 1005)
        #expect(await delivery.posted.count == 1005)
    }

    @Test("Foreground synchronization only fetches the count and posts no local alerts")
    func foregroundCount() async throws {
        let client = PagedNotificationClient(count: 201)
        let delivery = RecordingNotificationDelivery()
        let sync = BuildThisPleaseNotificationSync(client: client, namespace: UUID().uuidString, delivery: delivery)
        #expect(try await sync.synchronize() == 201)
        #expect(await delivery.posted.isEmpty)
        #expect(await client.requestedCursors.count == 1)
    }

    @Test("Muting after completion suppresses local delivery while preserving unread history")
    func mutedHistory() async throws {
        let client = PagedNotificationClient(count: 2, mutedTickets: ["ticket-0"])
        let delivery = RecordingNotificationDelivery()
        let namespace = UUID().uuidString
        defer { UserDefaults.standard.removeObject(forKey: "BuildThisPlease.notifications." + Data(namespace.utf8).base64EncodedString()) }
        let sync = BuildThisPleaseNotificationSync(client: client, namespace: namespace, delivery: delivery)
        #expect(try await sync.synchronize(inBackground: true) == 2)
        #expect(await delivery.posted == ["ticket-1"])
        let history = try await client.notifications(cursor: nil)
        #expect(history.items.count == 2)
        #expect(history.items.allSatisfy { $0.readAt == nil })
        try await client.setFollowing(ticketId: "ticket-0", following: true)
        #expect(try await sync.synchronize(inBackground: true) == 2)
        #expect(await delivery.posted == ["ticket-1", "ticket-0"])
    }

    @Test("Older or custom inbox responses without follow state recheck before local delivery")
    func followStateFallback() async throws {
        let client = PagedNotificationClient(count: 1, mutedTickets: ["ticket-0"], includeFollowState: false)
        let delivery = RecordingNotificationDelivery()
        let sync = BuildThisPleaseNotificationSync(client: client, namespace: UUID().uuidString, delivery: delivery)
        #expect(try await sync.synchronize(inBackground: true) == 1)
        #expect(await delivery.posted.isEmpty)
        #expect(await client.followingRequests == ["ticket-0"])
    }

    @Test("Background calls wait for a foreground fetch and deliver once", .timeLimit(.minutes(1)))
    func overlappingBackgroundDelivery() async throws {
        let client = PagedNotificationClient(count: 1, holdFirst: true)
        let delivery = RecordingNotificationDelivery()
        let namespace = UUID().uuidString
        defer { clearDelivered(namespace) }
        let sync = BuildThisPleaseNotificationSync(client: client, namespace: namespace, delivery: delivery)
        let foreground = Task { try await sync.synchronize() }
        await client.waitUntilFirstRequestHeld()
        let firstBackground = Task { try await sync.synchronize(inBackground: true) }
        try await waitForQueued(1, on: sync)
        let secondBackground = Task { try await sync.synchronize(inBackground: true) }
        try await waitForQueued(2, on: sync)
        #expect(await client.requestedCursors.count == 1)
        #expect(await delivery.posted.isEmpty)
        await client.releaseFirstRequest()
        #expect(try await foreground.value == 1)
        #expect(try await firstBackground.value == 1)
        #expect(try await secondBackground.value == 1)
        #expect(await delivery.posted == ["ticket-0"])
        #expect(await client.requestedCursors.count == 3)
    }

    @Test("Cancelling a queued background call exits before the active fetch finishes", .timeLimit(.minutes(1)))
    func cancelledQueuedBackground() async throws {
        let client = PagedNotificationClient(count: 1, holdFirst: true)
        let delivery = RecordingNotificationDelivery()
        let namespace = UUID().uuidString
        defer { clearDelivered(namespace) }
        let sync = BuildThisPleaseNotificationSync(client: client, namespace: namespace, delivery: delivery)
        let foreground = Task { try await sync.synchronize() }
        await client.waitUntilFirstRequestHeld()
        let cancelledBackground = Task { try await sync.synchronize(inBackground: true) }
        try await waitForQueued(1, on: sync)
        cancelledBackground.cancel()
        do {
            _ = try await cancelledBackground.value
            Issue.record("A cancelled queued call must throw cancellation")
        } catch is CancellationError { }
        #expect(await client.requestedCursors.count == 1)
        #expect(await delivery.posted.isEmpty)
        let nextBackground = Task { try await sync.synchronize(inBackground: true) }
        try await waitForQueued(1, on: sync)
        await client.releaseFirstRequest()
        #expect(try await foreground.value == 1)
        #expect(try await nextBackground.value == 1)
        #expect(await client.requestedCursors.count == 2)
        #expect(await delivery.posted == ["ticket-0"])
    }

    @Test("Cancelling an active foreground call leaves queued background work eligible", .timeLimit(.minutes(1)))
    func cancelledForegroundWithQueuedBackground() async throws {
        let client = PagedNotificationClient(count: 1, holdFirst: true)
        let delivery = RecordingNotificationDelivery()
        let namespace = UUID().uuidString
        defer { clearDelivered(namespace) }
        let sync = BuildThisPleaseNotificationSync(client: client, namespace: namespace, delivery: delivery)
        let foreground = Task { try await sync.synchronize() }
        await client.waitUntilFirstRequestHeld()
        let background = Task { try await sync.synchronize(inBackground: true) }
        try await waitForQueued(1, on: sync)
        foreground.cancel()
        await client.releaseFirstRequest()
        do {
            _ = try await foreground.value
            Issue.record("A cancelled active call must throw cancellation")
        } catch is CancellationError { }
        #expect(try await background.value == 1)
        #expect(await delivery.posted == ["ticket-0"])
    }

    @Test("A foreground failure is returned without discarding queued background work", .timeLimit(.minutes(1)))
    func failedForegroundWithQueuedBackground() async throws {
        let client = PagedNotificationClient(count: 1, holdFirst: true, failFirst: true)
        let delivery = RecordingNotificationDelivery()
        let namespace = UUID().uuidString
        defer { clearDelivered(namespace) }
        let sync = BuildThisPleaseNotificationSync(client: client, namespace: namespace, delivery: delivery)
        let foreground = Task { try await sync.synchronize() }
        await client.waitUntilFirstRequestHeld()
        let background = Task { try await sync.synchronize(inBackground: true) }
        try await waitForQueued(1, on: sync)
        await client.releaseFirstRequest()
        do {
            _ = try await foreground.value
            Issue.record("The foreground caller must receive its fetch failure")
        } catch BuildThisPleaseError.offline { }
        #expect(try await background.value == 1)
        #expect(await delivery.posted == ["ticket-0"])
    }

    private func waitForQueued(_ count: Int, on sync: BuildThisPleaseNotificationSync) async throws {
        while await sync.pendingSynchronizationCount != count {
            try Task.checkCancellation()
            await Task.yield()
        }
    }

    private func clearDelivered(_ namespace: String) {
        UserDefaults.standard.removeObject(forKey: "BuildThisPlease.notifications." + Data(namespace.utf8).base64EncodedString())
    }
}

private actor RecordingNotificationDelivery: BuildThisPleaseLocalNotificationDelivery {
    private(set) var posted: [String] = []
    func isAuthorized() async -> Bool { true }
    func post(_ update: BuildThisPleaseNotification) async throws { posted.append(update.ticketId) }
}

private actor PagedNotificationClient: BuildThisPleaseClientProtocol {
    let count: Int
    private var mutedTickets: Set<String>
    private let includeFollowState: Bool
    private let holdFirst: Bool
    private let failFirst: Bool
    private var heldFirstRequest: CheckedContinuation<Void, Never>?
    private var heldRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var requestedCursors: [String?] = []
    private(set) var followingRequests: [String] = []
    init(count: Int, mutedTickets: Set<String> = [], includeFollowState: Bool = true, holdFirst: Bool = false, failFirst: Bool = false) {
        self.count = count
        self.mutedTickets = mutedTickets
        self.includeFollowState = includeFollowState
        self.holdFirst = holdFirst
        self.failFirst = failFirst
    }
    func notifications(cursor: String?) async throws -> BuildThisPleaseNotificationPage {
        requestedCursors.append(cursor)
        let isFirst = requestedCursors.count == 1
        if isFirst && holdFirst {
            await withCheckedContinuation { continuation in
                heldFirstRequest = continuation
                let waiters = heldRequestWaiters
                heldRequestWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
        if isFirst && failFirst { throw BuildThisPleaseError.offline }
        let start = Int(cursor ?? "0") ?? 0
        let end = min(start + 100, count)
        return .init(items: (start..<end).map { .init(id: "notice-\($0)", ticketId: "ticket-\($0)", title: "Shipped \($0)", following: includeFollowState ? !mutedTickets.contains("ticket-\($0)") : nil) }, unreadCount: count, nextCursor: end < count ? String(end) : nil)
    }
    func waitUntilFirstRequestHeld() async {
        guard heldFirstRequest == nil else { return }
        await withCheckedContinuation { heldRequestWaiters.append($0) }
    }
    func releaseFirstRequest() {
        let held = heldFirstRequest
        heldFirstRequest = nil
        held?.resume()
    }
    func following(ticketId: String) async throws -> Bool { followingRequests.append(ticketId); return !mutedTickets.contains(ticketId) }
    func setFollowing(ticketId: String, following: Bool) async throws {
        if following { mutedTickets.remove(ticketId) } else { mutedTickets.insert(ticketId) }
    }
    func notificationPreferences() async throws -> BuildThisPleaseNotificationPreferences { .init(localNotificationsEnabled: true) }
    func configuration() async throws -> BuildThisPleaseConfigurationResponse { throw BuildThisPleaseError.invalidResponse }
    func requests() async throws -> [BuildThisPleaseTicket] { [] }
    func myRequests() async throws -> [BuildThisPleaseTicket] { [] }
    func implementedRequests() async throws -> [BuildThisPleaseTicket] { [] }
    func ticket(id: String) async throws -> BuildThisPleaseTicket { throw BuildThisPleaseError.invalidResponse }
    func comments(ticketId: String) async throws -> [BuildThisPleaseComment] { [] }
    func createTicket(title: String, description: String, idempotencyKey: String) async throws -> BuildThisPleaseTicket { throw BuildThisPleaseError.invalidResponse }
    func setVote(ticketId: String, voted: Bool) async throws -> BuildThisPleaseTicket { throw BuildThisPleaseError.invalidResponse }
    func createComment(ticketId: String, body: String, idempotencyKey: String) async throws -> BuildThisPleaseComment { throw BuildThisPleaseError.invalidResponse }
    func updateComment(ticketId: String, commentId: String, body: String) async throws -> BuildThisPleaseComment { throw BuildThisPleaseError.invalidResponse }
    func updateSubscriptionStatus(_ status: BuildThisPleaseSubscriptionStatus) async throws {}
}
#endif
