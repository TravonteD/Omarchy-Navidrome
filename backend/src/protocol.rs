use serde::{Deserialize, Serialize};

pub const PROTOCOL_VERSION: u16 = 2;
pub const ENGINE_NAME: &str = "navidrome-stream";

/// Song reference sent by the QML layer with metadata it already has. Only
/// `id` (the Subsonic song id) is required for playback; every other field is
/// optional metadata used for immediate UI feedback. The engine streams by id
/// regardless of whether the other fields are populated.
#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
pub struct SongRef {
    pub id: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub artists: Vec<String>,
    #[serde(default)]
    pub album: String,
    #[serde(default)]
    pub duration_ms: u32,
    #[serde(default)]
    pub cover_art: String,
    #[serde(default)]
    pub track: Option<u32>,
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct Request {
    pub v: u16,
    pub id: u64,
    #[serde(flatten)]
    pub command: Command,
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(tag = "command", rename_all = "snake_case")]
pub enum Command {
    Hello,
    Ping,
    GetState,
    Play,
    Pause,
    Toggle,
    Stop,
    Next,
    Previous,
    Seek {
        position_ms: u32,
    },
    SetVolume {
        volume: u16,
    },
    SetShuffle {
        enabled: bool,
    },
    SetRepeat {
        mode: RepeatMode,
    },
    /// Identity + credentials for the Navidrome server, kept in engine memory
    /// only. Never logged, never serialized into state, never echoed in an
    /// error message.
    ConfigureServer {
        url: String,
        username: String,
        password: String,
    },
    Load {
        #[serde(default)]
        songs: Vec<SongRef>,
        #[serde(default)]
        offset_index: Option<u32>,
        #[serde(default)]
        position_ms: u32,
        #[serde(default = "default_true")]
        play: bool,
    },
    AddToQueue {
        song: SongRef,
    },
}

const fn default_true() -> bool {
    true
}

impl SongRef {
    #[cfg(test)]
    fn default_with_id(id: &str) -> Self {
        Self {
            id: id.to_string(),
            ..Self::default()
        }
    }
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RepeatMode {
    #[default]
    Off,
    Context,
    Track,
}

#[derive(Clone, Copy, Debug, Default, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Lifecycle {
    #[default]
    Starting,
    Ready,
    Error,
    Stopped,
}

#[derive(Clone, Copy, Debug, Default, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum PlaybackStatus {
    #[default]
    Stopped,
    Loading,
    Playing,
    Paused,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct Track {
    /// Subsonic song id (was `uri` under the Spotify protocol).
    pub id: String,
    pub title: String,
    pub artists: Vec<String>,
    pub album: String,
    /// getCoverArt URL built by the backend including its auth token params.
    /// This is the one place credentials ride in a URL (served to the UI as an
    /// image source); it must never appear in a log line or error message.
    pub art_url: String,
    pub duration_ms: u32,
    pub item_type: String,
}

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct BackendState {
    pub protocol_version: u16,
    pub backend_version: String,
    pub engine: String,
    pub lifecycle: Lifecycle,
    pub session_connected: bool,
    pub username: String,
    pub active_client: String,
    pub playback: PlaybackStatus,
    pub track: Option<Track>,
    pub position_ms: u32,
    pub volume: u16,
    pub shuffle: bool,
    pub repeat: RepeatMode,
    pub generation: u64,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub error_code: String,
    pub error: String,
    #[serde(skip)]
    pub seek_sequence: u64,
}

impl Default for BackendState {
    fn default() -> Self {
        Self {
            protocol_version: PROTOCOL_VERSION,
            backend_version: env!("CARGO_PKG_VERSION").to_string(),
            engine: ENGINE_NAME.to_string(),
            lifecycle: Lifecycle::Starting,
            session_connected: false,
            username: String::new(),
            active_client: String::new(),
            playback: PlaybackStatus::Stopped,
            track: None,
            position_ms: 0,
            volume: 0,
            shuffle: false,
            repeat: RepeatMode::Off,
            generation: 0,
            error_code: String::new(),
            error: String::new(),
            seek_sequence: 0,
        }
    }
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct ProtocolError {
    pub code: String,
    pub message: String,
}

impl ProtocolError {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }
}

#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServerMessage<'a> {
    Response {
        v: u16,
        id: u64,
        ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        result: Option<serde_json::Value>,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<ProtocolError>,
    },
    Event {
        v: u16,
        event: &'a str,
        state: &'a BackendState,
    },
}

impl<'a> ServerMessage<'a> {
    pub fn success(id: u64, result: serde_json::Value) -> Self {
        Self::Response {
            v: PROTOCOL_VERSION,
            id,
            ok: true,
            result: Some(result),
            error: None,
        }
    }

    pub fn failure(id: u64, error: ProtocolError) -> Self {
        Self::Response {
            v: PROTOCOL_VERSION,
            id,
            ok: false,
            result: None,
            error: Some(error),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_is_flat_and_versioned() {
        let request: Request =
            serde_json::from_str(r#"{"v":2,"id":7,"command":"seek","position_ms":1234}"#).unwrap();
        assert_eq!(request.v, PROTOCOL_VERSION);
        assert_eq!(request.id, 7);
        assert_eq!(request.command, Command::Seek { position_ms: 1234 });
    }

    #[test]
    fn load_defaults_to_playing_from_the_first_song() {
        let request: Request =
            serde_json::from_str(r#"{"v":2,"id":1,"command":"load","songs":[{"id":"42"}]}"#)
                .unwrap();
        let Command::Load {
            songs,
            offset_index,
            position_ms,
            play,
        } = request.command
        else {
            panic!("expected load command");
        };
        assert_eq!(songs, vec![SongRef::default_with_id("42")]);
        assert_eq!(offset_index, None);
        assert_eq!(position_ms, 0);
        assert!(play);
    }

    #[test]
    fn song_ref_accepts_partial_metadata() {
        let song: SongRef = serde_json::from_str(
            r#"{"id":"a1","title":"Song","artists":["Artist"],"album":"Album","duration_ms":180000,"cover_art":"c1","track":3}"#,
        )
        .unwrap();
        assert_eq!(
            song,
            SongRef {
                id: "a1".into(),
                title: "Song".into(),
                artists: vec!["Artist".into()],
                album: "Album".into(),
                duration_ms: 180_000,
                cover_art: "c1".into(),
                track: Some(3),
            }
        );

        let minimal: SongRef = serde_json::from_str(r#"{"id":"a2"}"#).unwrap();
        assert!(minimal.title.is_empty());
        assert!(minimal.artists.is_empty());
        assert_eq!(minimal.duration_ms, 0);
        assert_eq!(minimal.track, None);
    }

    #[test]
    fn configure_server_parses_without_echoing_secrets() {
        let request: Request = serde_json::from_str(
            r#"{"v":2,"id":2,"command":"configure_server","url":"https://nav.example","username":"user","password":"hunter2"}"#,
        )
        .unwrap();
        assert_eq!(
            request.command,
            Command::ConfigureServer {
                url: "https://nav.example".into(),
                username: "user".into(),
                password: "hunter2".into(),
            }
        );
        // The shared state carries no credential-shaped fields at all.
        let state_json = serde_json::to_value(BackendState::default()).unwrap();
        let keys = state_json.as_object().unwrap();
        assert!(keys.get("password").is_none());
        assert!(keys.get("url").is_none());
        assert!(keys.get("server_url").is_none());
        assert_eq!(keys["engine"], ENGINE_NAME);
    }

    #[test]
    fn add_to_queue_carries_a_song_reference() {
        let request: Request = serde_json::from_str(
            r#"{"v":2,"id":3,"command":"add_to_queue","song":{"id":"77","title":"B-side"}}"#,
        )
        .unwrap();
        assert_eq!(
            request.command,
            Command::AddToQueue {
                song: SongRef {
                    id: "77".into(),
                    title: "B-side".into(),
                    ..SongRef::default()
                }
            }
        );
    }

    #[test]
    fn state_event_has_stable_envelope() {
        let state = BackendState::default();
        let value = serde_json::to_value(ServerMessage::Event {
            v: PROTOCOL_VERSION,
            event: "state_changed",
            state: &state,
        })
        .unwrap();
        assert_eq!(value["type"], "event");
        assert_eq!(value["v"], 2);
        assert_eq!(value["state"]["engine"], "navidrome-stream");
        assert!(value["state"].get("error_code").is_none());
        assert!(value["state"].get("seek_sequence").is_none());
    }

    #[test]
    fn state_event_includes_machine_readable_errors() {
        let state = BackendState {
            error_code: "stream_rejected".to_string(),
            error: "Navidrome rejected the stream request".to_string(),
            ..BackendState::default()
        };
        let value = serde_json::to_value(ServerMessage::Event {
            v: PROTOCOL_VERSION,
            event: "state_changed",
            state: &state,
        })
        .unwrap();

        assert_eq!(value["state"]["error_code"], "stream_rejected");
        assert_eq!(value["state"]["error"], state.error);
    }

    #[test]
    fn track_serializes_with_the_subsonic_id_field() {
        let track = Track {
            id: "42".into(),
            title: "Song".into(),
            artists: vec!["Artist".into()],
            album: "Album".into(),
            art_url: "https://nav.example/rest/getCoverArt?u=user".into(),
            duration_ms: 42_000,
            item_type: "track".into(),
        };
        let value = serde_json::to_value(&track).unwrap();
        assert_eq!(value["id"], "42");
        assert!(value.get("uri").is_none());
    }
}
