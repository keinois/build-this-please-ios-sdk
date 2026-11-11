# BuildThisPlease SDK

> This branch prepares SDK 0.2.0 (paused). It has no published release tag or artifact yet; test using the local checkout.


BuildThisPlease is a hosted feature-request board for iOS and Android apps. This public Swift package provides the iOS client, localized SwiftUI interface, App Attest integration, tests, privacy manifest, and a tiny example app. Android integration uses the separate [Android SDK](https://github.com/keinois/build-this-please-android-sdk). The Worker, administrator dashboard, database, production configuration, and customer data remain private.

## What app users can do

- Browse and vote on feature requests.
- Submit requests with an optional support email.
- Follow requests created by their installation.
- Exchange approved messages with the app team.
- Read implemented requests without public vote totals.
- Automatically translate user-written content when supported by iOS.

On iOS 18 and newer, translation starts for loaded requests at the feedback screen level, including offscreen rows and request details. Conversation messages are queued as soon as they load. The SDK batches work by source language and shares completed translations between screens. Translations are cached in the app's caches directory for up to 30 days, with limits of 500 entries and 2 MiB on disk. Cache keys include the exact text and both source and target languages, so edits and language changes require fresh results. The system may remove cached files. First-time translation can still require a language download; users can always choose **Show original**.

No end-user login is required. BuildThisPlease creates an installation identity, stores its credentials in Keychain, and protects production traffic with Apple App Attest.

## Requirements

- Xcode 26 or newer
- Swift 6.2 or newer
- iOS 18 or newer (minimum supported version)
- A physical App Attest-capable device for live integration testing

Rodrigo confirmed iOS 18 as the minimum supported version on October 20, 2026. The [package manifest](Package.swift), [example configuration](Examples/BuildThisPleaseExample/Configuration/Example.xcconfig), and [UI test deployment targets](Examples/BuildThisPleaseExample/BuildThisPleaseExample.xcodeproj/project.pbxproj) enforce this minimum.

## 1. Create the hosted project

### Agent-assisted setup

After signup approval and workspace creation, open **AI agent** in the dashboard and copy the remote MCP endpoint:

```text
https://mcp.feedback.keinois.com/mcp
```

Connect it in a compatible coding agent, approve only the permissions you want it to have, then ask it to run `setup_buildthisplease_for_current_repository`. The agent will inspect the local Xcode project for the app name, target, scheme, Team ID, bundle identifiers, and App Attest environments. It then creates an immutable setup proposal and stops.

Open the returned dashboard approval URL, review every value and proposed local edit, and approve or reject it yourself. Only after approval can the same agent connection create the hosted project and receive its project-scoped publishable key. The agent never needs Cloudflare credentials, dashboard cookies, backend source, signing keys, or provisioning profiles.

### Manual setup

1. Open [feedback.keinois.com](https://feedback.keinois.com).
2. Authenticate through Cloudflare Access.
3. On a new account, wait for the platform operator to approve the signup. An invitation to an existing workspace can also grant access.
4. Create a workspace. A workspace owns projects, collaborators, and exported data.
5. Create a project and enter its name, slug, Apple Team ID, bundle identifier, App Attest environment, and optional notification email.
6. Copy the generated `btp_pk_…` publishable key. It is shown in full only once.

For Debug and App Store builds of the same bundle, register two App identifiers in **Project settings**:

| Build | Team ID | Bundle ID | App Attest environment |
|---|---|---|---|
| Debug on a physical device | Your Apple Team ID | Exact Debug bundle ID | `development` |
| TestFlight/App Store | Your Apple Team ID | Exact Release bundle ID | `production` |

The publishable project key and API URL identify the mobile project; they are not administrator credentials. Never put Cloudflare credentials, dashboard cookies, deployment tokens, database credentials, or private backend source in an app.

## 2. Add the Swift package

In Xcode, choose **File → Add Package Dependencies…** and use:

```text
https://github.com/keinois/build-this-please-ios-sdk
```

Select the `BuildThisPlease` product and a tagged version such as `0.2.0` or newer. Because the package is public, developers and Xcode Cloud do not need access to the private backend repository.

## 3. Enable App Attest

Add the App Attest capability to the host target. Confirm the generated entitlements use `development` for Debug and `production` for Release/TestFlight:

```xml
<key>com.apple.developer.devicecheck.appattest-environment</key>
<string>development</string>
```

The value must match the App identifier registered in the BuildThisPlease dashboard.

App Attest is unavailable in the Simulator. Use `MockBuildThisPleaseClient` for Simulator development and previews. Validate the live service on a physical device before release.

## 4. Configure the client

Create one long-lived client for the app rather than recreating it whenever the view appears:

```swift
import BuildThisPlease
import SwiftUI

let baseURL = URL(string: "https://feedback.keinois.com")!

let environment: BuildThisPleaseConfiguration.Environment = {
    #if DEBUG
    // Uses Apple's development App Attest environment against the live service.
    return .staging(baseURL: baseURL)
    #else
    return .production(baseURL: baseURL)
    #endif
}()

let configuration = try BuildThisPleaseConfiguration(
    projectKey: "btp_pk_your_publishable_project_key",
    environment: environment,
    subscriptionStatus: isTrial ? .trial : (isPro ? .pro : .free),
    revenueCatAppUserID: currentRevenueCatAppUserID,
    userEmail: signedInEmail
)

let feedbackClient = BuildThisPleaseClient(configuration: configuration)
```

`.staging(baseURL:)` selects the `development` App Attest environment; it does not require a separate staging server. Production still rejects Simulator bypass sessions. Release builds must use `.production(baseURL:)`.

`revenueCatAppUserID` and `userEmail` are optional support context. Pass only data your app is permitted to share. When subscription or identity information changes, update the existing client:

```swift
try await feedbackClient.updateSubscriptionStatus(.pro)
try await feedbackClient.updateUserIdentity(
    revenueCatAppUserID: Purchases.shared.appUserID,
    email: currentEmail
)
```

## 5. Add the SwiftUI destination

`FeedbackListView` is designed for an existing app menu and `NavigationStack`:

```swift
struct SettingsMenu: View {
    let feedbackClient: BuildThisPleaseClient

    var body: some View {
        List {
            NavigationLink {
                BuildThisPlease.FeedbackListView(client: feedbackClient)
                    .buildThisPleaseTheme(.init(accent: .blue))
            } label: {
                Label("Feature requests", systemImage: "lightbulb")
            }
        }
        .navigationTitle("Settings")
    }
}
```

Use `BuildThisPlease.StandaloneFeedbackView(client:)` when BuildThisPlease must own its own `NavigationStack`.

Customize the accent and voted state without forking the SDK:

```swift
.buildThisPleaseTheme(.init(accent: .indigo, voteHighlight: .mint))
```

## 6. Verify before release

- The dashboard contains the exact Release Team ID and bundle identifier.
- The Release entitlement uses the `production` App Attest environment.
- The app uses `.production(baseURL: URL(string: "https://feedback.keinois.com")!)`.
- The app contains the correct publishable project key.
- A physical-device build can load, submit, vote, and reply.
- Notification recipients are correct in Project settings.
- No administrator or Cloudflare credentials are present in the app.

Run the package and example checks locally:

```bash
swift test
xcodebuild \
  -project Examples/BuildThisPleaseExample/BuildThisPleaseExample.xcodeproj \
  -scheme BuildThisPleaseExample \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/example-ci \
  CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=YES \
  build
```

## Dashboard operations

- Platform approval allows a developer to use BuildThisPlease but does not expose any customer workspace.
- Workspace invitations are bound to the invited email and grant access only after that identity authenticates and accepts.
- Workspace owners can invite administrators or read-only viewers.
- Workspace owners can export their data as JSON.
- Workspace deletion permanently removes every project and its feedback after exact-name confirmation. Export first.

For troubleshooting, CI, direct API usage, and an expanded launch checklist, see the [Integration guide](Documentation/Integration.md). Coding agents should also follow [AGENTS.md](AGENTS.md).

## Repository boundary

This repository intentionally contains only client-side code. Its example app is not included in the Swift package products and does not ship inside host applications. The private BuildThisPlease backend contains dashboard authorization, application-level tenant isolation, database migrations, deployment configuration, and production infrastructure.

Each submitted request includes the host app version as private backend metadata. The version is captured from the SDK configuration (which defaults to the host app version) and is not included in public request responses.

## Completion updates (0.2.0)

The board now includes an Updates inbox and optional verified completion emails through Cloudflare. See [Notifications integration](Documentation/Notifications.md) for unread badges, optional local alerts, background scheduling, app links and verified identity recovery. Each request starts with a permanent author vote, independent of its follow/mute preference.

## Request caching and launch preloading (0.2.0)

Retain the client when the host app starts and call `try await feedbackClient.preloadRequests()` from an app-owned task without blocking launch. The board reads disk-backed Requests, Mine and Implemented before refreshing each list independently, and keeps saved results visible offline. Preloading and initial board loads reuse complete snapshots for 60 seconds and share in-flight downloads; pull to refresh always fetches fresh data. See [Request caching and host lifecycle](Documentation/RequestCaching.md) for launch, foreground, logout and account-switch examples.
