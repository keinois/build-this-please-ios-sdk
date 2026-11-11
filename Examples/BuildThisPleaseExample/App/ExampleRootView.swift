import BuildThisPlease
import DeviceCheck
import SwiftUI

private enum ExampleMode: String, CaseIterable, Identifiable {
    case mock, staging, production
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    static var initial: ExampleMode {
        #if DEBUG
        .mock
        #else
        .production
        #endif
    }
}

struct ExampleRootView: View {
    @AppStorage("BuildThisPleaseExample.mode") private var modeRaw = ExampleMode.initial.rawValue
    @State private var scenario: MockBuildThisPleaseScenario = .normal
    @State private var subscription: BuildThisPleaseSubscriptionStatus = .trial
    @State private var resetToken = UUID()
    @State private var showsDeveloperMenu = false
    @State private var forceDarkMode = false
    @State private var retainedClient: (any BuildThisPleaseClientProtocol)?
    @State private var clientRevision = UUID()
    @State private var foregroundTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase
    private let fallbackClient = MockBuildThisPleaseClient()

    private var client: any BuildThisPleaseClientProtocol { retainedClient ?? fallbackClient }
    private var clientIdentity: String { "\(mode.rawValue)-\(scenario.rawValue)-\(subscription.rawValue)-\(resetToken)" }

    private var mode: ExampleMode {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") || previewsFeedbackDirectly { return .mock }
        return ExampleMode(rawValue: modeRaw) ?? .mock
        #else
        return .production
        #endif
    }

    private var previewsFeedbackDirectly: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--feedback-preview")
        #else
        false
        #endif
    }
    private func makeClient() -> any BuildThisPleaseClientProtocol {
        if mode == .mock {
            return MockBuildThisPleaseClient(scenario: scenario, subscriptionStatus: subscription)
        }
        guard let baseURL = configuredURL(for: mode), let key = configuredKey(for: mode) else {
            return MockBuildThisPleaseClient(
                scenario: .serverError,
                subscriptionStatus: subscription
            )
        }
        do {
            let environment: BuildThisPleaseConfiguration.Environment = mode == .production
                ? .production(baseURL: baseURL)
                : .staging(baseURL: baseURL)
            return BuildThisPleaseClient(configuration: try .init(
                projectKey: key,
                environment: environment,
                subscriptionStatus: subscription
            ))
        } catch {
            return MockBuildThisPleaseClient(scenario: .serverError, subscriptionStatus: subscription)
        }
    }

    var body: some View {
        Group {
            if previewsFeedbackDirectly {
                NavigationStack {
                    BuildThisPlease.FeedbackListView(client: client)
                        .buildThisPleaseTheme(.init())
                        .modifier(ExampleSoftScrollEdges())
                }
            } else {
                NavigationStack {
                    menu
                        .modifier(ExampleSoftScrollEdges())
                }
            }
        }
        .id(clientRevision)
        .task(id: clientIdentity) {
            let next = makeClient()
            retainedClient = next
            clientRevision = UUID()
            try? await next.preloadRequests()
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active, let retainedClient {
                foregroundTask?.cancel()
                foregroundTask = Task { try? await retainedClient.preloadRequests() }
            }
        }
        .onDisappear { foregroundTask?.cancel() }
        .preferredColorScheme(forceDarkMode ? .dark : nil)
        #if DEBUG
        .sheet(isPresented: $showsDeveloperMenu) {
            DeveloperMenu(
                modeRaw: $modeRaw,
                scenario: $scenario,
                subscription: $subscription,
                forceDarkMode: $forceDarkMode,
                reset: { resetToken = UUID() }
            )
        }
        #endif
    }

    private var menu: some View {
        VStack(spacing: 0) {
                if mode != .production {
                    HStack(spacing: 8) {
                        Circle().fill(mode == .mock ? .orange : .blue).frame(width: 8, height: 8)
                        Text("\(mode.label.uppercased()) / \(subscription.rawValue.uppercased())")
                            .font(.caption.monospaced().weight(.semibold))
                        Spacer()
                        #if DEBUG
                        Button("Developer controls", systemImage: "slider.horizontal.3") { showsDeveloperMenu = true }
                            .labelStyle(.iconOnly)
                        #endif
                    }
                    .padding(.horizontal).padding(.vertical, 9).background(.bar)
                    .accessibilityElement(children: .combine)
                }
                List {
                    Section("Example app menu") {
                        NavigationLink {
                            BuildThisPlease.FeedbackListView(client: client)
                                .id("\(mode.rawValue)-\(scenario.rawValue)-\(subscription.rawValue)-\(resetToken)")
                                .buildThisPleaseTheme(.init())
                                .modifier(ExampleSoftScrollEdges())
                        } label: {
                            Label("Feature requests", systemImage: "lightbulb")
                        }
                    }
                    Section {
                        Text("This demonstrates embedding BuildThisPlease as a destination inside an existing app menu and NavigationStack.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
        }
        .navigationTitle("Build This Please")
    }

    private func configuredURL(for mode: ExampleMode) -> URL? {
        let key = mode == .production ? "BTPProductionBaseURL" : "BTPStagingBaseURL"
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    private func configuredKey(for mode: ExampleMode) -> String? {
        let key = mode == .production ? "BTPProductionProjectKey" : "BTPStagingProjectKey"
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String, !value.isEmpty else { return nil }
        return value
    }
}

#if DEBUG
private struct DeveloperMenu: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var modeRaw: String
    @Binding var scenario: MockBuildThisPleaseScenario
    @Binding var subscription: BuildThisPleaseSubscriptionStatus
    @Binding var forceDarkMode: Bool
    let reset: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Run mode") {
                    Picker("Environment", selection: $modeRaw) {
                        ForEach(ExampleMode.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    Text("Staging and Production read their URL and project key from build settings. No credential is committed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Subscription") {
                    Picker("Reported state", selection: $subscription) {
                        ForEach(BuildThisPleaseSubscriptionStatus.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                }
                Section("Mock response") {
                    Picker("Scenario", selection: $scenario) {
                        ForEach(MockBuildThisPleaseScenario.allCases, id: \.self) { Text(label($0)).tag($0) }
                    }
                    Button("Reset deterministic data", systemImage: "arrow.counterclockwise") { reset() }
                }
                Section("Appearance") {
                    Toggle("Force dark mode", isOn: $forceDarkMode)
                }
                Section("Runtime") {
                    LabeledContent("Project", value: modeRaw)
                    LabeledContent("App Attest", value: DCAppAttestService.shared.isSupported ? "Supported" : "Unavailable")
                    LabeledContent("Bundle", value: Bundle.main.bundleIdentifier ?? "Unknown")
                    LabeledContent("Installation", value: modeRaw == "mock" ? "Deterministic mock" : "Stored in Keychain after registration")
                }
            }
            .navigationTitle("Example controls")
            .modifier(ExampleSoftScrollEdges())
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func label(_ value: MockBuildThisPleaseScenario) -> String {
        switch value {
        case .normal: "Seeded lifecycle"
        case .empty: "Empty"
        case .loading: "Slow loading"
        case .offline: "Offline"
        case .rateLimited: "Rate limited"
        case .expiredSession: "Expired session"
        case .serverError: "Server error"
        }
    }
}
#endif

#Preview { ExampleRootView() }
