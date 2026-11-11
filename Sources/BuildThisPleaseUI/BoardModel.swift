import BuildThisPleaseCore
import Foundation
import Observation

@Observable
@MainActor
final class BoardModel {
    enum Section: String, CaseIterable, Identifiable { case requests, mine, implemented; var id: String { rawValue } }
    let client: any BuildThisPleaseClientProtocol
    var selectedSection: Section = .requests
    var requests: [BuildThisPleaseTicket] = []
    var mine: [BuildThisPleaseTicket] = []
    var implemented: [BuildThisPleaseTicket] = []
    var isLoading = false
    private(set) var loadedSections: Set<Section> = []
    var errorMessage: String?
    var votingTicketIDs: Set<String> = []
    var selectedTicket: BuildThisPleaseTicket?
    var presentsCreate = false
    var presentsUpdates = false
    var unreadCount = 0
    private var lastActiveRefresh: Date?
    private var unreadRefreshGeneration = 0
    private var loadGeneration = 0
    private var mutationRevision = 0
    private var refreshingSections: Set<Section> = []
    private var listRequestRevisions: [Section: Int] = [:]
    private var listPublications: [Section: Int] = [:]
    private var ticketChanges: [String: (revision: Int, ticket: BuildThisPleaseTicket, replacedIDs: Set<String>, preservesMine: Bool)] = [:]
    func refreshUnread() async {
        guard !Task.isCancelled else { return }
        unreadRefreshGeneration += 1
        await fetchUnread(generation: unreadRefreshGeneration)
    }
    func becameActive() async {
        guard !Task.isCancelled, lastActiveRefresh.map({ Date.now.timeIntervalSince($0) >= 30 }) ?? true else { return }
        unreadRefreshGeneration += 1
        let generation = unreadRefreshGeneration
        await load()
        guard !Task.isCancelled, unreadRefreshGeneration == generation else { return }
        await fetchUnread(generation: generation, recordsActivation: true)
    }

    private func fetchUnread(generation: Int, recordsActivation: Bool = false) async {
        do {
            let count = try await client.notifications(cursor: nil).unreadCount
            guard !Task.isCancelled, unreadRefreshGeneration == generation else { return }
            unreadCount = count
            if recordsActivation { lastActiveRefresh = .now }
        } catch is CancellationError { }
        catch {
            if !Task.isCancelled, unreadRefreshGeneration == generation { errorMessage = error.localizedDescription }
        }
    }

    init(client: any BuildThisPleaseClientProtocol) { self.client = client }

    var currentTickets: [BuildThisPleaseTicket] {
        switch selectedSection { case .requests: requests; case .mine: mine; case .implemented: implemented }
    }

    var showsMineSection: Bool { !mine.isEmpty }
    var hasLoadedCurrentSection: Bool { loadedSections.contains(selectedSection) }

    func load() async {
        guard !Task.isCancelled else { return }
        // A cancelled scene task can still be awaiting a shared SDK download.
        // Let the current scene take ownership instead of dropping its refresh.
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer { if loadGeneration == generation { isLoading = false } }
        let revision = mutationRevision
        let restorationPublications = listPublications
        errorMessage = nil
        let saved = await client.cachedRequests()
        guard !Task.isCancelled, loadGeneration == generation else { return }
        // Restoration must not replace a successfully published manual refresh.
        // A failed or pending refresh can still use saved content while offline.
        let restorableSections = Section.allCases.filter {
            listPublications[$0, default: 0] == restorationPublications[$0, default: 0]
        }
        for section in restorableSections {
            let list: BuildThisPleaseCachedRequestList? = switch section {
            case .requests: saved?.requests
            case .mine: saved?.mine
            case .implemented: saved?.implemented
            }
            if let list { apply(list.items, section: section, startedAt: revision) }
        }
        await withTaskGroup(of: (Section, Int, Result<[BuildThisPleaseTicket], any Error>).self) { group in
            for section in restorableSections where !refreshingSections.contains(section) {
                let list: BuildThisPleaseCachedRequestList? = switch section {
                case .requests: saved?.requests
                case .mine: saved?.mine
                case .implemented: saved?.implemented
                }
                guard list?.isFresh() != true else { continue }
                let listRevision = advanceListRequestRevision(section)
                group.addTask { [client] in
                    do {
                        let tickets: [BuildThisPleaseTicket] = switch section {
                        case .requests: try await client.requests()
                        case .mine: try await client.myRequests()
                        case .implemented: try await client.implementedRequests()
                        }
                        return (section, listRevision, .success(tickets))
                    } catch { return (section, listRevision, .failure(error)) }
                }
            }
            for await (section, listRevision, result) in group {
                guard !Task.isCancelled, loadGeneration == generation, listRequestRevisions[section] == listRevision else { continue }
                switch result {
                case .success(let tickets): apply(tickets, section: section, startedAt: revision)
                case .failure(let error) where !(error is CancellationError): errorMessage = error.localizedDescription
                case .failure: break
                }
            }
        }
    }

    func refreshCurrentSection() async {
        let section = selectedSection
        guard refreshingSections.insert(section).inserted else { return }
        defer { refreshingSections.remove(section) }
        let listRevision = advanceListRequestRevision(section)
        let revision = mutationRevision
        do {
            let tickets: [BuildThisPleaseTicket] = switch section {
            case .requests: try await client.requests()
            case .mine: try await client.myRequests()
            case .implemented: try await client.implementedRequests()
            }
            guard !Task.isCancelled, listRequestRevisions[section] == listRevision else { return }
            apply(tickets, section: section, startedAt: revision)
            errorMessage = nil
        } catch is CancellationError { }
        catch { if listRequestRevisions[section] == listRevision { errorMessage = error.localizedDescription } }
    }

    @discardableResult
    private func advanceListRequestRevision(_ section: Section) -> Int {
        let revision = listRequestRevisions[section, default: 0] + 1
        listRequestRevisions[section] = revision
        return revision
    }

    private func apply(_ tickets: [BuildThisPleaseTicket], section: Section, startedAt revision: Int) {
        listPublications[section, default: 0] += 1
        loadedSections.insert(section)
        let changes = ticketChanges.values.filter { $0.revision > revision }.sorted { $0.revision < $1.revision }
        let items = changes.reduce(tickets) { items, change in
            merging(change.ticket, replacing: change.replacedIDs, into: items, section: section, preservesMine: change.preservesMine)
        }
        switch section {
        case .requests: requests = items.sortedByRequestPriority()
        case .mine: setMine(items)
        case .implemented: implemented = items.sortedByImplementationRecency()
        }
    }

    func created(_ ticket: BuildThisPleaseTicket) {
        loadedSections.insert(.mine)
        mutationRevision += 1
        ticketChanges[ticket.id] = (mutationRevision, ticket, [ticket.id], true)
        mine.removeAll { $0.id == ticket.id }
        mine.insert(ticket, at: 0)
        selectedSection = .mine
    }

    func toggleVote(_ ticket: BuildThisPleaseTicket) async {
        guard ticket.voteCount != nil, ticket.voteLocked != true, votingTicketIDs.insert(ticket.id).inserted else { return }
        defer { votingTicketIDs.remove(ticket.id) }
        do {
            let updated = try await client.setVote(ticketId: ticket.id, voted: !(ticket.hasVoted ?? false))
            replace(updated, replacingID: ticket.id)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func replace(_ ticket: BuildThisPleaseTicket) {
        replace(ticket, replacingID: ticket.id)
    }

    func replace(_ ticket: BuildThisPleaseTicket, replacingID: String) {
        var replacedIDs: Set<String> = [ticket.id, replacingID]
        for change in ticketChanges.values where !change.replacedIDs.isDisjoint(with: replacedIDs) {
            replacedIDs.formUnion(change.replacedIDs)
        }
        let preservesMine = mine.contains { matches($0, ids: replacedIDs) }
        ticketChanges = ticketChanges.filter { $0.value.replacedIDs.isDisjoint(with: replacedIDs) }
        mutationRevision += 1
        ticketChanges[ticket.id] = (mutationRevision, ticket, replacedIDs, preservesMine)
        requests = merging(ticket, replacing: replacedIDs, into: requests, section: .requests, preservesMine: preservesMine).sortedByRequestPriority()
        setMine(merging(ticket, replacing: replacedIDs, into: mine, section: .mine, preservesMine: preservesMine))
        implemented = merging(ticket, replacing: replacedIDs, into: implemented, section: .implemented, preservesMine: preservesMine).sortedByImplementationRecency()
    }

    private func matches(_ ticket: BuildThisPleaseTicket, ids: Set<String>) -> Bool {
        ids.contains(ticket.id) || ticket.canonicalTicketId.map(ids.contains) == true
    }

    private func merging(_ ticket: BuildThisPleaseTicket, replacing ids: Set<String>, into tickets: [BuildThisPleaseTicket], section: Section, preservesMine: Bool) -> [BuildThisPleaseTicket] {
        let wasPresent = tickets.contains { matches($0, ids: ids) }
        var items = tickets.filter { !matches($0, ids: ids) }
        let belongs: Bool = switch section {
        case .requests: [.inReview, .planned, .inProgress].contains(ticket.status)
        case .implemented: ticket.status == .implemented
        case .mine: wasPresent || preservesMine
        }
        if belongs { items.insert(ticket, at: 0) }
        return items
    }

    private func setMine(_ tickets: [BuildThisPleaseTicket]) {
        mine = tickets
        if mine.isEmpty && selectedSection == .mine {
            selectedSection = .requests
        }
    }
}

extension Array where Element == BuildThisPleaseTicket {
    func sortedByRequestPriority() -> Self {
        sorted {
            let leftVotes = $0.voteCount ?? 0
            let rightVotes = $1.voteCount ?? 0
            if leftVotes != rightVotes { return leftVotes > rightVotes }

            let leftProgress = $0.status.requestProgressRank
            let rightProgress = $1.status.requestProgressRank
            if leftProgress != rightProgress { return leftProgress > rightProgress }

            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id > $1.id
        }
    }

    func sortedByImplementationRecency() -> Self {
        sorted {
            let leftDate = $0.implementedAt ?? $0.updatedAt
            let rightDate = $1.implementedAt ?? $1.updatedAt
            if leftDate != rightDate { return leftDate > rightDate }
            return $0.id > $1.id
        }
    }
}

private extension BuildThisPleaseTicketStatus {
    var requestProgressRank: Int {
        switch self {
        case .inProgress: 3
        case .planned: 2
        case .inReview: 1
        default: 0
        }
    }
}

@Observable
@MainActor
final class TicketDetailModel {
    let client: any BuildThisPleaseClientProtocol
    var ticket: BuildThisPleaseTicket
    var comments: [BuildThisPleaseComment] = []
    var reply = ""
    var isLoading = false
    var isSending = false
    var isVoting = false
    var isFollowing: Bool?
    var isChangingFollow = false
    var errorMessage: String?
    var editingComment: BuildThisPleaseComment?
    let onTicketUpdated: (BuildThisPleaseTicket) -> Void
    private var replyIdempotencyKey = UUID().uuidString

    init(
        client: any BuildThisPleaseClientProtocol,
        ticket: BuildThisPleaseTicket,
        onTicketUpdated: @escaping (BuildThisPleaseTicket) -> Void
    ) {
        self.client = client
        self.ticket = ticket
        self.onTicketUpdated = onTicketUpdated
    }

    func load() async {
        guard !isLoading, !isVoting, !isChangingFollow else { return }
        isLoading = true; defer { isLoading = false }
        do {
            async let refreshed = client.ticket(id: ticket.id)
            async let messages = client.comments(ticketId: ticket.id)
            (ticket, comments) = try await (refreshed, messages)
            onTicketUpdated(ticket)
            errorMessage = nil
            try await refreshFollowing()
        }
        catch { errorMessage = error.localizedDescription }
    }

    func toggleVote() async {
        guard !isVoting, !isLoading, !isChangingFollow, ticket.voteLocked != true else { return }
        isVoting = true
        defer { isVoting = false }
        do {
            ticket = try await client.setVote(ticketId: ticket.id, voted: !(ticket.hasVoted ?? false))
            onTicketUpdated(ticket)
            errorMessage = nil
            try await refreshFollowing()
        }
        catch { errorMessage = error.localizedDescription }
    }

    private func refreshFollowing() async throws {
        isFollowing = nil
        isFollowing = try await client.following(ticketId: ticket.id)
    }

    func toggleFollowing() async {
        guard !isChangingFollow, !isLoading, !isVoting, let following = isFollowing else { return }
        isChangingFollow = true
        defer { isChangingFollow = false }
        do {
            try await client.setFollowing(ticketId: ticket.id, following: !following)
            isFollowing = !following
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func sendReply() async {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        isSending = true; defer { isSending = false }
        do { let comment = try await client.createComment(ticketId: ticket.id, body: trimmed, idempotencyKey: replyIdempotencyKey); comments.append(comment); reply = ""; replyIdempotencyKey = UUID().uuidString; errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    func updateComment(_ comment: BuildThisPleaseComment, body: String) async -> Bool {
        do {
            let updated = try await client.updateComment(ticketId: ticket.id, commentId: comment.id, body: body)
            comments = comments.map { $0.id == updated.id ? updated : $0 }
            editingComment = nil
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
