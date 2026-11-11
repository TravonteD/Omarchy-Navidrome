# Technical notes

This document keeps implementation, development, and deep troubleshooting
details out of the user-facing README.

## Architecture

Omarchy Navidrome runs as a plugin inside Omarchy's existing `omarchy-shell`
Quickshell process. It provides a shared service, a bar widget, and a
lazy-loaded panel. There is no embedded website, browser engine, second shell
process, or resident helper process.

Playback state and ordinary controls use MPRIS. Starting playback on this
computer uses the backend's private Unix socket (protocol v2: `configure_server`,
`load`, `add_to_queue`) when that process is running. All browsing, search,
stars, playlists, lyrics, and radio go through the Subsonic JSON API; there
is no second, remote playback path.

Local audio runs in the plugin-owned `omarchy-navidrome-backend` Rust
process, supervised by a static systemd user unit that is never enabled at
login. It is the only playback runtime: it owns configuration, the Subsonic
streaming/decoding engine, server writes (scrobbles and the persisted play
queue), MPRIS, lifecycle, and a stable private Unix-socket boundary. The app
starts the unit whenever its full player or mini-player is open or when you
play on this computer. Once every player surface closes, it stops after the
configured idle period; 0 keeps it available indefinitely.

The unit sets `PULSE_LATENCY_MSEC=30` for local playback and caps the
backend's tokio runtime at two workers so network fetching, preloading, and
blocking decoder work can overlap while the control loop stays responsive.
It also carries systemd restart bounds (`StartLimitBurst=5` inside
`StartLimitIntervalSec=300`, `RestartSec=5`), so a backend that keeps failing
hits the start limit instead of looping forever, and typed startup failures
(report over the socket and read by `playback-runtime.sh`) prevent pointless
restart attempts. Quickshell interpolates MPRIS position locally, so the
backend publishes one authoritative position update per second instead of
four.

MPRIS uses a PID-qualified instance bus name (`OmarchyNavidrome.instance<pid>`),
as required by the server library. Quickshell discovers the backend by its
identity ("Omarchy Navidrome (navidrome-stream)") and desktop entry. This
lets diagnostic instances coexist without replacing the supervised player's
bus ownership or making the app lose local playback state.

Volume sliders apply while the knob moves; the seek slider still commits on
release so a drag cannot make the player re-buffer per frame. A drag emits an
input event per move, so `Service` coalesces them: the first value is applied
immediately and later ones are queued and flushed at an 80 ms interval
(`Api.VOLUME_FLUSH_MS`). The queued value is only cleared once the player
accepts it, so the position the knob was released at is always the one that
lands. The optimistic slider value is held until the player reports it.

## The Subsonic request core and QML transport

`Subsonic.js` is the pure request core: RFC 1321 MD5 over UTF-8 (validated
against the spec's token example and reference vectors), per-request salt
generation with an injectable source, sorted-stable query building with
repeated parameter keys, server-URL canonicalization (lowered host,
trailing-slash trimming, IPv6 brackets, scheme validation), `subsonic-response`
parsing, defensive shared normalizers for songs/albums/artists/playlists/
lyrics/radio (bounded numbers, strict booleans, string-coerced IDs, id-less
entries dropped), and typed Subsonic error-code categories (40 wrong
credentials, 41/42 token auth rejected, 50 not authorized, 70 not found,
plus generic fallbacks). Verb/param builders cover search windows, album-list
windows with a legacy fallback, artist/album/top-songs/genres parsers,
playlist CRUD (repeated keys for `updatePlaylist`), star/unstar/rating with
clamping, scrobble, bookmark, and `getCoverArt` URL building.

`SubsonicApi.qml` is the QML transport: a job queue with bounded in-flight
requests and mutating-verb serialization, a timeout sweep with abort handles
and `cancelAll`, a redacted diagnostics ring buffer (endpoint names only —
never query strings or `u`/`t`/`s` values), fresh salt per request through
`Subsonic.requestUrl`, typed error surfacing, the mutating-verb uncertainty
contract (any unconfirmed write reports `uncertain`; local fail-fast failures
do not), serial-guarded `search3` cancellation, and the sequential `probe`
(`ping` → `getUser` → `getLicense`, short-circuits on typed failures). OAuth,
token refresh, and any rate-limit cooldown machinery do not exist in this
port. Stale responses can never reach a newer view: generation checks cover
search and page races in the test suite.

## Backend: the `navidrome-stream` engine (protocol v2)

The engine pulls `/rest/stream` from the configured server, decodes the
audio locally with `symphonia`, and writes it through `rodio` to the output
device `config.rs` manages. Its control and state channel is the owner-only
Unix socket at `$XDG_RUNTIME_DIR/omarchy-navidrome/backend.sock`
([docs/BACKEND_PROTOCOL.md](BACKEND_PROTOCOL.md) documents the full protocol):
requests are UTF-8 JSON with a protocol version and id; the engine pushes a
complete redacted state snapshot on connect and on every state change.

Key mechanics, as implemented:

- **`configure_server`** must be sent once per backend connection before any
  playback command, and re-sent after every socket reconnect (the engine
  holds the server identity in memory only). `BackendClient.qml` tracks its
  acknowledgment with a `serverConfigured` flag that resets on reconnect, and
  `Service.qml` re-fires configuration at the ready transition by design.
- **SongRef.** The engine streams by Subsonic id, so a `SongRef` requires
  only `id`; the other fields (title, artists, album, duration, cover art id)
  are display metadata the UI already holds. `load` replaces the queue;
  `add_to_queue` appends.
- **Bounded buffering.** The HTTP downloader pushes 64 KiB chunks into an
  8 MiB bounded buffer (128 × 64 KiB) that blocks the producer while full, and
  symphonia decodes from it into a second bounded decoded-PCM buffer. A slow
  sink therefore back-pressures the download instead of growing memory, and a
  failed consumer aborts the buffer instead of leaking a worker. A dead or
  broken stream recovers through at most `MAX_STREAM_ATTEMPTS` (3) bounded
  mid-stream restarts; beyond that the failure is typed, never an unbounded
  reconnect loop.
- **Server writes run off the audio pipeline.** One dedicated
  `stream-writes` worker thread performs the HTTP calls for scrobbles and
  `savePlayQueue`, so the audio path and the command loop never block on the
  server. A scrobble whose outcome is unknown is logged as uncertain and
  never retried (a double submission would corrupt play counts); a definite
  4xx/5xx is dropped without retry. Log lines name the song id only.
- **Honest scrobbles.** The engine owns the truth of a track's natural end:
  natural end submits `submission=true` exactly once; skip, stop, and a
  queue replaced mid-play submit only when the Audioscrobbler rule holds at
  the moment of leaving (≥ ½ of the track or ≥ 4 minutes heard, whichever
  comes first); a seek decides nothing; engine failures and shutdown never
  scrobble. Play start fires a harmless `submission=false` now-playing hint
  once per front. The `[global] scrobble` setting (validated bool) freezes
  the server's play counts when false.
- **Queue persistence.** After every queue mutation the engine schedules one
  debounced `savePlayQueue` (a burst saves at most once per ~5 s), carrying
  the repeated `id` params, `current` (the current song's **id** per the
  Subsonic contract, not an index), and `position`. A failed or uncertain
  save gets one bounded retry within the same dirty state, then it is
  reported uncertain and dropped. Graceful shutdown performs one final save
  bounded to ~2 s; `main.rs` handles SIGTERM so the teardown — and the final
  save — actually runs on the idle-shutdown path.
- **`get_saved_queue`.** The engine fetches the server's persisted play
  queue (`getPlayQueue`) without loading it and answers SongRefs plus the
  current id, its derived index, and the position in milliseconds. Empty or
  missing server queues parse empty, never an error. The engine never
  auto-loads — the caller decides: `Service.qml` refines the position with
  `getBookmarks` and loads the result paused through the regular v2 `load`
  path, so pressing Play resumes where the last session stopped.
- **Configuration.** `config.rs` reads `backend.conf` (`[global]`,
  TOML) and validates `format` against the exact codec list and
  `max_bit_rate`/`scrobble` types; the `check` subcommand validates the
  configuration file and prints its summary. Queue persistence is
  server-side (`savePlayQueue`); the engine keeps runtime state in memory
  only. The legacy audio-cache keys
  (`no_audio_cache`, `max_cache_size`, `cache_path`) are accepted for config
  compatibility, but the streaming engine keeps everything in its bounded
  in-memory buffers and writes no on-disk audio cache.

## Security contract (as implemented)

- The Navidrome credential set — server base URL, username, password — lives
  in GNOME Keyring under the fixed identity
  `service=quickshell-navidrome, kind=navidrome-credentials` as a single-line
  JSON payload `{v,url,username,password}`. One credential set per install:
  the URL inside the payload is the server identity, so saving again for the
  same server overwrites in place and a different server replaces it. The
  secret travels through `scripts/keyring-store.sh` on stdin only — never
  argv, never logs.
- Every Subsonic request uses token auth: `t = md5(password + salt)` with a
  fresh ≥ 6-char salt per request, `c=omarchy-navidrome`, `f=json`. The
  engine builds its own `stream`/`scrobble`/`getPlayQueue`/`savePlayQueue`
  URLs from the credentials it received via `configure_server`; the
  configuration is never serialized into shared state, echoed in an error
  message, or logged, and callers must not log the arguments either.
- **The authed `getCoverArt` art_url caveat.** The engine puts fully
  authenticated `getCoverArt` URLs (including `u`/`t`/`s`) into the state's
  `art_url` so the UI can feed them straight into `RetryImage`. This is the
  one place credentials ride in a URL, so the shared redaction helper scrubs
  the Subsonic `u`/`t`/`s`/`salt`/`token` query parameters everywhere else,
  and `art_url` must never appear in a log line, error message, or
  diagnostics dump.
- Redaction rules: no tokens, salts, passwords, or usernames in any emitted
  message, on either side of the socket. The QML transport redacts
  diagnostics to endpoint names; the engine's error messages are deliberately
  credential-free.
- The private backend socket is owner-only and consumed messages are never
  re-logged.
- Plain `http://` servers are allowed but flagged (`navidromeUrlInsecure`
  plus a visible "connection is NOT private" setup warning). TLS validation
  is never bypassed. The `formPost` (and, when advertised, `apiKey`)
  OpenSubsonic extensions are feature-detected optimizations, not
  requirements; the port does not yet use form POST, so token-auth
  credentials ride request URLs where the protocol requires them.

## Endpoints used

QML side (`SubsonicApi.qml` over `Subsonic.js`): `ping`, `getUser`, and
`getLicense` (the connection probe); `search3`; `getAlbumList2` (recently
played, frequent, newest, random, `byGenre` windows); `getStarred2`;
`getArtist`; `getAlbum`; `getSong`; `getTopSongs`; `getGenres`;
`getPlaylists`/`getPlaylist`/`createPlaylist`/`updatePlaylist`/
`deletePlaylist`; `star`/`unstar`; `getBookmarks`; `getLyricsBySongId`;
`getInternetRadioStations`; and `getCoverArt` URLs for `RetryImage`.
`setRating` and `scrobble`/`bookmark` write builders exist in `Subsonic.js`
but are not consumed by any view yet.

Backend side (engine): `stream` (with `format`/`maxBitRate` from settings),
`scrobble` (`submission=false` on play start, `submission=true` per the
decision matrix), `getPlayQueue`, `savePlayQueue`, and `getCoverArt` for the
state's `art_url`. Not used: `download`, `jukeboxControl`, podcast endpoints,
and any Last.fm-gated similarity endpoint (`getSimilarSongs2`).

## Runtime requirements

- Omarchy 4 with the Quickshell shell enabled
- a running Navidrome (Subsonic API 1.16.1) server and an account on it
- Omarchy base tools: `secret-tool`, `openssl`, `systemctl`, and Python 3
- Rust (cargo) for the backend build; see [RELEASING.md](RELEASING.md) for
  the local build and checksum story

Omarchy treats any write inside a plugin directory as a change to the plugin
and hot-reloads it, so the backend is compiled to
`$XDG_CACHE_HOME/omarchy-navidrome/target` (override with `CARGO_TARGET_DIR`),
never to the plugin directory itself. This keeps the recursive file watcher
from reloading the plugin — and killing the build — mid-setup. A stale
`backend/target/` left by an older build can be removed; the backend ignores
it.

## Local development

From a checkout on Omarchy 4:

```bash
./scripts/install-local.sh
```

The command validates the manifest, builds and installs the backend, links
the checkout at `~/.config/omarchy/plugins/quickshell.navidrome`, and enables
the bar widget. It refuses to replace an existing plugin.

To install only the playback integration:

```bash
./scripts/setup.sh
```

The guided credential setup is available in the terminal too:

```bash
./scripts/setup-playback.sh
```

Neither install path enables or starts a playback unit at login.

## Verification

```bash
./scripts/test.sh
```

The suite runs Rust tests, `cargo fmt` and Clippy, Qt 6 QML lint and offline
QML tests, Python helper tests, shell-script tests (including the credential
round-trip against a stubbed `secret-tool` and a fake Navidrome server), and
real Quickshell smoke and authorization tests with the actual Omarchy shell
imports.

Resource sampling:

```bash
./scripts/benchmark.sh idle 10
```

See [Benchmark](BENCHMARK.md) for methodology and recorded results. The
benchmark gates carried into the port: no requests on a cached revisit, no
artwork traffic when artwork is disabled, and no periodic feature timers for
closed optional views (the built-in lyrics surface starts with the timer
discipline already in place).

## Complete removal

Run the bundled uninstaller from outside the plugin directory:

```bash
cd "$HOME" && "$HOME/.config/omarchy/plugins/quickshell.navidrome/scripts/uninstall.sh"
```

This removes the plugin and all plugin-owned services, binaries, config,
state, caches, sockets, backups, and keyring entries (including the stored
Navidrome credential set and, for pre-port installs, the legacy refresh-token
entries). See the README's **Remove it completely** section for the
equivalent commands and legacy keybinding check.

## Upstream projects

- [Omarchy](https://github.com/basecamp/omarchy)
- [Navidrome](https://www.navidrome.org)
- [OpenSubsonic API](https://opensubsonic.netlify.app/docs/api-reference/)
