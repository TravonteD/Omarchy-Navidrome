# Backend protocol

The plugin backend listens at
`$XDG_RUNTIME_DIR/omarchy-navidrome/backend.sock`. The socket and every message
are private to the current user. The backend is a Subsonic HTTP streaming
engine (`navidrome-stream`): it pulls `/rest/stream` from the configured
Navidrome server, decodes the audio locally, and drives the output sink. The
socket is only the control and state channel. Transport is UTF-8 JSON, one
object per line.

## Envelope

Protocol version 2 requests carry the protocol version and a caller-chosen
integer id, with the command flattened into the object:

```json
{"v":2,"id":7,"command":"pause"}
```

A successful response keeps that id:

```json
{"type":"response","v":2,"id":7,"ok":true,"result":{}}
```

Failures set `ok` to false and return a stable machine-readable `code` plus a
human-readable `message`. An unsupported protocol version is rejected with the
`unsupported_version` code rather than guessed:

```json
{"type":"response","v":2,"id":7,"ok":false,
 "error":{"code":"unsupported_version","message":"protocol version 1 is unsupported; expected 2"}}
```

The server pushes a complete snapshot on connection and whenever playback
state changes:

```json
{"type":"event","v":2,"event":"state_changed","state":{"lifecycle":"ready"}}
```

The abbreviated example omits the remaining state fields. A real snapshot
contains the protocol and backend versions, `engine` (always
`"navidrome-stream"`), lifecycle, session connectivity, the configured
username, playback status, the current track, position in milliseconds, a
16-bit volume, shuffle/repeat state, a monotonically increasing `generation`,
and a redacted error string. When the error needs dedicated UI, the snapshot
also includes a stable `error_code` (see the error table below).

### Track shape

The state's `track` object identifies songs by their Subsonic id (protocol
v1 used `uri`; that field was renamed in v2):

```json
{
  "id": "tr-123",
  "title": "Song",
  "artists": ["Artist"],
  "album": "Album",
  "art_url": "https://nav.example/rest/getCoverArt?id=cr-9&u=alice&t=…&s=…",
  "duration_ms": 180000,
  "item_type": "track"
}
```

**`art_url` caveat.** `art_url` is a fully authenticated `getCoverArt` URL that
the backend builds (including the per-request `u`/`t`/`s` token parameters) so
the UI can feed it straight into `RetryImage`. It is the one place credentials
ride in a URL, so it must never appear in a log line, an error message, or a
diagnostics dump; the shared redaction helper scrubs the Subsonic token
parameters exactly for this reason.

## Commands

Version 2 commands are:

- `hello`, `ping`, and `get_state`;
- `play`, `pause`, `toggle`, `stop`, `next`, and `previous`;
- `seek` with `position_ms` and `set_volume` with a value from 0 through
  65535;
- `set_shuffle` and `set_repeat` (`off`, `context`, or `track`);
- `configure_server`;
- `add_to_queue` with a `song` object;
- `load` with `songs` plus optional `offset_index`, `position_ms`, and `play`
  (true by default); and
- `get_saved_queue`.

### SongRef (`load` and `add_to_queue`)

The engine streams by id, so on a `SongRef` only `id` (the Subsonic song id)
is required; every other field is metadata the UI already holds, used for
immediate display while the first bytes buffer. Empty values are legal:

```json
{"id":"tr-123","title":"Song","artists":["Artist","Second"],
 "album":"Album","duration_ms":180000,"cover_art":"cr-9","track":3}
```

```json
{"id":"tr-42"}
```

### configure_server

```json
{"v":2,"id":1,"command":"configure_server",
 "url":"https://nav.example","username":"alice","password":"…"}
```

Must be sent once per backend connection **before** any `load` or
`add_to_queue`, and re-sent after a reconnect (the engine holds the identity in
memory only). The configuration is kept in engine memory: it is never
serialized into shared state, never echoed in an error message, and never
logged. Callers must not log the arguments either.

```json
{"type":"response","v":2,"id":1,"ok":true,"result":{}}
```

### load

```json
{"v":2,"id":9,"command":"load",
 "songs":[{"id":"tr-123","title":"Song"},{"id":"tr-42"}],
 "offset_index":1,"position_ms":0,"play":true}
```

Replaces the queue with `songs` (at least one; the engine answers
`invalid_request` otherwise) and starts the song at `offset_index` (defaults
to 0; an out-of-range index is treated as 0). `position_ms` starts that song
at the given offset in milliseconds; `play` defaults to true and a false value
leaves the queue loaded but paused.

### add_to_queue

```json
{"v":2,"id":10,"command":"add_to_queue","song":{"id":"tr-77","title":"B-side"}}
```

Appends the song to the end of the current queue.

### get_saved_queue

```json
{"v":2,"id":11,"command":"get_saved_queue"}
```

Reads the play queue the server persists for this user (`getPlayQueue`)
**without loading it** — the engine never auto-restores; the caller decides
what to do with the result. The response result carries the queue as
SongRefs plus the current song and its position:

```json
{"type":"response","v":2,"id":11,"ok":true,"result":{
  "songs":[{"id":"tr-1","title":"Song","artists":["Artist"],"album":"Album",
            "duration_ms":180000,"cover_art":"cr-1","track":3}],
  "current_index": 2,
  "current_id": "tr-3",
  "position_ms": 42000
}}
```

- `songs` is the persisted queue in server order as SongRefs (the same shape
  `load` accepts). Subsonic durations arrive in seconds and are converted to
  `duration_ms`; id-less entries are dropped.
- `current_id` is the current song's id exactly as the server named it (the
  Subsonic play-queue contract stores the **id**, not an index; it may be
  absent).
- `current_index` is the position of `current_id` in `songs`, 0 when the
  server named no current song or the id is no longer in the list.
- `position_ms` is the position within the current song, 0 when absent.

An empty or missing server-side queue parses to
`{"songs":[],"current_index":0,"current_id":"","position_ms":0}` — never an
error. Parsing is defensive throughout (missing nodes are empty, numbers-as-
strings are accepted, hostile values clamp to zero). Requires a configured
server: without one the command answers `missing_credentials`. A failed
server read answers `stream_unavailable`. The fetch runs off the playback
pipeline on the engine's write thread, so the command loop and the audio
never block on the server.

## Server writes (scrobble and play-queue persistence)

The engine owns the truth of a track's natural end, so it also owns the
honest-scrobble contract:

- **Play start** of every track fires `scrobble?id=…&submission=false` once
  (harmless: it only refreshes the server's now-playing hint, never the play
  count).
- **Natural end** — the queue drained the current song into the next one and
  the decoder reached the true end of stream — fires
  `submission=true` exactly once, regardless of the played fraction.
- **Skip (next/previous), stop, and a queue replaced mid-play** fire
  `submission=true` only when the Audioscrobbler rule holds at the moment of
  leaving: at least half the track was heard, or at least four minutes of it
  (whichever comes first). Below both thresholds the submission is dropped
  silently. A worker that died mid-stream leaves a partially heard song even
  when its buffered audio finished playing, so it follows this rule too.
  Engine failures (rejected/undecodable/unavailable stream) never scrobble.
- **Seeking** stays on the same track and decides nothing.

Every scrobble rides the engine's off-pipeline write thread: the HTTP call
can never stall audio or the command loop. Under the uncertainty contract, a
scrobble whose outcome is unknown (timeout or transport failure mid-write)
is treated as uncertain and **never retried** — a second submission would
corrupt the play count. A definite failure (4xx/5xx) is dropped without
retry as well. Log lines name the song id only: never a URL, token, salt,
password, or status code.

The engine also persists the queue with `savePlayQueue` after every queue
mutation (`load`, `add_to_queue`, natural advance, skip, shuffle) and once
more on graceful shutdown, debounced so a burst of mutations saves at most
once per ~5 seconds. The save carries the queue's repeated `id` parameters,
`current` (the current song's id per the Subsonic contract), and `position`
in milliseconds. `savePlayQueue` is idempotent, so a failed or uncertain
save may be retried **once** within the same dirty state (a short backoff),
then it is reported uncertain and dropped — never an unbounded retry loop.
The final shutdown save is bounded to ~2 seconds; an unconfirmed final save
is logged as uncertain, never retried.

## Errors

| code | meaning |
| --- | --- |
| `unsupported_version` | request used a protocol version other than 2 |
| `invalid_request` | malformed frame, unknown command, or invalid field (for example an empty `songs` list) |
| `missing_credentials` | `load`/`add_to_queue` (or another playback command) arrived before `configure_server` |
| `invalid_configuration` | `configure_server` received a unusable URL or empty username/password |
| `stream_rejected` | Navidrome refused the stream request (bad credentials or permissions); no retry is attempted |
| `stream_unavailable` | the stream could not be built, resumed, or decoded, or a server read (saved play queue) failed |
| `engine_unavailable` / `engine_busy` | the engine task is gone or its command queue is full |
| `serialization_error` | a `get_state` snapshot could not be serialized |

Error messages are deliberately credential-free: they never echo the
configured URL, username, password, or a stream status code that could carry
session detail.

## Versioning

Adding an optional field or command is backward-compatible. Removing or
renaming a field (v2 renamed `Track.uri` to `Track.id` and replaced `load`'s
`context_uri`/`uris` bodies with `songs`), changing its meaning, or changing
framing requires a new protocol version. The Quickshell service uses this
socket to configure the server, start local playback (`load`), append to the
local queue, and read the server-persisted queue (`get_saved_queue`). Clients
must retain the Subsonic API/MPRIS fallback behavior when the socket is
absent or reports an unsupported version.
