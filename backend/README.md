# Omarchy Navidrome backend

This crate owns the plugin's local playback runtime for a self-hosted
[Navidrome](https://www.navidrome.org) server. It streams from the server's
Subsonic API (`/rest/stream`) with a bounded HTTP download → Symphonia decode
→ rodio playback pipeline; the engine holds the server URL, username, and
Navidrome password in memory only and recomputes `md5(password + salt)` token
auth per request.

The process provides:

- PulseAudio/PipeWire playback through rodio, with on-demand transcoding
  controlled by the `format` and `max_bit_rate` settings;
- a local queue engine driven by the versioned protocol (load, seek, skip,
  volume, shuffle, repeat) with gapless preload of the next song;
- an MPRIS player for Quickshell and other desktop media controls; and
- a versioned newline-delimited JSON protocol on an owner-only Unix socket.

## Streaming details

- Stream URLs follow the Subsonic token-auth contract:
  `t = md5(password + salt)` with a fresh ≥6-character alphanumeric salt per
  request, `v=1.16.1`, `c=omarchy-navidrome`, `f=json`; `format` is omitted
  for source playback (`""`) and `maxBitRate`/`timeOffset` are omitted when
  zero. The URL is used once per request and is never logged; cover-art URLs
  carry the same auth params and are only surfaced to the UI as image
  sources.
- Buffering is bounded on both sides: the download buffer caps at 128 × 64 KiB
  (8 MiB) and the decode queue at about one second of decoded PCM. A stalled
  server therefore backpressures instead of filling memory.
- Readiness is announced (the `Loading` state) before the first audible
  sample; the sink starts after 500 ms of decoded lead-in. The next song's
  download starts when the playhead reaches (duration − 15 s), or at the last
  15 s of buffered audio when the duration is unknown, so its decoded chunks
  queue behind the current track gaplessly.
- Seek re-requests the stream with `timeOffset` at 1-second granularity and
  bumps the seek sequence exactly once so MPRIS emits one `Seeked` signal.
- Position is published once per second from the decode clock (wall clock
  anchored at the first audible sample, frozen while paused, clamped to the
  buffered ceiling), matching the UI timer while Quickshell interpolates
  between updates.
- A server that dies mid-stream gets bounded retries (at most 3, with a short
  growing backoff, each resuming after the buffered playhead) and then a
  typed `stream_unavailable` error. A 4xx answer becomes `stream_rejected`
  without echoing the URL or any credential. Neither is an unbounded
  reconnect loop.
- Symphonia decodes FLAC, MP3, OGG/Vorbis, M4A/AAC, and WAV locally. Symphonia
  has no Opus decoder, so Opus material relies on server-side transcoding
  (set `format` to `mp3`/`flac`/`wav`/`ogg` to force one).

## Engine structure

The current-thread Tokio runtime keeps the socket, MPRIS, and state updates;
the playback pipeline runs on a dedicated std thread that owns the rodio
player and talks to the async side over channels: commands flow in through a
single FIFO (a queued Pause can never be overtaken by a later transport
action, and replies ride the same request machinery as before), and
diff-only playback events flow out into the state watch. If the pipeline
thread ends unexpectedly the process exits with the typed failure codes so
systemd's `RestartPreventExitStatus` stays meaningful. Backend state is held
in one watch channel, unchanged events are discarded, commands are bounded,
and MPRIS emits `Seeked` only for an actual seek event. MPRIS uses the
PID-qualified instance name so a stray second backend cannot take the
supervised process's bus ownership.

Server credentials arrive over the socket with `configure_server` and are
never logged, serialized into state, or echoed in an error message. The
password is consumed by the token-auth builder on every request; the shared
state carries only the username and a `session_connected` flag that flips on
without a network probe (connectivity problems surface as typed stream
errors instead).

Build and verify from the repository root:

```bash
cargo fmt --manifest-path backend/Cargo.toml --all -- --check
cargo test --manifest-path backend/Cargo.toml --locked
cargo clippy --manifest-path backend/Cargo.toml --locked --all-targets -- -D warnings
OMARCHY_NAVIDROME_BUILD_FROM_SOURCE=1 ./scripts/build-backend.sh
```

The backend builds from source into `$XDG_CACHE_HOME/omarchy-navidrome/target`
(override with `CARGO_TARGET_DIR`). Omarchy hot-reloads plugins on any write
inside their directory, so building to a cache path outside the plugin
prevents the shell's recursive watcher from reloading the plugin and killing
the build.

See [the protocol reference](../docs/BACKEND_PROTOCOL.md) for the
compatibility contract and [release process](../docs/RELEASING.md) for the
release requirements. The plugin's supervised backend unit is the only
playback runtime; it is started on demand and never enabled at login.
