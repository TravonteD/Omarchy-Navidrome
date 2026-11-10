# Omarchy Navidrome port plan

Prepared 10 November 2026. This plan states how the successful Omarchy Spotify
implementation becomes **Omarchy Navidrome**: a Quickshell plugin for a
self-hosted [Navidrome](https://www.navidrome.org) library, reusing the proven
architecture while replacing everything that exists only because Spotify does.

The upstream Spotify plan and its implementation record remain in
[IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) and
[IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md) as history. They are not
release requirements for the Navidrome port; this document governs it.

## Ground facts (checked 10 November 2026)

- Navidrome implements Subsonic API **1.16.1** with OpenSubsonic extensions;
  JSON responses are supported with `f=json`. See
  [Navidrome's compatibility matrix](https://www.navidrome.org/docs/developers/subsonic-api/).
- Authentication supports per-request **token auth** (`t = md5(password + s)`
  with a fresh ≥6-char salt), legacy `p`, and a trusted reverse-proxy header.
  It answers 4xx error 41/42 when a scheme is rejected.
  [OpenSubsonic authentication](https://opensubsonic.netlify.app/docs/api-reference/).
- `getOpenSubsonicExtensions` advertises optional behavior; Navidrome converts
  `application/x-www-form-urlencoded` POST bodies into query parameters, which
  covers long `updatePlaylist` requests.
- Relevant endpoints: `ping`, `getUser`, `search3`, `getAlbumList2`,
  `getStarred2`, `getIndexes`, `getArtist`, `getAlbum`, `getGenres`,
  `getPlaylists`/`getPlaylist`/`createPlaylist`/`updatePlaylist`/`deletePlaylist`,
  `star`/`unstar`/`setRating`/`scrobble`, `getBookmarks`/`createBookmark`,
  `getPlayQueue`/`savePlayQueue`, `getLyrics`/`getLyricsBySongId`,
  `getInternetRadioStations`, `getScanStatus`/`startScan`, `stream`, `download`,
  `getCoverArt`, `startScan`.
- `stream` serves on-demand transcoding (`format`, `maxBitRate`). Navidrome
  never marks plays from `stream`; play counts change only when
  `scrobble` is called with `submission=true`.
- `jukeboxControl` exists but plays through the **server's** audio hardware and
  is disabled unless `Jukebox.Enabled` is set server-side. It is not a default
  playback path; at most an optional extra later.
- There is no Connect, no multi-device transfer, no OAuth, no rate-limit
  cooldown system, and no video endpoints. IDs are always strings.

## Decisions

1. **Playback engine: Rust streaming rewrite.** Keep the proven shell of the
   backend — systemd user unit, owner-only private Unix socket, MPRIS,
   failure typing, diagnostics, idle shutdown — and replace the librespot
   media transport with an HTTP streaming client plus a symphonia-family
   decoder writing to the same audio path. The backend URL-building code owns
   credentials only as far as the protocol requires; see the security contract.
2. **Authentication: server URL + username + Navidrome password in the keyring.**
   Token auth recomputes `md5(password + salt)` per request, so the plugin must
   retain the actual password, not a hash or refresh token. Store it with the
   existing keyring scripts, separated per server identity. Feature-detect
   `formPost` (and `apiKey` when advertised) via `getOpenSubsonicExtensions`;
   these are optimizations, not requirements.
3. **No Spotify Connect.** Devices view, Sonos support, Avahi discovery, the
   Connect identity, `SpotifyConnectManager.qml`, and the spotifyd
   fallback/patches/provenance chain are removed. MPRIS continues to expose
   local playback, and remote MPRIS controllers (another player on this
   machine, e.g. a phone via its own means) keep working through the bus.
4. **Browsing is simpler than Spotify.** Most cursor-paginated Web API paths
   become deterministic windows (`getAlbumList2` offsets, one-shot
   `getPlaylist`) or per-category bounded searches (`search3`). The
   FilterScanController work remains useful for genre scanning and long lists;
   the "beyond 200 items" dance disappears along with cursor pagination.
5. **Keep the lightweight discipline.** Same bar widget, lazy panel, recycled
   rows, artwork gating, IPC ownership, bounded caches, benchmark gates. The
   Spotify benchmark harness methodology carries over unchanged.
6. **Lyrics become built-in.** `getLyricsBySongId` (embedded, external files,
   and synced content) replaces the Omasing handoff as the default surface.
   Keep the lyrics view, hide-button, and shortcuts already validated for #46.
7. **Non-HTTPS servers are allowed but flagged.** Many Navidrome instances run
   on plain local HTTP. Show a persistent setup warning for insecure URLs, and
   never claim the connection is private when it is not.

## Security contract

- Navidrome password lives in the keyring, per server identity, and is read
  only through the existing `keyring-store.sh` path. It never appears in logs,
  diagnostics, session state, or URL strings outside the request builder.
- Token-auth credentials ride on every request URL. Use form POST when
  advertised and available so credentials leave the URL, especially for
  playback, which otherwise puts `t`/`s` into stream URLs the backend builds.
- The private backend socket remains owner-only; credentials passed across it
  are consumed and never re-logged. Redaction rules from the Spotify backend
  (no tokens, salts, passwords, or usernames in any emitted message) carry over
  verbatim.
- Setup must warn clearly on plain `http://` targets and on self-signed TLS
  that will not validate. Never silently accept an invalid certificate.

## Feature mapping

| Spotify feature | Navidrome port | Notes |
| --- | --- | --- |
| Premium account gate | Nothing — no account gating | Server access is the gate (`getUser`). |
| OAuth PKCE, client IDs (#58) | Password + token auth, feature-detected extensions | Setup flow asks for URL, username, password. |
| Home view | Recently played / frequent / newest albums, starred | `getAlbumList2` windows. |
| Discover (official mixes) | Explore: random albums, genres, internet radio | Optional later: `getSimilarSongs2` needs Last.fm. |
| This Is playlist + top songs | Artist top songs from `getArtist` | Artist pages become the artist's album list. |
| search | `search3` per-category windows | No Lucene queries — keep simple text queries. |
| playlists CRUD | Same verbs in Subsonic | `updatePlaylist` via form POST when advertised. |
| saved tracks | `star` / `unstar` / `getStarred2` | Show combined album/song starred view. |
| listen history | Nothing direct | scrobbles live on the server; Home uses frequent/recent album lists. |
| queue | Local queue in backend, persisted with `savePlayQueue` | Restore via `getPlayQueue`; also refill from playlists. |
| last-play resume (#55) | Replace with bookmark restore (`getBookmarks`) and `savePlayQueue` from prior session | Exact-position resume becomes real, since the server keeps per-track positions. |
| Spotify Connect devices | Dropped | Remote MPRIS controllers keep working. |
| Sonos / Avahi / restricted-device logic | Dropped | |
| lyrics via Omasing | Built-in `getLyricsBySongId` | Keep the hide-lyrics preference; swap provider. |
| artwork from Spotify | `getCoverArt` with `RetryImage` | Keep traffic gating and artwork master switch. |
| transcoding/audio quality setting | `format` + `maxBitRate` selection | Default: source; expose a bounded quality list. |
| scrobbles | Explicit `scrobble submission=true` at natural end | Also send `submission=false` on play start where harmless. |
| sleep timer, shortcuts, MPRIS, IPC, bar widget | Unchanged | Carry over the tested machinery as-is. |

## Delivery sequence

Effort scale: S is a focused change, M spans components, L is a state-model or
engine rewrite. Every step must leave the plugin loadable and the test suite
green. Work items remain individual reviewable commits even while only this
local clone is affected.

| Order | Work package | Priority / effort | Depends on | Shipping outcome |
| --- | --- | --- | --- | --- |
| 0 | Baseline and identity | P0 / M | this clone | Renamed clone with green test suite, Spotify-only code removed |
| 1 | Navidrome API layer | P0 / L | 0 | Full browsing/search/star/playlist verbs over Subsonic JSON |
| 2 | Setup, credentials, connectivity | P0 / M | 1 | Guided first-run with server URL/user/password into keyring |
| 3 | Stream engine | P0 / L | 1 | Local playback via `/rest/stream` with MPRIS + transcode controls |
| 4 | Queue, scrobble, resume | P1 / L | 3 | Persistent queue, honest scrobbles, bookmark-position resume |
| 5 | Collection and discovery UI | P1 / M | 1 | Home/Explore/artist/album/playlist views on richer content than before |
| 6 | Lyrics, radio, settings cleanup | P2 / M | 1 | Built-in lyrics, internet radio, final settings surface |
| 7 | Docs, release, install | P1 / M | 3 | Renamed docs/README/install script, local build pipeline |

### 0. Baseline and identity

Rename the product identity end to end: manifest id/name, entrypoint display
names, systemd unit names and `ExecStart` paths, `$XDG_CACHE_HOME` /
`$XDG_STATE_HOME` directory roots (`omarchy-navidrome`), backend binary and
socket names, the Subsonic `c` client id, `scripts/build-backend.sh`,
`scripts/install-local.sh`, uninstall inventory, and the CI workflow names.
Update tests and fixtures in the same commit; the suite must be green
immediately after the rename.

Remove Spotify-only surfaces only once their replacements exist (**not
before**): keep the shell loading at every intermediate step. The removal pass
deletes `SpotifyConnectManager.qml`, the Connect identity and OAuth keyring
flows in `AuthManager.qml`, the Sonos/discovery paths in `Service.qml`,
`patches/*` and `config/spotifyd.conf`, the spotifyd fallback unit, and the
Spotify announcement/provenance gating inside `scripts/setup.sh`, keeping the
socket-first startup diagnostics and restart bounds implemented earlier.

Acceptance: no user-visible string promises Spotify; every path that persists
state writes under the new home; the whole `scripts/test.sh` gate passes.

### 1. Navidrome API layer

Rewrite `Api.js` and `SpotifyApi.qml` as Subsonic transports. Keep the
transport hardening earned upstream (#38-derived): no overlapping same-route
storms, bounded requests, explicit state machine, and cancellation hooks. Keep
`SearchController` semantics — first-page/pagination, generation checks; only
Result shapes change — `search3` serves every search surface with windows
bounded by server config, and pagination-aware album list windows stay honest
about partial vs. exhaustive results.

Add a small pure-JS `md5(password + salt)` helper, tested against the spec
examples. Salt generation comes from a single source so retries don't reuse a
salt; every request builds fresh salt and token. Transport state tests reuse
the existing fixtures.

Acceptance: connection probe verifies server + user (`ping`, `getUser`,
`getLicense`) before any heavy listing; no credentials in test fixtures; stale
responses can never reach a newer view (tests cover a query and page race).

### 2. Setup, credentials, and connectivity

Adapt `scripts/setup-playback.sh` to a guided first-run: server base URL,
username, password; a live probe to the actual server; then the keyring write.
Replace the OAuth/browser round-trip completely — no callback servers, no
PKCE, no browser-driven flows. Public state directory root moves
to `omarchy-navidrome`. The reconnect budget gets re-derived from Subsonic
error codes (40 wrong user/pass, 41 token failure, 42 apiKey, 0 generic) as
typed categories rather than the Spotify terminal-failure list.

Handle self-hosted realities: HTTP allowed with a visible warning; custom
certificate checks never bypass; timeouts measured by user-set ping budget;
port reuse like 443 behind a proxy holds exactly once.

Acceptance: wrong password yields a typed error, not a generic reconnect push;
keyring stores exactly one credential per server identity; uninstall removes
all owned files under the new root; setup re-run without re-prompting stores
the same identity cleanly.

### 3. Stream engine

Replace the librespot transport in the Rust backend with an HTTP streaming
player. Concretely: resolve a stream URL (format + maxBitRate from settings
and server-side transcode decision), stream with bounded buffering, decode
with `symphonia` (verify supported codecs: FLAC, MP3, OGG/Vorbis, M4A/AAC,
WAV, and current Opus support when choosing the default `format`), and write
through `rodio` to the same output device `config.rs` already manages. Keep
gapless preload of the next track, seek by byte/decode position, and the
one-position-update-per-second MPRIS contract.

Implement restart and reload bounds exactly as the Spotify backend has them
(five starts in five minutes, typed exit codes, failure record on the socket).
Keep config validation as a `check` subcommand against the server. Queue state
lives in `state.rs`/`state.json` keyed per server identity.

Acceptance: stream across formats listed above without restart loops; seek to
mid-track works in and out; sleeping the machine recovers into the next queue
entry; playback announces readiness before the first audible sample in a
measured frame-stall budget; a server that dies mid-stream produces bounded
retry behavior with a typed error rather than unbounded reconnects.

### 4. Queue, scrobble, and resume

Queue becomes backend-owned with `savePlayQueue` persistence on the server,
refilled through `getPlayQueue` the way the Spotify backend restores last-play
state. Scrobbles fire `submission=true` exactly at natural track end (never
for local stop, seek, or skip before meaningful playback); this is the only
mechanism Navidrome honors, so correctness here is correctness of play counts.
Bookmarks restore the exact position of a partially played track when the user
chooses Play after a reload.

Failed writes must never replay blindly: treat interrupted playlist-writing or
scrobble enqueues as uncertain, matching the uncertainty contract from
package 1 in the Spotify plan.

Acceptance: during a seamless track transition the scrobble lands once; a
forced stop doesn't scrobble; a fresh session resumes exact track and position
for a bookmarked song; an airplane-mode queue edit lands on the server within
one retry budget.

### 5. Collection and discovery UI

Rebuild the views on Subsonic content. Home uses recent/frequent/newest album
lists; Explore adds random albums, genre browsing via `getGenres`, and
internet radio Stations; artist pages show albums plus top songs;
album pages list their tracks. Every previously implemented behavior — row
actions, keyboard navigation, compact layout at 300px width, scroll/depth
restoration, artwork gating, Save(visible)/(star) state consistency across
surfaces — continues to hold; the fixtures change, not the standards.

Acceptance: every standard from the Spotify quality plan is re-verified in a
live server session; starred state is consistent across bar, mini-player, and
panel; navigation remains keyboard-complete at narrow widths.

### 6. Lyrics, radio, and settings cleanup

Wire `getLyricsBySongId` into the existing lyrics view. Keep `showLyrics`
setting, hide-button behavior, and shortcut hints. Internet radio appears as a
source alongside albums (playable streams, no local persistence). Settings
shed Spotify-only items (`clientId`, streaming device identity), and the
streaming-quality setting grows to the Navidrome `format`/`maxBitRate`
choices. Keep artwork preferences, fixed
bar width, and every verified keybinding that survives the port.

Acceptance: lyrics load for embedded and synced files, with no fetches when
the surface is closed or artwork-disabled state would apply; radio stations
play like songs without claiming library identity; settings survive reload.

### 7. Docs, release, and install

Update README (Navidrome story, shortcuts, install instructions), TECHNICAL
(architecture, security contract, endpoints), RELEASING (simplified: local
build and versioned archive; the GitHub attestation chain is replaced by a
local-build checksum doc until the first actual release), and the CHANGELOG
starting from a fresh 0.1.0 entry describing the port, not inheriting Spotify
numbering. `scripts/install-local.sh` keeps local compilation to
`$XDG_CACHE_HOME/omarchy-navidrome/target`, reloads quickshell, and keeps the
uninstall inventory current.

Acceptance: from a fresh clone the documented command installs a working
plugin against a running Navidrome server; uninstall restores prior state;
no Spotify reference survives in install output.

## Validation gates carrying forward

- `scripts/test.sh` remains the single gate: Rust tests/Clippy, QML tests,
  Python helper tests, script checks, quickshell smoke tests with real Omarchy
  imports.
- Live-server validation uses environment variables (server URL, username,
  password) supplied out of band, never committed or logged. Tests round-trip
  against a throwaway library surface (toggle a star twice, check the queue
  save/replay pair) — nothing destructive to the real library.
- Race tests to carry over with reworked fixtures: stale page after a new
  search; timeout releasing a slot exactly once; interrupted playlist write
  treated as uncertain; server URL/credential change draining in-flight
  requests; and raw bytes on a real subprocess timeout still applying to
  helpers that shell out.
- Benchmark gates to carry over: no requests on cached revisit, no artwork
  traffic when disabled, no periodic feature timers for closed optional
  views (lyrics timer correctness is explicitly inherited after #50's caution,
  though built-in lyrics start with the timer discipline already present).

## Out of scope for the first release

- Jukebox mode (`jukeboxControl`), even when the server enables it.
- Sharing, smart-playlist creation beyond what the server exposes, podcast
  endpoints (Navidrome doesn't implement them), and Last.fm-gated similarity.
- Multi-server support (one server identity per plugin install initially).
- Anything that reintroduces a browser engine, resident helper beyond the
  supervised backend, or a licensing/attestation claim the project cannot make.
