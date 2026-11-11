# Loading requests at app launch

Version 0.1.6 can restore request lists from disk before refreshing them. Create and retain the client early in the host app, then call `preloadRequests()` from an app-owned task. Creating a client does not start networking. Opening the board reads saved Requests, Mine and Implemented first; each successful list refresh appears independently, even while another endpoint is still downloading. Saved requests remain visible after a failed refresh or while offline.

`preloadRequests()` refreshes each missing, incomplete or older-than-60-second list and shares in-flight requests with the board. Session establishment and recovery remain serialized with App Attest mutations; list downloads run independently after receiving their session token, and simultaneous rejected tokens share the recovered session. Repeated startup/foreground calls within that window avoid duplicate downloads. `requests()`, `myRequests()` and `implementedRequests()` always request fresh data and update the cache. Pull to refresh, including the retry control in empty sections, uses those fresh methods. A successful empty response replaces the old list. If one list fails, other lists can still update; preload throws after all three attempts finish.

## Retain the client and its launch task

This dependency can be created by your existing app composition root. Supply the dashboard-issued configuration, including an opaque account namespace when your app has accounts. Do not create it from a view's `body`.

```swift
import BuildThisPlease
import Observation
import SwiftUI

@Observable @MainActor
final class FeedbackDependency {
    private(set) var client: BuildThisPleaseClient?
    private var preloadTask: Task<Void, Never>?

    init(configuration: BuildThisPleaseConfiguration) {
        client = BuildThisPleaseClient(configuration: configuration)
        refreshWhenActive() // Launch proceeds while requests load.
    }

    func refreshWhenActive() {
        guard let client else { return }
        preloadTask?.cancel()
        preloadTask = Task {
            do { try await client.preloadRequests() }
            catch is CancellationError { }
            catch { /* Keep saved requests; report through your existing logging. */ }
        }
    }

    func replaceAccount(configuration: BuildThisPleaseConfiguration?) async {
        preloadTask?.cancel()
        preloadTask = nil
        let previous = client
        client = nil // Remove the previous account's feedback destination first.
        await previous?.clearRequestCache()
        if let configuration {
            client = BuildThisPleaseClient(configuration: configuration)
            refreshWhenActive()
        }
    }
}

struct HostFeedbackMenu: View {
    let feedback: FeedbackDependency
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                if let client = feedback.client {
                    NavigationLink("Feature requests") {
                        BuildThisPlease.FeedbackListView(client: client)
                    }
                }
            }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active { feedback.refreshWhenActive() }
        }
    }
}
```

The host must serialize account transitions and close any presented feedback view before calling `replaceAccount`. On logout, call `await feedback.replaceAccount(configuration: nil)`. On login, pass a configuration with `identityNamespace` set to a stable opaque identifier unique to that host account; use the same namespace when that account returns. Keep anonymous use in its own namespace. Email addresses and RevenueCat metadata do not partition the cache or establish ownership. Use a new client when the account changes, rather than changing support metadata on an old account's client.

Cancelling one waiter does not cancel a shared list download that another screen or launch task may still need. Such finite downloads remain owned by the retained client. `clearRequestCache()` cancels its list downloads, clears memory and disk, and prevents delayed reads or mutations from restoring the cleared snapshot. Cancel the host's tasks first so they cannot initiate new requests after clearing. This method deletes cached request data; it does not delete installation credentials or server feedback.

## Custom interfaces

```swift
func showSavedThenRefresh(client: any BuildThisPleaseClientProtocol) async {
    if let saved = await client.cachedRequests() {
        // Publish saved.requests?.items, saved.mine?.items and saved.implemented?.items.
        // A nil list has not loaded; an empty items array is a loaded empty list.
        _ = saved
    }
    do { try await client.preloadRequests() }
    catch { /* Present an error alongside retained content. */ }
    let refreshed = await client.cachedRequests()
    _ = refreshed // Publish successful refreshed lists, even if another list failed.
}
```

Each `BuildThisPleaseCachedRequestList` has `items`, `updatedAt` (last successful full list fetch) and `isComplete`. A successful create can seed a partial Mine list (`isComplete == false`) before Mine has loaded; it remains visible but does not suppress a full refresh. `isFresh()` defaults to 60 seconds and requires a complete list. Protocol defaults preserve source compatibility for custom/mock clients; implement the cache methods to opt a custom client into persisted snapshots.

## Storage and freshness

The cache lives in the app's caches directory, expires lists after seven days, and limits stored files to 8 MiB in total. Encoding, reads, eviction and atomic writes run away from the UI actor. Storage is best effort: the OS can remove it, and a disk failure never fails an otherwise successful server operation. A caller can provide `requestCacheDirectory` when constructing a client to choose a dedicated cache directory.

Cache keys hash the endpoint URL, SDK environment, project key, bundle identifier, host `identityNamespace` and installation identity. A replacement installation cannot read the previous installation's private Mine list or vote flags; App Attest key recovery that preserves the installation can keep its cache. Files contain request snapshots, not session tokens, support emails or RevenueCat metadata. Request titles/descriptions can still contain user-written personal information; logout clearing belongs in the host's account lifecycle.

Successful votes, creations and detail loads update saved rows. Newer local changes survive older in-flight list responses; successful list refreshes otherwise replace server removals and accept new rows. Foreground preloading is a refresh opportunity, not a real-time subscription. New administrator information appears on the next refresh; the SDK does not add push delivery, background execution permissions or background polling automatically. Optional host-owned background jobs may call `preloadRequests()` when the OS grants time.
