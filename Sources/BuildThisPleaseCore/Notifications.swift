import Foundation

public struct BuildThisPleaseNotification: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let ticketId: String
    public let title: String
    public let implementationNote: String?
    public let appVersion: String?
    public let createdAt: Date
    public var readAt: Date?
    /// Current follow state. When absent, local synchronization queries the client.
    public var following: Bool?
    public init(id: String, ticketId: String, title: String, implementationNote: String? = nil, appVersion: String? = nil, createdAt: Date = .now, readAt: Date? = nil, following: Bool? = nil) {
        self.id=id; self.ticketId=ticketId; self.title=title; self.implementationNote=implementationNote; self.appVersion=appVersion; self.createdAt=createdAt; self.readAt=readAt; self.following=following
    }
}
public struct BuildThisPleaseNotificationPage: Codable, Sendable {
    public let items: [BuildThisPleaseNotification]
    public let unreadCount: Int
    public let nextCursor: String?
    public init(items: [BuildThisPleaseNotification], unreadCount: Int, nextCursor: String?) { self.items=items; self.unreadCount=unreadCount; self.nextCursor=nextCursor }
}
public struct BuildThisPleaseNotificationPreferences: Codable, Sendable {
    public var email: String?
    public var emailEnabled: Bool
    public var emailVerified: Bool
    public var verificationPending: Bool
    public var localNotificationsEnabled: Bool
    public var identityLinked: Bool
    public init(email: String? = nil, emailEnabled: Bool = false, emailVerified: Bool = false, verificationPending: Bool = false, localNotificationsEnabled: Bool = false, identityLinked: Bool = false) {
        self.email=email;self.emailEnabled=emailEnabled;self.emailVerified=emailVerified;self.verificationPending=verificationPending;self.localNotificationsEnabled=localNotificationsEnabled;self.identityLinked=identityLinked
    }
}

#if canImport(UserNotifications)
import UserNotifications

protocol BuildThisPleaseLocalNotificationDelivery: Sendable {
    func isAuthorized() async -> Bool
    func post(_ update: BuildThisPleaseNotification) async throws
}

private struct SystemLocalNotificationDelivery: BuildThisPleaseLocalNotificationDelivery {
    func isAuthorized() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }
    func post(_ update: BuildThisPleaseNotification) async throws {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "A request you follow is ready", bundle: .module)
        content.body = update.title
        content.userInfo = ["buildThisPleaseTicketId": update.ticketId, "buildThisPleaseNotificationId": update.id]
        content.sound = .default
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "btp." + update.id, content: content, trigger: nil))
    }
}

/// Retain one synchronizer per project and signed-in host account. The host schedules
/// background runtime; this helper never installs a notification-center delegate.
public actor BuildThisPleaseNotificationSync {
    private let client: any BuildThisPleaseClientProtocol
    private let storageKey: String
    private let delivery: any BuildThisPleaseLocalNotificationDelivery
    private var syncing = false
    private struct WaitingSynchronization {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }
    private var waitingSynchronizations: [WaitingSynchronization] = []
    // A read-only test seam for entering cancellation/overlap cases deterministically.
    var pendingSynchronizationCount: Int { waitingSynchronizations.count }
    private var lastUnreadCount = 0
    public init(client: any BuildThisPleaseClientProtocol, namespace: String) {
        self.client=client
        self.delivery = SystemLocalNotificationDelivery()
        self.storageKey="BuildThisPlease.notifications." + Data(namespace.utf8).base64EncodedString()
    }
    init(client: any BuildThisPleaseClientProtocol, namespace: String, delivery: any BuildThisPleaseLocalNotificationDelivery) {
        self.client = client
        self.delivery = delivery
        self.storageKey = "BuildThisPlease.notifications." + Data(namespace.utf8).base64EncodedString()
    }
    public static func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
    @discardableResult public func synchronize(inBackground: Bool = false) async throws -> Int {
        try await acquireSynchronization()
        defer { releaseSynchronization() }
        try Task.checkCancellation()
        var page = try await client.notifications(cursor: nil)
        try Task.checkCancellation()
        lastUnreadCount = page.unreadCount
        guard inBackground else { return page.unreadCount }
        let preferences = try await client.notificationPreferences()
        try Task.checkCancellation()
        guard preferences.localNotificationsEnabled else { return page.unreadCount }
        let authorized = await delivery.isAuthorized()
        try Task.checkCancellation()
        guard authorized else { return page.unreadCount }
        var delivered = Set(UserDefaults.standard.stringArray(forKey: storageKey) ?? [])
        var seenCursors: Set<String> = []
        while true {
            for update in page.items where update.readAt == nil && !delivered.contains(update.ticketId) {
                try Task.checkCancellation()
                let following: Bool
                if let current = update.following { following = current }
                else { following = try await client.following(ticketId: update.ticketId) }
                guard following else { continue }
                try Task.checkCancellation()
                try await delivery.post(update)
                delivered.insert(update.ticketId)
                UserDefaults.standard.set(Array(delivered), forKey: storageKey)
                try Task.checkCancellation()
            }
            guard let cursor = page.nextCursor else { break }
            guard seenCursors.insert(cursor).inserted else { throw BuildThisPleaseError.invalidResponse }
            try Task.checkCancellation()
            page = try await client.notifications(cursor: cursor)
            try Task.checkCancellation()
        }
        return lastUnreadCount
    }

    private func acquireSynchronization() async throws {
        try Task.checkCancellation()
        guard syncing else { syncing = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                waitingSynchronizations.append(.init(id: id, continuation: continuation))
            }
        } onCancel: {
            // This task only retires a queued continuation. Network and delivery
            // always remain in the host caller's task and inherit its cancellation.
            Task { await self.cancelWaitingSynchronization(id) }
        }
    }

    private func cancelWaitingSynchronization(_ id: UUID) {
        guard let index = waitingSynchronizations.firstIndex(where: { $0.id == id }) else { return }
        waitingSynchronizations.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func releaseSynchronization() {
        guard !waitingSynchronizations.isEmpty else { syncing = false; return }
        // Keep the lease reserved until the resumed caller releases it, including
        // cancellation that arrives between granting its turn and resuming it.
        waitingSynchronizations.removeFirst().continuation.resume()
    }
}
#endif
