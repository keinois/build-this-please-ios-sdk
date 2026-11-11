import BuildThisPleaseCore
import Foundation
import Testing
@testable import BuildThisPleaseUI

@Suite("Updates loading lifecycle", .timeLimit(.minutes(1)))
struct UpdatesModelTests {
    @Test("Reactivation refreshes before a cancelled scene load finishes", arguments: HeldUpdatesFailure.allCases)
    @MainActor
    fileprivate func foregroundRestartsCancelledLoad(oldFailure: HeldUpdatesFailure) async {
        let old = update("old")
        let fresh = update("fresh")
        let client = HeldUpdatesClient(
            pages: [page([old], cursor: "old-next"), page([fresh], cursor: "fresh-next")],
            settings: [.init(email: "old@example.com"), .init(email: "fresh@example.com", emailEnabled: true)],
            heldLoads: [1], failures: [1: oldFailure]
        )
        let model = UpdatesModel(client: client)
        let previousScene = Task { await model.load() }
        await client.waitUntilHeld(call: 1)
        previousScene.cancel()

        await model.load()

        #expect(await client.requestedCursors.count == 2)
        #expect(model.updates == [fresh])
        #expect(model.email == "fresh@example.com")
        #expect(model.preferences.emailEnabled)
        #expect(model.cursor == "fresh-next")
        #expect(!model.loading)
        #expect(model.error == nil)
        await client.release(call: 1)
        await previousScene.value
        #expect(model.updates == [fresh])
        #expect(model.email == "fresh@example.com")
        #expect(model.cursor == "fresh-next")
        #expect(!model.loading)
        #expect(model.error == nil)
    }

    @Test("An old scene finishing cannot clear the replacement load's busy state")
    @MainActor
    func replacementOwnsLoadingState() async {
        let fresh = update("fresh")
        let client = HeldUpdatesClient(pages: [page([update("old")]), page([fresh])], heldLoads: [1, 2])
        let model = UpdatesModel(client: client)
        let previousScene = Task { await model.load() }
        await client.waitUntilHeld(call: 1)
        previousScene.cancel()
        let completion = UpdatesLoadCompletion()
        let currentScene = Task { await model.load(); completion.finished = true }
        // If a regression drops the replacement call, fail without waiting for
        // a second network call that will never arrive.
        while await client.startedLoadCount < 2 && !completion.finished { await Task.yield() }
        if await client.startedLoadCount == 2 { await client.waitUntilHeld(call: 2) }

        await client.release(call: 1)
        await previousScene.value

        #expect(await client.startedLoadCount == 2)
        #expect(model.loading)
        #expect(model.updates.isEmpty)
        #expect(model.error == nil)
        await client.release(call: 2)
        await currentScene.value
        #expect(model.updates == [fresh])
        #expect(!model.loading)
    }

    @Test("The latest refresh failure keeps the displayed inbox and preferences")
    @MainActor
    func latestFailureKeepsContent() async {
        let saved = update("saved")
        let client = HeldUpdatesClient(
            pages: [page([saved], cursor: "saved-next"), page([])],
            settings: [.init(email: "saved@example.com", localNotificationsEnabled: true)],
            failures: [2: .offline]
        )
        let model = UpdatesModel(client: client)
        await model.load()
        await model.load()
        #expect(model.updates == [saved])
        #expect(model.cursor == "saved-next")
        #expect(model.email == "saved@example.com")
        #expect(model.preferences.localNotificationsEnabled)
        #expect(model.error != nil)
        #expect(!model.loading)
    }

    @Test("Cancellation without a replacement leaves no cancellation error", arguments: HeldUpdatesFailure.allCases)
    @MainActor
    fileprivate func cancelledLoadDoesNotPublish(failure: HeldUpdatesFailure) async {
        let client = HeldUpdatesClient(pages: [page([update("cancelled")])], heldLoads: [1], failures: [1: failure])
        let model = UpdatesModel(client: client)
        let loading = Task { await model.load() }
        await client.waitUntilHeld(call: 1)
        loading.cancel()
        await client.release(call: 1)
        await loading.value
        #expect(model.updates.isEmpty)
        #expect(model.error == nil)
        #expect(!model.loading)
    }

    @Test("Refreshing discards delayed pagination and rejects its stale cursor")
    @MainActor
    func refreshReplacesPagination() async {
        let fresh = update("fresh")
        let client = HeldUpdatesClient(
            pages: [page([update("first")], cursor: "old-next"), page([update("later")], cursor: "old-last"), page([fresh], cursor: "fresh-next")],
            heldLoads: [2]
        )
        let model = UpdatesModel(client: client)
        await model.load()
        let pagination = Task { await model.load(cursor: "old-next") }
        await client.waitUntilHeld(call: 2)
        await model.load()
        await client.release(call: 2)
        await pagination.value
        await model.load(cursor: "old-next")
        #expect(await client.requestedCursors == [nil, "old-next", nil])
        #expect(model.updates == [fresh])
        #expect(model.cursor == "fresh-next")
        #expect(!model.loading)
    }

    @Test("Load more appends unique rows and advances the cursor")
    @MainActor
    func paginationAppends() async {
        let first = update("first")
        let next = update("next")
        let client = HeldUpdatesClient(pages: [page([first], cursor: "next"), page([first, next])])
        let model = UpdatesModel(client: client)
        await model.load()
        await model.load(cursor: "next")
        #expect(model.updates == [first, next])
        #expect(model.cursor == nil)
        #expect(await client.requestedCursors == [nil, "next"])
    }

    @Test("A refresh cannot undo a preference save or clear its busy state", arguments: [false, true])
    @MainActor
    func preferenceSaveSurvivesRefresh(releaseSaveFirst: Bool) async {
        let saved = BuildThisPleaseNotificationPreferences(email: "saved@example.com", emailEnabled: true, verificationPending: true)
        let client = HeldUpdatesClient(
            pages: [page([])], settings: [.init(email: "old@example.com")], heldLoads: [1], savedPreferences: saved, holdSave: true
        )
        let model = UpdatesModel(client: client)
        model.email = "saved@example.com"
        let saving = Task { await model.saveEmail(enabled: true) }
        await client.waitUntilSaveHeld()
        let refresh = Task { await model.load() }
        await client.waitUntilHeld(call: 1)

        if releaseSaveFirst {
            await client.releaseSave()
            await saving.value
            #expect(model.loading)
            await client.release(call: 1)
            await refresh.value
        } else {
            await client.release(call: 1)
            await refresh.value
            #expect(model.loading)
            #expect(!model.preferences.emailEnabled)
            await client.releaseSave()
            await saving.value
        }

        #expect(model.preferences.email == "saved@example.com")
        #expect(model.preferences.emailEnabled)
        #expect(model.preferences.verificationPending)
        #expect(model.email == "saved@example.com")
        #expect(model.notice != nil)
        #expect(model.error == nil)
        #expect(!model.loading)
    }

    @Test("A delayed refresh keeps a failed preference save visible", arguments: [false, true])
    @MainActor
    func preferenceFailureSurvivesRefresh(refreshFails: Bool) async {
        let client = HeldUpdatesClient(
            pages: [page([])], heldLoads: [1], failures: refreshFails ? [1: .offline] : [:], holdSave: true, failSave: true
        )
        let model = UpdatesModel(client: client)
        model.email = "saved@example.com"
        let saving = Task { await model.saveEmail(enabled: true) }
        await client.waitUntilSaveHeld()
        let refresh = Task { await model.load() }
        await client.waitUntilHeld(call: 1)
        await client.releaseSave()
        await saving.value
        let saveError = model.error
        #expect(saveError != nil)
        await client.release(call: 1)
        await refresh.value
        #expect(model.error == saveError)
        #expect(!model.loading)
    }

    @Test("A successful read acknowledgement survives an older inbox response")
    @MainActor
    func readSurvivesDelayedInbox() async {
        let unread = update("notice")
        let client = HeldUpdatesClient(pages: [page([unread]), page([unread])], heldLoads: [2])
        let model = UpdatesModel(client: client)
        await model.load()
        let refresh = Task { await model.load() }
        await client.waitUntilHeld(call: 2)
        await model.open(unread)
        #expect(await client.markedReadIDs == [unread.id])
        #expect(model.selectedTicket?.id == unread.ticketId)
        #expect(model.updates.first?.readAt != nil)
        await client.release(call: 2)
        await refresh.value
        #expect(model.updates.first?.readAt != nil)
        #expect(model.error == nil)
    }

    private func update(_ id: String) -> BuildThisPleaseNotification {
        .init(id: id, ticketId: "ticket-" + id, title: "Shipped " + id)
    }

    private func page(_ items: [BuildThisPleaseNotification], cursor: String? = nil) -> BuildThisPleaseNotificationPage {
        .init(items: items, unreadCount: items.count, nextCursor: cursor)
    }
}

@MainActor
private final class UpdatesLoadCompletion {
    var finished = false
}

private enum HeldUpdatesFailure: CaseIterable, Sendable {
    case none, cancellation, offline
}

private actor HeldUpdatesClient: BuildThisPleaseClientProtocol {
    let pages: [BuildThisPleaseNotificationPage]
    let settings: [BuildThisPleaseNotificationPreferences]
    let heldLoads: Set<Int>
    let failures: [Int: HeldUpdatesFailure]
    let savedPreferences: BuildThisPleaseNotificationPreferences
    let holdSave: Bool
    let failSave: Bool
    private var notificationCalls = 0
    private var preferenceCalls = 0
    private var held: [String: CheckedContinuation<Void, Never>] = [:]
    private var heldWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var saveContinuation: CheckedContinuation<Void, Never>?
    private var saveWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var requestedCursors: [String?] = []
    private(set) var markedReadIDs: [String] = []

    var startedLoadCount: Int { min(notificationCalls, preferenceCalls) }

    init(
        pages: [BuildThisPleaseNotificationPage],
        settings: [BuildThisPleaseNotificationPreferences] = [.init()],
        heldLoads: Set<Int> = [],
        failures: [Int: HeldUpdatesFailure] = [:],
        savedPreferences: BuildThisPleaseNotificationPreferences = .init(),
        holdSave: Bool = false,
        failSave: Bool = false
    ) {
        self.pages = pages
        self.settings = settings
        self.heldLoads = heldLoads
        self.failures = failures
        self.savedPreferences = savedPreferences
        self.holdSave = holdSave
        self.failSave = failSave
    }

    func notifications(cursor: String?) async throws -> BuildThisPleaseNotificationPage {
        notificationCalls += 1
        let call = notificationCalls
        requestedCursors.append(cursor)
        let page = pages[min(call - 1, pages.count - 1)]
        await hold(call: call, kind: "page")
        switch failures[call, default: .none] {
        case .none: return page
        case .cancellation: throw CancellationError()
        case .offline: throw BuildThisPleaseError.offline
        }
    }

    func notificationPreferences() async throws -> BuildThisPleaseNotificationPreferences {
        preferenceCalls += 1
        let call = preferenceCalls
        let preferences = settings[min(call - 1, settings.count - 1)]
        await hold(call: call, kind: "preferences")
        return preferences
    }

    // Deliberately ignore task cancellation until released, like a shared SDK
    // operation or an underlying request that is still unwinding.
    private func hold(call: Int, kind: String) async {
        guard heldLoads.contains(call) else { return }
        await withCheckedContinuation { continuation in
            held["\(call)-\(kind)"] = continuation
            if isHeld(call: call) {
                heldWaiters.removeValue(forKey: call)?.forEach { $0.resume() }
            }
        }
    }

    private func isHeld(call: Int) -> Bool {
        held["\(call)-page"] != nil && held["\(call)-preferences"] != nil
    }

    func waitUntilHeld(call: Int) async {
        guard !isHeld(call: call) else { return }
        await withCheckedContinuation { heldWaiters[call, default: []].append($0) }
    }

    func release(call: Int) {
        held.removeValue(forKey: "\(call)-page")?.resume()
        held.removeValue(forKey: "\(call)-preferences")?.resume()
    }

    func updateNotificationPreferences(email: String?, emailEnabled: Bool?, localNotificationsEnabled: Bool?) async throws -> BuildThisPleaseNotificationPreferences {
        if holdSave {
            await withCheckedContinuation { continuation in
                saveContinuation = continuation
                saveWaiters.forEach { $0.resume() }
                saveWaiters.removeAll()
            }
        }
        if failSave { throw BuildThisPleaseError.invalidResponse }
        return savedPreferences
    }

    func waitUntilSaveHeld() async {
        guard saveContinuation == nil else { return }
        await withCheckedContinuation { saveWaiters.append($0) }
    }

    func releaseSave() {
        let continuation = saveContinuation
        saveContinuation = nil
        continuation?.resume()
    }

    func ticket(id: String) async throws -> BuildThisPleaseTicket {
        .init(id: id, title: id, description: "Shipped", status: .implemented)
    }
    func markNotificationsRead(ids: [String]) async throws { markedReadIDs += ids }
    func configuration() async throws -> BuildThisPleaseConfigurationResponse { throw BuildThisPleaseError.invalidResponse }
    func requests() async throws -> [BuildThisPleaseTicket] { [] }
    func myRequests() async throws -> [BuildThisPleaseTicket] { [] }
    func implementedRequests() async throws -> [BuildThisPleaseTicket] { [] }
    func comments(ticketId: String) async throws -> [BuildThisPleaseComment] { [] }
    func createTicket(title: String, description: String, idempotencyKey: String) async throws -> BuildThisPleaseTicket { throw BuildThisPleaseError.invalidResponse }
    func setVote(ticketId: String, voted: Bool) async throws -> BuildThisPleaseTicket { throw BuildThisPleaseError.invalidResponse }
    func createComment(ticketId: String, body: String, idempotencyKey: String) async throws -> BuildThisPleaseComment { throw BuildThisPleaseError.invalidResponse }
    func updateComment(ticketId: String, commentId: String, body: String) async throws -> BuildThisPleaseComment { throw BuildThisPleaseError.invalidResponse }
    func updateSubscriptionStatus(_ status: BuildThisPleaseSubscriptionStatus) async throws { }
}
