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

Known pre-existing issue (verified identical on the unmodified upstream
checkout at `e7371f3`, so not introduced by the port): the Quickshell app
smoke step in `scripts/test-quickshell.sh` fails under the current Omarchy
snapshot because `Color` singleton members are `undefined` in the copied
test environment (`Unable to assign [undefined] to QColor`), which the
smoke test treats as a hard failure. `Color.qml` exists in
`/usr/share/omarchy/shell/Commons`; the failure pattern suggests the theme
palette is not initialized outside a real shell session — an environment or
shell API change since the 8 September validation run, worth a dedicated
fix pass.

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
