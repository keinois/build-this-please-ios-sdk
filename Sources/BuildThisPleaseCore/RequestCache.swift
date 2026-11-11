import Foundation

/// A successfully loaded list, including a successful empty response.
public struct BuildThisPleaseCachedRequestList: Codable, Sendable, Equatable {
    public let items: [BuildThisPleaseTicket]
    public let updatedAt: Date
    public let isComplete: Bool

    public init(items: [BuildThisPleaseTicket], updatedAt: Date, isComplete: Bool = true) {
        self.items = items
        self.updatedAt = updatedAt
        self.isComplete = isComplete
    }

    private enum CodingKeys: CodingKey { case items, updatedAt, isComplete }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        items = try values.decode([BuildThisPleaseTicket].self, forKey: .items)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        isComplete = try values.decodeIfPresent(Bool.self, forKey: .isComplete) ?? true
    }

    public func isFresh(maxAge: TimeInterval = 60, now: Date = .now) -> Bool {
        let age = now.timeIntervalSince(updatedAt)
        return isComplete && age >= 0 && age < maxAge
    }
}

/// Lists load independently; nil means that list has not been saved.
public struct BuildThisPleaseRequestSnapshot: Codable, Sendable, Equatable {
    public let requests: BuildThisPleaseCachedRequestList?
    public let mine: BuildThisPleaseCachedRequestList?
    public let implemented: BuildThisPleaseCachedRequestList?

    public init(requests: BuildThisPleaseCachedRequestList? = nil, mine: BuildThisPleaseCachedRequestList? = nil, implemented: BuildThisPleaseCachedRequestList? = nil) {
        self.requests = requests
        self.mine = mine
        self.implemented = implemented
    }

    func list(_ section: RequestList) -> BuildThisPleaseCachedRequestList? {
        switch section { case .requests: requests; case .mine: mine; case .implemented: implemented }
    }

    func replacing(_ section: RequestList, with list: BuildThisPleaseCachedRequestList?) -> Self {
        .init(requests: section == .requests ? list : requests, mine: section == .mine ? list : mine, implemented: section == .implemented ? list : implemented)
    }

    func unexpired(now: Date = .now) -> Self? {
        let result = RequestList.allCases.reduce(self) { snapshot, section in
            snapshot.replacing(section, with: snapshot.list(section).flatMap { list in
                let age = now.timeIntervalSince(list.updatedAt)
                return age >= 0 && age < 7 * 24 * 60 * 60 ? list : nil
            })
        }
        return result.requests == nil && result.mine == nil && result.implemented == nil ? nil : result
    }
}

enum RequestList: CaseIterable, Sendable {
    case requests, mine, implemented
    var path: String {
        switch self {
        case .requests: "/v1/tickets?limit=100"
        case .mine: "/v1/me/tickets?limit=100"
        case .implemented: "/v1/implemented?limit=100"
        }
    }
}

/// File operations and encoding run on this actor, away from the UI actor.
/// One shared instance orders atomic writes and deletion across retained clients.
actor RequestCacheDiskStore {
    static let shared = RequestCacheDiskStore()
    static let maximumBytes = 8 * 1024 * 1024
    private let directory: URL
    private struct Envelope: Codable { let version: Int; let snapshot: BuildThisPleaseRequestSnapshot }

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("io.buildthisplease.requests", isDirectory: true)
    }

    func read(key: String) -> BuildThisPleaseRequestSnapshot? {
        let url = file(key)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= Self.maximumBytes,
              let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.version == 1,
              let snapshot = envelope.snapshot.unexpired() else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return snapshot
    }

    func write(_ snapshot: BuildThisPleaseRequestSnapshot, key: String) {
        guard let data = try? JSONEncoder().encode(Envelope(version: 1, snapshot: snapshot)), data.count <= Self.maximumBytes else {
            remove(key: key)
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file(key), options: .atomic)
            trim(keeping: file(key))
        } catch { /* A cache failure must never fail an authenticated operation. */ }
    }

    func remove(key: String) { try? FileManager.default.removeItem(at: file(key)) }

    func removeScope(prefix: String) {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.lastPathComponent.hasPrefix(prefix + "-") && url.pathExtension == "json" {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func file(_ key: String) -> URL { directory.appendingPathComponent(key + ".json") }

    private func trim(keeping current: URL) {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        let entries = urls.compactMap { url -> (URL, Int, Date)? in
            guard url.pathExtension == "json", let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var total = entries.reduce(0) { $0 + $1.1 }
        for (url, size, modified) in entries where url != current {
            if total > Self.maximumBytes || Date.now.timeIntervalSince(modified) > 7 * 24 * 60 * 60 {
                try? FileManager.default.removeItem(at: url)
                total -= size
            }
        }
    }
}
