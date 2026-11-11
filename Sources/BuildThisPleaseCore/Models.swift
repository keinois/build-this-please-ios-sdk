import Foundation

public enum BuildThisPleaseSubscriptionStatus: String, Codable, CaseIterable, Sendable {
    case unknown, free, trial, pro, expired
}

public enum BuildThisPleaseTicketStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case inReview = "in_review"
    case planned
    case inProgress = "in_progress"
    case implemented
    case rejected
    case merged
    case archived

    public var displayName: String {
        switch self {
        case .pending: String(localized: "Pending", bundle: .module)
        case .inReview: String(localized: "In Review", bundle: .module)
        case .planned: String(localized: "Planned", bundle: .module)
        case .inProgress: String(localized: "In Progress", bundle: .module)
        case .implemented: String(localized: "Implemented", bundle: .module)
        case .rejected: String(localized: "Rejected", bundle: .module)
        case .merged: String(localized: "Merged", bundle: .module)
        case .archived: String(localized: "Archived", bundle: .module)
        }
    }
}

public struct BuildThisPleaseTicket: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let description: String
    public let status: BuildThisPleaseTicketStatus
    public let commentsLocked: Bool
    public let createdAt: Date
    public let updatedAt: Date
    public let implementedAt: Date?
    public let implementedAppVersion: String?
    public let implementationNote: String?
    public let canonicalTicketId: String?
    public let voteCount: Int?
    public let hasVoted: Bool?
    public let voteLocked: Bool?

    public init(
        id: String,
        title: String,
        description: String,
        status: BuildThisPleaseTicketStatus,
        commentsLocked: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        implementedAt: Date? = nil,
        implementedAppVersion: String? = nil,
        implementationNote: String? = nil,
        canonicalTicketId: String? = nil,
        voteCount: Int? = nil,
        hasVoted: Bool? = nil,
        voteLocked: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.status = status
        self.commentsLocked = commentsLocked
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.implementedAt = implementedAt
        self.implementedAppVersion = implementedAppVersion
        self.implementationNote = implementationNote
        self.canonicalTicketId = canonicalTicketId
        self.voteCount = voteCount
        self.hasVoted = hasVoted
        self.voteLocked = voteLocked
    }
}

public struct BuildThisPleaseComment: Codable, Identifiable, Hashable, Sendable {
    public enum Author: String, Codable, Sendable { case user, administrator }
    public let id: String
    public let ticketId: String
    public let author: Author
    public let body: String?
    public let isEdited: Bool
    public let isHidden: Bool
    public let isApproved: Bool
    public let isMine: Bool
    public let createdAt: Date
    public let updatedAt: Date

    public init(id: String, ticketId: String, author: Author, body: String?, isEdited: Bool, isHidden: Bool, isApproved: Bool = true, isMine: Bool = false, createdAt: Date, updatedAt: Date) {
        self.id = id; self.ticketId = ticketId; self.author = author; self.body = body
        self.isEdited = isEdited; self.isHidden = isHidden; self.isApproved = isApproved; self.isMine = isMine
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, ticketId, author, body, isEdited, isHidden, isApproved, isMine, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        ticketId = try values.decode(String.self, forKey: .ticketId)
        author = try values.decode(Author.self, forKey: .author)
        body = try values.decodeIfPresent(String.self, forKey: .body)
        isEdited = try values.decode(Bool.self, forKey: .isEdited)
        isHidden = try values.decode(Bool.self, forKey: .isHidden)
        isApproved = try values.decodeIfPresent(Bool.self, forKey: .isApproved) ?? true
        isMine = try values.decodeIfPresent(Bool.self, forKey: .isMine) ?? false
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
    }
}

public struct BuildThisPleasePage<Item: Codable & Sendable>: Codable, Sendable {
    public let items: [Item]
    public let nextCursor: String?
}

public struct BuildThisPleaseProject: Codable, Sendable {
    public let id: String
    public let name: String
    public let slug: String
    public let accentColor: String
    public init(id: String, name: String, slug: String, accentColor: String) {
        self.id = id; self.name = name; self.slug = slug; self.accentColor = accentColor
    }
}

public struct BuildThisPleaseConfigurationResponse: Codable, Sendable {
    public struct Capabilities: Codable, Sendable {
        public let allowInProgressVoting: Bool
        public let implementedCommentsLocked: Bool
        public init(allowInProgressVoting: Bool, implementedCommentsLocked: Bool) {
            self.allowInProgressVoting = allowInProgressVoting; self.implementedCommentsLocked = implementedCommentsLocked
        }
    }
    public let project: BuildThisPleaseProject
    public let capabilities: Capabilities
    public init(project: BuildThisPleaseProject, capabilities: Capabilities) {
        self.project = project; self.capabilities = capabilities
    }
}

public enum BuildThisPleaseError: LocalizedError, Sendable, Equatable {
    case invalidConfiguration(String)
    case server(code: String, message: String, status: Int)
    case invalidResponse
    case appAttestUnavailable
    case attestationFailed
    case sessionExpired
    case offline

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message): message
        case .server(_, let message, _): message
        case .invalidResponse:
            String(localized: "The app received an invalid response.", bundle: .module)
        case .appAttestUnavailable:
            String(localized: "This device cannot establish a secure feedback session.", bundle: .module)
        case .attestationFailed:
            String(localized: "The app could not verify this installation. Please try again.", bundle: .module)
        case .sessionExpired:
            String(localized: "The feedback session expired. Please try again.", bundle: .module)
        case .offline:
            String(localized: "You appear to be offline. Check your connection and try again.", bundle: .module)
        }
    }
}
