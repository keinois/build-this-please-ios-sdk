import Foundation
import Testing
@testable import BuildThisPleaseCore

@Suite("Completion notification contract") struct NotificationTests {
    @Test("An author vote is permanent while request updates can be muted")
    func authorVote() async throws {
        let client = MockBuildThisPleaseClient()
        let ticket = try await client.createTicket(title: "A feature", description: "Please build it.", idempotencyKey: UUID().uuidString)
        #expect(ticket.voteCount == 1)
        #expect(ticket.voteLocked == true)
        await #expect(throws: BuildThisPleaseError.self) { try await client.setVote(ticketId: ticket.id, voted: false) }
        try await client.setFollowing(ticketId: ticket.id, following: false)
        #expect(try await client.following(ticketId: ticket.id) == false)
    }
    @Test("Reading an update persists unread state independently of email preferences")
    func unreadState() async throws {
        let client = MockBuildThisPleaseClient()
        let before = try await client.notifications()
        #expect(before.unreadCount == 1)
        let notice = try #require(before.items.first)
        try await client.markNotificationsRead(ids: [notice.id])
        #expect(try await client.notifications().unreadCount == 0)
        #expect(try await client.notificationPreferences().emailEnabled == false)
    }
    @Test("Completion snapshots decode without vote information")
    func decoding() throws {
        let data = Data(#"{"items":[{"id":"n1","ticketId":"t1","title":"Ready","implementationNote":"Shipped","appVersion":"2.0","createdAt":"2026-10-15T00:00:00.000Z","readAt":null}],"unreadCount":1,"nextCursor":null}"#.utf8)
        let page = try JSONCoding.decoder().decode(BuildThisPleaseNotificationPage.self, from: data)
        #expect(page.unreadCount == 1)
        #expect(page.items.first?.appVersion == "2.0")
        #expect(page.items.first?.readAt == nil)
    }
    @Test("Core-only distributions package their required-reason privacy manifest")
    func corePrivacyManifest() throws {
        let url = try #require(Bundle.module.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        let manifest = try #require(value as? [String: Any])
        let apis = try #require(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let defaults = try #require(apis.first { $0["NSPrivacyAccessedAPIType"] as? String == "NSPrivacyAccessedAPICategoryUserDefaults" })
        #expect((defaults["NSPrivacyAccessedAPITypeReasons"] as? [String])?.contains("CA92.1") == true)
        #expect(manifest["NSPrivacyTracking"] as? Bool == false)
    }

}
