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

1. Navidrome API layer (`Api.js`/`SpotifyApi.qml` rewrite on Subsonic JSON).
2. Setup, credentials, connectivity (URL/user/password, keyring).
3. Stream engine (Rust `/rest/stream` player with symphonia + rodio).
4. Queue, scrobble, resume persistence.
5. Collection and discovery UI adaptation.
6. Lyrics (`getLyricsBySongId`), internet radio, settings cleanup.
7. Docs, release, install scripts.

Live-server validation (user's Navidrome instance) begins with package 1's
transport work; credentials will be supplied out of band only.
