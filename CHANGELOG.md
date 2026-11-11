# Changelog

## 0.2.0

- Disk-backed Requests, Mine and Implemented snapshots with independent cache-first loading and offline retention.
- Explicit host launch/foreground preloading, 60-second freshness and shared in-flight list requests.
- Account/environment/installation-scoped cache, seven-day expiration, 8 MiB storage bound, and logout clearing.
- Vote/create/detail cache updates and guards against delayed responses overwriting newer mutations or cleared data.

- Completion-only Updates inbox with unread state, pagination and request navigation.
- Optional verified completion emails delivered by Cloudflare Email Service.
- Request follow/mute controls independent of votes; automatic permanent author vote.
- Optional local-notification synchronization for host-owned background scheduling.
- Verified notification identity linking and account-scoped credential namespaces.
- Requires BuildThisPlease backend migrations through 0017, including App Attest recovery support. Existing installations continue anonymously; support emails are not automatically subscribed.
