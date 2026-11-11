//! Subsonic stream endpoint helpers: request URL building with token auth,
//! bounded buffering between the HTTP download and the decoder, and the
//! sample conversion helpers that map decoded audio onto the output device.
//!
//! Credential rules: [`AuthPair`] never implements `Debug`/`Display`, every
//! builder error omits the URL, and no function here logs. Callers may only
//! log song ids and playback state, never a built URL.

use std::collections::VecDeque;
use std::io::{Read, Seek, SeekFrom};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use md5::{Digest, Md5};
use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::{CODEC_TYPE_NULL, DecoderOptions};
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSource;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;
use symphonia::default::{get_codecs, get_probe};

/// Subsonic client id announced as `c` on every request.
pub const CLIENT_ID: &str = "omarchy-navidrome";
/// Subsonic API version announced as `v`.
pub const API_VERSION: &str = "1.16.1";
/// Minimum salt length Navidrome accepts for token auth.
pub const MIN_SALT_LENGTH: usize = 6;
/// Length of the salts this backend generates (fresh per request).
pub const GENERATED_SALT_LENGTH: usize = 8;
/// Download chunk size pushed into the bounded buffer.
pub const DOWNLOAD_CHUNK_BYTES: usize = 64 * 1024;
/// Bounded download buffer: `MAX_BUFFER_CHUNKS` chunks of
/// `DOWNLOAD_CHUNK_BYTES` bytes, i.e. 128 × 64 KiB = 8 MiB. When full, the
/// downloader blocks until the decoder consumes data.
pub const MAX_BUFFER_CHUNKS: usize = 128;
/// Decoded PCM lead-in required before the sink starts (readiness is
/// announced before the first audible sample, then playback waits for this
/// much decoded audio).
pub const PREBUFFER_MS: u64 = 500;
/// Look-ahead at which the next song's download starts.
pub const PRELOAD_LOOKAHEAD_MS: u64 = 15_000;
/// Bounded mid-stream retries before a typed `stream_unavailable` error.
pub const MAX_STREAM_ATTEMPTS: u8 = 3;
/// Base backoff between stream retry attempts, multiplied by the attempt
/// number (250 ms, 500 ms, 750 ms).
pub const RETRY_BACKOFF_MS: u64 = 250;
/// Allowed `format` values, empty string means "source" (omit the param).
pub const FORMATS: &[&str] = &["", "mp3", "flac", "wav", "ogg", "opus", "aac"];
/// Read-ahead window of [`HttpRangeSource`]: one Range GET fetches at most
/// this many bytes into memory. Sequential reads are served from the window;
/// a `Seek` outside it issues a new Range GET from the target offset, so the
/// memory a decode holds stays bounded no matter how far symphonia seeks
/// through a container (a 256 KiB window comfortably covers the box-header
/// hops an MP4 walk needs and keeps sequential decode cheap).
pub const RANGE_WINDOW_BYTES: usize = 256 * 1024;

// ---------------------------------------------------------------------------
// Salts and token auth
// ---------------------------------------------------------------------------

/// Injectable salt source so tests can pin URLs to known values.
pub trait SaltSource: Send + Sync + 'static {
    fn salt(&self) -> String;
}

/// Production salt source: a fresh random alphanumeric salt per request.
#[derive(Clone, Copy, Debug, Default)]
pub struct RandomSalt;

impl SaltSource for RandomSalt {
    fn salt(&self) -> String {
        // Fresh alphanumeric salt per request; retries never reuse one.
        (0..GENERATED_SALT_LENGTH)
            .map(|_| fastrand::alphanumeric())
            .collect()
    }
}

/// Deterministic salt source for tests and pinned URL fixtures.
#[allow(dead_code)] // test/fixture helper; the production source is RandomSalt
#[derive(Clone, Debug)]
pub struct FixedSalt(pub String);

impl SaltSource for FixedSalt {
    fn salt(&self) -> String {
        self.0.clone()
    }
}

/// `t = md5(password + salt)`, lowercase hex, per the Subsonic token auth
/// contract.
pub fn auth_token(password: &str, salt: &str) -> String {
    let mut hasher = Md5::new();
    hasher.update(password.as_bytes());
    hasher.update(salt.as_bytes());
    hex_lower(&hasher.finalize())
}

fn hex_lower(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push(char::from_digit(u32::from(byte >> 4), 16).unwrap());
        out.push(char::from_digit(u32::from(byte & 0x0f), 16).unwrap());
    }
    out
}

/// Username and Navidrome password. Held in engine memory only.
pub struct AuthPair {
    pub username: String,
    pub password: String,
}

impl AuthPair {
    pub fn new(username: impl Into<String>, password: impl Into<String>) -> Self {
        Self {
            username: username.into(),
            password: password.into(),
        }
    }
}

/// Manual `Debug` so a stray `{auth:?}` can never print the password.
impl std::fmt::Debug for AuthPair {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("AuthPair { username: [redacted], password: [redacted] }")
    }
}

/// The auth parameters shared by every Subsonic request, in a stable order.
pub fn auth_query(auth: &AuthPair, salt: &str) -> String {
    format!(
        "u={}&t={}&s={}&v={}&c={}&f=json",
        percent_encode(&auth.username),
        auth_token(&auth.password, salt),
        percent_encode(salt),
        API_VERSION,
        CLIENT_ID,
    )
}

fn query_param(key: &str, value: &str) -> String {
    format!("{key}={}", percent_encode(value))
}

/// Percent-encode a query component (RFC 3986 unreserved characters pass).
pub fn percent_encode(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.as_bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*byte as char)
            }
            other => {
                out.push('%');
                out.push(
                    char::from_digit(u32::from(other >> 4), 16)
                        .unwrap()
                        .to_ascii_uppercase(),
                );
                out.push(
                    char::from_digit(u32::from(other & 0x0f), 16)
                        .unwrap()
                        .to_ascii_uppercase(),
                );
            }
        }
    }
    out
}

/// Reject base URLs without an http(s) scheme. The error never contains the
/// URL.
pub fn validate_base_url(value: &str) -> Result<(), &'static str> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return Err("server URL is empty");
    }
    let lower = trimmed.to_ascii_lowercase();
    if !(lower.starts_with("http://") || lower.starts_with("https://")) {
        return Err("server URL must start with http:// or https://");
    }
    let rest = &trimmed[trimmed.find("://").unwrap() + 3..];
    let host = rest.split(['/', '?', '#']).next().unwrap_or("");
    if host.is_empty() {
        return Err("server URL has no host");
    }
    Ok(())
}

fn join_endpoint(base_url: &str, endpoint: &str, query: &str) -> Result<String, String> {
    validate_base_url(base_url).map_err(|reason| reason.to_string())?;
    let base = base_url.trim_end_matches('/');
    Ok(format!("{base}/rest/{endpoint}?{query}"))
}

/// `<base>/rest/stream?id=...&<auth>&[format=...][&maxBitRate=...][&timeOffset=...]`
///
/// `format` empty means "source" and is omitted; `max_bit_rate` 0 means no
/// cap and is omitted; `time_offset_secs` 0 (start of track) is omitted.
pub fn build_stream_url(
    base_url: &str,
    auth: &AuthPair,
    salt: &str,
    song_id: &str,
    format: &str,
    max_bit_rate: u16,
    time_offset_secs: u64,
) -> Result<String, String> {
    if salt.chars().count() < MIN_SALT_LENGTH {
        return Err("stream salt is too short".to_string());
    }
    let mut query = vec![query_param("id", song_id), auth_query(auth, salt)];
    if !format.is_empty() {
        if !FORMATS.contains(&format) {
            return Err(format!("unsupported stream format {format:?}"));
        }
        query.push(query_param("format", format));
    }
    if max_bit_rate > 0 {
        query.push(format!("maxBitRate={max_bit_rate}"));
    }
    if time_offset_secs > 0 {
        query.push(format!("timeOffset={time_offset_secs}"));
    }
    join_endpoint(base_url, "stream", &query.join("&"))
}

/// `<base>/rest/getCoverArt?id=...&<auth>`. The returned URL carries the
/// token auth params and is only ever surfaced as the track's `art_url` for
/// image loading; it must never be logged.
pub fn build_cover_art_url(
    base_url: &str,
    auth: &AuthPair,
    salt: &str,
    cover_art_id: &str,
) -> Result<String, String> {
    if cover_art_id.is_empty() {
        return Ok(String::new());
    }
    let query = [query_param("id", cover_art_id), auth_query(auth, salt)].join("&");
    join_endpoint(base_url, "getCoverArt", &query)
}

/// `<base>/rest/scrobble?id=...&submission=true|false&<auth>`.
///
/// `submission=true` is the play-count write; `submission=false` only marks a
/// now-playing hint and never touches play counts. The URL is used once by
/// the caller and never logged.
pub fn build_scrobble_url(
    base_url: &str,
    auth: &AuthPair,
    salt: &str,
    song_id: &str,
    submission: bool,
) -> Result<String, String> {
    if salt.chars().count() < MIN_SALT_LENGTH {
        return Err("scrobble salt is too short".to_string());
    }
    let query = [
        query_param("id", song_id),
        format!("submission={}", if submission { "true" } else { "false" }),
        auth_query(auth, salt),
    ]
    .join("&");
    join_endpoint(base_url, "scrobble", &query)
}

/// `<base>/rest/savePlayQueue?id=...&id=...&current=...&[position=...]&<auth>`.
///
/// Per the Subsonic contract, `current` is the **id of the currently playing
/// song** (it must be one of the repeated `id` values), not a queue index.
/// `position_ms` is the position within that song; `None`/0 omits the
/// parameter, which servers treat as position 0.
pub fn build_save_play_queue_url(
    base_url: &str,
    auth: &AuthPair,
    salt: &str,
    song_ids: &[String],
    current_id: &str,
    position_ms: Option<u64>,
) -> Result<String, String> {
    if salt.chars().count() < MIN_SALT_LENGTH {
        return Err("play queue salt is too short".to_string());
    }
    if song_ids.is_empty() {
        return Err("the play queue has no songs to save".to_string());
    }
    let mut query: Vec<String> = song_ids.iter().map(|id| query_param("id", id)).collect();
    query.push(query_param("current", current_id));
    if let Some(position) = position_ms.filter(|value| *value > 0) {
        query.push(format!("position={position}"));
    }
    query.push(auth_query(auth, salt));
    join_endpoint(base_url, "savePlayQueue", &query.join("&"))
}

/// `<base>/rest/getPlayQueue?<auth>` — the read side of play-queue
/// persistence.
pub fn build_get_play_queue_url(
    base_url: &str,
    auth: &AuthPair,
    salt: &str,
) -> Result<String, String> {
    if salt.chars().count() < MIN_SALT_LENGTH {
        return Err("play queue salt is too short".to_string());
    }
    join_endpoint(base_url, "getPlayQueue", &auth_query(auth, salt))
}

// ---------------------------------------------------------------------------
// Non-playback server reads and writes (scrobble, play queue)
// ---------------------------------------------------------------------------

/// Outcome of one non-playback write (scrobble, queue save). By construction
/// it carries no URL, no status code, and no credential material, so it is
/// safe to pass to any log line.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WriteOutcome {
    /// 2xx: the server confirmed the write.
    Completed,
    /// 4xx/5xx: a definite failure.
    Rejected,
    /// Transport-level failure (timeout, broken connection): the write may
    /// have landed. Callers treat this as uncertain.
    Transport,
}

/// Fire one GET-style Subsonic write and classify the outcome. The URL is
/// used once for the request and never appears in the result.
pub fn send_write(agent: &ureq::Agent, url: &str) -> WriteOutcome {
    match agent.get(url).call() {
        Ok(_) => WriteOutcome::Completed,
        Err(ureq::Error::Status(_, _)) => WriteOutcome::Rejected,
        Err(_) => WriteOutcome::Transport,
    }
}

/// A defensively parsed `getPlayQueue` response. Missing nodes parse to an
/// empty queue; nothing here can panic on hostile input.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct ParsedPlayQueue {
    pub songs: Vec<crate::protocol::SongRef>,
    /// The current song's id exactly as the server named it ("" when absent).
    pub current_id: String,
    /// Position of `current_id` in `songs`, 0 when absent or not found.
    pub current_index: usize,
    /// Position within the current song, in milliseconds.
    pub position_ms: u64,
}

/// Read `getPlayQueue` and parse it defensively. The URL is used once and
/// never appears in the outcome.
pub fn fetch_play_queue(agent: &ureq::Agent, url: &str) -> ReadOutcome {
    match agent.get(url).call() {
        Ok(response) if (200..300).contains(&response.status()) => {
            let mut body = String::new();
            let _ = response.into_reader().read_to_string(&mut body);
            ReadOutcome::Parsed(parse_play_queue(&body))
        }
        Ok(_) => ReadOutcome::Rejected,
        Err(ureq::Error::Status(_, _)) => ReadOutcome::Rejected,
        Err(_) => ReadOutcome::Transport,
    }
}

/// Outcome of one `getPlayQueue` read. Carries no URL or credential material.
#[derive(Debug, Clone, PartialEq)]
pub enum ReadOutcome {
    Parsed(ParsedPlayQueue),
    Rejected,
    Transport,
}

fn json_text(value: Option<&serde_json::Value>) -> String {
    match value {
        Some(serde_json::Value::String(text)) => text.clone(),
        Some(serde_json::Value::Number(number)) => number.to_string(),
        _ => String::new(),
    }
}

fn json_u64(value: Option<&serde_json::Value>) -> u64 {
    match value {
        Some(serde_json::Value::Number(number)) => number.as_u64().unwrap_or(0),
        // Some servers send numbers as strings; both shapes must parse.
        Some(serde_json::Value::String(text)) => text.trim().parse::<u64>().unwrap_or(0),
        _ => 0,
    }
}

/// One `getPlayQueue` entry shaped into a SongRef. Durations arrive in
/// seconds; an entry without an id is dropped by the caller.
fn parse_queue_entry(entry: &serde_json::Value) -> Option<crate::protocol::SongRef> {
    let id = json_text(entry.get("id"));
    if id.trim().is_empty() {
        return None;
    }
    let mut song = crate::protocol::SongRef {
        id,
        ..crate::protocol::SongRef::default()
    };
    song.title = json_text(entry.get("title"));
    let artist = json_text(entry.get("artist"));
    if !artist.is_empty() {
        song.artists = vec![artist];
    }
    song.album = json_text(entry.get("album"));
    song.duration_ms = json_u64(entry.get("duration"))
        .saturating_mul(1000)
        .min(u64::from(u32::MAX)) as u32;
    song.cover_art = json_text(entry.get("coverArt"));
    let track = json_u64(entry.get("track"));
    song.track = (track > 0).then(|| track.min(u64::from(u32::MAX)) as u32);
    Some(song)
}

/// Defensive `getPlayQueue` JSON parsing: a failed status, a missing
/// `playQueue` node, and id-less entries all simply mean "nothing saved";
/// this never returns an error and never panics.
pub fn parse_play_queue(body: &str) -> ParsedPlayQueue {
    let value: serde_json::Value = serde_json::from_str(body).unwrap_or(serde_json::Value::Null);
    let root = value.get("subsonic-response").unwrap_or(&value);
    if root.get("status").and_then(|status| status.as_str()) != Some("ok") {
        return ParsedPlayQueue::default();
    }
    let Some(queue) = root.get("playQueue") else {
        return ParsedPlayQueue::default();
    };
    let mut songs = Vec::new();
    if let Some(entries) = queue.get("entry") {
        let items: Vec<&serde_json::Value> = match entries {
            serde_json::Value::Array(items) => items.iter().collect(),
            item => vec![item],
        };
        for item in items {
            if let Some(song) = parse_queue_entry(item) {
                songs.push(song);
            }
        }
    }
    let current_id = json_text(queue.get("current"));
    let current_index = songs
        .iter()
        .position(|song| song.id == current_id)
        .unwrap_or(0);
    ParsedPlayQueue {
        songs,
        current_id,
        current_index,
        position_ms: json_u64(queue.get("position")),
    }
}

// ---------------------------------------------------------------------------
// Bounded raw-chunk buffer (HTTP downloader → symphonia decoder)
// ---------------------------------------------------------------------------

struct RawInner {
    chunks: VecDeque<Vec<u8>>,
    closed: bool,
    aborted: bool,
}

/// Bounded FIFO of raw byte chunks with blocking backpressure on the producer
/// and abort support for the consumer.
pub struct BoundedBuffer {
    inner: Mutex<RawInner>,
    space: Condvar,
    data: Condvar,
    capacity_chunks: usize,
}

impl BoundedBuffer {
    pub fn new(capacity_chunks: usize) -> Self {
        Self {
            inner: Mutex::new(RawInner {
                chunks: VecDeque::new(),
                closed: false,
                aborted: false,
            }),
            space: Condvar::new(),
            data: Condvar::new(),
            capacity_chunks,
        }
    }

    /// Push a chunk, blocking while the buffer is full. Returns `Err` once
    /// the consumer aborted the buffer.
    pub fn push(&self, chunk: Vec<u8>) -> Result<(), BufferClosed> {
        let mut inner = self.inner.lock().unwrap();
        loop {
            if inner.aborted {
                return Err(BufferClosed);
            }
            if inner.closed {
                return Err(BufferClosed);
            }
            if inner.chunks.len() < self.capacity_chunks {
                break;
            }
            inner = self.space.wait(inner).unwrap();
        }
        inner.chunks.push_back(chunk);
        self.data.notify_one();
        Ok(())
    }

    /// Pop a chunk, blocking until data is available or the buffer closed.
    /// Returns `None` at end of stream (closed or aborted).
    pub fn pop(&self) -> Option<Vec<u8>> {
        let mut inner = self.inner.lock().unwrap();
        loop {
            if let Some(chunk) = inner.chunks.pop_front() {
                self.space.notify_one();
                return Some(chunk);
            }
            if inner.closed || inner.aborted {
                return None;
            }
            inner = self.data.wait(inner).unwrap();
        }
    }

    /// Producer finished successfully: readers drain what is left, then see
    /// end of stream.
    pub fn close(&self) {
        let mut inner = self.inner.lock().unwrap();
        inner.closed = true;
        self.data.notify_all();
        self.space.notify_all();
    }

    /// Producer failed (network). Same as `close` for readers.
    pub fn fail(&self) {
        self.close();
    }

    /// Consumer abort: unblocks a blocked producer with an error and ends
    /// the stream for readers.
    pub fn abort(&self) {
        let mut inner = self.inner.lock().unwrap();
        inner.aborted = true;
        self.data.notify_all();
        self.space.notify_all();
    }
}

#[derive(Debug, PartialEq, Eq)]
pub struct BufferClosed;

// ---------------------------------------------------------------------------
// Bounded decoded-PCM buffer (decoder → pipeline thread)
// ---------------------------------------------------------------------------

/// A chunk of decoded, device-shaped PCM plus its frame count.
pub struct PcmChunk {
    pub frames: usize,
    pub samples: Vec<f32>,
}

struct PcmInner {
    chunks: VecDeque<PcmChunk>,
    closed: bool,
    aborted: bool,
    frames: usize,
}

/// Bounded FIFO of decoded PCM frames. Capacity is `max_frames` (about two
/// seconds of audio); the decoder blocks when full, which also bounds how far
/// ahead of the playhead decoding runs.
pub struct PcmBuffer {
    inner: Mutex<PcmInner>,
    space: Condvar,
    data: Condvar,
    max_frames: usize,
}

impl PcmBuffer {
    pub fn new(max_frames: usize) -> Self {
        Self {
            inner: Mutex::new(PcmInner {
                chunks: VecDeque::new(),
                closed: false,
                aborted: false,
                frames: 0,
            }),
            space: Condvar::new(),
            data: Condvar::new(),
            max_frames,
        }
    }

    pub fn push(&self, chunk: PcmChunk) -> Result<(), BufferClosed> {
        let mut inner = self.inner.lock().unwrap();
        loop {
            if inner.aborted || inner.closed {
                return Err(BufferClosed);
            }
            if inner.frames + chunk.frames <= self.max_frames {
                break;
            }
            inner = self.space.wait(inner).unwrap();
        }
        inner.frames += chunk.frames;
        inner.chunks.push_back(chunk);
        self.data.notify_one();
        Ok(())
    }

    /// Non-blocking pop for the consumer side (pipeline thread).
    pub fn try_pop(&self) -> Option<PcmChunk> {
        let mut inner = self.inner.lock().unwrap();
        if let Some(chunk) = inner.chunks.pop_front() {
            inner.frames -= chunk.frames;
            self.space.notify_one();
            return Some(chunk);
        }
        None
    }

    pub fn close(&self) {
        let mut inner = self.inner.lock().unwrap();
        inner.closed = true;
        self.data.notify_all();
        self.space.notify_all();
    }

    pub fn abort(&self) {
        let mut inner = self.inner.lock().unwrap();
        inner.aborted = true;
        inner.closed = true;
        self.data.notify_all();
        self.space.notify_all();
    }
}

// ---------------------------------------------------------------------------
// HTTP download
// ---------------------------------------------------------------------------

/// Outcome of one stream download attempt. Never carries the URL or any
/// credential material.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DownloadOutcome {
    /// Response body fully consumed.
    Completed,
    /// Server answered 4xx: bad credentials or permissions.
    Rejected { status: u16 },
    /// Server answered 5xx or another transport-level failure.
    Failed,
}

/// Agent shared by every stream request. Generous read timeout so a stalled
/// server turns into a retryable failure instead of hanging forever.
pub fn stream_agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(10))
        .timeout_read(Duration::from_secs(30))
        .build()
}

/// Download `url` into `buffer`, closing or failing the buffer at the end.
/// The URL is used once to make the request and is never included in the
/// returned outcome.
pub fn download_stream(agent: &ureq::Agent, url: &str, buffer: &BoundedBuffer) -> DownloadOutcome {
    let outcome = match agent.get(url).call() {
        Ok(response) => {
            let status = response.status();
            if (200..300).contains(&status) {
                read_body(response.into_reader(), buffer)
            } else if (400..500).contains(&status) {
                DownloadOutcome::Rejected { status }
            } else {
                DownloadOutcome::Failed
            }
        }
        Err(ureq::Error::Status(status, _)) => {
            if (400..500).contains(&status) {
                DownloadOutcome::Rejected { status }
            } else {
                DownloadOutcome::Failed
            }
        }
        Err(_) => DownloadOutcome::Failed,
    };
    match &outcome {
        DownloadOutcome::Completed => buffer.close(),
        _ => buffer.fail(),
    }
    outcome
}

fn read_body(mut reader: impl Read, buffer: &BoundedBuffer) -> DownloadOutcome {
    let mut chunk = vec![0u8; DOWNLOAD_CHUNK_BYTES];
    loop {
        match reader.read(&mut chunk) {
            Ok(0) => return DownloadOutcome::Completed,
            Ok(n) => {
                if buffer.push(chunk[..n].to_vec()).is_err() {
                    // Consumer aborted; stop reading.
                    return DownloadOutcome::Failed;
                }
            }
            Err(_) => return DownloadOutcome::Failed,
        }
    }
}

// ---------------------------------------------------------------------------
// HTTP-Range seekable media source (fallback for seek-needing containers)
// ---------------------------------------------------------------------------

/// Typed failure of a Range request. Never carries the URL, a token, a salt,
/// or any credential material.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RangeSourceError {
    /// The server answered 4xx.
    Rejected { status: u16 },
    /// The server answered 5xx or the request failed at the transport level.
    Failed,
    /// The server ignored the `Range` header on a request for a non-zero
    /// offset: honoring the answer would require downloading (and skipping
    /// over) everything before the offset, so the source refuses.
    RangeUnsupported,
    /// HTTP 416 (or an empty body): the server has nothing at/after this
    /// offset. For a reader this is end of stream, not a failure.
    Eof,
}

/// A `MediaSource` that fetches bytes from `url` with HTTP Range requests.
///
/// Memory is bounded to a single read-ahead window (`RANGE_WINDOW_BYTES` by
/// default): sequential reads are served from the window, and a `Seek`
/// outside it invalidates the window so the next read issues a fresh Range
/// GET from the target offset. This is the recovery path for containers that
/// symphonia cannot probe from a non-seekable stream — an MP4 whose `moov`
/// atom sits at the end of the file is the common case.
///
/// The struct deliberately does not implement `Debug`: it holds the
/// credential-bearing stream URL, and no log line may ever render it.
pub struct HttpRangeSource {
    agent: ureq::Agent,
    url: String,
    window_bytes: usize,
    /// Full length of the resource when the server declared one
    /// (`Content-Range` total on a 206 answer, `Content-Length` otherwise).
    total_len: Option<u64>,
    /// True only when the server both accepted a Range request and sent a
    /// known length; everything else reports unseekable.
    seekable: bool,
    position: u64,
    window: Vec<u8>,
    /// Start offset of `window`; `u64::MAX` when there is no valid window.
    window_start: u64,
}

impl HttpRangeSource {
    /// Open the source with one probe request (`Range: bytes=0-…`), which
    /// also fills the first read-ahead window. Errors are typed and free of
    /// the URL.
    pub fn open(agent: &ureq::Agent, url: &str) -> Result<Self, RangeSourceError> {
        Self::with_window(agent, url, RANGE_WINDOW_BYTES)
    }

    /// Test hook: a smaller window keeps the window-boundary and seek
    /// behavior observable without large fixtures.
    pub fn with_window(
        agent: &ureq::Agent,
        url: &str,
        window_bytes: usize,
    ) -> Result<Self, RangeSourceError> {
        debug_assert!(window_bytes > 0);
        let mut source = Self {
            agent: agent.clone(),
            url: url.to_string(),
            window_bytes,
            total_len: None,
            seekable: false,
            position: 0,
            window: Vec::new(),
            window_start: u64::MAX,
        };
        source.fetch(0)?;
        Ok(source)
    }

    /// Issue one bounded Range GET for `start..start+window_bytes` and fill
    /// the read-ahead window. The URL is used for the request only and never
    /// appears in the error.
    fn fetch(&mut self, start: u64) -> Result<(), RangeSourceError> {
        let end = start
            .saturating_add(self.window_bytes as u64)
            .saturating_sub(1);
        let response = match self
            .agent
            .get(&self.url)
            .set("Range", &format!("bytes={start}-{end}"))
            .call()
        {
            Ok(response) => response,
            Err(ureq::Error::Status(status, _)) => {
                if status == 416 {
                    // Nothing is served at/after this offset: end of stream
                    // for a reader, never a credential problem.
                    return Err(RangeSourceError::Eof);
                }
                return Err(if (400..500).contains(&status) {
                    RangeSourceError::Rejected { status }
                } else {
                    RangeSourceError::Failed
                });
            }
            Err(_) => return Err(RangeSourceError::Failed),
        };
        let status = response.status();
        if status == 416 {
            // Nothing is served at/after this offset: end of stream for a
            // reader, never a credential problem.
            return Err(RangeSourceError::Eof);
        }
        if (400..500).contains(&status) {
            return Err(RangeSourceError::Rejected { status });
        }
        if !(200..300).contains(&status) {
            return Err(RangeSourceError::Failed);
        }
        let content_length = response
            .header("Content-Length")
            .and_then(|value| value.parse::<u64>().ok());
        let range_accepted = status == 206;
        let range_total = if range_accepted {
            response
                .header("Content-Range")
                .and_then(parse_content_range_total)
        } else {
            None
        };
        // Seekable requires both an accepted Range probe and a known length;
        // a `Content-Length` on a 206 answer describes the window, not the
        // resource, so only the `Content-Range` total counts there.
        self.seekable |= range_accepted && content_length.is_some() && range_total.is_some();
        self.total_len = if range_accepted {
            range_total
        } else {
            content_length
        };
        // At a non-zero offset a 200 answer means the server ignored the
        // Range header; reaching the offset would need an unbounded download.
        if !range_accepted && start > 0 {
            return Err(RangeSourceError::RangeUnsupported);
        }
        let mut reader = response.into_reader();
        let window = read_window(&mut reader, self.window_bytes).map_err(|_| {
            // Transport-level failure mid-window; the URL stays out of it.
            RangeSourceError::Failed
        })?;
        self.window = window;
        self.window_start = start;
        Ok(())
    }

    fn window_covers(&self, position: u64) -> bool {
        position >= self.window_start && position < self.window_start + self.window.len() as u64
    }
}

/// Parse the total from a `Content-Range: bytes a-b/total` header value.
/// `*` (unknown total) parses to `None`.
fn parse_content_range_total(value: &str) -> Option<u64> {
    let total = value.rsplit('/').next()?;
    if total.trim() == "*" {
        return None;
    }
    total.trim().parse::<u64>().ok()
}

/// Read at most `window_bytes` bytes into one window buffer.
fn read_window(reader: &mut impl Read, window_bytes: usize) -> std::io::Result<Vec<u8>> {
    let mut window = Vec::with_capacity(window_bytes);
    let mut chunk = [0u8; DOWNLOAD_CHUNK_BYTES];
    while window.len() < window_bytes {
        let want = (window_bytes - window.len()).min(chunk.len());
        match reader.read(&mut chunk[..want]) {
            Ok(0) => break,
            Ok(n) => window.extend_from_slice(&chunk[..n]),
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        }
    }
    Ok(window)
}

impl Read for HttpRangeSource {
    fn read(&mut self, out: &mut [u8]) -> std::io::Result<usize> {
        if out.is_empty() {
            return Ok(0);
        }
        if let Some(total) = self.total_len {
            if self.position >= total {
                return Ok(0);
            }
        }
        if !self.window_covers(self.position) {
            match self.fetch(self.position) {
                Ok(()) => {}
                Err(RangeSourceError::Eof) => return Ok(0),
                Err(RangeSourceError::Rejected { status }) => {
                    // Status only; never the URL or any credential material.
                    return Err(std::io::Error::other(format!(
                        "stream range request was rejected (status {status})"
                    )));
                }
                Err(RangeSourceError::RangeUnsupported) => {
                    return Err(std::io::Error::other(
                        "the server does not support range requests for this stream",
                    ));
                }
                Err(RangeSourceError::Failed) => {
                    return Err(std::io::Error::other("the stream could not be fetched"));
                }
            }
            // An accepted answer with an empty body is end of stream too;
            // keep serving EOF instead of re-fetching the same offset.
            if self.window.is_empty() {
                return Ok(0);
            }
        }
        let offset_in_window = (self.position - self.window_start) as usize;
        let available = &self.window[offset_in_window..];
        let count = available.len().min(out.len());
        out[..count].copy_from_slice(&available[..count]);
        self.position += u64::try_from(count).unwrap_or(u64::MAX);
        Ok(count)
    }
}

impl Seek for HttpRangeSource {
    fn seek(&mut self, position: SeekFrom) -> std::io::Result<u64> {
        let target: i128 = match position {
            SeekFrom::Start(offset) => i128::from(offset),
            SeekFrom::Current(delta) => i128::from(self.position) + i128::from(delta),
            SeekFrom::End(delta) => {
                let total = self.total_len.ok_or_else(|| {
                    std::io::Error::other(
                        "stream length is unknown; seeking from the end is unsupported",
                    )
                })?;
                i128::from(total) + i128::from(delta)
            }
        };
        if target < 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "seek before the start of the stream",
            ));
        }
        self.position = target as u64;
        // Keep the window when the target is inside it (a backward hop within
        // the read-ahead costs no request); otherwise the next read issues a
        // fresh Range GET from the new offset.
        if !self.window_covers(self.position) {
            self.window_start = u64::MAX;
            self.window.clear();
        }
        Ok(self.position)
    }
}

impl MediaSource for HttpRangeSource {
    fn is_seekable(&self) -> bool {
        self.seekable
    }

    fn byte_len(&self) -> Option<u64> {
        self.total_len
    }
}

// ---------------------------------------------------------------------------
// Stream workers (download + decode threads)
// ---------------------------------------------------------------------------

/// Outcome of one decode attempt. Never carries URL or credential material.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DecodeOutcome {
    Completed,
    Failed(String),
}

/// Messages from worker threads back to the pipeline. Stale sequence numbers
/// are discarded by the pipeline after a seek/stop/advance.
#[derive(Debug)]
pub enum WorkerEvent {
    DownloadDone { seq: u64, outcome: DownloadOutcome },
    DecodeDone { seq: u64, outcome: DecodeOutcome },
}

/// Handle over one track's download and decode threads. Dropping the handle
/// does not stop the threads; call [`WorkerHandle::abort`] to release them.
pub struct WorkerHandle {
    pub seq: u64,
    /// The bounded download buffer, absent for a decode-only worker (the
    /// HTTP-Range fallback reads the stream directly and has no downloader).
    pub buffer: Option<Arc<BoundedBuffer>>,
    pub pcm: Arc<PcmBuffer>,
}

impl WorkerHandle {
    /// Unblock and end both worker threads.
    pub fn abort(&self) {
        if let Some(buffer) = &self.buffer {
            buffer.abort();
        }
        self.pcm.abort();
    }
}

/// Spawn one track's download and decode threads. The URL is built here with
/// the given fresh salt; it is used once for the request and never logged.
#[allow(clippy::too_many_arguments)]
pub fn spawn_worker(
    agent: &ureq::Agent,
    base_url: &str,
    auth: &AuthPair,
    salt: String,
    song_id: &str,
    format: &str,
    max_bit_rate: u16,
    offset_secs: u64,
    device_channels: u16,
    device_rate: u32,
    events: std::sync::mpsc::Sender<WorkerEvent>,
    seq: u64,
) -> Result<WorkerHandle, String> {
    let url = build_stream_url(
        base_url,
        auth,
        &salt,
        song_id,
        format,
        max_bit_rate,
        offset_secs,
    )?;

    let buffer = Arc::new(BoundedBuffer::new(MAX_BUFFER_CHUNKS));
    let pcm = Arc::new(PcmBuffer::new(pcm_capacity_frames(
        device_rate,
        device_channels,
    )));

    let downloader = {
        let agent = agent.clone();
        let buffer = Arc::clone(&buffer);
        let events = events.clone();
        std::thread::Builder::new()
            .name(format!("stream-download-{seq}"))
            .spawn(move || {
                let outcome = download_stream(&agent, &url, &buffer);
                // The URL is never included in the outcome or any log line.
                let _ = events.send(WorkerEvent::DownloadDone { seq, outcome });
            })
            .map_err(|error| format!("failed to spawn the download thread: {error}"))?
    };

    let decode_buffer = Arc::clone(&buffer);
    let decode_pcm = Arc::clone(&pcm);
    let decode_events = events.clone();
    let owned_song_id = song_id.to_string();
    let decoder = match std::thread::Builder::new()
        .name(format!("stream-decode-{seq}"))
        .spawn(move || {
            let outcome = decode_stream(
                &decode_buffer,
                &decode_pcm,
                device_channels,
                device_rate,
                &owned_song_id,
            );
            let _ = decode_events.send(WorkerEvent::DecodeDone { seq, outcome });
        }) {
        Ok(handle) => handle,
        Err(error) => {
            // Do not leave a downloader running against an aborted buffer.
            buffer.abort();
            let _ = downloader.join();
            return Err(format!("failed to spawn the decode thread: {error}"));
        }
    };

    let _ = decoder;
    Ok(WorkerHandle {
        seq,
        buffer: Some(buffer),
        pcm,
    })
}

/// Spawn one track's decode-only worker reading from an HTTP-Range seekable
/// source. This is the single bounded fallback when the bounded-buffer fast
/// path fails its format probe because the container needs seeking (an MP4
/// with the `moov` atom at the end is the common case). There is no
/// downloader: the source fetches windows itself. The URL is built here with
/// the given fresh salt and is never logged.
#[allow(clippy::too_many_arguments)]
pub fn spawn_range_worker(
    agent: &ureq::Agent,
    base_url: &str,
    auth: &AuthPair,
    salt: String,
    song_id: &str,
    format: &str,
    max_bit_rate: u16,
    offset_secs: u64,
    device_channels: u16,
    device_rate: u32,
    events: std::sync::mpsc::Sender<WorkerEvent>,
    seq: u64,
) -> Result<WorkerHandle, String> {
    let url = build_stream_url(
        base_url,
        auth,
        &salt,
        song_id,
        format,
        max_bit_rate,
        offset_secs,
    )?;

    let pcm = Arc::new(PcmBuffer::new(pcm_capacity_frames(
        device_rate,
        device_channels,
    )));
    let decode_pcm = Arc::clone(&pcm);
    let decode_events = events.clone();
    let owned_song_id = song_id.to_string();
    let agent = agent.clone();
    let decoder = std::thread::Builder::new()
        .name(format!("stream-range-decode-{seq}"))
        .spawn(move || {
            let outcome = decode_stream_from_url(
                &agent,
                &url,
                &decode_pcm,
                device_channels,
                device_rate,
                &owned_song_id,
            );
            let _ = decode_events.send(WorkerEvent::DecodeDone { seq, outcome });
        })
        .map_err(|error| format!("failed to spawn the range decode thread: {error}"))?;
    let _ = decoder;
    Ok(WorkerHandle {
        seq,
        buffer: None,
        pcm,
    })
}

/// Bounded decode queue capacity: about one second of device-shaped PCM.
fn pcm_capacity_frames(device_rate: u32, device_channels: u16) -> usize {
    (device_rate as usize).saturating_mul(usize::from(device_channels))
}

/// Decode batches this many frames before pushing into the PCM buffer, to
/// keep the rodio queue at sane source counts.
fn batch_target_frames(device_rate: u32, device_channels: u16) -> usize {
    let per_second = pcm_capacity_frames(device_rate, device_channels);
    (per_second / 5).max(1)
}

/// A read-only `MediaSource` that pulls raw bytes from the bounded buffer.
/// Reports itself as a stream so symphonia never seeks to determine length.
struct RawStreamSource {
    buffer: Arc<BoundedBuffer>,
    pending: Vec<u8>,
    offset: usize,
}

impl Read for RawStreamSource {
    fn read(&mut self, out: &mut [u8]) -> std::io::Result<usize> {
        while self.offset >= self.pending.len() {
            match self.buffer.pop() {
                Some(chunk) => {
                    self.pending = chunk;
                    self.offset = 0;
                }
                None => return Ok(0),
            }
        }
        let available = &self.pending[self.offset..];
        let count = available.len().min(out.len());
        out[..count].copy_from_slice(&available[..count]);
        self.offset += count;
        Ok(count)
    }
}

impl std::io::Seek for RawStreamSource {
    fn seek(&mut self, _position: std::io::SeekFrom) -> std::io::Result<u64> {
        Err(std::io::Error::other(
            "streaming source does not support seeking",
        ))
    }
}

impl MediaSource for RawStreamSource {
    fn is_seekable(&self) -> bool {
        false
    }

    fn byte_len(&self) -> Option<u64> {
        None
    }
}

/// Pull raw bytes from the bounded buffer, decode them with symphonia,
/// convert to the output device's channel layout and sample rate, and push
/// bounded PCM chunks.
fn decode_stream(
    buffer: &Arc<BoundedBuffer>,
    pcm: &Arc<PcmBuffer>,
    device_channels: u16,
    device_rate: u32,
    song_id: &str,
) -> DecodeOutcome {
    let source = RawStreamSource {
        buffer: Arc::clone(buffer),
        pending: Vec::new(),
        offset: 0,
    };
    let mss = MediaSourceStream::new(Box::new(source), Default::default());
    decode_media_source(mss, pcm, device_channels, device_rate, song_id)
}

/// Decode the same stream URL from an HTTP-Range seekable source. Used as
/// the one bounded fallback when the bounded-buffer fast path cannot probe
/// the format (a seek-needing container such as MP4 with `moov` at the end).
/// Failure reasons are honest and never name the URL.
fn decode_stream_from_url(
    agent: &ureq::Agent,
    url: &str,
    pcm: &Arc<PcmBuffer>,
    device_channels: u16,
    device_rate: u32,
    song_id: &str,
) -> DecodeOutcome {
    let source = match HttpRangeSource::open(agent, url) {
        Ok(source) => source,
        Err(RangeSourceError::Rejected { .. }) => {
            return DecodeOutcome::Failed(
                "the server rejected the range request for this stream".to_string(),
            );
        }
        Err(RangeSourceError::RangeUnsupported) => {
            return DecodeOutcome::Failed(
                "the server does not support range requests, so this stream cannot be decoded in place"
                    .to_string(),
            );
        }
        Err(_) => {
            return DecodeOutcome::Failed(
                "the stream could not be fetched with range requests".to_string(),
            );
        }
    };
    let mss = MediaSourceStream::new(Box::new(source), Default::default());
    decode_media_source(mss, pcm, device_channels, device_rate, song_id)
}

/// Whether a failed decode attempt should be retried once from the
/// HTTP-Range seekable source. Deliberately textual: symphonia reports
/// container/feature limits as `Error::Unsupported`, which formats as
/// "unsupported feature: …" — exactly the `isomp4: missing moov atom`
/// failure of an MP4 whose `moov` atom sits at the end of the file and
/// cannot be reached in a non-seekable stream. Only probe failures qualify;
/// a decoder-init or mid-stream failure (including genuinely unsupported
/// codecs) does not fix itself by seeking. Matching the error text keeps
/// this independent of symphonia's internal error variants, which are not a
/// stability contract.
pub fn probe_failure_needs_range(reason: &str) -> bool {
    reason.starts_with("stream format probe failed: ") && reason.contains("unsupported")
}

/// Probe and decode an already-opened media source into the bounded PCM
/// buffer. Shared by the bounded-buffer fast path and the HTTP-Range
/// fallback.
fn decode_media_source(
    mss: MediaSourceStream,
    pcm: &Arc<PcmBuffer>,
    device_channels: u16,
    device_rate: u32,
    song_id: &str,
) -> DecodeOutcome {
    let hint = Hint::new();
    let probed = match get_probe().format(
        &hint,
        mss,
        &FormatOptions::default(),
        &MetadataOptions::default(),
    ) {
        Ok(probed) => probed,
        Err(error) => return DecodeOutcome::Failed(format!("stream format probe failed: {error}")),
    };
    let mut format = probed.format;
    let track_index = match format
        .tracks()
        .iter()
        .position(|track| track.codec_params.codec != CODEC_TYPE_NULL)
    {
        Some(index) => index,
        None => return DecodeOutcome::Failed("stream carries no audio track".to_string()),
    };
    let track_id = format.tracks()[track_index].id;
    let mut decoder = match get_codecs().make(
        &format.tracks()[track_index].codec_params,
        &DecoderOptions::default(),
    ) {
        Ok(decoder) => decoder,
        Err(error) => return DecodeOutcome::Failed(format!("stream decoder init failed: {error}")),
    };

    let channels = usize::from(device_channels);
    let mut errors = 0u32;
    let mut batch: Vec<f32> = Vec::new();

    loop {
        let packet = match format.next_packet() {
            Ok(packet) => packet,
            Err(SymphoniaError::IoError(error))
                if error.kind() == std::io::ErrorKind::UnexpectedEof =>
            {
                break;
            }
            Err(SymphoniaError::ResetRequired) => break,
            Err(SymphoniaError::IoError(error)) => {
                return DecodeOutcome::Failed(format!("stream read failed: {error}"));
            }
            Err(error) => return DecodeOutcome::Failed(format!("stream ended abruptly: {error}")),
        };
        if packet.track_id() != track_id {
            continue;
        }
        match decoder.decode(&packet) {
            Ok(decoded) => {
                errors = 0;
                if decoded.frames() == 0 {
                    continue;
                }
                let spec = *decoded.spec();
                let source_channels = spec.channels.count();
                let rate = spec.rate;
                let mut samples = SampleBuffer::<f32>::new(decoded.capacity() as u64, spec);
                samples.copy_interleaved_ref(decoded);
                let source = samples.samples();
                let frames = source.len() / source_channels.max(1);
                let mut converted = Vec::with_capacity(frames * channels);
                for frame in 0..frames {
                    let range = frame * source_channels..(frame + 1) * source_channels;
                    converted.extend(convert_frame_layout(
                        &source[range],
                        source_channels,
                        channels,
                    ));
                }
                let converted = if rate != device_rate {
                    resample(&converted, channels, rate, device_rate)
                } else {
                    converted
                };
                batch.extend(converted);
                if batch.len() / channels >= batch_target_frames(device_rate, device_channels) {
                    let frames = batch.len() / channels;
                    if pcm
                        .push(PcmChunk {
                            frames,
                            samples: std::mem::take(&mut batch),
                        })
                        .is_err()
                    {
                        // Consumer aborted; stop quietly.
                        return DecodeOutcome::Completed;
                    }
                }
            }
            Err(SymphoniaError::DecodeError(reason)) => {
                errors += 1;
                log::debug!("skipping undecodable packet in song {song_id}: {reason}");
                if errors > 20 {
                    return DecodeOutcome::Failed("too many undecodable packets".to_string());
                }
            }
            Err(SymphoniaError::IoError(error)) => {
                return DecodeOutcome::Failed(format!("stream read failed: {error}"));
            }
            Err(error) => return DecodeOutcome::Failed(format!("decode failed: {error}")),
        }
    }

    if !batch.is_empty() {
        let frames = batch.len() / channels;
        let _ = pcm.push(PcmChunk {
            frames,
            samples: batch,
        });
    }
    pcm.close();
    DecodeOutcome::Completed
}

// ---------------------------------------------------------------------------
// Sample conversion helpers (decoded spec → output device spec)
// ---------------------------------------------------------------------------

/// Map an interleaved frame from `from` channels to `to` channels.
///
/// Downmix averages channel pairs; upmix duplicates channels. Mono→stereo
/// keeps level; stereo→mono averages L/R.
pub fn convert_frame_layout(frame: &[f32], from: usize, to: usize) -> Vec<f32> {
    if from == to || from == 0 || to == 0 {
        return frame.to_vec();
    }
    let mut out = Vec::with_capacity(to);
    if to < from {
        // Fold extra channels into the first `to` channels pairwise.
        let pairs = from / to;
        for index in 0..to {
            let mut sum = 0.0_f32;
            for pair in 0..pairs {
                sum += frame[index + pair * to];
            }
            out.push(sum / pairs as f32);
        }
    } else {
        // Duplicate the source across the extra channels.
        for index in 0..to {
            out.push(frame[index.min(from - 1)]);
        }
    }
    out
}

/// Linear resample interleaved audio from `from` Hz to `to` Hz.
/// Identity when the rates match. Pure so tests can pin the math.
pub fn resample(samples: &[f32], channels: usize, from: u32, to: u32) -> Vec<f32> {
    if from == to || channels == 0 || samples.is_empty() {
        return samples.to_vec();
    }
    let src_frames = samples.len() / channels;
    if src_frames < 2 {
        return samples.to_vec();
    }
    let dst_frames = (((src_frames as u64) * (to as u64)) / (from as u64)) as usize;
    let mut out = Vec::with_capacity(dst_frames * channels);
    let step = f64::from(from) / f64::from(to);
    for dst in 0..dst_frames {
        let src_pos = dst as f64 * step;
        let src_index = src_pos as usize;
        let frac = (src_pos - (src_index as f64)).min(1.0) as f32;
        let next = (src_index + 1).min(src_frames - 1);
        for channel in 0..channels {
            let a = samples[src_index * channels + channel];
            let b = samples[next * channels + channel];
            out.push(a + (b - a) * frac);
        }
    }
    out
}

/// Backoff before the n-th stream retry attempt (n starting at 1).
pub fn retry_backoff_ms(attempt: u8) -> u64 {
    RETRY_BACKOFF_MS * u64::from(attempt)
}

/// Whether another bounded mid-stream restart is allowed after `failures`
/// consecutive failures.
pub fn stream_retry_allowed(failures: u8) -> bool {
    failures < MAX_STREAM_ATTEMPTS
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    const TEST_SALT: &str = "abcdef12";

    fn test_auth() -> AuthPair {
        AuthPair::new("user", "secret1")
    }

    #[test]
    fn token_auth_matches_the_subsonic_md5_contract() {
        // Pinned values computed independently: md5("sesame" + "c19b2d") and
        // md5("secret1" + "abcdef12").
        assert_eq!(
            auth_token("sesame", "c19b2d"),
            "26719a1196d2a940705a59634eb18eab"
        );
        assert_eq!(
            auth_token("secret1", "abcdef12"),
            "453c8b23d259fa984521e5c34d37f5dd"
        );
    }

    #[test]
    fn stream_url_built_with_a_pinned_salt() {
        let url = build_stream_url(
            "https://nav.example",
            &test_auth(),
            TEST_SALT,
            "song 42",
            "mp3",
            320,
            90,
        )
        .unwrap();
        assert_eq!(
            url,
            "https://nav.example/rest/stream?\
             id=song%2042&\
             u=user&\
             t=453c8b23d259fa984521e5c34d37f5dd&\
             s=abcdef12&\
             v=1.16.1&\
             c=omarchy-navidrome&\
             f=json&\
             format=mp3&\
             maxBitRate=320&\
             timeOffset=90"
        );
    }

    #[test]
    fn stream_url_omits_source_format_and_uncapped_bitrate() {
        let url = build_stream_url(
            "https://nav.example/",
            &test_auth(),
            TEST_SALT,
            "42",
            "",
            0,
            0,
        )
        .unwrap();
        assert!(url.ends_with("/rest/stream?id=42&u=user&t=453c8b23d259fa984521e5c34d37f5dd&s=abcdef12&v=1.16.1&c=omarchy-navidrome&f=json"));
        assert!(!url.contains("format="));
        assert!(!url.contains("maxBitRate"));
        assert!(!url.contains("timeOffset"));
    }

    #[test]
    fn stream_url_rejects_short_salts() {
        assert!(
            build_stream_url("https://nav.example", &test_auth(), "abc", "42", "", 0, 0).is_err()
        );
    }

    #[test]
    fn cover_art_url_carries_the_auth_token() {
        let url =
            build_cover_art_url("https://nav.example", &test_auth(), TEST_SALT, "art-9").unwrap();
        assert_eq!(
            url,
            "https://nav.example/rest/getCoverArt?\
             id=art-9&\
             u=user&\
             t=453c8b23d259fa984521e5c34d37f5dd&\
             s=abcdef12&\
             v=1.16.1&\
             c=omarchy-navidrome&\
             f=json"
        );
        assert!(
            build_cover_art_url("https://nav.example", &test_auth(), TEST_SALT, "")
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn scrobble_url_pins_the_submission_flag() {
        let submitted =
            build_scrobble_url("https://nav.example", &test_auth(), TEST_SALT, "tr 9", true)
                .unwrap();
        assert_eq!(
            submitted,
            "https://nav.example/rest/scrobble?\
             id=tr%209&\
             submission=true&\
             u=user&\
             t=453c8b23d259fa984521e5c34d37f5dd&\
             s=abcdef12&\
             v=1.16.1&\
             c=omarchy-navidrome&\
             f=json"
        );
        let now_playing = build_scrobble_url(
            "https://nav.example",
            &test_auth(),
            TEST_SALT,
            "tr-9",
            false,
        )
        .unwrap();
        assert!(now_playing.contains("id=tr-9&submission=false"));
        assert!(
            build_scrobble_url("https://nav.example", &test_auth(), "abc", "tr-9", true).is_err()
        );
    }

    #[test]
    fn save_play_queue_url_repeats_ids_and_pins_current_and_position() {
        let url = build_save_play_queue_url(
            "https://nav.example",
            &test_auth(),
            TEST_SALT,
            &["tr-1".to_string(), "tr-2".to_string()],
            "tr-2",
            Some(42_000),
        )
        .unwrap();
        assert!(url.starts_with("https://nav.example/rest/savePlayQueue?"));
        assert!(url.contains("id=tr-1"));
        assert!(url.contains("id=tr-2"));
        // Subsonic's `current` is the current song's id, not an index.
        assert!(url.contains("current=tr-2"));
        assert!(url.contains("position=42000"));
        assert!(url.contains("t=453c8b23d259fa984521e5c34d37f5dd"));

        // Position 0 (or None) is omitted; servers treat it as 0.
        let bare = build_save_play_queue_url(
            "https://nav.example",
            &test_auth(),
            TEST_SALT,
            &["tr-1".to_string()],
            "tr-1",
            None,
        )
        .unwrap();
        assert!(!bare.contains("position="));
        // An empty queue and a short salt are rejected.
        assert!(
            build_save_play_queue_url(
                "https://nav.example",
                &test_auth(),
                TEST_SALT,
                &[],
                "",
                None
            )
            .is_err()
        );
        assert!(
            build_save_play_queue_url(
                "https://nav.example",
                &test_auth(),
                "abc",
                &["tr-1".to_string()],
                "tr-1",
                None
            )
            .is_err()
        );
    }

    #[test]
    fn get_play_queue_url_carries_only_the_auth_params() {
        let url = build_get_play_queue_url("https://nav.example", &test_auth(), TEST_SALT).unwrap();
        assert_eq!(
            url,
            "https://nav.example/rest/getPlayQueue?\
             u=user&\
             t=453c8b23d259fa984521e5c34d37f5dd&\
             s=abcdef12&\
             v=1.16.1&\
             c=omarchy-navidrome&\
             f=json"
        );
        assert!(build_get_play_queue_url("https://nav.example", &test_auth(), "abc").is_err());
    }

    #[test]
    fn write_builder_errors_never_leak_credentials() {
        for error in [
            build_scrobble_url("not a url", &test_auth(), TEST_SALT, "tr-1", true).unwrap_err(),
            build_save_play_queue_url(
                "",
                &test_auth(),
                TEST_SALT,
                &["tr-1".to_string()],
                "tr-1",
                None,
            )
            .unwrap_err(),
            build_get_play_queue_url("https://nav.example", &test_auth(), "abc").unwrap_err(),
        ] {
            assert!(!error.contains("user"));
            assert!(!error.contains("secret1"));
            assert!(!error.contains("abcdef12"));
            assert!(!error.contains("453c8b23"));
            assert!(!error.contains("nav.example"));
        }
    }

    #[test]
    fn play_queue_response_parses_entries_current_and_position() {
        let queue = parse_play_queue(
            r#"{"subsonic-response":{"status":"ok","playQueue":{
                "current":"tr-2","position":"42000","entry":[
                    {"id":"tr-1","title":"A","artist":"Art","album":"Al",
                     "duration":180,"coverArt":"c1","track":3},
                    {"id":"tr-2","title":"B"}]}}}"#,
        );
        assert_eq!(queue.songs.len(), 2);
        assert_eq!(queue.songs[0].id, "tr-1");
        assert_eq!(queue.songs[0].artists, vec!["Art".to_string()]);
        // Subsonic durations are seconds; the protocol wants milliseconds.
        assert_eq!(queue.songs[0].duration_ms, 180_000);
        assert_eq!(queue.songs[0].cover_art, "c1");
        assert_eq!(queue.songs[0].track, Some(3));
        assert_eq!(queue.current_id, "tr-2");
        assert_eq!(queue.current_index, 1);
        assert_eq!(queue.position_ms, 42_000);
    }

    #[test]
    fn play_queue_response_never_throws_and_defaults_to_empty() {
        let hostile = [
            "",
            "not json",
            "{}",
            r#"{"subsonic-response":{"status":"failed"}}"#,
            r#"{"subsonic-response":{"status":"ok"}}"#,
            r#"{"subsonic-response":{"status":"ok","playQueue":null}}"#,
            // Id-less entries are dropped; hostile numbers clamp to zero.
            r#"{"subsonic-response":{"status":"ok","playQueue":{
                "entry":[{"title":"no id"},{"id":"tr-1","duration":-5}]}}}"#,
            r#"{"subsonic-response":{"status":"ok","playQueue":{
                "entry":{"id":42,"title":"single node"},
                "current":42,"position":-9}}}"#,
        ];
        for body in hostile {
            let queue = parse_play_queue(body);
            assert_eq!(queue.position_ms, 0, "hostile position must clamp: {body}");
            for song in &queue.songs {
                assert!(!song.id.is_empty());
            }
        }
        let single = parse_play_queue(
            r#"{"subsonic-response":{"status":"ok","playQueue":{
                "entry":{"id":42,"title":"single node"},"current":42}}}"#,
        );
        assert_eq!(single.songs.len(), 1);
        assert_eq!(single.songs[0].id, "42");
        assert_eq!(single.current_id, "42");
        assert_eq!(single.current_index, 0);
        // A current id that is no longer in the list falls back to index 0.
        let orphans = parse_play_queue(
            r#"{"subsonic-response":{"status":"ok","playQueue":{
                "entry":[{"id":"tr-1"}],"current":"gone"}}}"#,
        );
        assert_eq!(orphans.current_index, 0);
        assert_eq!(orphans.current_id, "gone");
    }

    #[test]
    fn base_url_validation_rejects_bare_hosts_and_keeps_scheme() {
        assert!(validate_base_url("https://nav.example").is_ok());
        assert!(validate_base_url("http://192.168.1.10:4533").is_ok());
        assert!(validate_base_url("nav.example").is_err());
        assert!(validate_base_url("ftp://nav.example").is_err());
        assert!(validate_base_url("https://").is_err());
        assert!(validate_base_url("").is_err());
    }

    #[test]
    fn random_salts_meet_the_length_and_uniqueness_contract() {
        let salts: Vec<String> = (0..64).map(|_| RandomSalt.salt()).collect();
        for salt in &salts {
            assert_eq!(salt.chars().count(), GENERATED_SALT_LENGTH);
            assert!(salt.chars().count() >= MIN_SALT_LENGTH);
            assert!(salt.chars().all(|c| c.is_ascii_alphanumeric()));
        }
        assert!(salts.windows(2).any(|pair| pair[0] != pair[1]));
    }

    #[test]
    fn auth_pair_never_renders_secrets() {
        let auth = AuthPair::new("somebody", "secret1");
        let debug = format!("{auth:?}");
        assert!(debug.contains("[redacted]"));
        assert!(!debug.contains("somebody"));
        assert!(!debug.contains("secret1"));
    }

    #[test]
    fn bounded_buffer_applies_backpressure_and_fifo_order() {
        let buffer = BoundedBuffer::new(2);
        buffer.push(vec![1]).unwrap();
        buffer.push(vec![2]).unwrap();
        // Producer would block here; verify the consumer drains FIFO.
        assert_eq!(buffer.pop(), Some(vec![1]));
        assert_eq!(buffer.pop(), Some(vec![2]));

        let closed = BoundedBuffer::new(2);
        closed.push(vec![7]).unwrap();
        closed.close();
        assert_eq!(closed.pop(), Some(vec![7]));
        assert_eq!(closed.pop(), None);

        let aborted = BoundedBuffer::new(2);
        aborted.abort();
        assert!(aborted.push(vec![9]).is_err());
        assert_eq!(aborted.pop(), None);
    }

    #[test]
    fn layout_conversion_duplicates_on_upmix_and_folds_on_downmix() {
        assert_eq!(convert_frame_layout(&[0.5], 1, 2), vec![0.5, 0.5]);
        assert_eq!(convert_frame_layout(&[-1.0, 1.0], 2, 1), vec![0.0]);
        assert_eq!(
            convert_frame_layout(&[1.0, 2.0, 3.0, 4.0], 4, 2),
            vec![2.0, 3.0]
        );
        // Identity conversion is a copy.
        assert_eq!(
            convert_frame_layout(&[0.25, -0.25], 2, 2),
            vec![0.25, -0.25]
        );
    }

    #[test]
    fn resample_is_identity_at_matching_rates() {
        let samples = vec![0.0, 0.1, 0.2, 0.3];
        assert_eq!(resample(&samples, 2, 44_100, 44_100), samples);
    }

    #[test]
    fn resample_keeps_frame_alignment_and_interpolates() {
        // 4 frames of mono at 100 Hz → 8 frames at 200 Hz.
        let out = resample(&[0.0, 1.0, 2.0, 3.0], 1, 100, 200);
        assert_eq!(out.len(), 8);
        assert!((out[0] - 0.0).abs() < 1e-6);
        assert!((out[2] - 1.0).abs() < 1e-6);
        assert!((out[4] - 2.0).abs() < 1e-6);
        assert!((out[7] - 3.0).abs() < 1e-6);

        // Stereo stays interleaved.
        let stereo = vec![0.0, 10.0, 1.0, 11.0, 2.0, 12.0, 3.0, 13.0];
        let out = resample(&stereo, 2, 100, 200);
        assert_eq!(out.len(), 16);
        assert!((out[0] - 0.0).abs() < 1e-6);
        assert!((out[1] - 10.0).abs() < 1e-6);
        assert!((out[8] - 2.0).abs() < 1e-6);
        assert!((out[9] - 12.0).abs() < 1e-6);
    }

    #[test]
    fn retry_backoff_grows_and_is_capped_by_the_attempt_budget() {
        assert_eq!(retry_backoff_ms(1), 250);
        assert_eq!(retry_backoff_ms(2), 500);
        assert_eq!(retry_backoff_ms(3), 750);
        assert!(!stream_retry_allowed(MAX_STREAM_ATTEMPTS));
        assert!(stream_retry_allowed(MAX_STREAM_ATTEMPTS - 1));
    }

    // -- HTTP-Range seekable source -----------------------------------------
    //
    // A tiny in-test HTTP server serving a canned byte blob: one connection
    // per request, `Connection: close`, and one of four selectable behaviors.
    // It lets the Range source be exercised end to end without a real
    // Navidrome server.

    #[derive(Clone, Copy, PartialEq, Eq)]
    enum ServerMode {
        /// Honors Range with 206 + Content-Range + Content-Length.
        Ranges,
        /// Ignores Range: always 200 + Content-Length with the full body.
        NoRange,
        /// Honors Range but sends neither Content-Length nor Content-Range
        /// (close-delimited body): length unknown, unseekable.
        NoLength,
        /// Rejects every request with 403.
        Reject4xx,
    }

    fn spawn_test_http_server(blob: Vec<u8>, mode: ServerMode) -> (String, Arc<AtomicUsize>) {
        let listener = std::net::TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        let blob = Arc::new(blob);
        let requests = Arc::new(AtomicUsize::new(0));
        let counter = Arc::clone(&requests);
        // The accept loop lives until the test process ends; a blocked
        // accept thread is harmless there.
        let _ = std::thread::Builder::new()
            .name("test-http".to_string())
            .spawn(move || {
                for stream in listener.incoming() {
                    let Ok(stream) = stream else { continue };
                    counter.fetch_add(1, Ordering::SeqCst);
                    let blob = Arc::clone(&blob);
                    let _ = std::thread::Builder::new()
                        .name("test-http-conn".to_string())
                        .spawn(move || serve_one(stream, &blob, mode));
                }
            });
        (format!("http://127.0.0.1:{port}/rest/stream"), requests)
    }

    fn serve_one(mut stream: std::net::TcpStream, blob: &[u8], mode: ServerMode) {
        use std::io::Write;
        let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
        let mut head = Vec::new();
        let mut byte = [0u8; 1];
        loop {
            match stream.read(&mut byte) {
                Ok(1) => {
                    head.push(byte[0]);
                    if head.ends_with(b"\r\n\r\n") || head.len() > 16 * 1024 {
                        break;
                    }
                }
                _ => return,
            }
        }
        let head = String::from_utf8_lossy(&head);
        let range = header_value(&head, "range");
        let write =
            |stream: &mut std::net::TcpStream, status: &str, headers: &[String], body: &[u8]| {
                let mut head = format!("HTTP/1.1 {status}\r\n");
                for header in headers {
                    head.push_str(header);
                    head.push_str("\r\n");
                }
                head.push_str("Connection: close\r\n\r\n");
                let _ = stream.write_all(head.as_bytes());
                let _ = stream.write_all(body);
                let _ = stream.flush();
            };
        match mode {
            ServerMode::Reject4xx => write(&mut stream, "403 Forbidden", &[], b""),
            ServerMode::NoRange => write(
                &mut stream,
                "200 OK",
                &[format!("Content-Length: {}", blob.len())],
                blob,
            ),
            ServerMode::Ranges | ServerMode::NoLength => match range.and_then(parse_range) {
                Some((start, end_hint)) => {
                    let last = blob.len() as u64 - 1;
                    if start > last {
                        let headers = if mode == ServerMode::Ranges {
                            vec![
                                format!("Content-Range: bytes */{}", blob.len()),
                                "Content-Length: 0".to_string(),
                            ]
                        } else {
                            Vec::new()
                        };
                        write(&mut stream, "416 Range Not Satisfiable", &headers, b"");
                    } else {
                        let end = end_hint.map_or(last, |hint| hint.min(last));
                        let slice = &blob[start as usize..=(end as usize)];
                        // NoLength sends neither Content-Length nor
                        // Content-Range: a close-delimited window with a
                        // fully unknown length.
                        let headers = if mode == ServerMode::Ranges {
                            vec![
                                format!("Content-Range: bytes {start}-{end}/{}", blob.len()),
                                format!("Content-Length: {}", slice.len()),
                            ]
                        } else {
                            Vec::new()
                        };
                        write(&mut stream, "206 Partial Content", &headers, slice);
                    }
                }
                // No (or unparsable) Range header: the full body.
                None if mode == ServerMode::Ranges => write(
                    &mut stream,
                    "200 OK",
                    &[format!("Content-Length: {}", blob.len())],
                    blob,
                ),
                None => write(&mut stream, "200 OK", &[], blob),
            },
        }
    }

    fn header_value<'a>(head: &'a str, name: &str) -> Option<&'a str> {
        head.lines().find_map(|line| {
            let (key, value) = line.split_once(':')?;
            key.trim().eq_ignore_ascii_case(name).then(|| value.trim())
        })
    }

    /// Parse a single `bytes=a-b` / `bytes=a-` range specification.
    fn parse_range(value: &str) -> Option<(u64, Option<u64>)> {
        let spec = value.strip_prefix("bytes=")?.split(',').next()?.trim();
        let (start, end) = spec.split_once('-')?;
        let start = start.trim().parse::<u64>().ok()?;
        let end = match end.trim() {
            "" => None,
            end => Some(end.trim().parse::<u64>().ok()?),
        };
        Some((start, end))
    }

    const WINDOW: usize = 1024;

    fn test_blob(len: usize) -> Vec<u8> {
        (0..len as u64).map(|index| (index % 251) as u8).collect()
    }

    fn counter(requests: &Arc<AtomicUsize>) -> usize {
        requests.load(Ordering::SeqCst)
    }

    #[test]
    fn http_range_source_reads_sequentially_across_the_window() {
        let blob = test_blob(5000);
        let (url, requests) = spawn_test_http_server(blob.clone(), ServerMode::Ranges);
        let mut source = HttpRangeSource::with_window(&stream_agent(), &url, WINDOW).unwrap();
        // Content-Length + accepted Range probe → seekable with a length.
        assert!(source.is_seekable());
        assert_eq!(source.byte_len(), Some(5000));
        // The open probe already fetched the first window.
        assert_eq!(counter(&requests), 1);
        let mut out = Vec::new();
        source.read_to_end(&mut out).unwrap();
        assert_eq!(out, blob);
        // One windowed fetch per 1024 bytes: the probe plus four more.
        assert_eq!(counter(&requests), 5);
    }

    #[test]
    fn http_range_source_seeks_start_current_and_end() {
        let blob = test_blob(5000);
        let (url, requests) = spawn_test_http_server(blob.clone(), ServerMode::Ranges);
        let mut source = HttpRangeSource::with_window(&stream_agent(), &url, WINDOW).unwrap();
        // Drain exactly the first window so a new one is definitely needed.
        let mut out = vec![0u8; WINDOW];
        source.read_exact(&mut out).unwrap();
        assert_eq!(out, &blob[..WINDOW]);
        // Seek(Start) outside the window: one fresh Range GET.
        assert_eq!(source.seek(SeekFrom::Start(3000)).unwrap(), 3000);
        let mut out = vec![0u8; 100];
        source.read_exact(&mut out).unwrap();
        assert_eq!(out, &blob[3000..3100]);
        // Seek(Current) backwards out of the window: another fetch.
        source.seek(SeekFrom::Current(-150)).unwrap();
        let mut out = vec![0u8; 10];
        source.read_exact(&mut out).unwrap();
        assert_eq!(out, &blob[2950..2960]);
        // Seek(End) against the server-declared total.
        assert_eq!(source.seek(SeekFrom::End(-100)).unwrap(), 4900);
        let mut out = vec![0u8; 50];
        source.read_exact(&mut out).unwrap();
        assert_eq!(out, &blob[4900..4950]);
        assert_eq!(counter(&requests), 4);
    }

    #[test]
    fn http_range_source_reuses_the_window_after_a_within_window_seek() {
        let blob = test_blob(5000);
        let (url, requests) = spawn_test_http_server(blob.clone(), ServerMode::Ranges);
        let mut source = HttpRangeSource::with_window(&stream_agent(), &url, WINDOW).unwrap();
        let mut out = vec![0u8; 500];
        source.read_exact(&mut out).unwrap();
        assert_eq!(out, &blob[..500]);
        // A backward seek inside the read-ahead window costs no request.
        source.seek(SeekFrom::Start(10)).unwrap();
        let mut out = vec![0u8; 5];
        source.read_exact(&mut out).unwrap();
        assert_eq!(out, &blob[10..15]);
        assert_eq!(counter(&requests), 1);
    }

    #[test]
    fn http_range_source_reports_eof_at_and_past_the_end() {
        let blob = test_blob(5000);
        let (url, requests) = spawn_test_http_server(blob, ServerMode::Ranges);
        let mut source = HttpRangeSource::with_window(&stream_agent(), &url, WINDOW).unwrap();
        assert_eq!(source.seek(SeekFrom::End(0)).unwrap(), 5000);
        let mut buf = [0u8; 16];
        assert_eq!(source.read(&mut buf).unwrap(), 0);
        assert_eq!(counter(&requests), 1);
        // Seeking past the end reads as EOF without another request.
        source.seek(SeekFrom::Start(6000)).unwrap();
        assert_eq!(source.read(&mut buf).unwrap(), 0);
        assert_eq!(counter(&requests), 1);
    }

    #[test]
    fn http_range_source_maps_416_to_end_of_stream_without_a_known_length() {
        let blob = test_blob(3000);
        let (url, requests) = spawn_test_http_server(blob.clone(), ServerMode::NoLength);
        let mut source = HttpRangeSource::with_window(&stream_agent(), &url, WINDOW).unwrap();
        // No Content-Length and no Content-Range: unknown length, unseekable.
        assert!(!source.is_seekable());
        assert_eq!(source.byte_len(), None);
        // Sequential reads still work (close-delimited windows).
        let mut out = Vec::new();
        source.read_to_end(&mut out).unwrap();
        assert_eq!(out, blob);
        // Past the last byte the server answers 416; the source reads EOF.
        let before = counter(&requests);
        source.seek(SeekFrom::Start(5000)).unwrap();
        let mut buf = [0u8; 16];
        assert_eq!(source.read(&mut buf).unwrap(), 0);
        assert_eq!(counter(&requests), before + 1);
    }

    #[test]
    fn http_range_source_needs_a_known_length_to_seek_from_the_end() {
        let blob = test_blob(3000);
        let (url, _requests) = spawn_test_http_server(blob, ServerMode::NoLength);
        let mut source = HttpRangeSource::with_window(&stream_agent(), &url, WINDOW).unwrap();
        let error = source.seek(SeekFrom::End(0)).unwrap_err();
        assert!(error.to_string().contains("unknown"));
        // Seeking before the start of the stream stays an error.
        source.seek(SeekFrom::Start(100)).unwrap();
        assert!(source.seek(SeekFrom::Current(-200)).is_err());
    }

    #[test]
    fn http_range_source_survives_a_server_that_ignores_range() {
        let blob = test_blob(5000);
        let (url, _requests) = spawn_test_http_server(blob.clone(), ServerMode::NoRange);
        let mut source = HttpRangeSource::with_window(&stream_agent(), &url, WINDOW).unwrap();
        // The probe answer is a plain 200: unseekable, but the length is
        // known from Content-Length.
        assert!(!source.is_seekable());
        assert_eq!(source.byte_len(), Some(5000));
        let mut out = vec![0u8; 100];
        source.read_exact(&mut out).unwrap();
        assert_eq!(out, &blob[..100]);
        // A seek to a non-zero offset needs a Range request the server will
        // ignore; the source refuses instead of downloading unboundedly.
        source.seek(SeekFrom::Start(2000)).unwrap();
        let error = source.read(&mut [0u8; 16]).unwrap_err();
        assert!(error.to_string().contains("range requests"));
        // No URL ever leaks into the error text.
        assert!(!error.to_string().contains("127.0.0.1"));
        // Seek(End) works positionally against the declared length...
        assert_eq!(source.seek(SeekFrom::End(-1)).unwrap(), 4999);
        // ...but reading there fails the same honest way.
        assert!(source.read(&mut [0u8; 16]).is_err());
    }

    #[test]
    fn http_range_source_open_rejects_4xx_without_leaking_the_url() {
        let (url, _requests) = spawn_test_http_server(test_blob(10), ServerMode::Reject4xx);
        // Match instead of unwrap_err(): the source must never be Debug,
        // because its Debug would render the credential-bearing URL.
        let error = match HttpRangeSource::with_window(&stream_agent(), &url, WINDOW) {
            Err(error) => error,
            Ok(_) => panic!("a 403 server must not open a range source"),
        };
        assert_eq!(error, RangeSourceError::Rejected { status: 403 });
        assert!(!format!("{error:?}").contains("127.0.0.1"));
    }

    #[test]
    fn content_range_totals_parse_including_the_unknown_star() {
        assert_eq!(
            parse_content_range_total("bytes 0-262143/1234567"),
            Some(1_234_567)
        );
        assert_eq!(parse_content_range_total("bytes 0-9/*"), None);
        assert_eq!(parse_content_range_total("bytes */42"), Some(42));
        assert_eq!(parse_content_range_total("garbage"), None);
    }

    #[test]
    fn the_probe_failure_heuristic_targets_unsupported_probe_failures() {
        assert!(probe_failure_needs_range(
            "stream format probe failed: unsupported feature: isomp4: missing moov atom"
        ));
        assert!(probe_failure_needs_range(
            "stream format probe failed: unsupported feature: mp4 is not streamable"
        ));
        // Other probe failures and any non-probe failure do not qualify.
        assert!(!probe_failure_needs_range(
            "stream format probe failed: end of stream"
        ));
        assert!(!probe_failure_needs_range(
            "stream decoder init failed: unsupported codec type"
        ));
        assert!(!probe_failure_needs_range("stream carries no audio track"));
        assert!(!probe_failure_needs_range(
            "stream read failed: connection reset"
        ));
    }

    /// Real one-second 440 Hz AAC-in-MP4 fixture, generated once with
    /// ffmpeg (`ffmpeg -f lavfi -i sine=frequency=440:duration=1 -c:a aac
    /// -b:a 64k tone.m4a`). ffmpeg writes the `moov` atom after `mdat`
    /// unless `-movflags +faststart` is used, which is exactly the failure
    /// shape of the unseekable bounded-buffer stream.
    static M4A_FIXTURE: &[u8] = include_bytes!("../tests/fixtures/sine-440.m4a");

    #[test]
    fn the_m4a_fixture_stays_small_with_moov_at_the_end() {
        assert!(M4A_FIXTURE.len() < 100 * 1024);
        let mdat = M4A_FIXTURE
            .windows(4)
            .position(|window| window == b"mdat")
            .expect("fixture carries an mdat box");
        let moov = M4A_FIXTURE
            .windows(4)
            .position(|window| window == b"moov")
            .expect("fixture carries a moov box");
        assert!(moov > mdat, "fixture must keep moov after mdat");
    }

    #[test]
    fn the_unseekable_bounded_buffer_probe_fails_on_the_moov_at_end_m4a() {
        let buffer = Arc::new(BoundedBuffer::new(MAX_BUFFER_CHUNKS));
        buffer.push(M4A_FIXTURE.to_vec()).unwrap();
        buffer.close();
        let pcm = Arc::new(PcmBuffer::new(44_100 * 2));
        let source = RawStreamSource {
            buffer: Arc::clone(&buffer),
            pending: Vec::new(),
            offset: 0,
        };
        let mss = MediaSourceStream::new(Box::new(source), Default::default());
        let outcome = decode_media_source(mss, &pcm, 2, 44_100, "42");
        let DecodeOutcome::Failed(reason) = outcome else {
            panic!("the fast path must fail on a moov-at-end m4a");
        };
        assert!(
            probe_failure_needs_range(&reason),
            "unexpected probe reason: {reason}"
        );
        // No PCM was ever produced by the failed fast path.
        assert!(pcm.try_pop().is_none());
    }

    #[test]
    fn the_range_source_decodes_the_moov_at_end_m4a_end_to_end() {
        let (url, _requests) = spawn_test_http_server(M4A_FIXTURE.to_vec(), ServerMode::Ranges);
        let source = HttpRangeSource::open(&stream_agent(), &url).expect("range source opens");
        assert!(source.is_seekable());
        assert_eq!(source.byte_len(), Some(M4A_FIXTURE.len() as u64));
        let pcm = Arc::new(PcmBuffer::new(44_100 * 2));
        let mss = MediaSourceStream::new(Box::new(source), Default::default());
        let outcome = decode_media_source(mss, &pcm, 2, 44_100, "42");
        assert_eq!(outcome, DecodeOutcome::Completed);
        let mut frames = 0usize;
        while let Some(chunk) = pcm.try_pop() {
            frames += chunk.frames;
        }
        // A full second of 44.1 kHz audio, resampled to the device rate.
        assert!(frames > 40_000, "decoded too few frames: {frames}");
    }

    #[test]
    fn spawn_range_worker_decodes_the_moov_at_end_m4a_off_thread() {
        let (url, _requests) = spawn_test_http_server(M4A_FIXTURE.to_vec(), ServerMode::Ranges);
        let (events, receiver) = std::sync::mpsc::channel();
        let handle = spawn_range_worker(
            &stream_agent(),
            &url,
            &AuthPair::new("user", "secret1"),
            FixedSalt("abcdef12".to_string()).salt(),
            "song 42",
            "",
            0,
            0,
            2,
            44_100,
            events,
            7,
        )
        .unwrap();
        assert_eq!(handle.seq, 7);
        // A decode-only worker has no bounded download buffer.
        assert!(handle.buffer.is_none());
        match receiver.recv_timeout(Duration::from_secs(10)) {
            Ok(WorkerEvent::DecodeDone { seq: 7, outcome }) => {
                assert_eq!(outcome, DecodeOutcome::Completed);
            }
            other => panic!("unexpected worker event: {other:?}"),
        }
        let mut frames = 0usize;
        while let Some(chunk) = handle.pcm.try_pop() {
            frames += chunk.frames;
        }
        assert!(frames > 40_000, "decoded too few frames: {frames}");
    }
}
