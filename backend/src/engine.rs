use std::{
    collections::VecDeque,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc as std_mpsc,
    },
    time::{Duration, Instant},
};

use anyhow::{Context, Result, anyhow};
use rodio::{DeviceSinkBuilder, MixerDeviceSink, Player};
use tokio::sync::{mpsc, oneshot};

use crate::{
    config::BackendConfig,
    failure::Failure,
    protocol::{
        BackendState, Command, ENGINE_NAME, PlaybackStatus, ProtocolError, RepeatMode, SongRef,
        Track,
    },
    state::StateStore,
    stream::{
        self, AuthPair, DecodeOutcome, DownloadOutcome, ParsedPlayQueue, PcmChunk, RandomSalt,
        ReadOutcome, SaltSource, WorkerEvent, WorkerHandle, WriteOutcome,
    },
};

const INITIAL_VOLUME: u16 = ((u16::MAX as u32 * 90) / 100) as u16;
const ENGINE_QUEUE_CAPACITY: usize = 64;
/// Pipeline poll cadence while a track is loading or playing.
const POLL_INTERVAL: Duration = Duration::from_millis(20);
/// Idle poll cadence when nothing is loaded.
const IDLE_POLL_INTERVAL: Duration = Duration::from_millis(200);
/// MPRIS contract: one position update per second.
const POSITION_TICK_MS: u64 = 1000;
/// Audioscrobbler rule: a track counts as played when at least half of it
/// was heard (fraction rule for short tracks)...
const SCROBBLE_MIN_FRACTION: f64 = 0.5;
/// ...or at least four minutes of it (rule for long tracks).
const SCROBBLE_MIN_PLAYED_MS: u64 = 4 * 60 * 1000;
/// A burst of queue mutations saves at most once per debounce window.
const QUEUE_SAVE_DEBOUNCE: Duration = Duration::from_secs(5);
/// Short backoff before the single bounded retry of a failed queue save.
const QUEUE_SAVE_RETRY_DELAY: Duration = Duration::from_secs(2);
/// One dirty queue-save state gets an initial attempt plus one retry
/// (savePlayQueue is idempotent, so the retry never duplicates a write).
const QUEUE_SAVE_MAX_ATTEMPTS: u8 = 2;
/// Bounded window at shutdown in which the final queue save must confirm.
const QUEUE_SAVE_SHUTDOWN_WAIT: Duration = Duration::from_secs(2);

pub struct EngineRequest {
    pub command: Command,
    pub reply: Option<oneshot::Sender<Result<serde_json::Value, ProtocolError>>>,
}

pub type EngineSender = mpsc::Sender<EngineRequest>;

pub struct EngineRuntime {
    pub commands: EngineSender,
    shutdown: Arc<AtomicBool>,
    done: oneshot::Receiver<Result<()>>,
}

impl EngineRuntime {
    pub async fn wait_done(&mut self) -> Result<()> {
        (&mut self.done)
            .await
            .context("stream engine supervisor stopped")?
    }

    pub fn shutdown(&self) {
        self.shutdown.store(true, Ordering::SeqCst);
    }
}

/// Events produced by the playback pipeline thread and applied into the
/// shared state by an async task (diff-only, mirroring the previous
/// librespot event application and its tests).
#[derive(Clone, Debug)]
pub enum PlaybackEvent {
    /// A track became current. `begin` publishes the loading state (an
    /// audible stop happens before the next sample); gapless hand-offs keep
    /// the already-playing status continuous.
    TrackStarted {
        track: Track,
        position_ms: u32,
        begin: bool,
    },
    /// The first audible sample of the segment is playing.
    PlaybackStarted {
        position_ms: u32,
    },
    Paused {
        position_ms: u32,
    },
    Stopped,
    PositionTick {
        position_ms: u32,
    },
    /// An accepted seek: exactly one per seek so MPRIS emits one `Seeked`.
    Seeked {
        position_ms: u32,
    },
    VolumeChanged {
        volume: u16,
    },
    ShuffleChanged {
        enabled: bool,
    },
    RepeatChanged {
        mode: RepeatMode,
    },
    /// ConfigureServer applied in engine memory. Only the username crosses
    /// this boundary; the password never leaves the pipeline.
    ServerConfigured {
        username: String,
    },
    /// Typed playback error (machine-readable code, credential-free text).
    Error {
        code: String,
        message: String,
    },
}

// ---------------------------------------------------------------------------
// Startup
// ---------------------------------------------------------------------------

pub async fn start(config: BackendConfig, state: StateStore) -> Result<EngineRuntime> {
    let output = open_output(config.audio_device.as_deref()).map_err(|error| {
        log::error!("{error:#}");
        if config.audio_device.is_some() {
            Failure::InvalidConfiguration
        } else {
            Failure::Transient
        }
    })?;
    log::info!(
        "audio output opened: {} Hz, {} channels",
        output.rate,
        output.channels
    );

    state.update(|current| {
        current.lifecycle = crate::protocol::Lifecycle::Ready;
        current.engine = ENGINE_NAME.to_string();
        current.volume = INITIAL_VOLUME;
        current.error_code.clear();
        current.error.clear();
        true
    });

    let (commands, command_rx) = mpsc::channel::<EngineRequest>(ENGINE_QUEUE_CAPACITY);
    let (control_tx, control_rx) = std_mpsc::channel::<ControlMessage>();
    let (events, event_rx) = tokio::sync::mpsc::unbounded_channel::<PlaybackEvent>();
    let (worker_tx, worker_rx) = std_mpsc::channel::<WorkerEvent>();
    let (http_tx, http_rx) = std_mpsc::channel::<HttpWork>();
    let (http_outcome_tx, http_outcome_rx) = std_mpsc::channel::<HttpOutcome>();
    let shutdown = Arc::new(AtomicBool::new(false));

    spawn_http_worker(stream::stream_agent(), http_rx, http_outcome_tx);
    tokio::spawn(run_commands(command_rx, control_tx.clone()));
    tokio::spawn(run_events(event_rx, state.clone()));

    let pipeline = Pipeline::new(
        config.format,
        config.max_bit_rate,
        INITIAL_VOLUME,
        output,
        events.clone(),
        worker_tx,
        config.scrobble,
        http_tx,
        http_outcome_rx,
    );

    let (done_tx, done) = oneshot::channel();
    let (pipeline_done_tx, pipeline_done_rx) = oneshot::channel();
    let pipeline_shutdown = Arc::clone(&shutdown);
    let pipeline_thread = std::thread::Builder::new()
        .name("stream-pipeline".to_string())
        .spawn(move || {
            let result = pipeline.run(control_rx, worker_rx, pipeline_shutdown);
            // The oneshot replaces thread::join(): joining from the async
            // supervisor would block the single-threaded runtime forever.
            let _ = pipeline_done_tx.send(result);
        })
        .map_err(|error| anyhow!("failed to spawn the stream pipeline thread: {error}"))?;
    let _ = pipeline_thread;

    tokio::spawn(supervise(pipeline_done_rx, done_tx));

    Ok(EngineRuntime {
        commands,
        shutdown,
        done,
    })
}

/// Watches the pipeline thread's completion. An unexpected end (including a
/// panic, which drops the sender) is a typed process failure so the systemd
/// contract and the socket failure record keep working.
async fn supervise(
    done: oneshot::Receiver<Result<(), Failure>>,
    done_tx: oneshot::Sender<Result<()>>,
) {
    let result = match done.await {
        Ok(result) => result.map_err(anyhow::Error::from),
        Err(_) => Err(anyhow!("stream pipeline thread ended unexpectedly")),
    };
    let _ = done_tx.send(result);
}

// ---------------------------------------------------------------------------
// Async command forwarding (FIFO into the pipeline)
// ---------------------------------------------------------------------------

async fn run_commands(
    mut receiver: mpsc::Receiver<EngineRequest>,
    control: std_mpsc::Sender<ControlMessage>,
) {
    while let Some(request) = receiver.recv().await {
        let (reply_tx, reply_rx) = oneshot::channel();
        let delivered = control
            .send(ControlMessage {
                command: request.command,
                reply: reply_tx,
            })
            .is_ok();
        if !delivered {
            if let Some(reply) = request.reply {
                let _ = reply.send(Err(ProtocolError::new(
                    "engine_unavailable",
                    "playback engine is unavailable",
                )));
            }
            continue;
        }
        if let Some(reply) = request.reply {
            let result = match reply_rx.await {
                Ok(result) => result,
                Err(_) => Err(ProtocolError::new(
                    "engine_unavailable",
                    "playback engine stopped before replying",
                )),
            };
            let _ = reply.send(result);
        }
    }
}

async fn run_events(
    mut events: tokio::sync::mpsc::UnboundedReceiver<PlaybackEvent>,
    state: StateStore,
) {
    while let Some(event) = events.recv().await {
        state.update(|current| apply_event(current, &event));
    }
}

/// Fire-and-forget send used by MPRIS; bounded by the engine command queue.
pub fn send_without_reply(commands: &EngineSender, command: Command) -> Result<(), ProtocolError> {
    match commands.try_send(EngineRequest {
        command,
        reply: None,
    }) {
        Ok(()) => Ok(()),
        Err(mpsc::error::TrySendError::Full(_)) => Err(ProtocolError::new(
            "engine_busy",
            "playback engine command queue is full",
        )),
        Err(mpsc::error::TrySendError::Closed(_)) => Err(ProtocolError::new(
            "engine_unavailable",
            "playback engine is unavailable",
        )),
    }
}

/// Reply-carrying send used by the socket protocol server.
pub async fn send_with_reply(
    commands: &EngineSender,
    command: Command,
) -> Result<serde_json::Value, ProtocolError> {
    let (reply, receiver) = oneshot::channel();
    commands
        .send(EngineRequest {
            command,
            reply: Some(reply),
        })
        .await
        .map_err(|_| ProtocolError::new("engine_unavailable", "playback engine is unavailable"))?;
    receiver.await.map_err(|_| {
        ProtocolError::new(
            "engine_unavailable",
            "playback engine stopped before replying",
        )
    })?
}

// ---------------------------------------------------------------------------
// State event application (diff-only)
// ---------------------------------------------------------------------------

fn replace_if_changed<T: PartialEq>(target: &mut T, value: T) -> bool {
    if *target == value {
        false
    } else {
        *target = value;
        true
    }
}

fn replace_error(state: &mut BackendState, code: &str, message: impl Into<String>) -> bool {
    let mut changed = replace_if_changed(&mut state.error_code, code.to_string());
    changed |= replace_if_changed(&mut state.error, message.into());
    changed
}

fn apply_event(state: &mut BackendState, event: &PlaybackEvent) -> bool {
    match event {
        PlaybackEvent::TrackStarted {
            track,
            position_ms,
            begin,
        } => {
            let mut changed = replace_if_changed(&mut state.track, Some(track.clone()));
            changed |= replace_if_changed(&mut state.position_ms, *position_ms);
            if *begin {
                // An audible stop precedes this track's first sample, so the
                // loading state is published before any audio plays.
                changed |= replace_if_changed(&mut state.playback, PlaybackStatus::Loading);
            }
            changed |= replace_error(state, "", "");
            changed
        }
        PlaybackEvent::PlaybackStarted { position_ms } => {
            let playback_changed = replace_if_changed(&mut state.playback, PlaybackStatus::Playing);
            replace_if_changed(&mut state.position_ms, *position_ms) || playback_changed
        }
        PlaybackEvent::Paused { position_ms } => {
            let playback_changed = replace_if_changed(&mut state.playback, PlaybackStatus::Paused);
            replace_if_changed(&mut state.position_ms, *position_ms) || playback_changed
        }
        PlaybackEvent::Stopped => {
            let mut changed = replace_if_changed(&mut state.playback, PlaybackStatus::Stopped);
            changed |= replace_if_changed(&mut state.position_ms, 0);
            changed |= replace_if_changed(&mut state.track, None);
            changed
        }
        PlaybackEvent::PositionTick { position_ms } => {
            replace_if_changed(&mut state.position_ms, *position_ms)
        }
        PlaybackEvent::Seeked { position_ms } => {
            replace_if_changed(&mut state.position_ms, *position_ms);
            state.seek_sequence = state.seek_sequence.wrapping_add(1);
            true
        }
        PlaybackEvent::VolumeChanged { volume } => replace_if_changed(&mut state.volume, *volume),
        PlaybackEvent::ShuffleChanged { enabled } => {
            replace_if_changed(&mut state.shuffle, *enabled)
        }
        PlaybackEvent::RepeatChanged { mode } => replace_if_changed(&mut state.repeat, *mode),
        PlaybackEvent::ServerConfigured { username } => {
            let connected = replace_if_changed(&mut state.session_connected, true);
            replace_if_changed(&mut state.username, username.clone()) || connected
        }
        PlaybackEvent::Error { code, message } => replace_error(state, code, message.clone()),
    }
}

// ---------------------------------------------------------------------------
// Output device
// ---------------------------------------------------------------------------

pub struct Output {
    _sink: MixerDeviceSink,
    player: Player,
    channels: u16,
    rate: u32,
}

fn open_output(audio_device: Option<&str>) -> Result<Output> {
    let mut sink = match audio_device {
        Some(name) => {
            let device = find_output_device(name)
                .ok_or_else(|| anyhow!("configured audio output device {name:?} was not found"))?;
            DeviceSinkBuilder::from_device(device)?
                .open_stream()
                .map_err(|error| anyhow!("failed to open audio output: {error}"))
        }
        None => DeviceSinkBuilder::from_default_device()?
            .open_stream()
            .map_err(|error| anyhow!("failed to open the default audio output: {error}")),
    }?;
    sink.log_on_drop(false);
    let config = sink.config();
    let channels = config.channel_count().get();
    let rate = config.sample_rate().get();
    let player = Player::connect_new(sink.mixer());
    // Start paused; the pipeline unpauses after the prebuffer threshold.
    player.pause();
    Ok(Output {
        _sink: sink,
        player,
        channels,
        rate,
    })
}

fn find_output_device(name: &str) -> Option<rodio::Device> {
    use rodio::cpal::traits::{DeviceTrait, HostTrait};
    let host = rodio::cpal::default_host();
    host.output_devices().ok()?.find(|device| {
        device
            .description()
            .map(|description| description.name().eq_ignore_ascii_case(name))
            .unwrap_or(false)
    })
}

/// Linear volume mapping: 0..=65535 → 0.0..=1.0 sink gain.
pub fn volume_to_f32(volume: u16) -> f32 {
    f32::from(volume) / f32::from(u16::MAX)
}

// ---------------------------------------------------------------------------
// Server writes off the pipeline thread (scrobble, play-queue persistence)
// ---------------------------------------------------------------------------
//
// Scrobble and savePlayQueue calls must never stall audio or the command
// loop, so the pipeline only builds the request URLs (it is the only place
// that holds the server credentials) and hands them to one dedicated worker
// thread. URLs ride the channel in memory only; they are never logged.

pub(crate) enum HttpWork {
    /// One `scrobble` call. Never retried: a scrobble whose outcome is
    /// unknown may still have landed, and a second submission would corrupt
    /// the play count.
    Scrobble { song_id: String, url: String },
    /// One debounced `savePlayQueue` call. Idempotent, so a bounded retry
    /// within the same dirty state is safe.
    SaveQueue { seq: u64, url: String },
    /// One `getPlayQueue` read completing the command's deferred reply.
    GetSavedQueue {
        url: String,
        reply: oneshot::Sender<Result<serde_json::Value, ProtocolError>>,
    },
}

pub(crate) enum HttpOutcome {
    Scrobbled {
        song_id: String,
        outcome: WriteOutcome,
    },
    QueueSaved {
        seq: u64,
        outcome: WriteOutcome,
    },
}

fn spawn_http_worker(
    agent: ureq::Agent,
    work: std_mpsc::Receiver<HttpWork>,
    outcomes: std_mpsc::Sender<HttpOutcome>,
) {
    let spawned = std::thread::Builder::new()
        .name("stream-writes".to_string())
        .spawn(move || {
            while let Ok(work) = work.recv() {
                match work {
                    HttpWork::Scrobble { song_id, url } => {
                        // The URL is used once here and never logged.
                        let outcome = stream::send_write(&agent, &url);
                        let _ = outcomes.send(HttpOutcome::Scrobbled { song_id, outcome });
                    }
                    HttpWork::SaveQueue { seq, url } => {
                        let outcome = stream::send_write(&agent, &url);
                        let _ = outcomes.send(HttpOutcome::QueueSaved { seq, outcome });
                    }
                    HttpWork::GetSavedQueue { url, reply } => {
                        let result = saved_queue_result(stream::fetch_play_queue(&agent, &url));
                        let _ = reply.send(result);
                    }
                }
            }
        });
    // Detached on purpose: the pipeline must never block on this thread, and
    // at shutdown it only waits a bounded time for the final save.
    let _ = spawned;
}

/// `get_saved_queue` response shape: the persisted queue as SongRefs plus the
/// current song (its exact server id and the derived index) and its position
/// in milliseconds. Read failures are typed and credential-free.
fn saved_queue_result(outcome: ReadOutcome) -> Result<serde_json::Value, ProtocolError> {
    match outcome {
        ReadOutcome::Parsed(ParsedPlayQueue {
            songs,
            current_id,
            current_index,
            position_ms,
        }) => Ok(serde_json::json!({
            "songs": songs,
            "current_index": current_index,
            "current_id": current_id,
            "position_ms": position_ms,
        })),
        ReadOutcome::Rejected | ReadOutcome::Transport => Err(ProtocolError::new(
            "stream_unavailable",
            "the saved play queue could not be read",
        )),
    }
}

/// The scrobble decision matrix as implemented:
///   natural end      → submitted, whatever the fraction (the queue drained
///                      the song into the next one);
///   played ≥ 4 min   → submitted (Audioscrobbler rule for long tracks);
///   played ≥ ½ length→ submitted (rule for short tracks, known duration);
///   otherwise        → dropped silently.
fn scrobble_decision(played_ms: u64, duration_ms: u32, natural_end: bool) -> bool {
    if natural_end {
        return true;
    }
    if played_ms >= SCROBBLE_MIN_PLAYED_MS {
        return true;
    }
    duration_ms > 0 && (played_ms as f64) / f64::from(duration_ms) >= SCROBBLE_MIN_FRACTION
}

/// Debounced, bounded savePlayQueue scheduling. A burst of queue mutations
/// coalesces into one save per `QUEUE_SAVE_DEBOUNCE`; a failed or uncertain
/// save may be retried once within the same dirty state (the write is
/// idempotent); a new mutation starts a fresh bounded budget. Never an
/// unbounded retry loop.
struct QueueSaveScheduler {
    dirty: bool,
    due_at: Option<Instant>,
    attempts: u8,
}

impl QueueSaveScheduler {
    fn new() -> Self {
        Self {
            dirty: false,
            due_at: None,
            attempts: 0,
        }
    }

    /// A queue mutation happened: fresh bounded budget, and a burst keeps
    /// the save parked at its original due time.
    fn mark_dirty(&mut self, now: Instant) {
        self.attempts = 0;
        if self.dirty {
            return;
        }
        self.dirty = true;
        self.due_at = Some(now + QUEUE_SAVE_DEBOUNCE);
    }

    fn due(&self, now: Instant) -> bool {
        self.dirty && self.due_at.is_some_and(|due| now >= due)
    }

    /// A save left for the worker thread: the dirty state clears and one
    /// attempt is spent.
    fn fired(&mut self) {
        self.dirty = false;
        self.due_at = None;
        self.attempts = self.attempts.saturating_add(1);
    }

    fn succeeded(&mut self) {
        self.attempts = 0;
    }

    /// One bounded retry on a failed/uncertain save. False when the budget
    /// is spent and the possibly-landed state was dropped as uncertain.
    fn failed(&mut self, now: Instant) -> bool {
        if self.attempts >= QUEUE_SAVE_MAX_ATTEMPTS {
            self.attempts = 0;
            return false;
        }
        self.dirty = true;
        self.due_at = Some(now + QUEUE_SAVE_RETRY_DELAY);
        true
    }
}

// ---------------------------------------------------------------------------
// Pipeline thread
// ---------------------------------------------------------------------------

pub struct ControlMessage {
    pub command: Command,
    pub reply: oneshot::Sender<Result<serde_json::Value, ProtocolError>>,
}

/// Navidrome identity + credentials, held in engine memory only.
struct ServerIdentity {
    base_url: String,
    auth: AuthPair,
}

/// Why playback stopped. Only deliberate leaves (skip, stop, replaced
/// queue) can earn a fraction-gated submission; engine failures must never
/// scrobble, and a natural end has already been handled by the boundary.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum StopCause {
    /// Next/Previous moved playback away, or the queue ended on a skip.
    Skip,
    /// The Stop command (UI or MPRIS).
    UserStop,
    /// A new `load` replaced the queue mid-playback.
    Replaced,
    /// Typed engine error (rejected/undecodable/unavailable stream).
    Failed,
}

/// The song whose audio is currently at the head of the player queue.
struct FrontTrack {
    worker: WorkerHandle,
    song: SongRef,
    track: Track,
    /// Cumulative ms appended by earlier fronts of this segment.
    segment_offset_ms: u64,
    /// Song position where this worker's stream starts (seek/resume offset).
    worker_offset_ms: u64,
    /// ms appended to the player for this worker so far.
    appended_ms: u64,
    /// The decoder reported end of stream.
    eof: bool,
    /// The downloader died mid-stream; buffered audio still plays while a
    /// bounded retry rebuilds the stream.
    worker_failed: bool,
    /// submission=false fired once per front when its audio starts. A seek
    /// rebuilds the front and may refresh the hint; that is harmless (it
    /// only updates the now-playing marker, never the play count).
    now_playing_sent: bool,
    /// Queue index of the song this front is playing.
    index: usize,
}

impl FrontTrack {
    /// The front's audio can be considered finished once decoding ended or
    /// the worker died.
    fn drained(&self) -> bool {
        self.eof || self.worker_failed
    }
}

/// A preloaded next song (or a mid-stream retry replacement) whose decoded
/// audio is already appended to the player queue behind the front.
struct PendingTrack {
    worker: WorkerHandle,
    song: SongRef,
    track: Track,
    /// Song position where this worker's stream starts (0 for a preload,
    /// the buffered end for a mid-stream retry continuation).
    worker_offset_ms: u64,
    appended_ms: u64,
    eof: bool,
    index: usize,
}

/// A scheduled bounded stream retry.
struct RetryState {
    at: Instant,
}

struct Pipeline {
    events: tokio::sync::mpsc::UnboundedSender<PlaybackEvent>,
    worker_tx: std_mpsc::Sender<WorkerEvent>,
    output: Output,
    server: Option<ServerIdentity>,
    format: String,
    max_bit_rate: u16,
    salt: Box<dyn SaltSource>,
    agent: ureq::Agent,
    queue: VecDeque<SongRef>,
    current: Option<usize>,
    status: PlaybackStatus,
    volume: u16,
    shuffle: bool,
    repeat: RepeatMode,
    front: Option<FrontTrack>,
    pending: Option<PendingTrack>,
    retry: Option<RetryState>,
    next_worker_seq: u64,
    /// Consecutive mid-stream failures for the current track (bounded retry).
    failures: u8,
    /// Segment clock: position at the anchor moment + anchor while playing.
    playhead_base_ms: u64,
    anchor: Option<Instant>,
    last_tick_second: u64,
    /// Whether `submission=true` scrobbles fire at all (backend config).
    scrobble_enabled: bool,
    /// Off-thread channel for scrobble/queue-save/getPlayQueue work.
    http_tx: std_mpsc::Sender<HttpWork>,
    /// Write outcomes reported back by the worker thread.
    http_outcomes: std_mpsc::Receiver<HttpOutcome>,
    /// Debounced, bounded savePlayQueue scheduling.
    queue_save: QueueSaveScheduler,
    /// Monotonic sequence distinguishing queue-save outcomes.
    queue_save_seq: u64,
}

impl Pipeline {
    #[allow(clippy::too_many_arguments)]
    fn new(
        format: String,
        max_bit_rate: u16,
        volume: u16,
        output: Output,
        events: tokio::sync::mpsc::UnboundedSender<PlaybackEvent>,
        worker_tx: std_mpsc::Sender<WorkerEvent>,
        scrobble_enabled: bool,
        http_tx: std_mpsc::Sender<HttpWork>,
        http_outcomes: std_mpsc::Receiver<HttpOutcome>,
    ) -> Self {
        Self {
            events,
            worker_tx,
            output,
            server: None,
            format,
            max_bit_rate,
            salt: Box::new(RandomSalt),
            agent: stream::stream_agent(),
            queue: VecDeque::new(),
            current: None,
            status: PlaybackStatus::Stopped,
            volume,
            shuffle: false,
            repeat: RepeatMode::Off,
            front: None,
            pending: None,
            retry: None,
            next_worker_seq: 0,
            failures: 0,
            playhead_base_ms: 0,
            anchor: None,
            last_tick_second: u64::MAX,
            scrobble_enabled,
            http_tx,
            http_outcomes,
            queue_save: QueueSaveScheduler::new(),
            queue_save_seq: 0,
        }
    }

    fn run(
        mut self,
        control_rx: std_mpsc::Receiver<ControlMessage>,
        worker_rx: std_mpsc::Receiver<WorkerEvent>,
        shutdown: Arc<AtomicBool>,
    ) -> Result<(), Failure> {
        self.output.player.set_volume(volume_to_f32(self.volume));
        loop {
            if shutdown.load(Ordering::SeqCst) {
                self.teardown();
                return Ok(());
            }

            while let Ok(event) = worker_rx.try_recv() {
                self.handle_worker_event(event);
            }

            while let Ok(message) = control_rx.try_recv() {
                let ControlMessage { command, reply } = message;
                // Forward through the local-command discipline so arrival
                // order (and therefore Pause ordering) is preserved.
                self.handle_control(command, Some(reply));
            }

            self.pump(Instant::now());

            let interval = if self.front.is_some() {
                POLL_INTERVAL
            } else {
                IDLE_POLL_INTERVAL
            };
            // A command may arrive while blocked here; it must be executed,
            // not dropped.
            match control_rx.recv_timeout(interval) {
                Ok(message) => {
                    let ControlMessage { command, reply } = message;
                    self.handle_control(command, Some(reply));
                }
                Err(std_mpsc::RecvTimeoutError::Timeout) => {}
                Err(std_mpsc::RecvTimeoutError::Disconnected) => {
                    self.teardown();
                    return Ok(());
                }
            }
        }
    }

    fn teardown(&mut self) {
        // Clean shutdown: one final savePlayQueue with the queue as it stands
        // (the position advanced since the last debounced save), bounded so a
        // dead server cannot hang the process. The shutdown itself is not a
        // scrobble: quitting mid-track is not a play under the Audioscrobbler
        // rule, and idle shutdowns must not invent one.
        self.final_queue_save();
        self.stop_workers();
        self.output.player.clear();
    }

    /// Runs one control message. Commands execute sequentially in arrival
    /// order; `get_saved_queue` completes its reply off-thread and owns the
    /// reply channel until then.
    fn handle_control(
        &mut self,
        command: Command,
        reply: Option<oneshot::Sender<Result<serde_json::Value, ProtocolError>>>,
    ) {
        if let Command::GetSavedQueue = command {
            self.get_saved_queue(reply);
            return;
        }
        let result = dispatch_local_command(command, |command| self.execute(command));
        if let Some(reply) = reply {
            let _ = reply.send(result);
        }
    }

    // -- command execution --------------------------------------------------
    //
    // Commands execute sequentially in arrival order (the async side forwards
    // them through one FIFO channel), so a queued Pause can never be overtaken
    // by a Play/Toggle/Next/Previous that arrived behind it.

    fn execute(&mut self, command: Command) -> Result<serde_json::Value, ProtocolError> {
        match command {
            Command::ConfigureServer {
                url,
                username,
                password,
            } => self.configure_server(url, username, password),
            Command::Load {
                songs,
                offset_index,
                position_ms,
                play,
            } => {
                self.require_server()?;
                if songs.is_empty() {
                    return Err(ProtocolError::new(
                        "invalid_request",
                        "load requires at least one song",
                    ));
                }
                let index = offset_index
                    .map(|value| value as usize)
                    .filter(|value| *value < songs.len())
                    .unwrap_or(0);
                self.begin_segment_with_queue(songs, index, position_ms, play);
                Ok(serde_json::json!({}))
            }
            Command::AddToQueue { song } => {
                self.require_server()?;
                self.queue.push_back(song);
                self.mark_queue_dirty();
                Ok(serde_json::json!({}))
            }
            Command::Play => {
                match self.status {
                    PlaybackStatus::Paused => self.resume(),
                    PlaybackStatus::Stopped => self.start_current_or_stop(),
                    PlaybackStatus::Loading | PlaybackStatus::Playing => {}
                }
                Ok(serde_json::json!({}))
            }
            Command::Pause => {
                self.pause();
                Ok(serde_json::json!({}))
            }
            Command::Toggle => {
                match self.status {
                    PlaybackStatus::Playing => self.pause(),
                    PlaybackStatus::Paused => self.resume(),
                    PlaybackStatus::Stopped => self.start_current_or_stop(),
                    PlaybackStatus::Loading => {}
                }
                Ok(serde_json::json!({}))
            }
            Command::Stop => {
                self.stop_playback(StopCause::UserStop);
                Ok(serde_json::json!({}))
            }
            Command::Next => {
                if let Some(index) = self.next_index() {
                    self.jump_to(index);
                } else {
                    self.stop_playback(StopCause::Skip);
                }
                Ok(serde_json::json!({}))
            }
            Command::Previous => {
                let index = self.current.unwrap_or(0).saturating_sub(1);
                self.jump_to(index);
                Ok(serde_json::json!({}))
            }
            Command::Seek { position_ms } => {
                if self.front.is_some() {
                    self.seek(position_ms);
                }
                Ok(serde_json::json!({}))
            }
            Command::SetVolume { volume } => {
                self.volume = volume;
                self.output.player.set_volume(volume_to_f32(volume));
                let _ = self.events.send(PlaybackEvent::VolumeChanged { volume });
                Ok(serde_json::json!({}))
            }
            Command::SetShuffle { enabled } => {
                self.shuffle = enabled;
                if enabled {
                    shuffle_tail(&mut self.queue, self.current);
                    // Shuffle reorders the queue tail: a queue mutation.
                    self.mark_queue_dirty();
                }
                let _ = self.events.send(PlaybackEvent::ShuffleChanged { enabled });
                Ok(serde_json::json!({}))
            }
            Command::SetRepeat { mode } => {
                self.repeat = mode;
                let _ = self.events.send(PlaybackEvent::RepeatChanged { mode });
                Ok(serde_json::json!({}))
            }
            Command::GetSavedQueue | Command::Hello | Command::Ping | Command::GetState => {
                Err(ProtocolError::new(
                    "invalid_request",
                    "command is handled by the protocol server or completes asynchronously",
                ))
            }
        }
    }

    fn configure_server(
        &mut self,
        url: String,
        username: String,
        password: String,
    ) -> Result<serde_json::Value, ProtocolError> {
        let base_url = url.trim().trim_end_matches('/').to_string();
        if let Err(reason) = stream::validate_base_url(&base_url) {
            // The reason is a static string; the URL itself is never echoed.
            return Err(ProtocolError::new("invalid_configuration", reason));
        }
        let username = username.trim().to_string();
        if username.is_empty() {
            return Err(ProtocolError::new(
                "invalid_configuration",
                "username is empty",
            ));
        }
        if password.is_empty() {
            return Err(ProtocolError::new(
                "invalid_configuration",
                "password is empty",
            ));
        }
        self.server = Some(ServerIdentity {
            base_url,
            auth: AuthPair::new(username.clone(), password),
        });
        // session_connected becomes true without a network probe; connectivity
        // problems surface later as typed stream errors instead.
        let _ = self
            .events
            .send(PlaybackEvent::ServerConfigured { username });
        Ok(serde_json::json!({}))
    }

    fn require_server(&self) -> Result<(), ProtocolError> {
        match self.server {
            Some(_) => Ok(()),
            None => Err(ProtocolError::new(
                "missing_credentials",
                "configure the Navidrome server before loading songs",
            )),
        }
    }

    // -- queue / track transitions -------------------------------------------

    fn next_index(&self) -> Option<usize> {
        advance_index(self.current.unwrap_or(0), self.queue.len(), self.repeat)
    }

    /// Replace the queue and start the song at `index`.
    fn begin_segment_with_queue(
        &mut self,
        songs: Vec<SongRef>,
        index: usize,
        position_ms: u32,
        play: bool,
    ) {
        self.stop_playback(StopCause::Replaced);
        self.failures = 0;
        self.queue = songs.into();
        self.current = Some(index);
        self.mark_queue_dirty();
        let song = self.queue[index].clone();
        self.spawn_front(song, index, u64::from(position_ms) / 1000, true);
        if play {
            self.status = PlaybackStatus::Loading;
        } else {
            self.status = PlaybackStatus::Paused;
            let position = self.song_position_ms(Instant::now());
            let _ = self.events.send(PlaybackEvent::Paused {
                position_ms: position,
            });
        }
    }

    /// Start playing the queue entry at `index` from its beginning. Reached
    /// by the Next/Previous skips (and by Play on a stopped queue), so the
    /// track being left follows the skip rule of the scrobble matrix.
    fn jump_to(&mut self, index: usize) {
        self.leave_track(false);
        self.mark_queue_dirty();
        if index >= self.queue.len() {
            self.stop_playback(StopCause::Skip);
            return;
        }
        self.stop_workers();
        self.output.player.clear();
        self.anchor = None;
        self.playhead_base_ms = 0;
        self.last_tick_second = u64::MAX;
        self.current = Some(index);
        let song = self.queue[index].clone();
        self.spawn_front(song, index, 0, true);
        self.status = PlaybackStatus::Loading;
    }

    fn start_current_or_stop(&mut self) {
        match (self.current, self.queue.is_empty()) {
            (Some(index), false) if index < self.queue.len() => {
                if self.front.is_some() {
                    self.resume();
                } else {
                    self.jump_to(index);
                }
            }
            _ => self.stop_playback(StopCause::Skip),
        }
    }

    fn resume(&mut self) {
        if self.front.is_none() || self.status == PlaybackStatus::Playing {
            return;
        }
        self.output.player.play();
        self.anchor = Some(Instant::now());
        self.status = PlaybackStatus::Playing;
        let position = self.song_position_ms(Instant::now());
        let _ = self.events.send(PlaybackEvent::PlaybackStarted {
            position_ms: position,
        });
    }

    fn pause(&mut self) {
        if self.status != PlaybackStatus::Playing {
            return;
        }
        let position = self.song_position_ms(Instant::now());
        self.output.player.pause();
        self.anchor = None;
        self.playhead_base_ms = self.segment_position_ms(Instant::now());
        self.status = PlaybackStatus::Paused;
        let _ = self.events.send(PlaybackEvent::Paused {
            position_ms: position,
        });
    }

    /// Stop playback. A deliberate leave (skip, stop, replaced queue) first
    /// runs the fraction-gated scrobble decision; engine failures must never
    /// scrobble. See [`scrobble_decision`] for the full matrix.
    fn stop_playback(&mut self, cause: StopCause) {
        if cause != StopCause::Failed {
            self.leave_track(false);
        }
        self.stop_playback_without_leave();
    }

    fn stop_playback_without_leave(&mut self) {
        self.stop_workers();
        self.output.player.clear();
        self.output.player.pause();
        self.anchor = None;
        self.playhead_base_ms = 0;
        self.last_tick_second = u64::MAX;
        self.status = PlaybackStatus::Stopped;
        let _ = self.events.send(PlaybackEvent::Stopped);
    }

    fn seek(&mut self, position_ms: u32) {
        let seconds = u64::from(position_ms) / 1000;
        let was_playing = self.status == PlaybackStatus::Playing;
        self.stop_workers();
        self.output.player.clear();
        self.anchor = None;
        // The segment clock restarts at the new offset once the prebuffered
        // audio starts (pump sets the anchor).
        self.playhead_base_ms = 0;
        self.last_tick_second = u64::MAX;
        if let Some(index) = self.current {
            if let Some(song) = self.queue.get(index).cloned() {
                // A seek stays on the same track: no loading transition, and
                // while paused it must stay paused.
                self.spawn_front(song, index, seconds, false);
                self.status = if was_playing {
                    PlaybackStatus::Loading
                } else {
                    PlaybackStatus::Paused
                };
            }
        }
        // Exactly one Seeked per accepted seek so MPRIS emits one Seeked.
        let _ = self.events.send(PlaybackEvent::Seeked {
            position_ms: seconds.saturating_mul(1000) as u32,
        });
    }

    /// Start playing the song at the front from its beginning and reset the
    /// per-track leave bookkeeping.
    fn spawn_front(&mut self, song: SongRef, index: usize, offset_secs: u64, begin: bool) {
        let Some(server) = self.server.as_ref() else {
            return;
        };
        let salt = self.salt.salt();
        let worker = match stream::spawn_worker(
            &self.agent,
            &server.base_url,
            &server.auth,
            salt,
            &song.id,
            &self.format,
            self.max_bit_rate,
            offset_secs,
            self.output.channels,
            self.output.rate,
            self.worker_tx.clone(),
            self.next_worker_seq,
        ) {
            Ok(worker) => worker,
            Err(message) => {
                // The error text comes from the URL builder and is free of
                // credentials by construction.
                log::error!("stream request could not be built: {message}");
                let _ = self.events.send(PlaybackEvent::Error {
                    code: "stream_unavailable".into(),
                    message: "the stream request could not be built".into(),
                });
                return;
            }
        };
        self.next_worker_seq += 1;
        let track = self.build_track(&song);
        let _ = self.events.send(PlaybackEvent::TrackStarted {
            track: track.clone(),
            position_ms: (offset_secs.saturating_mul(1000)).min(u64::from(u32::MAX)) as u32,
            begin,
        });
        self.front = Some(FrontTrack {
            worker,
            song,
            track,
            segment_offset_ms: 0,
            worker_offset_ms: offset_secs.saturating_mul(1000),
            appended_ms: 0,
            eof: false,
            worker_failed: false,
            now_playing_sent: false,
            index,
        });
    }

    fn build_track(&self, song: &SongRef) -> Track {
        // The art URL is the one credential-bearing URL: it is built here and
        // served to the UI as an image source, never logged.
        let art_url = self
            .server
            .as_ref()
            .map(|server| {
                let salt = self.salt.salt();
                stream::build_cover_art_url(
                    &server.base_url,
                    &server.auth,
                    salt.as_str(),
                    song.cover_art.as_str(),
                )
                .unwrap_or_default()
            })
            .unwrap_or_default();
        Track {
            id: song.id.clone(),
            title: song.title.clone(),
            artists: song.artists.clone(),
            album: song.album.clone(),
            art_url,
            duration_ms: song.duration_ms,
            item_type: "track".to_string(),
        }
    }

    // -- worker events -------------------------------------------------------

    fn handle_worker_event(&mut self, event: WorkerEvent) {
        match event {
            WorkerEvent::DownloadDone { seq, outcome } => self.on_download_done(seq, outcome),
            WorkerEvent::DecodeDone { seq, outcome } => self.on_decode_done(seq, outcome),
        }
    }

    fn seq_is_current(&self, seq: u64) -> bool {
        self.front
            .as_ref()
            .is_some_and(|front| front.worker.seq == seq)
            || self
                .pending
                .as_ref()
                .is_some_and(|pending| pending.worker.seq == seq)
    }

    fn on_download_done(&mut self, seq: u64, outcome: DownloadOutcome) {
        if !self.seq_is_current(seq) {
            return; // stale worker from a seek/stop/advance
        }
        let is_front = self
            .front
            .as_ref()
            .is_some_and(|front| front.worker.seq == seq);
        match outcome {
            DownloadOutcome::Completed => {}
            DownloadOutcome::Rejected { status: _ } => {
                // Bad credentials or permissions; no retry helps. The status
                // code is deliberately not echoed to keep URLs/sessions out
                // of any visible message.
                let _ = self.events.send(PlaybackEvent::Error {
                    code: "stream_rejected".into(),
                    message:
                        "Navidrome rejected the stream request. Check the configured server credentials."
                            .into(),
                });
                self.stop_playback(StopCause::Failed);
            }
            DownloadOutcome::Failed => {
                if is_front {
                    if let Some(front) = self.front.as_mut() {
                        front.worker_failed = true;
                    }
                    self.schedule_stream_retry();
                } else if let Some(pending) = self.pending.as_mut() {
                    // A failed preload/retry replacement: drop it and let the
                    // retry scheduler (or the queue advance) recover.
                    log::warn!("preloaded stream for song {} failed", pending.song.id);
                    pending.worker.abort();
                    self.pending = None;
                }
            }
        }
    }

    fn on_decode_done(&mut self, seq: u64, outcome: DecodeOutcome) {
        if !self.seq_is_current(seq) {
            return;
        }
        match outcome {
            DecodeOutcome::Completed => {
                if let Some(front) = self.front.as_mut() {
                    if front.worker.seq == seq {
                        front.eof = true;
                        self.failures = 0;
                    }
                }
                if let Some(pending) = self.pending.as_mut() {
                    if pending.worker.seq == seq {
                        pending.eof = true;
                    }
                }
            }
            DecodeOutcome::Failed(reason) => {
                // A container the decoder cannot read will not fix itself; a
                // server-side transcode format usually resolves it.
                log::error!("stream decode failed: {reason}");
                let _ = self.events.send(PlaybackEvent::Error {
                    code: "stream_unavailable".into(),
                    message: "the stream could not be decoded".into(),
                });
                self.stop_playback(StopCause::Failed);
            }
        }
    }

    /// Bounded mid-stream recovery: at most `MAX_STREAM_ATTEMPTS` restarts,
    /// each resuming the stream after the buffered playhead, then a typed
    /// error — never an unbounded reconnect loop.
    fn schedule_stream_retry(&mut self) {
        if !stream::stream_retry_allowed(self.failures) {
            let _ = self.events.send(PlaybackEvent::Error {
                code: "stream_unavailable".into(),
                message: "Navidrome stopped serving the stream".into(),
            });
            self.stop_playback(StopCause::Failed);
            return;
        }
        self.failures += 1;
        let attempt = self.failures;
        log::warn!(
            "stream interrupted after {} buffered ms; scheduling retry {attempt}",
            self.front.as_ref().map_or(0, |front| front.appended_ms)
        );
        self.retry = Some(RetryState {
            at: Instant::now() + Duration::from_millis(stream::retry_backoff_ms(attempt)),
        });
    }

    /// Spawn a replacement worker that continues the current song after the
    /// buffered audio (the player queue keeps its FIFO order, so no already
    /// buffered samples are lost or duplicated).
    fn spawn_retry_worker(&mut self) {
        let Some(front) = self.front.as_ref() else {
            self.retry = None;
            return;
        };
        let resume_at = front.worker_offset_ms + front.appended_ms;
        let seconds = resume_at / 1000;
        let Some(server) = self.server.as_ref() else {
            self.retry = None;
            return;
        };
        let salt = self.salt.salt();
        match stream::spawn_worker(
            &self.agent,
            &server.base_url,
            &server.auth,
            salt,
            &front.song.id,
            &self.format,
            self.max_bit_rate,
            seconds,
            self.output.channels,
            self.output.rate,
            self.worker_tx.clone(),
            self.next_worker_seq,
        ) {
            Ok(worker) => {
                self.next_worker_seq += 1;
                let song = front.song.clone();
                let track = front.track.clone();
                let index = front.index;
                self.pending = Some(PendingTrack {
                    worker,
                    song,
                    track,
                    worker_offset_ms: resume_at,
                    appended_ms: 0,
                    eof: false,
                    index,
                });
            }
            Err(message) => {
                log::error!("stream retry could not be built: {message}");
                let _ = self.events.send(PlaybackEvent::Error {
                    code: "stream_unavailable".into(),
                    message: "the stream could not be resumed".into(),
                });
                self.stop_playback(StopCause::Failed);
            }
        }
        self.retry = None;
    }

    // -- playback progress ----------------------------------------------------

    fn pump(&mut self, now: Instant) {
        // Debounced savePlayQueue and write outcomes first: they must drain
        // on every tick, including idle ones with no front.
        self.pump_queue_save(now);

        // A scheduled bounded retry comes due here.
        let retry_due = self.retry.as_ref().is_some_and(|retry| now >= retry.at);
        if retry_due {
            self.spawn_retry_worker();
        }

        self.append_pcm();
        if self.front.is_none() {
            return;
        }

        let segment_position = self.segment_position_ms(now);
        let position = self.song_position_ms(now);

        // One position update per second.
        let second = u64::from(position) / POSITION_TICK_MS;
        if self.status == PlaybackStatus::Playing && second != self.last_tick_second {
            self.last_tick_second = second;
            let _ = self.events.send(PlaybackEvent::PositionTick {
                position_ms: position,
            });
        }

        self.maybe_preload(position);

        // Track boundary: the front is fully buffered and fully played.
        if let Some(front) = self.front.as_ref() {
            let played_in_front = segment_position.saturating_sub(front.segment_offset_ms);
            if front.drained() && played_in_front >= front.appended_ms {
                self.advance_after_track_end();
            }
        }

        // Readiness: the loading state was already announced; start the sink
        // once the prebuffer lead is decoded.
        if self.status == PlaybackStatus::Loading {
            if let Some(front) = self.front.as_ref() {
                let buffered = front.appended_ms >= stream::PREBUFFER_MS || front.drained();
                if buffered {
                    self.output.player.play();
                    self.anchor = Some(now);
                    // The segment clock starts at zero here; the front's seek
                    // offset lives in worker_offset_ms and is added per song.
                    self.playhead_base_ms = 0;
                    self.last_tick_second = u64::MAX;
                    self.status = PlaybackStatus::Playing;
                    let position = self.song_position_ms(now);
                    let _ = self.events.send(PlaybackEvent::PlaybackStarted {
                        position_ms: position,
                    });
                }
            }
        }

        // A track whose audio just started (fresh front, gapless hand-off,
        // resume, or post-seek rebuild) fires its now-playing hint once.
        if self.status == PlaybackStatus::Playing {
            self.send_now_playing();
        }
    }

    fn append_pcm(&mut self) {
        if let Some(front) = self.front.as_ref() {
            let mut chunks = Vec::new();
            while let Some(chunk) = front.worker.pcm.try_pop() {
                chunks.push(chunk);
            }
            let mut appended_ms = front.appended_ms;
            for chunk in chunks {
                let ms = chunk_ms(&chunk, self.output.rate);
                if ms > 0 {
                    let (channels, rate) =
                        rodio_sample_format(self.output.channels, self.output.rate);
                    self.output.player.append(rodio::buffer::SamplesBuffer::new(
                        channels,
                        rate,
                        chunk.samples,
                    ));
                    appended_ms += ms;
                }
            }
            if let Some(front) = self.front.as_mut() {
                front.appended_ms = appended_ms;
            }
        }
        // Preloaded next-track PCM is appended after the front's, so the
        // player's FIFO order stays song-accurate even though these chunks
        // are queued long before the boundary.
        if let Some(pending) = self.pending.as_ref() {
            let mut chunks = Vec::new();
            while let Some(chunk) = pending.worker.pcm.try_pop() {
                chunks.push(chunk);
            }
            let mut appended_ms = pending.appended_ms;
            for chunk in chunks {
                let ms = chunk_ms(&chunk, self.output.rate);
                if ms > 0 {
                    let (channels, rate) =
                        rodio_sample_format(self.output.channels, self.output.rate);
                    self.output.player.append(rodio::buffer::SamplesBuffer::new(
                        channels,
                        rate,
                        chunk.samples,
                    ));
                    appended_ms += ms;
                }
            }
            if let Some(pending) = self.pending.as_mut() {
                pending.appended_ms = appended_ms;
            }
        }
    }

    fn maybe_preload(&mut self, position_ms: u32) {
        if self.pending.is_some() {
            return;
        }
        let Some(front) = self.front.as_ref() else {
            return;
        };
        let duration = u64::from(front.song.duration_ms);
        let played = u64::from(position_ms).saturating_sub(front.worker_offset_ms);
        let by_duration = duration > 0 && played + stream::PRELOAD_LOOKAHEAD_MS >= duration;
        let by_buffered = front.drained()
            && front.appended_ms.saturating_sub(played) <= stream::PRELOAD_LOOKAHEAD_MS;
        if !(by_duration || by_buffered) {
            return;
        }
        let Some(next_index) = advance_index(front.index, self.queue.len(), self.repeat) else {
            return;
        };
        if next_index == front.index {
            // Repeat-track restarts are handled at the boundary; no preload.
            return;
        }
        let Some(song) = self.queue.get(next_index).cloned() else {
            return;
        };
        let Some(server) = self.server.as_ref() else {
            return;
        };
        let salt = self.salt.salt();
        match stream::spawn_worker(
            &self.agent,
            &server.base_url,
            &server.auth,
            salt,
            &song.id,
            &self.format,
            self.max_bit_rate,
            0,
            self.output.channels,
            self.output.rate,
            self.worker_tx.clone(),
            self.next_worker_seq,
        ) {
            Ok(worker) => {
                self.next_worker_seq += 1;
                let track = self.build_track(&song);
                self.pending = Some(PendingTrack {
                    worker,
                    song,
                    track,
                    worker_offset_ms: 0,
                    appended_ms: 0,
                    eof: false,
                    index: next_index,
                });
            }
            Err(message) => {
                log::warn!("preloading song {} failed: {message}", song.id);
            }
        }
    }

    fn advance_after_track_end(&mut self) {
        // The queue drained the current song into the next one: this is the
        // natural end. The submission lands unconditionally when the decoder
        // reached the true end of stream; a worker that died mid-stream
        // (eof=false) leaves a partially heard song and follows the skip
        // rule instead.
        self.leave_track(self.front.as_ref().is_some_and(|front| front.eof));
        let finished = self.front.take().expect("boundary with no front");
        finished.worker.abort();
        if finished.eof {
            // A fully decoded track counts as success for the retry budget.
            self.failures = 0;
        }
        let segment_end = finished.segment_offset_ms + finished.appended_ms;
        // The current index changes here: a queue mutation for persistence.
        self.mark_queue_dirty();
        match self.pending.take() {
            Some(pending) => {
                // Gapless hand-off: rodio already queued this song's decoded
                // audio behind the finished track.
                self.current = Some(pending.index);
                self.front = Some(FrontTrack {
                    worker: pending.worker,
                    song: pending.song,
                    track: pending.track,
                    segment_offset_ms: segment_end,
                    worker_offset_ms: pending.worker_offset_ms,
                    appended_ms: pending.appended_ms,
                    eof: pending.eof,
                    worker_failed: false,
                    now_playing_sent: false,
                    index: pending.index,
                });
                let _ = self.events.send(PlaybackEvent::TrackStarted {
                    track: self.front.as_ref().unwrap().track.clone(),
                    position_ms: 0,
                    begin: false,
                });
            }
            None => match advance_index(finished.index, self.queue.len(), self.repeat) {
                Some(index) => {
                    // Nothing preloaded: an audible gap while the next song
                    // buffers, so the loading state is published again.
                    self.anchor = None;
                    self.playhead_base_ms = 0;
                    self.last_tick_second = u64::MAX;
                    self.current = Some(index);
                    let song = self.queue[index].clone();
                    self.spawn_front(song, index, 0, true);
                    self.status = PlaybackStatus::Loading;
                }
                // The natural-end leave already ran at the top of this
                // method; stopping here must not decide again.
                None => self.stop_playback_without_leave(),
            },
        }
    }

    // -- clock ---------------------------------------------------------------

    /// Position on the segment clock: `playhead_base_ms` at the anchor
    /// moment, advancing with wall-clock time while playing.
    fn segment_position_ms(&self, now: Instant) -> u64 {
        match self.anchor {
            Some(anchor) => {
                self.playhead_base_ms + now.saturating_duration_since(anchor).as_millis() as u64
            }
            None => self.playhead_base_ms,
        }
    }

    /// Song position derived from the decode clock: the segment position
    /// minus everything appended before this front, clamped to what is
    /// actually buffered (and to the declared duration when known).
    fn song_position_ms(&self, now: Instant) -> u32 {
        let Some(front) = &self.front else {
            return self.playhead_base_ms.min(u64::from(u32::MAX)) as u32;
        };
        let segment_position = self.segment_position_ms(now);
        let played_in_front = segment_position.saturating_sub(front.segment_offset_ms);
        let buffered_ceiling = front.worker_offset_ms + front.appended_ms;
        let mut position = front.worker_offset_ms.saturating_add(played_in_front);
        position = position.min(buffered_ceiling);
        if front.song.duration_ms > 0 {
            position = position.min(u64::from(front.song.duration_ms));
        }
        position.min(u64::from(u32::MAX)) as u32
    }

    // -- scrobble and play-queue persistence ---------------------------------

    /// Fire-and-forget `scrobble` over the off-thread worker. Requires a
    /// configured server; without one the call is dropped silently.
    fn send_scrobble(&mut self, song_id: &str, submission: bool) {
        if !self.scrobble_enabled {
            return;
        }
        let Some(server) = self.server.as_ref() else {
            return;
        };
        let salt = self.salt.salt();
        match stream::build_scrobble_url(&server.base_url, &server.auth, &salt, song_id, submission)
        {
            Ok(url) => {
                // Off-thread: the write must never stall audio or the
                // command loop. Uncertain outcomes are never retried (a
                // double submission would corrupt the play count).
                let _ = self.http_tx.send(HttpWork::Scrobble {
                    song_id: song_id.to_string(),
                    url,
                });
            }
            Err(message) => {
                // Builder errors are credential-free static strings.
                log::warn!("scrobble request could not be built: {message}");
            }
        }
    }

    /// submission=false on a front's first audible start. Harmless per the
    /// plan: it only refreshes the server's now-playing hint.
    fn send_now_playing(&mut self) {
        let Some(front) = self.front.as_ref() else {
            return;
        };
        if front.now_playing_sent {
            return;
        }
        let song_id = front.song.id.clone();
        self.send_scrobble(&song_id, false);
        if let Some(front) = self.front.as_mut() {
            front.now_playing_sent = true;
        }
    }

    /// Leaving the current track. `natural_end` is true only when the
    /// decoder reached the true end of stream — the queue drained the song
    /// into the next one, and the submission lands regardless of the
    /// fraction. Every other leave (skip, stop, replaced queue) follows the
    /// Audioscrobbler rule: at least half the track or four minutes heard,
    /// else dropped silently. A worker that died mid-stream leaves a
    /// partially heard song even when its buffered audio finished playing,
    /// so eof=false follows the skip rule too.
    fn leave_track(&mut self, natural_end: bool) {
        let Some(front) = self.front.as_ref() else {
            return;
        };
        let played_ms = u64::from(self.song_position_ms(Instant::now()));
        let duration_ms = front.song.duration_ms;
        if !scrobble_decision(played_ms, duration_ms, natural_end) {
            return;
        }
        let song_id = front.song.id.clone();
        self.send_scrobble(&song_id, true);
    }

    /// A queue mutation happened (load, add_to_queue, advance, skip,
    /// shuffle): schedule one debounced save.
    fn mark_queue_dirty(&mut self) {
        self.queue_save.mark_dirty(Instant::now());
    }

    /// Enqueue one savePlayQueue for the queue as it stands. Returns false
    /// when there is nothing to save (no server or empty queue) or the
    /// request could not be built; builder errors are credential-free.
    fn send_queue_save(&mut self, seq: u64) -> bool {
        let Some(server) = self.server.as_ref() else {
            return false;
        };
        if self.queue.is_empty() {
            return false;
        }
        let current = self
            .current
            .map_or(0, |index| index.min(self.queue.len() - 1));
        let current_id = self.queue[current].id.clone();
        let ids: Vec<String> = self.queue.iter().map(|song| song.id.clone()).collect();
        // Subsonic's `current` carries the current song's id; `position` is
        // its position in milliseconds (omitted at 0, which servers treat
        // as 0 anyway).
        let position_ms = u64::from(self.song_position_ms(Instant::now()));
        let salt = self.salt.salt();
        match stream::build_save_play_queue_url(
            &server.base_url,
            &server.auth,
            &salt,
            &ids,
            &current_id,
            (position_ms > 0).then_some(position_ms),
        ) {
            Ok(url) => {
                let _ = self.http_tx.send(HttpWork::SaveQueue { seq, url });
                true
            }
            Err(message) => {
                log::warn!("play queue save could not be built: {message}");
                false
            }
        }
    }

    fn pump_queue_save(&mut self, now: Instant) {
        while let Ok(outcome) = self.http_outcomes.try_recv() {
            self.handle_http_outcome(outcome, now);
        }
        if self.queue_save.due(now) {
            let seq = self.queue_save_seq;
            self.queue_save_seq += 1;
            self.queue_save.fired();
            // Nothing to save (server gone, queue emptied): drop silently.
            let _ = self.send_queue_save(seq);
        }
    }

    fn handle_http_outcome(&mut self, outcome: HttpOutcome, now: Instant) {
        match outcome {
            HttpOutcome::Scrobbled { song_id, outcome } => match outcome {
                stream::WriteOutcome::Completed => {
                    log::debug!("scrobble recorded for song {song_id}");
                }
                stream::WriteOutcome::Rejected => {
                    // Definite failure: dropped without retry. Only the song
                    // id is ever named — never the URL, token, or salt.
                    log::debug!("scrobble for song {song_id} was rejected");
                }
                stream::WriteOutcome::Transport => {
                    // Uncertain: the write may have landed before the
                    // connection broke. Never retried — a second submission
                    // would corrupt the play count.
                    log::warn!("scrobble for song {song_id} is uncertain; not retried");
                }
            },
            HttpOutcome::QueueSaved { outcome, .. } => match outcome {
                stream::WriteOutcome::Completed => self.queue_save.succeeded(),
                stream::WriteOutcome::Rejected | stream::WriteOutcome::Transport => {
                    // savePlayQueue is idempotent, so one retry within this
                    // dirty state is bounded and safe; past the budget the
                    // possibly-landed save is reported uncertain and dropped.
                    if !self.queue_save.failed(now) {
                        log::warn!(
                            "saving the play queue did not confirm; given up for this state"
                        );
                    }
                }
            },
        }
    }

    /// Clean shutdown/idle: one final savePlayQueue with the queue as it
    /// stands, regardless of the debounce, so the next session resumes the
    /// exact track and position. Bounded to `QUEUE_SAVE_SHUTDOWN_WAIT` so a
    /// dead server cannot hang the process; an unconfirmed final save is
    /// reported as uncertain, never retried.
    fn final_queue_save(&mut self) {
        if self.queue.is_empty() || self.server.is_none() {
            return;
        }
        let seq = self.queue_save_seq;
        self.queue_save_seq += 1;
        if !self.send_queue_save(seq) {
            return;
        }
        let deadline = Instant::now() + QUEUE_SAVE_SHUTDOWN_WAIT;
        loop {
            match self.http_outcomes.recv_timeout(Duration::from_millis(250)) {
                Ok(HttpOutcome::QueueSaved { seq: done, .. }) if done == seq => return,
                Ok(_) => {}
                Err(std_mpsc::RecvTimeoutError::Timeout) => {}
                Err(std_mpsc::RecvTimeoutError::Disconnected) => return,
            }
            if Instant::now() >= deadline {
                log::warn!("the final queue save did not confirm in time; it may not have landed");
                return;
            }
        }
    }

    /// get_saved_queue: read the server-persisted play queue without loading
    /// it (the engine never auto-restores; the caller decides). Completes
    /// off-thread so the command loop never blocks on the server.
    fn get_saved_queue(
        &mut self,
        reply: Option<oneshot::Sender<Result<serde_json::Value, ProtocolError>>>,
    ) {
        let Some(reply) = reply else {
            return;
        };
        let Some(server) = self.server.as_ref() else {
            let _ = reply.send(Err(ProtocolError::new(
                "missing_credentials",
                "configure the Navidrome server before reading the saved queue",
            )));
            return;
        };
        let salt = self.salt.salt();
        match stream::build_get_play_queue_url(&server.base_url, &server.auth, &salt) {
            Ok(url) => {
                let _ = self.http_tx.send(HttpWork::GetSavedQueue { url, reply });
            }
            Err(message) => {
                log::warn!("saved queue request could not be built: {message}");
                let _ = reply.send(Err(ProtocolError::new(
                    "stream_unavailable",
                    "the saved play queue could not be read",
                )));
            }
        }
    }

    fn stop_workers(&mut self) {
        if let Some(front) = self.front.take() {
            front.worker.abort();
        }
        if let Some(pending) = self.pending.take() {
            pending.worker.abort();
        }
        self.retry = None;
    }
}

fn chunk_ms(chunk: &PcmChunk, rate: u32) -> u64 {
    if rate == 0 {
        return 0;
    }
    u64::from(chunk.frames as u32) * 1000 / u64::from(rate)
}

fn rodio_sample_format(channels: u16, rate: u32) -> (rodio::ChannelCount, rodio::SampleRate) {
    (
        std::num::NonZero::new(channels).expect("non-zero channel count"),
        std::num::NonZero::new(rate).expect("non-zero sample rate"),
    )
}

/// Next queue index for a skip or a track boundary. `RepeatMode::Track`
/// restarts the current song, `Context` wraps at the end, `Off` stops.
fn advance_index(current: usize, len: usize, repeat: RepeatMode) -> Option<usize> {
    if len == 0 {
        return None;
    }
    let current = current.min(len - 1);
    match repeat {
        RepeatMode::Track => Some(current),
        RepeatMode::Context => Some(if current + 1 < len { current + 1 } else { 0 }),
        RepeatMode::Off => (current + 1 < len).then_some(current + 1),
    }
}

/// Shuffle the not-yet-played tail of the queue, keeping the current song in
/// place. `fastrand` supplies the randomness.
fn shuffle_tail(queue: &mut VecDeque<SongRef>, current: Option<usize>) {
    let start = current.map_or(0, |index| index + 1);
    if start >= queue.len() {
        return;
    }
    let tail: Vec<SongRef> = queue.drain(start..).collect();
    let mut tail = tail;
    fastrand::shuffle(&mut tail);
    queue.extend(tail);
}

/// FIFO forwarding of a local (socket/MPRIS) command into the pipeline. Every
/// command is queued in arrival order and executed sequentially, which is the
/// guarantee Pause relies on: a Play/Toggle/Next/Previous behind it cannot
/// overtake it.
fn dispatch_local_command(
    command: Command,
    mut send: impl FnMut(Command) -> Result<serde_json::Value, ProtocolError>,
) -> Result<serde_json::Value, ProtocolError> {
    send(command)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::BackendState;

    fn track(id: &str) -> Track {
        Track {
            id: id.to_string(),
            title: "A song".into(),
            artists: vec!["An artist".into()],
            album: "An album".into(),
            art_url: String::new(),
            duration_ms: 42_000,
            item_type: "track".into(),
        }
    }

    #[test]
    fn replacement_track_keeps_playing_status_continuous() {
        let mut state = BackendState {
            playback: PlaybackStatus::Playing,
            position_ms: 42_000,
            ..BackendState::default()
        };
        let event = PlaybackEvent::TrackStarted {
            track: track("next"),
            position_ms: 0,
            begin: false,
        };
        assert!(apply_event(&mut state, &event));
        assert_eq!(state.playback, PlaybackStatus::Playing);
        assert_eq!(state.position_ms, 0);
        assert_eq!(state.track.as_ref().unwrap().id, "next");
    }

    #[test]
    fn begin_track_publishes_loading_before_the_first_sample() {
        let mut state = BackendState::default();
        let event = PlaybackEvent::TrackStarted {
            track: track("42"),
            position_ms: 0,
            begin: true,
        };
        assert!(apply_event(&mut state, &event));
        assert_eq!(state.playback, PlaybackStatus::Loading);
        assert!(state.error_code.is_empty());
    }

    #[test]
    fn repeated_position_ticks_do_not_publish_duplicate_state() {
        let mut state = BackendState {
            playback: PlaybackStatus::Playing,
            position_ms: 1_000,
            ..BackendState::default()
        };
        let event = PlaybackEvent::PositionTick { position_ms: 1_000 };
        assert!(!apply_event(&mut state, &event));

        let event = PlaybackEvent::PositionTick { position_ms: 2_000 };
        assert!(apply_event(&mut state, &event));
        assert_eq!(state.position_ms, 2_000);
    }

    #[test]
    fn explicit_seek_is_published_even_when_position_is_unchanged() {
        let mut state = BackendState {
            position_ms: 1_000,
            ..BackendState::default()
        };
        let event = PlaybackEvent::Seeked { position_ms: 1_000 };
        assert!(apply_event(&mut state, &event));
        assert_eq!(state.seek_sequence, 1);
        assert_eq!(state.position_ms, 1_000);
    }

    #[test]
    fn error_codes_are_typed_and_cleared_by_the_next_track() {
        let mut state = BackendState::default();

        let rejected = PlaybackEvent::Error {
            code: "stream_rejected".into(),
            message: "Navidrome rejected the stream request".into(),
        };
        assert!(apply_event(&mut state, &rejected));
        assert_eq!(state.error_code, "stream_rejected");

        let unavailable = PlaybackEvent::Error {
            code: "stream_unavailable".into(),
            message: "Navidrome stopped serving the stream".into(),
        };
        assert!(apply_event(&mut state, &unavailable));
        assert_eq!(state.error_code, "stream_unavailable");
        assert_eq!(state.error, "Navidrome stopped serving the stream");

        let event = PlaybackEvent::TrackStarted {
            track: track("42"),
            position_ms: 0,
            begin: true,
        };
        assert!(apply_event(&mut state, &event));
        assert!(state.error_code.is_empty());
        assert!(state.error.is_empty());
    }

    #[test]
    fn stopped_clears_track_and_position() {
        let mut state = BackendState {
            playback: PlaybackStatus::Playing,
            position_ms: 9_000,
            track: Some(track("42")),
            ..BackendState::default()
        };
        assert!(apply_event(&mut state, &PlaybackEvent::Stopped));
        assert_eq!(state.playback, PlaybackStatus::Stopped);
        assert_eq!(state.position_ms, 0);
        assert!(state.track.is_none());
    }

    #[test]
    fn server_configuration_connects_the_session_without_a_probe() {
        let mut state = BackendState::default();
        let event = PlaybackEvent::ServerConfigured {
            username: "user".into(),
        };
        assert!(apply_event(&mut state, &event));
        assert!(state.session_connected);
        assert_eq!(state.username, "user");
        assert_eq!(state.engine, "navidrome-stream");
        // No credential-shaped field exists in the state at all.
        let encoded = serde_json::to_value(&state).unwrap();
        assert!(encoded.get("password").is_none());
        assert!(encoded.get("url").is_none());
    }

    #[test]
    fn volume_maps_linearly_to_the_sink_gain() {
        assert_eq!(volume_to_f32(0), 0.0);
        assert_eq!(volume_to_f32(u16::MAX), 1.0);
        // u16::MAX/2 is one step below the exact midpoint; linear mapping
        // keeps it within a rounding step of 0.5.
        assert!((volume_to_f32(u16::MAX / 2) - 0.5).abs() < 1e-4);
        assert!((volume_to_f32(32_768) - 0.5).abs() < 1e-4);
    }

    #[test]
    fn queue_advances_by_repeat_mode() {
        assert_eq!(advance_index(0, 3, RepeatMode::Off), Some(1));
        assert_eq!(advance_index(2, 3, RepeatMode::Off), None);
        assert_eq!(advance_index(2, 3, RepeatMode::Context), Some(0));
        assert_eq!(advance_index(1, 3, RepeatMode::Track), Some(1));
        assert_eq!(advance_index(0, 0, RepeatMode::Context), None);
    }

    #[test]
    fn scrobble_decision_follows_the_submission_matrix() {
        // Natural end: always submitted, whatever the fraction.
        assert!(scrobble_decision(0, 0, true));
        assert!(scrobble_decision(1_000, 500_000, true));
        // Fraction rule boundary: exactly half counts.
        assert!(scrobble_decision(500, 1_000, false));
        assert!(!scrobble_decision(499, 1_000, false));
        // Four-minute rule boundary: counts regardless of the fraction.
        assert!(scrobble_decision(240_000, 600_000, false));
        assert!(!scrobble_decision(239_999, 600_000, false));
        // Unknown duration relies on the four-minute rule alone.
        assert!(scrobble_decision(240_000, 0, false));
        assert!(!scrobble_decision(239_999, 0, false));
        // Below both thresholds: dropped silently.
        assert!(!scrobble_decision(90_000, 300_000, false));
    }

    #[test]
    fn queue_save_burst_coalesces_into_one_debounced_save() {
        let start = Instant::now();
        let mut scheduler = QueueSaveScheduler::new();
        // A burst of mutations inside the window marks dirty once.
        scheduler.mark_dirty(start);
        scheduler.mark_dirty(start + Duration::from_millis(100));
        scheduler.mark_dirty(start + Duration::from_millis(200));
        assert!(!scheduler.due(start));
        assert!(!scheduler.due(start + Duration::from_secs(4)));
        assert!(scheduler.due(start + QUEUE_SAVE_DEBOUNCE));
        // One fired save clears the state and spends one attempt.
        scheduler.fired();
        assert!(!scheduler.due(start + QUEUE_SAVE_DEBOUNCE + QUEUE_SAVE_DEBOUNCE));
        assert_eq!(scheduler.attempts, 1);
    }

    #[test]
    fn failed_queue_save_retries_once_then_drops_the_state() {
        let start = Instant::now();
        let mut scheduler = QueueSaveScheduler::new();
        scheduler.mark_dirty(start);
        scheduler.fired();
        // First failure: one bounded retry is scheduled soon.
        assert!(scheduler.failed(start));
        assert!(scheduler.due(start + QUEUE_SAVE_RETRY_DELAY));
        scheduler.fired();
        // Second failure: budget spent, the possibly-landed save is dropped.
        assert!(!scheduler.failed(start));
        assert!(!scheduler.dirty);
        assert_eq!(scheduler.attempts, 0);
    }

    #[test]
    fn new_queue_mutation_and_success_reset_the_save_budget() {
        let start = Instant::now();
        let mut scheduler = QueueSaveScheduler::new();
        scheduler.mark_dirty(start);
        scheduler.fired();
        scheduler.failed(start);
        // A new mutation starts a fresh bounded budget.
        scheduler.mark_dirty(start);
        assert_eq!(scheduler.attempts, 0);
        scheduler.fired();
        scheduler.succeeded();
        assert_eq!(scheduler.attempts, 0);
        assert!(!scheduler.dirty);
    }

    #[test]
    fn saved_queue_result_shape_is_typed_and_defensive() {
        let queue = stream::ParsedPlayQueue {
            songs: vec![SongRef {
                id: "tr-1".into(),
                title: "Song".into(),
                artists: vec!["Artist".into()],
                album: "Album".into(),
                duration_ms: 180_000,
                cover_art: "cr-1".into(),
                track: Some(3),
            }],
            current_id: "tr-1".into(),
            current_index: 0,
            position_ms: 42_000,
        };
        let value = saved_queue_result(stream::ReadOutcome::Parsed(queue)).unwrap();
        assert_eq!(value["songs"][0]["id"], "tr-1");
        assert_eq!(value["songs"][0]["duration_ms"], 180_000);
        assert_eq!(value["current_id"], "tr-1");
        assert_eq!(value["current_index"], 0);
        assert_eq!(value["position_ms"], 42_000);

        // Read failures are typed, credential-free errors.
        for outcome in [
            stream::ReadOutcome::Rejected,
            stream::ReadOutcome::Transport,
        ] {
            let error = saved_queue_result(outcome).unwrap_err();
            assert_eq!(error.code, "stream_unavailable");
            assert!(!error.message.contains("http"));
            assert!(!error.message.contains("token"));
        }
    }

    #[test]
    fn shuffle_tail_keeps_the_current_song_first() {
        let songs: Vec<SongRef> = (0..5)
            .map(|id| SongRef {
                id: id.to_string(),
                ..SongRef::default()
            })
            .collect();
        let mut queue: VecDeque<SongRef> = songs.into();
        shuffle_tail(&mut queue, Some(0));
        assert_eq!(queue[0].id, "0");
        let mut ids: Vec<&str> = queue.iter().map(|song| song.id.as_str()).collect();
        ids.sort_unstable();
        assert_eq!(ids, vec!["0", "1", "2", "3", "4"]);
    }

    #[test]
    fn fire_and_forget_command_queue_is_bounded() {
        let (commands, _receiver) = mpsc::channel(1);
        assert!(send_without_reply(&commands, Command::Play).is_ok());
        let error = send_without_reply(&commands, Command::Pause).unwrap_err();
        assert_eq!(error.code, "engine_busy");
    }
}

#[cfg(test)]
mod local_control_tests {
    use super::*;

    // Models the pipeline as a receiver with retained playback. Commands are
    // forwarded in arrival order; there is no activation step to race.
    #[derive(Default)]
    struct Receiver {
        playing: bool,
        index: i32,
        commands: Vec<Command>,
    }

    impl Receiver {
        fn send(&mut self, command: Command) -> Result<serde_json::Value, ProtocolError> {
            self.commands.push(command.clone());
            match command {
                Command::Play => self.playing = true,
                Command::Pause => self.playing = false,
                Command::Toggle => self.playing = !self.playing,
                Command::Next => self.index += 1,
                Command::Previous => self.index -= 1,
                _ => {}
            }
            Ok(serde_json::json!({}))
        }

        fn dispatch(&mut self, command: Command) {
            dispatch_local_command(command, |command| self.send(command)).unwrap();
        }
    }

    #[test]
    fn play_then_pause_cannot_be_reordered() {
        let mut receiver = Receiver::default();
        receiver.dispatch(Command::Play);
        receiver.dispatch(Command::Pause);
        assert!(!receiver.playing);
        assert_eq!(receiver.commands, vec![Command::Play, Command::Pause]);
    }

    #[test]
    fn repeated_skips_and_previous_keep_every_action_in_order() {
        let mut receiver = Receiver::default();
        receiver.dispatch(Command::Next);
        receiver.dispatch(Command::Next);
        assert_eq!(receiver.index, 2);
        receiver.dispatch(Command::Previous);
        assert_eq!(receiver.index, 1);
        assert_eq!(
            receiver.commands,
            vec![Command::Next, Command::Next, Command::Previous]
        );
    }

    #[test]
    fn toggle_flips_retained_playback_in_arrival_order() {
        let mut receiver = Receiver::default();
        receiver.dispatch(Command::Toggle);
        assert!(receiver.playing);
        receiver.dispatch(Command::Toggle);
        assert!(!receiver.playing);
    }

    #[test]
    fn play_is_idempotent_for_active_playback() {
        let mut receiver = Receiver {
            playing: true,
            ..Receiver::default()
        };
        receiver.dispatch(Command::Play);
        assert!(receiver.playing);
    }

    #[test]
    fn pause_and_other_transport_commands_keep_exact_order() {
        let mut receiver = Receiver::default();
        let commands = vec![
            Command::Pause,
            Command::Stop,
            Command::Seek { position_ms: 1000 },
            Command::SetVolume { volume: 100 },
            Command::SetShuffle { enabled: true },
            Command::SetRepeat {
                mode: RepeatMode::Track,
            },
        ];
        for command in &commands {
            receiver.dispatch(command.clone());
        }
        assert!(!receiver.playing);
        assert_eq!(receiver.commands, commands);
    }

    #[test]
    fn forwarding_errors_propagate_to_the_caller() {
        let result = dispatch_local_command(Command::Play, |_| {
            Err(ProtocolError::new("engine_unavailable", "pipeline closed"))
        });
        let error = result.unwrap_err();
        assert_eq!(error.code, "engine_unavailable");
    }
}
