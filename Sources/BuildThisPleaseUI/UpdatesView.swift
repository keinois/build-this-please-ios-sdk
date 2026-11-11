import BuildThisPleaseCore
import Foundation
import Observation
import SwiftUI

/// Embed in a NavigationStack, or present in a sheet containing one.
public struct BuildThisPleaseUpdatesView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var model: UpdatesModel

    public init(client: any BuildThisPleaseClientProtocol) {
        _model = State(initialValue: UpdatesModel(client: client))
    }

    public var body: some View {
        List {
            Section {
                if model.loading && model.updates.isEmpty { ProgressView() }
                else if model.updates.isEmpty {
                    ContentUnavailableView(String(localized: "No updates yet", bundle: .module), systemImage: "bell", description: Text(String(localized: "Completed requests you follow will appear here.", bundle: .module)))
                }
                ForEach(model.updates) { update in
                    Button { Task { await model.open(update) } } label: {
                        HStack(alignment: .top) {
                            Image(systemName: update.readAt == nil ? "circle.fill" : "checkmark.circle")
                                .foregroundStyle(update.readAt == nil ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(update.title).font(.headline)
                                if let version = update.appVersion { Text("Available in version \(version)", bundle: .module).font(.subheadline) }
                                if let note = update.implementationNote { Text(note).font(.body) }
                                Text(update.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    .accessibilityLabel(Text(update.title))
                    .accessibilityValue(update.readAt == nil ? String(localized: "Unread", bundle: .module) : String(localized: "Read", bundle: .module))
                }
                if let cursor = model.cursor { Button(String(localized: "Load more", bundle: .module)) { Task { await model.load(cursor: cursor) } }.disabled(model.loading) }
            } header: { Text(String(localized: "Completed requests", bundle: .module)) }
            Section {
                TextField(String(localized: "Email address", bundle: .module), text: $model.email)
                    .autocorrectionDisabled()
                Button(model.preferences.emailEnabled ? String(localized: "Update email address", bundle: .module) : String(localized: "Email me when requests ship", bundle: .module)) { Task { await model.saveEmail(enabled: true) } }
                    .disabled(model.loading || !RequestEmailValidator.isValid(model.email) || model.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if model.preferences.verificationPending { Text(String(localized: "Check your email to confirm updates. The link expires in 24 hours.", bundle: .module)).font(.footnote) }
                if model.preferences.emailEnabled || model.preferences.verificationPending {
                    Button(String(localized: "Stop completion emails", bundle: .module), role: .destructive) { Task { await model.saveEmail(enabled: false) } }.disabled(model.loading)
                }
                Toggle(String(localized: "Local notifications", bundle: .module), isOn: Binding(get: { model.preferences.localNotificationsEnabled }, set: { enabled in Task { await model.saveLocal(enabled) } }))
                    .disabled(model.loading)
            } header: { Text(String(localized: "Notification preferences", bundle: .module)) }
              footer: { Text(String(localized: "Local alerts arrive after a background sync. The app controls background refresh. You can follow requests without sharing an email.", bundle: .module)) }
            if let notice = model.notice { Section { Text(notice).accessibilityAddTraits(.updatesFrequently) } }
            if let error = model.error { Section { Text(error).foregroundStyle(.red); Button(String(localized: "Try again", bundle: .module)) { Task { await model.load() } } } }
        }
        .navigationTitle(String(localized: "Updates", bundle: .module))
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(String(localized: "Done", bundle: .module)) { dismiss() } } }
        .task(id: phase) { if phase == .active { await model.load() } }
        .refreshable { await model.load() }
        .navigationDestination(item: $model.selectedTicket) { ticket in TicketDetailView(client: model.client, ticket: ticket, onTicketUpdated: { _ in }) }
    }

}

@Observable
@MainActor
final class UpdatesModel {
    let client: any BuildThisPleaseClientProtocol
    var updates: [BuildThisPleaseNotification] = []
    var preferences = BuildThisPleaseNotificationPreferences()
    var email = ""
    var cursor: String?
    var error: String?
    var notice: String?
    var selectedTicket: BuildThisPleaseTicket?
    private var isLoading = false
    private var isSavingPreferences = false
    private var loadGeneration = 0
    private var preferencesRevision = 0
    private var readDates: [String: Date] = [:]

    var loading: Bool { isLoading || isSavingPreferences }

    init(client: any BuildThisPleaseClientProtocol) { self.client = client }

    func load(cursor: String? = nil) async {
        guard !Task.isCancelled else { return }
        // Pagination belongs to the currently displayed first page. A full
        // refresh can replace an older load, including a cancelled scene task.
        if let cursor { guard !loading, self.cursor == cursor else { return } }
        loadGeneration += 1
        let generation = loadGeneration
        let revision = preferencesRevision
        isLoading = true
        defer { if loadGeneration == generation { isLoading = false } }
        do {
            async let page = client.notifications(cursor: cursor)
            async let settings = client.notificationPreferences()
            let (loaded, prefs) = try await (page, settings)
            guard !Task.isCancelled, loadGeneration == generation else { return }
            let items = loaded.items.map { item in
                var item = item
                if item.readAt == nil { item.readAt = readDates[item.id] }
                return item
            }
            if cursor == nil { updates = items }
            else { updates += items.filter { item in !updates.contains { $0.id == item.id } } }
            self.cursor = loaded.nextCursor
            // A fetch begun before or during a save must not undo that save.
            if preferencesRevision == revision, !isSavingPreferences {
                preferences = prefs
                email = prefs.email ?? ""
                error = nil
            }
        } catch is CancellationError { }
        catch {
            if !Task.isCancelled, loadGeneration == generation, preferencesRevision == revision, !isSavingPreferences {
                self.error = error.localizedDescription
            }
        }
    }

    func open(_ update: BuildThisPleaseNotification) async {
        do {
            let ticket = try await client.ticket(id: update.ticketId)
            try Task.checkCancellation()
            try await client.markNotificationsRead(ids: [update.id])
            try Task.checkCancellation()
            let readAt = Date.now
            readDates[update.id] = readAt
            if let index = updates.firstIndex(where: { $0.id == update.id }) { updates[index].readAt = readAt }
            selectedTicket = ticket
        } catch is CancellationError { }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    func saveEmail(enabled: Bool) async {
        guard !loading, !Task.isCancelled else { return }
        isSavingPreferences = true
        preferencesRevision += 1
        defer { isSavingPreferences = false; preferencesRevision += 1 }
        notice = nil
        do {
            let saved = try await client.updateNotificationPreferences(email: enabled ? email.trimmingCharacters(in: .whitespacesAndNewlines) : nil, emailEnabled: enabled, localNotificationsEnabled: nil)
            try Task.checkCancellation()
            preferences = saved
            error = nil
            notice = preferences.verificationPending ? String(localized: "Verification email requested.", bundle: .module) : String(localized: "Preferences saved.", bundle: .module)
        } catch is CancellationError { }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    func saveLocal(_ enabled: Bool) async {
        guard !loading, !Task.isCancelled else { return }
        isSavingPreferences = true
        preferencesRevision += 1
        defer { isSavingPreferences = false; preferencesRevision += 1 }
        do {
            if enabled {
                let allowed = try await BuildThisPleaseNotificationSync.requestAuthorization()
                try Task.checkCancellation()
                guard allowed else { error = String(localized: "Allow notifications in system Settings to enable local alerts.", bundle: .module); return }
            }
            let saved = try await client.updateNotificationPreferences(email: nil, emailEnabled: nil, localNotificationsEnabled: enabled)
            try Task.checkCancellation()
            preferences = saved
            error = nil
        } catch is CancellationError { }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}
