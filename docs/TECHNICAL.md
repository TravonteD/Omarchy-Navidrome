# Technical notes

This document keeps implementation, development, and deep troubleshooting
details out of the user-facing README.

## Architecture

Omarchy Navidrome runs as a plugin inside Omarchy's existing `omarchy-shell`
Quickshell process. It provides a shared service, a bar widget, and a lazy-loaded
panel. There is no embedded website, browser engine, second shell process, or
resident helper process.

Local playback state and ordinary controls use MPRIS. Starting playback on this
computer uses the backend's private Unix socket (`load`, `add_to_queue`) when
that process is running. All browsing, search, stars, and playlist verbs go
through the Subsonic JSON API (protocol v2 below); there is no second, remote
playback path.

Local audio runs in the plugin-owned `omarchy-navidrome-backend` Rust process,
supervised by a static systemd user unit that is never enabled at login. It is
the only playback runtime: it owns configuration, the audio cache, the Subsonic
stream/scrobble client, MPRIS, lifecycle, and a stable private Unix-socket
boundary. The app starts the unit whenever its full player or mini-player is
open or when you play on this computer. Once every player surface closes, it
stops after the configured idle period; 0 keeps it available indefinitely.

The unit sets `PULSE_LATENCY_MSEC=30` for local playback and caps the backend's
tokio runtime at two workers so network fetching, preloading, and blocking
decoder work can overlap while the control loop stays responsive. Quickshell
interpolates MPRIS position locally, so the backend publishes one authoritative
position update per second instead of four.

MPRIS uses a PID-qualified instance bus name (`OmarchyNavidrome.instance<pid>`),
as required by the server library. Quickshell discovers the backend by its
identity ("Omarchy Navidrome (navidrome-stream)") and desktop entry. This lets
diagnostic instances coexist without replacing the supervised player's bus
ownership or making the app lose local playback state.

Volume sliders apply while the knob moves; the seek slider still commits on
release so a drag cannot make the player re-buffer per frame. A drag emits an
input event per move, so `Service` coalesces them: the first value is applied
immediately and later ones are queued and flushed at an 80 ms interval
(`Api.VOLUME_FLUSH_MS`). The queued value is only cleared once the player
accepts it, so the position the knob was released at is always the one that
lands. The optimistic slider value is held until the player reports it.

## Runtime requirements

- Omarchy 4 with the Quickshell shell enabled
- a running Navidrome (Subsonic API 1.16.1) server and an account on it
- the exact-commit attested plugin backend or a local source build
- Omarchy base tools: `secret-tool`, `openssl`, `systemctl`, and Python 3

The verified-release fast path also uses `curl` and GitHub CLI when available;
neither is trusted as a bypass when provenance verification cannot complete.

Omarchy's plugin installer deliberately clones and validates plugins without
running install hooks or privileged code. The enabled plugin therefore prepares
local playback on first load. It downloads the raw backend for the current
architecture from the matching version tag, checks the release checksum, then
requires GitHub's signed build provenance to match this repository, the pinned
release workflow, the exact tag and tagged commit, and a GitHub-hosted runner.
The tagged commit must be an ancestor of the checkout, and the backend source
and Rust toolchain must be unchanged between them. This permits later UI and
documentation commits without weakening the backend source binding. A
same-release checksum alone is never accepted as provenance.

If `gh` is unavailable or any download, checksum, identity, or attestation
check fails, the artifact is not executed. Setup instead builds `Cargo.lock`
from the reviewed source with the available Cargo when present. Configuration,
verified downloads, local builds, and user units themselves need no privilege.

Omarchy treats any write inside a plugin directory as a change to the plugin and
hot-reloads it, so the backend is compiled to
`$XDG_CACHE_HOME/omarchy-navidrome/target` (override with `CARGO_TARGET_DIR`),
never to the plugin directory itself. This keeps the recursive file watcher
from reloading the plugin — and killing the build — mid-setup. A stale
`backend/target/` left by an older build can be removed; the backend ignores it.

## Authentication

Navidrome credentials are one set per install: the server base URL, a
username, and the account password. The password is stored in GNOME Keyring
through `scripts/keyring-store.sh` (secret on stdin only, never argv, never
logs) under the fixed identity `service=quickshell-navidrome,
kind=navidrome-credentials` as a single-line JSON payload
`{v,url,username,password}`; the URL inside the payload is the server
identity, so saving again for the same server overwrites in place and a
different server replaces it. Reusable state lives only in the keyring and in
the backend's process memory — credentials passed across the private socket
are consumed and never re-logged.

Every Subsonic request uses token auth: `t = md5(password + salt)` with a
fresh salt (>= 6 chars) per request, `c=omarchy-navidrome`, `f=json`. The
QMD-side transport (`SubsonicApi.qml`) builds URLs through the tested
`Subsonic.js` core, serializes mutating verbs, redacts diagnostics to
endpoint names only, and maps typed error codes (40 wrong credentials, 41/42
token rejection, 50 not authorized, 70 not found). The stream engine builds
its own `stream`/`scrobble`/`getPlayQueue` URLs from the credentials it
received via `configure_server`; they never appear in logs or state files.

Plain `http://` servers are allowed but flagged: the credential model keeps a
`navidromeUrlInsecure` warning flag and the first-run setup prints a plain
"connection is NOT private" warning. TLS validation is never bypassed.

The `formPost` (and, when advertised, `apiKey`) OpenSubsonic extensions are
feature-detected optimizations, not requirements.

## Local development

From a checkout on Omarchy 4:

```bash
./scripts/install-local.sh
```

The command validates the manifest, installs the user-level playback files,
links the checkout at
`~/.config/omarchy/plugins/quickshell.navidrome`, and enables the bar widget. It
refuses to replace an existing plugin.

To install only the playback integration:

```bash
./scripts/setup.sh
```

Neither path enables or starts a playback unit at login.

## Verification

```bash
./scripts/test.sh
```

The suite runs Omarchy manifest validation, Qt 6 QML lint, offline Qt tests with
mocked authentication responses, shell-script tests, configuration checks, and a
forbidden-heavyweight-dependency scan.

Resource sampling:

```bash
./scripts/benchmark.sh idle 10
```

See [Benchmark](BENCHMARK.md) for methodology and recorded results.

## Complete removal

Run the bundled uninstaller from outside the plugin directory:

```bash
cd "$HOME" && "$HOME/.config/omarchy/plugins/quickshell.navidrome/scripts/uninstall.sh"
```

This removes the plugin and all plugin-owned services, binaries, config, state,
caches, sockets, backups, and keyring entries (including the stored Navidrome
credential set and the pre-port Spotify-era refresh tokens). See the README's
**Remove it completely** section for the equivalent commands and legacy
keybinding check.

## Upstream projects

- [Omarchy](https://github.com/basecamp/omarchy)
- [Navidrome](https://www.navidrome.org)
- [OpenSubsonic API](https://opensubsonic.netlify.app/docs/api-reference/)
