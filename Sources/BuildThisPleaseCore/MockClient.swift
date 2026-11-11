import Foundation

public enum MockBuildThisPleaseScenario: String, CaseIterable, Sendable {
    case normal, empty, loading, offline, rateLimited, expiredSession, serverError
}

public actor MockBuildThisPleaseClient: BuildThisPleaseClientProtocol {
    private var mockPreferences = BuildThisPleaseNotificationPreferences()
    private var mockUpdates = [BuildThisPleaseNotification(id: "completion-implemented", ticketId: "implemented", title: "Implemented release notes", implementationNote: "Requests you follow now have completion updates.", appVersion: "1.0")]
    private var mutedTickets: Set<String> = []
    private var followedTickets: Set<String> = []
    private var ownedTickets: Set<String> = []
    private var allTickets: [BuildThisPleaseTicket]
    private var commentsByTicket: [String: [BuildThisPleaseComment]]
    private let scenario: MockBuildThisPleaseScenario
    private var subscriptionStatus: BuildThisPleaseSubscriptionStatus

    public init(
        tickets: [BuildThisPleaseTicket] = MockBuildThisPleaseClient.sampleTickets,
        comments: [String: [BuildThisPleaseComment]] = MockBuildThisPleaseClient.sampleComments,
        scenario: MockBuildThisPleaseScenario = .normal,
        subscriptionStatus: BuildThisPleaseSubscriptionStatus = .trial
    ) {
        self.allTickets = scenario == .empty ? [] : tickets
        self.commentsByTicket = scenario == .empty ? [:] : comments
        self.followedTickets = Set(self.allTickets.filter { $0.hasVoted == true }.map(\.id))
        self.scenario = scenario
        self.subscriptionStatus = subscriptionStatus
    }

    public func configuration() async throws -> BuildThisPleaseConfigurationResponse {
        try await prepare()
        return .init(project: .init(id: "example", name: "BuildThisPlease Example", slug: "example", accentColor: "#B88A2B"), capabilities: .init(allowInProgressVoting: true, implementedCommentsLocked: true))
    }
    public func requests() async throws -> [BuildThisPleaseTicket] { try await prepare(); return allTickets.filter { [.inReview, .planned, .inProgress].contains($0.status) } }
    public func myRequests() async throws -> [BuildThisPleaseTicket] {
        try await prepare()
        var seen = Set<String>()
        return allTickets.compactMap { ticket in
            let resolved = ticket.status == .merged && ticket.canonicalTicketId != nil
                ? allTickets.first(where: { $0.id == ticket.canonicalTicketId }) ?? ticket
                : ticket
            return seen.insert(resolved.id).inserted ? resolved : nil
        }
    }
    public func implementedRequests() async throws -> [BuildThisPleaseTicket] { try await prepare(); return allTickets.filter { $0.status == .implemented } }
    public func ticket(id: String) async throws -> BuildThisPleaseTicket {
        try await prepare()
        guard var value = allTickets.first(where: { $0.id == id }) else { throw BuildThisPleaseError.invalidResponse }
        if value.status == .merged, let destination = value.canonicalTicketId { value = allTickets.first(where: { $0.id == destination }) ?? value }
        return value
    }
    public func comments(ticketId: String) async throws -> [BuildThisPleaseComment] { try await prepare(); return commentsByTicket[ticketId] ?? [] }
    public func createTicket(title: String, description: String, idempotencyKey: String) async throws -> BuildThisPleaseTicket { try await createTicket(title: title, description: description, email: nil, idempotencyKey: idempotencyKey) }
    public func createTicket(title: String, description: String, email: String?, idempotencyKey: String) async throws -> BuildThisPleaseTicket { try await prepare(); let value = BuildThisPleaseTicket(id: UUID().uuidString, title: title, description: description, status: .pending, voteCount: 1, hasVoted: true, voteLocked: true); ownedTickets.insert(value.id); followedTickets.insert(value.id); allTickets.insert(value, at: 0); return value }
    public func setVote(ticketId: String, voted: Bool) async throws -> BuildThisPleaseTicket { try await prepare(); guard let index = allTickets.firstIndex(where: { $0.id == ticketId }) else { throw BuildThisPleaseError.invalidResponse }; let old = allTickets[index]; if old.voteLocked == true { throw BuildThisPleaseError.server(code: "author_vote_permanent", message: "The author’s first vote is permanent.", status: 409) }; let value = BuildThisPleaseTicket(id: old.id, title: old.title, description: old.description, status: old.status, commentsLocked: old.commentsLocked, createdAt: old.createdAt, updatedAt: .now, implementedAt: old.implementedAt, implementedAppVersion: old.implementedAppVersion, implementationNote: old.implementationNote, voteCount: max(0, (old.voteCount ?? 0) + (voted ? 1 : -1)), hasVoted: voted); allTickets[index] = value; if voted && !mutedTickets.contains(ticketId) { followedTickets.insert(ticketId) }; return value }
    public func createComment(ticketId: String, body: String, idempotencyKey: String) async throws -> BuildThisPleaseComment { try await prepare(); let value = BuildThisPleaseComment(id: UUID().uuidString, ticketId: ticketId, author: .user, body: body, isEdited: false, isHidden: false, isApproved: false, isMine: true, createdAt: .now, updatedAt: .now); commentsByTicket[ticketId, default: []].append(value); return value }
    public func updateComment(ticketId: String, commentId: String, body: String) async throws -> BuildThisPleaseComment {
        try await prepare()
        guard let index = commentsByTicket[ticketId]?.firstIndex(where: { $0.id == commentId && $0.isMine && !$0.isHidden }) else {
            throw BuildThisPleaseError.server(code: "comment_not_editable", message: "This message cannot be edited.", status: 403)
        }
        let old = commentsByTicket[ticketId]![index]
        let updated = BuildThisPleaseComment(id: old.id, ticketId: old.ticketId, author: old.author, body: body, isEdited: true, isHidden: false, isApproved: false, isMine: old.isMine, createdAt: old.createdAt, updatedAt: .now)
        commentsByTicket[ticketId]![index] = updated
        return updated
    }
    public func updateSubscriptionStatus(_ status: BuildThisPleaseSubscriptionStatus) async throws { try await prepare(); subscriptionStatus = status }

    public func notifications(cursor: String? = nil) async throws -> BuildThisPleaseNotificationPage {
        try await prepare(); let values: [BuildThisPleaseNotification] = scenario == .empty ? [] : mockUpdates.map { update in
            var value = update
            value.following = followedTickets.contains(update.ticketId)
            return value
        }
        return .init(items: values, unreadCount: values.filter { $0.readAt == nil }.count, nextCursor: nil)
    }
    public func markNotificationsRead(ids: [String]) async throws { try await prepare(); for index in mockUpdates.indices where ids.contains(mockUpdates[index].id) { mockUpdates[index].readAt = .now } }
    public func notificationPreferences() async throws -> BuildThisPleaseNotificationPreferences { try await prepare(); return mockPreferences }
    public func updateNotificationPreferences(email: String?, emailEnabled: Bool?, localNotificationsEnabled: Bool?) async throws -> BuildThisPleaseNotificationPreferences {
        try await prepare()
        if let email { mockPreferences.email=email }
        if let emailEnabled { mockPreferences.emailEnabled=emailEnabled; mockPreferences.emailVerified=emailEnabled; mockPreferences.verificationPending=false }
        if let localNotificationsEnabled { mockPreferences.localNotificationsEnabled=localNotificationsEnabled }
        return mockPreferences
    }
    public func following(ticketId: String) async throws -> Bool { try await prepare(); return followedTickets.contains(ticketId) }
    public func setFollowing(ticketId: String, following: Bool) async throws { try await prepare(); if following { mutedTickets.remove(ticketId); followedTickets.insert(ticketId) } else { mutedTickets.insert(ticketId); followedTickets.remove(ticketId) } }

    private func prepare() async throws {
        switch scenario {
        case .normal, .empty: return
        case .loading: try await Task.sleep(for: .seconds(2))
        case .offline: throw BuildThisPleaseError.offline
        case .rateLimited: throw BuildThisPleaseError.server(code: "rate_limit_exceeded", message: "Too many requests. Try again shortly.", status: 429)
        case .expiredSession: throw BuildThisPleaseError.sessionExpired
        case .serverError: throw BuildThisPleaseError.server(code: "fixture_error", message: "The example server is unavailable.", status: 503)
        }
    }

    public static let sampleTickets: [BuildThisPleaseTicket] = [
        .init(id: "review", title: "Filter requests by status", description: "Focus on the requests that are planned or already being built.", status: .inReview, voteCount: 12, hasVoted: false),
        .init(id: "planned", title: "Remember my selected tab", description: "Open on the same section I used last time.", status: .planned, voteCount: 7, hasVoted: true),
        .init(id: "pending", title: "Compact weekly summary", description: "A quick overview of what changed this week.", status: .pending),
        .init(id: "progress", title: "Export my requests", description: "Keep a copy of feedback submitted from this installation.", status: .inProgress, voteCount: 4, hasVoted: false),
        .init(id: "rejected", title: "Public profile", description: "A profile is intentionally unnecessary for anonymous feedback.", status: .rejected, commentsLocked: true),
        .init(id: "merged", title: "Duplicate selected-tab request", description: "This request resolves to the planned canonical ticket.", status: .merged, commentsLocked: true, canonicalTicketId: "planned"),
        .init(id: "implemented", title: "Implemented release notes", description: "A quiet list of shipped requests.", status: .implemented, commentsLocked: true, implementedAt: .now, implementedAppVersion: "1.0", implementationNote: "Implemented requests now have a dedicated list.")
    ]

    public static let sampleComments: [String: [BuildThisPleaseComment]] = [
        "review": [
            .init(id: "comment-user", ticketId: "review", author: .user, body: "A filter for planned work would help.", isEdited: true, isHidden: false, isMine: true, createdAt: .now.addingTimeInterval(-3_600), updatedAt: .now),
            .init(id: "comment-admin", ticketId: "review", author: .administrator, body: "That is now part of the design.", isEdited: false, isHidden: false, createdAt: .now.addingTimeInterval(-1_800), updatedAt: .now),
            .init(id: "comment-other-user", ticketId: "review", author: .user, body: "I would use this too.", isEdited: false, isHidden: false, createdAt: .now.addingTimeInterval(-1_200), updatedAt: .now),
            .init(id: "comment-hidden", ticketId: "review", author: .user, body: nil, isEdited: false, isHidden: true, isMine: true, createdAt: .now.addingTimeInterval(-900), updatedAt: .now)
        ]
    ]
}
