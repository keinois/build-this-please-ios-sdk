# Completion updates — 0.2.0

The embedded board includes an Updates button, read/unread inbox, follow/mute controls and optional email/local preferences. Request submission creates a permanent author vote; `voteLocked` disables its removal. Email remains optional and requires confirmation in the emailed form. Returning to the app refreshes preferences; manual refresh is available.

For a host-owned destination, embed `BuildThisPleaseUpdatesView(client:)` in a `NavigationStack`. Keep the same retained client used by the feedback board.

```swift
let updates = BuildThisPleaseNotificationSync(
    client: feedbackClient,
    namespace: projectKey + ":" + currentAccountNamespace
)
// On app activation, use this value for a host-owned Feedback badge.
let unreadCount = try await updates.synchronize()
// In a host-registered BGAppRefreshTask handler:
try await updates.synchronize(inBackground: true)
```

Retain the synchronizer. The host registers and schedules its BGAppRefreshTask, calls the helper from that handler, respects cancellation/expiration, and reschedules its next refresh. Background execution is optional and OS-controlled; the SDK does not silently add background modes, schedule tasks, request notification permission at startup, or replace the host's notification-center delegate. The Updates preference requests notification authorization only after the user enables local alerts. Without background integration, email and the in-app inbox still work; local alerts cannot discover server completions while the app is closed.

Overlapping calls on the same synchronizer wait their turn, so a foreground badge refresh cannot discard a background alert-delivery request. Each call stays in its host-owned task; cancel queued and active host tasks on expiration or account changes. A cancelled queued call exits without fetching or posting alerts. A previous call's failure does not discard later queued work, and repeated background calls retain persistent alert deduplication.

Handle `buildThisPleaseTicketId` in the existing notification delegate to navigate after a local alert. Email app links use the same query parameter on the project's configured HTTPS app URL. Opening a request from the inbox marks its notification read. Hosts handling a local alert or email can fetch `client.notifications(cursor: nil)` and call `markNotificationsRead(ids:)` for matching entries after navigation succeeds.

## Optional cross-device identity

`revenueCatAppUserID` remains metadata. For signed-in users, configure `identityNamespace` using a stable host account ID so sessions and credentials do not leak across account switches. Obtain `try await feedbackClient.installationIdentifier()`, send it to your authenticated host backend, then call `try await feedbackClient.linkUserIdentity(token: proof)` with the returned signed proof. The backend derives the user ID from its authenticated session; the app must never hold a signing secret.

The optional Worker secret `IDENTITY_SIGNING_KEYS` maps project IDs to per-project HS256 secrets (32+ random characters). Token claims: issuer `buildthisplease-host`, audience the BuildThisPlease project ID, subject the stable RevenueCat/host ID, `installationId`, `iat`, and `exp` no more than 300 seconds after `iat`. Verified email confirmation can also link notification inboxes in a project. Neither linking method transfers request/comment ownership or attestation credentials. Anonymous RevenueCat IDs do not guarantee reinstall recovery.

On account switching dispose the old client UI/synchronizer and create a client with the next account namespace. Give the feedback destination `.id(currentAccountNamespace)` so SwiftUI discards its retained view state, and dismiss any old request navigation. Cancel background refresh work for the previous account. Reuse a stable anonymous namespace for signed-out use. The SDK rejects linking a different verified account into an already linked installation.

Upgrade the backend through migration 0017 and deploy its matching App Attest recovery endpoints before adopting SDK 0.2.0. Migration 0016 adds completion updates; 0017 supports the iOS client's installation-preserving key recovery. Release via a semantic tag `0.2.0`; the package manifest intentionally does not hardcode a tag version. Simulator builds prove compilation, not live App Attest, email delivery or background notification timing.

The Core resource bundle includes its own privacy manifest, including Core-only integrations. App-private notification deduplication uses UserDefaults reason `CA92.1`; request-cache eviction reads modification timestamps within the app container using file-timestamp reason `C617.1` ([Apple’s approved reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)). The manifest describes feedback, optional email and user identifiers for app functionality, without tracking; verified identity linking means feedback can be linked to a user. Reconcile the host app’s privacy disclosures with the features and optional identity fields it enables.
