# Port status

Progress record for the Omarchy Navidrome port. Requirements governing the
port are in [NAVIDROME_PORT_PLAN.md](NAVIDROME_PORT_PLAN.md).

## Package 0 — baseline and identity (in progress, 10 November 2026)

Done so far:

- Port plan written after checking Navidrome's Subsonic API compatibility
  matrix, authentication methods, `stream`/`scrobble` semantics, and the
  `jukeboxControl` server-side limitation against current upstream
  documentation (sources linked in the plan).
- Product identity renamed mechanically across code, scripts, systemd units,
  backend binary name, manifest, CI definitions, and tests:
  `omarchy-spotify*` → `omarchy-navidrome*`,
  `quickshell.spotify` → `quickshell.navidrome`,
  "Omarchy Spotify" → "Omarchy Navidrome". The spotifyd fallback unit/logic is
  renamed (not deleted) because its removal belongs to a later cleanup pass
  once the stream engine replaces it.

Validation after the rename:

- Rust: 23 backend tests pass; `cargo fmt`/`clippy` clean.
- QML: 188 transport/search/UI tests pass; plugin validation and `qmllint`
  pass.
- Python: 19 helper tests pass; script checks pass.

Formerly failing gate step, now fixed (10 November 2026): the Quickshell app
smoke step in `scripts/test-quickshell.sh` reported `Unable to assign
[undefined] to QColor` because bare `Color` references in the plugin QML
bound to Quickshell's own built-in global `Color` singleton (`QQuickColor`,
a utility type with `rgba`/`blend`/`tint` members, no palette), shadowing the
`qs.Commons` `Color` palette singleton — its `foreground`, `popups`, `bar`
and friends are all `undefined`. Quickshell 0.3.2 resolves unqualified
singleton names against the built-in set, so `import qs.Commons` alone is
not enough; the first-party shell avoids this by importing qualified
(`import qs.Commons as Commons` → `Commons.Color.*`) in every file. The
plugin now follows the same convention (qualified imports and `Commons.Color`
references in the seven affected QML files). Verified identical on the
unmodified upstream checkout at `e7371f3`, so it was not introduced by the
port; it reproduced standalone in a minimal test root with only
`/usr/share/omarchy/shell/Commons` copied in, proving it was name
shadowing rather than a missing theme initialization in the copied
environment. No harness changes were needed and no stubs were introduced —
the smoke test still boots the real Service/Panel against the real
`/usr/share/omarchy/shell` imports, now warning-free.

## Package 1 — Navidrome API layer (in progress, 10 November 2026)

- `Subsonic.js` landed: the pure request core — RFC 1321 MD5 over UTF-8
  (validated against the spec's token example and reference vectors,
  including multi-block and multibyte inputs), per-request salt generation
  with an injectable source, sorted-stable query building with repeated
  parameter keys, server-URL canonicalization (lowered host, trailing-slash
  trimming, IPv6 brackets, scheme validation), `subsonic-response` parsing,
  and typed Subsonic error-code categories (40 wrong credentials, 41/42
  token auth rejected, 50 not authorized, 70 not found, plus generic
  fallbacks). 13 new tests; suite at 201 passing.

Continued on 10 November 2026:

- `Subsonic.js` grew the verb/normalizer layer: defensive shared parsing
  (bounded numbers, strict booleans, string-coerced IDs, id-less entry
  dropping), normalized song/album/artist/playlist shapes, probe helpers
  (`parseLicense`, `parseUser`, `describeProbeError` over the existing typed
  categories), `search3` per-category windows, `albumList2` window params with
  legacy list fallback, artist/album/top-songs/genres parsers, playlist CRUD
  param builders (repeated keys for `updatePlaylist`), star/unstar/rating with
  clamping, scrobble params, and `coverArtUrl` over `requestUrl`. 22 new test
  functions with invented Navidrome-shaped fixtures.
- `SubsonicApi.qml` landed: the QML transport replacing `SpotifyApi.qml`'s
  role — job queue with bounded in-flight and mutating-verb serialization,
  timeout sweep, abort handles, `cancelAll`, redacted diagnostics ring buffer
  (endpoint names only, never query strings or `u`/`t`/`s` values), fresh salt
  per request through `Subsonic.requestUrl`, typed error surfacing from
  `parseResponse`, the mutating-verb uncertainty contract (any unconfirmed
  write reports `uncertain`; local fail-fast failures do not), serial-guarded
  `search3` cancellation, the sequential `probe` (ping → `getUser` →
  `getLicense`, short-circuits on typed failures, cancellable), and local
  fail-fast categories `invalidServerUrl`/`missingCredentials`. OAuth, token
  refresh, and the 429 cooldown machinery are deliberately not ported.
- New `tests/tst_subsonic_api.qml` covers salt freshness, typed failures,
  stale-search and page races, single-shot timeout expiry with slot release,
  uncertain writes, probe ordering/short-circuit/restart, diagnostics
  redaction across the whole battery, `cancelAll`, and local fail-fast. 14
  new test cases; suite at 238 passing. `SubsonicApi.qml` added to the
  `qmllint` gate.
- `SpotifyApi.qml` and its consumers remain untouched by design: the removal
  pass waits for package 5's UI rewiring.

## Stream transport on protocol v2 (10 November 2026)

The Rust backend was rewritten as a Subsonic HTTP streaming engine (protocol
v2). The QML side was wired to the new transport boundary without the UI
remodel (that lands with the package 5 Subsonic data model):

- `BackendClient.qml` sends `{"v":2,...}` requests, gained
  `configureServer(url, username, password, callback)` (inputs never logged;
  its acknowledgment is tracked by a `serverConfigured` flag that resets on
  every socket reconnect), and its `loadPlayback` now sends complete `songs`
  arrays (SongRef) instead of Spotify play bodies.
- `Api.js` replaced `backendLoadFields` with `backendLoadFieldsV2(items,
  options)` (pure Subsonic-row mapping with defensive defaults and a
  seconds-vs-milliseconds duration heuristic) plus
  `playbackLoadBodyV2`/`backendSongRefV2` for the interim Spotify-shaped call
  sites; `Api.redact` now also scrubs Subsonic `u`/`t`/`s`/`salt`/`token`
  query params (the backend's authed `getCoverArt` art_url set).
- `AuthManager.qml` gained the `navidromeCredentials()` accessor (stub:
  empty values until the setup flow fills the properties).
- `Service.qml` calls `configureServer` at the ready transition (fires again
  by design after reconnects), builds `pendingPlaybackLoad` per play request,
  and sends `add_to_queue` as `{song: SongRef}`. All Spotify remote paths are
  unchanged.
- `docs/BACKEND_PROTOCOL.md` was rewritten for protocol v2 (commands, SongRef,
  events, error codes, the art_url auth-params caveat, and the logging ban).

Validation after the wiring: 242 QML tests pass (was 238), the 44 backend
Rust tests still pass, and `qmllint` stays clean. Known transitional
behavior: until package 5 delivers Subsonic song ids into the UI rows, local
playback through the stream engine surfaces `missing_credentials` (no setup
pass yet) and Spotify remote playback stays the fallback.

## Remaining in package 0

- second rename pass done for: uppercase env names (`OMARCHY_NAVIDROME_*`),
  manifest descriptions/aliases (bar alias `spotify` → `navidrome`,
  version reset to 0.1.0 aligning backend `Cargo.toml`, `Cargo.lock`, tests,
  and a fresh `0.1.0 (unreleased port)` CHANGELOG section), interim README
  (with the uninstall chapter the script tests require), and install-script
  wording.
- Left in place deliberately until their replacement ships: Spotify-only
  file/component names still referenced by tests and flows that later packages
  rewrite (`SpotifyApi.qml`, `SpotifyConnectManager.qml`,
  `benchmark-spotify-desktop.sh` as a comparator, `spotifyd` fallback files).
- Decide the fate of the pre-existing Quickshell smoke failure above: fix the
  harness stub or restore theme initialization so the gate is green.

## Next packages

1. Navidrome API layer (`Api.js`/`SpotifyApi.qml` rewrite on Subsonic JSON) —
   transport and verbs landed; the remaining piece is rewiring
   `SearchController`/consumers onto it, which lands with package 5's UI pass.
2. Setup, credentials, connectivity (URL/user/password, keyring).
3. Stream engine (Rust `/rest/stream` player with symphonia + rodio).
4. Queue, scrobble, resume persistence.
5. Collection and discovery UI adaptation.
6. Lyrics (`getLyricsBySongId`), internet radio, settings cleanup.
7. Docs, release, install scripts.

Live-server validation (user's Navidrome instance) begins with package 1's
transport work; credentials will be supplied out of band only.
