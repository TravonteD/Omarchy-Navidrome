//! Subsonic stream endpoint helpers: request URL building with token auth,
//! bounded buffering between the HTTP download and the decoder, and the
//! sample conversion helpers that map decoded audio onto the output device.
//!
//! Credential rules: [`AuthPair`] never implements `Debug`/`Display`, every
//! builder error omits the URL, and no function here logs. Callers may only
//! log song ids and playback state, never a built URL.

use std::collections::VecDeque;
use std::io::Read;
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
    pub buffer: Arc<BoundedBuffer>,
    pub pcm: Arc<PcmBuffer>,
}

impl WorkerHandle {
    /// Unblock and end both worker threads.
    pub fn abort(&self) {
        self.buffer.abort();
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
    Ok(WorkerHandle { seq, buffer, pcm })
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

/// Pull raw bytes, decode them with symphonia, convert to the output
/// device's channel layout and sample rate, and push bounded PCM chunks.
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
}
