import Foundation

public struct BuildThisPleaseConfiguration: Sendable {
    public enum Environment: Sendable {
        case production(baseURL: URL)
        case staging(baseURL: URL)
        case local(baseURL: URL)

        public var baseURL: URL {
            switch self {
            case .production(let value), .staging(let value), .local(let value): value
            }
        }

        var attestationEnvironment: String {
            switch self {
            case .production: "production"
            case .staging, .local: "development"
            }
        }

        var permitsDevelopmentBypass: Bool {
            if case .production = self { false } else { true }
        }
    }

    public let projectKey: String
    public let environment: Environment
    public var subscriptionStatus: BuildThisPleaseSubscriptionStatus
    public var revenueCatAppUserID: String?
    public var userEmail: String?
    public let identityNamespace: String?
    public let bundleIdentifier: String
    public let appVersion: String?
    public let osVersion: String

    public init(
        projectKey: String,
        environment: Environment,
        subscriptionStatus: BuildThisPleaseSubscriptionStatus = .unknown,
        revenueCatAppUserID: String? = nil,
        userEmail: String? = nil,
        identityNamespace: String? = nil,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        appVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString
    ) throws {
        guard !projectKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BuildThisPleaseError.invalidConfiguration(
                String(localized: "A project key is required.", bundle: .module)
            )
        }
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            throw BuildThisPleaseError.invalidConfiguration(
                String(localized: "A bundle identifier is required.", bundle: .module)
            )
        }
        self.projectKey = projectKey
        self.environment = environment
        self.subscriptionStatus = subscriptionStatus
        self.revenueCatAppUserID = Self.normalizedOptional(revenueCatAppUserID)
        self.identityNamespace = Self.normalizedOptional(identityNamespace)
        self.userEmail = Self.normalizedOptional(userEmail)?.lowercased()
        self.bundleIdentifier = bundleIdentifier
        self.appVersion = appVersion
        self.osVersion = osVersion
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
