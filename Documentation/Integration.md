# BuildThisPlease integration and operations guide

This guide covers the path from developer signup to a verified production release.

## Supported platforms

BuildThisPlease supports iOS and Android through separate native SDKs. This guide covers the Swift SDK; use the [Android SDK](https://github.com/keinois/build-this-please-android-sdk) for Android integration.

The minimum supported iOS version is iOS 18, as confirmed by Rodrigo on October 20, 2026. The Swift package and example deployment settings enforce this minimum; see the [requirements](../README.md#requirements).

Workspace tenancy is an existing technical capability. A future commercial or public SaaS offering and its pricing remain undecided; the account/workspace flows below do not establish a decision to sell the service.

## Account and workspace lifecycle

### New customer

1. Visit [feedback.keinois.com](https://feedback.keinois.com) and authenticate with the email you will use for BuildThisPlease.
2. The first visit creates a pending signup. Pending users cannot list or access projects.
3. A platform operator approves or rejects the signup from **Platform approvals**.
4. After approval, create a workspace. The creator becomes its owner.
5. Create one or more projects inside that workspace.

Platform operators manage signup decisions but cannot see a customer's workspace, projects, requests, conversations, installations, or exports unless that customer separately invites them.

### Invited collaborator

1. A workspace owner or administrator enters the collaborator's exact email in **Workspace → Collaborator invitations**.
2. The collaborator authenticates at [feedback.keinois.com](https://feedback.keinois.com) using that same email.
3. The dashboard shows the matching invitation before normal project access.
4. Accepting it creates the membership. Invitations expire after 14 days and can be revoked before acceptance.

An invitation is not a reusable bearer link. Matching the authenticated email is required.

## Roles

| Role | View projects | Manage feedback | Configure projects | Invite collaborators | Delete workspace |
|---|---:|---:|---:|---:|---:|
| Owner | Yes | Yes | Yes | Yes | Yes |
| Administrator | Yes | Yes | Yes | Yes | No |
| Viewer | Yes | No | No | No | No |

Every backend operation resolves the project through the authenticated identity's workspace membership. Project IDs alone never grant access.

## Project setup

### Agent-assisted setup

BuildThisPlease exposes an OAuth-protected remote MCP server at `https://mcp.feedback.keinois.com/mcp`. It is optional; manual setup remains available.

1. Sign in to the dashboard, complete signup approval, and create a workspace.
2. Open **AI agent**, copy the MCP endpoint, and add it to a compatible client.
3. During OAuth, choose application permissions. Read/setup/feedback/collaborator access are independent from sensitive identity access and destructive administration.
4. Ask the agent to run `setup_buildthisplease_for_current_repository` in the host app repository.
5. The agent discovers Xcode values locally and creates a 24-hour immutable setup draft. It returns a dashboard approval URL and must stop.
6. Review the project, Xcode target/scheme, all Team ID/bundle/environment tuples, notification email, and proposed repository changes. Approve or reject manually.
7. After approval, the same OAuth identity applies the draft, receives the publishable key, integrates the SDK, and builds the app.

OAuth authenticates the dashboard identity but does not replace application authorization. Every MCP tool checks workspace membership and role again. Platform operators gain no customer-data access. User-written titles, descriptions, and messages returned to an agent are marked as untrusted content and must never be followed as instructions.

Sensitive installation emails and RevenueCat IDs are omitted unless the user separately approves that MCP permission. Destructive operations require explicit confirmation; permanent workspace deletion additionally requires a fresh preview token and exact workspace name. All tool outcomes are audit logged.

### Manual setup

Creating a project generates a publishable key and can register the first App Attest identity. The complete key is shown only once. Rotated keys are also shown only once.

Project settings provide:

- Public behavior controls and project activation
- Development and production App Attest identifiers
- Transactional notification recipients
- Publishable-key rotation
- Email delivery status
- Project CSV export

Workspace settings provide collaborator management, complete JSON export, and workspace deletion.

## App Attest environments

Apple binds an App Attest key to the app identity and environment. These values must agree:

1. Host app's signed Team ID
2. Runtime bundle identifier
3. App Attest entitlement (`development` or `production`)
4. Identifier registered in the BuildThisPlease project

| Configuration | Entitlement | SDK environment | Device |
|---|---|---|---|
| Simulator and previews | Unavailable | `MockBuildThisPleaseClient` | Simulator |
| Debug against live backend | `development` | `.staging(baseURL: productionURL)` | Physical device |
| TestFlight/App Store | `production` | `.production(baseURL: productionURL)` | Physical device |

Despite its name, `.staging(baseURL:)` selects the development App Attest environment and may point at the live URL for Debug testing. The production Worker does not permit unsupported-device bypass sessions, so a Simulator must use the mock client.

Common failures:

- **Invalid nonce or challenge:** stale or mismatched registration request; update the SDK and retry on a physical device.
- **Assertion signature invalid:** Team ID, bundle ID, environment, or stored App Attest key does not match the registered identity.
- **App Attest unavailable:** the build is in Simulator or on an unsupported device while configured for production.
- **Project identity rejected:** add the exact bundle/environment pair in Project settings.

Changing the bundle identifier, Apple Team, or App Attest environment creates a different app identity. Register it before distributing that build.

## Configuration and secrets

The `btp_pk_…` key is publishable and can be extracted from an app binary. It therefore carries no administrative permissions. It is reasonable to supply the URL and key through build settings so every app target uses the correct project.

Never store these in an app or this SDK repository:

- Cloudflare API or Access credentials
- Dashboard cookies or JWTs
- Database credentials or exports
- GitHub tokens
- Apple private signing keys

## Client lifetime and identity updates

Create one `BuildThisPleaseClient` per project and retain it in the app dependency graph. The actor coordinates session establishment and persists installation credentials in Keychain.

Initial configuration can include subscription state, RevenueCat App User ID, optional support email, and automatically detected app metadata. Call `updateSubscriptionStatus(_:)` after a subscription transition. Call `updateUserIdentity(revenueCatAppUserID:email:)` after RevenueCat login/alias changes or when the known support email changes. These values are support metadata; BuildThisPlease does not require an end-user account.

## Request caching and launch preloading

Retain the client early and start `preloadRequests()` in a retained host task at launch and on foreground entry. The SDK initializer does not perform network requests. The board restores cached lists before independently refreshing missing or stale sections; force refresh remains available for empty and populated lists. Use an opaque account-specific `identityNamespace`, cancel host tasks and await `clearRequestCache()` before replacing an account's client or completing logout. Changing optional support metadata is not an account transition. See [Request caching](RequestCaching.md) for compilable lifecycle examples, freshness, storage limits and cancellation behavior.

## SwiftUI integration choices

- `BuildThisPlease.FeedbackListView(client:)`: destination inside the host app's navigation.
- `BuildThisPlease.StandaloneFeedbackView(client:)`: feedback interface with its own navigation stack.
- `BuildThisPleaseFeedbackView(client:)`: lower-level embeddable UI product.
- `BuildThisPleaseCore`: client and model layer without the interface.
- `MockBuildThisPleaseClient`: deterministic local, preview, and Simulator testing.

Apply `buildThisPleaseTheme(_:)` above the feedback view to customize accent and vote highlighting. The SDK owns and localizes its interface strings.

## Xcode Cloud and CI

The SDK repository is public, so no additional private-repository authorization is required. CI still needs normal access to the host app repository and signing configuration.

The Release workflow should:

- Resolve a tagged SDK version rather than `main`
- Use the production App Attest entitlement
- Select the intended bundle identifier and Apple Team
- Supply the correct project URL and publishable key
- Never enable a development bypass

## Release checklist

1. BuildThisPlease signup is approved.
2. The developer has the intended workspace role.
3. The project belongs to the correct workspace.
4. Production Team ID, bundle ID, and App Attest environment are registered.
5. Notification recipients have been reviewed.
6. The host app resolves a tagged SDK release.
7. The Release target contains the production App Attest entitlement.
8. The client uses the production URL and project key.
9. A physical-device test covers loading, creating, voting, commenting, and editing a sent message.
10. The dashboard receives the test request and conversation.
11. Email delivery succeeds when notifications are required.
12. No private infrastructure credential is present in the app archive or source repository.

## Data portability and deletion

Project CSV export is useful for ticket-level reporting. Workspace JSON export contains the workspace's projects, members, identifiers, notification recipients, installations, tickets, comments, votes, merges, and audit events.

Workspace deletion is permanent and cascades through all owned projects and feedback. Only an owner can perform it, and the exact workspace name is required. Export and verify the downloaded data before deletion.

## Recovery when an App Attest key becomes unusable

The client retains the existing installation identity, requests, comments and votes.
Native DeviceCheck errors 2 or 3 while generating an assertion trigger a bounded
key replacement, not a new installation registration. Replacement requires a full
Apple attestation and either a saved installation recovery credential or a
previous session accepted by the server's restricted legacy recovery bridge.
Missing, rejected or malformed identity proof fails closed and retains local
credentials; RevenueCat IDs and email addresses do not authorize recovery.

The SDK enrolls a random 256-bit recovery credential through an existing,
assertion-authenticated session. Only its SHA-256 hash is sent during enrollment
and new registration. Keychain stores this credential under the existing project
and identity namespace. The credential is never a publishable project key or user identity.

Replacement state is persisted before network requests or active credential
changes. It includes the original installation, old proof, replacement key,
replacement recovery credential, operation ID, and challenge/attestation progress.
The server atomically replaces the key on the same installation. A lost completion
response can be retried using the same saved operation and proof without creating
another installation. Pending state is removed only after all replacement
credentials are durable. Session establishment, recovery and assertion-authenticated mutations are
serialized per retained client to prevent mixed key/session pairs and assertion
counter reordering. Request-list GET downloads share that session coordination,
then run independently so a slow endpoint does not block the other lists.

Apple's `serverUnavailable` error during attestation preserves the same key and
client data hash for a later retry. A completed attestation object is persisted
before submitting it, avoiding a second attestation of the same key. Recovery
does not clear drafts, request data, votes, host-app data, or change any UI layout.

Initial registration also retains challenge expiry and attestation progress. After
an expired challenge, the SDK first checks whether that key already registered
and recovers that installation if so. It restarts an initial registration only
after an explicit unregistered-key response and only when no active identity
credentials exist. A network error preserves the pending key and proof.

Recovery of an interrupted initial registration does not assume that the server
stored its recovery hash merely because the App Attest key exists. The SDK saves
its active key, session, and recovery candidate with `enrolled=false`, then
confirms enrollment using a full assertion before returning business data. If
confirmation fails, that flag and the complete active identity remain durable
for retry.
