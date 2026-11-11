.pragma library

.import "Subsonic.js" as Subsonic

var SEARCH_TYPES = ["track", "artist", "album", "playlist"]

function clampUnit(value) {
  return Math.max(0, Math.min(1, Number(value) || 0))
}

function normalizeVolumePercent(value) {
  if (value === null || value === undefined || value === "") return null
  var volume = Number(value)
  return isFinite(volume) ? Math.max(0, Math.min(100, volume)) : null
}

function shallowCopy(value) {
  var copy = ({})
  if (!value || typeof value !== "object" || Array.isArray(value)) return copy
  for (var key in value) copy[key] = value[key]
  return copy
}

function assign(target, source) {
  var next = target && typeof target === "object" && !Array.isArray(target)
    ? target : ({})
  if (!source || typeof source !== "object" || Array.isArray(source)) return next
  for (var key in source) next[key] = source[key]
  return next
}

function parseJson(text, fallback) {
  try {
    var parsed = JSON.parse(String(text || ""))
    return parsed === null ? fallback : parsed
  } catch (e) {
    return fallback
  }
}

function barTrackText(title, artist, showTitle, showArtist, playing, showPaused) {
  if (playing !== true && showPaused === false) return ""
  var cleanTitle = String(title || "").trim()
  var cleanArtist = String(artist || "").trim()
  var parts = []
  if (showArtist && cleanArtist) parts.push(cleanArtist)
  if (showTitle && cleanTitle) parts.push(cleanTitle)
  return parts.join(" - ")
}

function canScrollBarText(showTitle, showArtist) {
  return showTitle === true || showArtist === true
}

var BAR_TEXT_WIDTH_MIN = 160
var BAR_TEXT_WIDTH_MAX = 560
var BAR_TEXT_WIDTH_STEP = 40

// Slider geometry for the bar label cap. The uncapped notch sits one step past
// the widest real width, so 0 has somewhere to live without a second control.
function barTextWidthSlider() {
  return {
    min: BAR_TEXT_WIDTH_MIN,
    step: BAR_TEXT_WIDTH_STEP,
    unlimited: BAR_TEXT_WIDTH_MAX + BAR_TEXT_WIDTH_STEP,
    ticks: (BAR_TEXT_WIDTH_MAX - BAR_TEXT_WIDTH_MIN) / BAR_TEXT_WIDTH_STEP + 2
  }
}

// Cap in unscaled px, snapped to the slider's notches. 0 means no cap;
// anything unparseable falls back to the historical 240px bound.
function normalizedMaxBarTextWidth(value) {
  if (value === undefined || value === null || String(value).trim() === "")
    return 240
  var width = Number(value)
  if (!isFinite(width) || width < 0) return 240
  if (width === 0) return 0
  var clamped = Math.max(BAR_TEXT_WIDTH_MIN, Math.min(BAR_TEXT_WIDTH_MAX, width))
  return BAR_TEXT_WIDTH_MIN + Math.round(
    (clamped - BAR_TEXT_WIDTH_MIN) / BAR_TEXT_WIDTH_STEP) * BAR_TEXT_WIDTH_STEP
}

function normalizedScrollSpeed(value) {
  var speed = Number(value)
  if (!isFinite(speed)) speed = 1
  return Math.round(Math.max(0.25, Math.min(3, speed)) * 4) / 4
}

// The Navidrome transcode choice exposed as two settings: the /rest/stream
// `format` ("source" = keep the file's own format) and a bounded `maxBitRate`
// cap in kbps ("0" = no cap). These lists must match the backend's config
// validation exactly — backend/src/config.rs checks format against
// backend/src/stream.rs FORMATS ("" plus the same six suffixes) and accepts
// any maxBitRate an integer within u16, while the UI only ever offers this
// bounded cap list.
var AUDIO_FORMATS = ["source", "mp3", "flac", "wav", "ogg", "opus", "aac"]
var AUDIO_MAX_BIT_RATES = [0, 64, 96, 128, 192, 320]

function normalizedAudioFormat(value) {
  var format = String(value === undefined || value === null
    ? "source" : value).trim()
  return AUDIO_FORMATS.indexOf(format) >= 0 ? format : "source"
}

function normalizedAudioMaxBitRate(value) {
  var rate = Math.floor(Number(value))
  if (!isFinite(rate)) return 0
  return AUDIO_MAX_BIT_RATES.indexOf(rate) >= 0 ? rate : 0
}

// Cycle through the option list and wrap; used by the settings buttons.
function cycledChoice(list, value) {
  var options = Array.isArray(list) ? list : []
  if (!options.length) return value
  var index = options.indexOf(value)
  return options[(index + 1 + options.length) % options.length]
}


function timestampIsFresh(timestamp, now, lifetimeMs) {
  var checkedAt = Number(timestamp)
  var current = Number(now)
  var lifetime = Number(lifetimeMs)
  if (!isFinite(checkedAt) || !isFinite(current) || !isFinite(lifetime)
      || checkedAt <= 0 || lifetime <= 0) return false
  var age = current - checkedAt
  return age >= 0 && age < lifetime
}

function deadlineRemainingSeconds(deadline, now) {
  var end = Number(deadline)
  var current = Number(now)
  if (!isFinite(end) || !isFinite(current)) return 0
  return Math.max(0, Math.ceil((end - current) / 1000))
}

// Maintain a small least-recently-touched key order without replacing the
// caller's array. One touch can add at most one key, so a single returned key
// lets callers evict the matching map entry without replacement collections.
function touchBoundedOrder(order, key, limit) {
  if (!Array.isArray(order)) return ""
  var name = String(key || "")
  if (!name) return ""
  var maximum = Math.max(0, Math.floor(Number(limit) || 0))
  var oldIndex = order.indexOf(name)
  if (oldIndex >= 0) order.splice(oldIndex, 1)
  order.push(name)
  return order.length > maximum ? String(order.shift() || "") : ""
}

// Nested arrays become array-like QML sequences after passing through a
// ListView model. Preserve them instead of relying on Array.isArray(), which
// returns false for that representation.
function arrayValues(values) {
  if (Array.isArray(values)) return values
  if (!values || typeof values === "string") return []
  var length = Number(values.length)
  if (!isFinite(length) || length <= 0) return []
  var result = []
  for (var i = 0; i < Math.floor(length); i++) result.push(values[i])
  return result
}

function redact(value) {
  var text = String(value || "")
  text = text.replace(/(authorization\s*:\s*bearer\s+)[^\s]+/ig, "$1<redacted>")
  // Subsonic request credentials ride in query params (u=, t= token hash,
  // s= salt); getCoverArt art_url URLs carry the full token set, so log lines
  // mentioning one are scrubbed too.
  text = text.replace(/(^|[?&\s])((?:code|access_token|refresh_token|code_verifier|client_secret|password|u|t|s|salt|token)=)[^&#\s]+/ig, "$1$2<redacted>")
  text = text.replace(/("(?:access_token|refresh_token|code|code_verifier|client_secret|password)"\s*:\s*")[^"]+/ig, "$1<redacted>")
  return text
}

function playlistOwnedByUser(playlist, userId) {
  var user = String(userId || "")
  return !!playlist && !!user && String(playlist.ownerId || "") === user
}

// Subsonic playlists are always readable by the owner; a non-owner simply
// sees the playlist listed without editable actions. An empty list after a
// successful load means the server returned no entries.
function playlistItemsEmptyMessage(playlist, itemCount, error) {
  if (!playlist) return ""
  var count = Number(itemCount) || 0
  if (error) return "Couldn't load this playlist. Try again in a moment."
  if (count > 0) return ""
  return "This playlist has no visible items."
}

// While a player surface is open, keep the local engine running so the mini
// player and media keys keep working. The configured idle timeout begins
// only after every player surface closes.
function visibleLocalReceiverAction(uiVisible, fullyConnected, running, busy) {
  if (uiVisible !== true || fullyConnected !== true) return "idle"
  if (busy === true) return "wait"
  if (running === true) return "idle"
  return "start"
}
// A paused item is still an active media session: keep its MPRIS metadata and
// resume controls alive after the UI closes. Only an empty/stopped receiver is
// eligible for the configured background shutdown timeout.
function idleShutdownShouldRun(daemonRunning, hasMedia, uiVisible, idleMinutes) {
  return daemonRunning === true && hasMedia !== true && uiVisible !== true
    && Number(idleMinutes) > 0
}

function normalizedShortcutPlayer(value) {
  var text = String(value || "")
  if (text === "Full player") return "Full player"
  if (text === "Mini player") return "Mini player"
  return "Omarchy Music app"
}

function normalizedShortcutHints(value) {
  return String(value || "On") === "Off" ? "Off" : "On"
}

function shortcutSequenceList(value) {
  if (value === undefined || value === null || value === "") return []
  return Array.isArray(value) ? value : [value]
}

function parseShortcutSequence(sequence) {
  var raw = String(sequence || "").replace(/^\s+|\s+$/g, "")
  var result = { ctrl: false, shift: false, alt: false, key: "" }
  if (!raw) return result
  var parts = raw.split("+")
  for (var i = 0; i < parts.length; i++) {
    var part = String(parts[i] || "").replace(/^\s+|\s+$/g, "")
    if (!part) continue
    var lower = part.toLowerCase()
    if (lower === "ctrl" || lower === "control") result.ctrl = true
    else if (lower === "shift") result.shift = true
    else if (lower === "alt") result.alt = true
    else if (lower === "meta" || lower === "super") continue
    else result.key = part
  }
  return result
}

function shortcutModifiersMatch(sequence, held) {
  var parsed = parseShortcutSequence(sequence)
  var flags = held && typeof held === "object" ? held : {}
  var ctrl = flags.ctrl === true
  var shift = flags.shift === true
  var alt = flags.alt === true
  return parsed.ctrl === ctrl && parsed.shift === shift && parsed.alt === alt
}

function shortcutModifierFlagsAfterEvent(reportedFlags, pressed, previousFlags,
    changedModifierFlag) {
  var reported = Number(reportedFlags) || 0
  var previous = Number(previousFlags) || 0
  var changed = Number(changedModifierFlag) || 0
  if (changed !== 0)
    return pressed === true ? (reported | changed) : (reported & ~changed)
  // Some Qt key-release events omit modifiers that are still physically held.
  // A non-modifier release cannot change that state, so retain the last value.
  return pressed === true ? reported : previous
}

function shortcutKeycap(sequence) {
  var key = String(parseShortcutSequence(sequence).key || "")
  var lower = key.toLowerCase()
  if (lower === "left") return "←"
  if (lower === "right") return "→"
  if (lower === "up") return "↑"
  if (lower === "down") return "↓"
  if (lower === "space") return "Space"
  if (lower === "esc" || lower === "escape") return "Esc"
  if (lower === "tab") return "Tab"
  if (lower === "menu") return "Menu"
  return key
}

function shortcutHintCaption(sequences, held, active) {
  if (active === false) return ""
  var list = shortcutSequenceList(sequences)
  var labels = []
  var seen = {}
  for (var i = 0; i < list.length; i++) {
    if (!shortcutModifiersMatch(list[i], held)) continue
    var label = shortcutKeycap(list[i])
    if (!label || seen[label]) continue
    seen[label] = true
    labels.push(label)
  }
  return labels.join(" ")
}

function shortcutOverlayLabel(sequences, held, active, navHint) {
  if (active === false) return ""
  var nav = String(navHint || "")
  var chord = shortcutHintCaption(sequences, held, true)
  if (nav && chord && nav !== chord) return nav + " " + chord
  if (nav) return nav
  return chord
}

function repeatModeLabel(mode) {
  var value = String(mode || "off")
  if (value === "track") return "This song"
  if (value === "context") return "All"
  return "Off"
}

var TYPE_LABELS = {
  track: { singular: "Song", plural: "Songs" },
  artist: { singular: "Artist", plural: "Artists" },
  album: { singular: "Album", plural: "Albums" },
  playlist: { singular: "Playlist", plural: "Playlists" }
}

function typeLabel(type, plural) {
  var entry = TYPE_LABELS[String(type || "")]
  if (!entry) return plural ? "results" : "Library item"
  return plural ? entry.plural : entry.singular
}

function searchTypeLabel(type) {
  return typeLabel(type, true)
}

function mediaTypeLabel(type) {
  return typeLabel(type, false)
}

var MUTE_THRESHOLD = 0.001
var UNMUTE_FLOOR = 0.05
var SEARCH_DEBOUNCE_MS = 300
var SEARCH_REQUEST_TIMEOUT_MS = 8000

function normalizedSearchType(value) {
  var type = String(value || "")
  return SEARCH_TYPES.indexOf(type) >= 0 ? type : "track"
}

function searchNeedsLoad(query, activeQuery, typeLoaded) {
  var term = String(query || "").trim()
  return term !== "" && (String(activeQuery || "").trim() !== term
    || typeLoaded !== true)
}

var VOLUME_FLUSH_MS = 80
var SLIDER_VOLUME_ACK_TOLERANCE = 0.04

function nextVolume(current, delta) {
  return clampUnit((Number(current) || 0) + (Number(delta) || 0))
}

function pendingSliderVolumeShouldHold(reportedSlider, pending, now) {
  if (!pending) return false
  if ((Number(now) || 0) >= (Number(pending.expiresAt) || 0)) return false
  var requested = Number(pending.slider)
  if (!isFinite(requested)) return false
  return Math.abs(clampUnit(reportedSlider) - clampUnit(requested))
    > SLIDER_VOLUME_ACK_TOLERANCE
}

function displayedSliderVolume(reportedSlider, pending, now) {
  if (pendingSliderVolumeShouldHold(reportedSlider, pending, now))
    return clampUnit(pending.slider)
  return clampUnit(reportedSlider)
}

function shouldRememberVolume(value) {
  return clampUnit(value) > MUTE_THRESHOLD
}

function unmuteVolume(previous) {
  return Math.max(UNMUTE_FLOOR, Number(previous) || 0)
}

function seekPosition(position, delta, length) {
  var next = Math.max(0, (Number(position) || 0) + (Number(delta) || 0))
  var maximum = Math.max(0, Number(length) || 0)
  return maximum > 0 ? Math.min(maximum, next) : next
}

// --------------------------------------------------------------------------
// Protocol v2 load fields
//
// The backend's Subsonic streaming engine (protocol v2) takes complete song
// references and streams by `id` alone, so all metadata on a SongRef is
// optional: empty strings, an empty artists list, and 0 duration are all
// legal and simply mean the UI has nothing better to show.
//
// Subsonic song durations are whole seconds. Trust the explicit millisecond
// fields first; a bare `duration` value below 10000 is treated as seconds (a
// real song is never longer than that in ms naming, and never that short in
// seconds), anything at or above it as already-converted milliseconds.
function backendSongDurationMsV2(item) {
  var source = item || {}
  var ms = Math.floor(Number(source.duration_ms) || 0)
  if (ms > 0) return ms
  ms = Math.floor(Number(source.durationMs) || 0)
  if (ms > 0) return ms
  var raw = Math.floor(Number(source.duration) || 0)
  if (raw <= 0) return 0
  return raw < 10000 ? raw * 1000 : raw
}

// Collect the Subsonic artists for a SongRef. Rows may carry `artists` as an
// array of strings or {name} objects, or a single `artist`/`artistName`
// string; everything degrades into the one flat string array the protocol
// defines. Duplicates are dropped.
function backendSongArtistsV2(item) {
  var names = []
  var source = arrayValues((item || {}).artists)
  for (var i = 0; i < source.length; i++) {
    var entry = source[i]
    if (!entry) continue
    var name = String(typeof entry === "object" ? entry.name : entry).trim()
    if (name && names.indexOf(name) < 0) names.push(name)
  }
  if (!names.length) {
    var single = String((item && (item.artist || item.artistName)) || "").trim()
    if (single) names.push(single)
  }
  return names
}

// Map one UI row to a protocol v2 SongRef. Subsonic fields are the primary
// source; title/artist degrade to their closest row field (name -> title,
// artist -> artists) so rows without normalized fields still stream.
// Rows without any usable id return null and are dropped by the caller.
function backendSongRefV2(item) {
  if (!item || typeof item !== "object") return null
  var id = String(item.id === undefined || item.id === null ? "" : item.id).trim()
  if (!id) return null
  var song = { id: id }
  var title = String(item.title !== undefined && item.title !== null
    ? item.title : (item.name || "")).trim()
  if (title) song.title = title
  var artists = backendSongArtistsV2(item)
  if (artists.length) song.artists = artists
  var album = String(item.album || "").trim()
  if (album) song.album = album
  var duration = Math.max(0, Math.floor(backendSongDurationMsV2(item)))
  if (duration > 0) song.duration_ms = duration
  var cover = String(item.coverArt || item.cover_art || "").trim()
  if (cover) song.cover_art = cover
  var track = Math.floor(Number(item.track))
  if (isFinite(track) && track > 0) song.track = track
  return song
}

// Build the v2 `load` payload from a list of given items and options:
//   items   — array (or QML sequence) of rows mapped by backendSongRefV2
//   options — { offset_index, position_ms, play } (all optional)
// Returns null when no row carries an id. `play` defaults to true; an
// offset_index outside the songs list is clamped by the backend to 0.
function backendLoadFieldsV2(items, options) {
  var rows = arrayValues(items)
  var songs = []
  for (var i = 0; i < rows.length; i++) {
    var song = backendSongRefV2(rows[i])
    if (song) songs.push(song)
  }
  if (!songs.length) return null
  var spec = options && typeof options === "object" ? options : ({})
  var fields = { songs: songs, play: spec.play !== false }
  var index = Math.floor(Number(spec.offset_index))
  if (isFinite(index) && index >= 0) fields.offset_index = index
  var position = Math.floor(Number(spec.position_ms))
  if (position > 0) fields.position_ms = position
  return fields
}

// Turn a play request into a v2 load body. The visible list becomes the
// engine's queue starting at the clicked row (wrapping around), so Next
// reaches the list's end the way the displayed order runs. A resume offset in
// milliseconds is honored for a row loaded mid-song.
function playbackLoadBodyV2(item, sourceItems, resumeMs) {
  if (!item || typeof item !== "object") return null
  // Playback must start somewhere: a clicked row with no usable id (a pure
  // context header, for instance) cannot anchor the queue.
  if (!backendSongRefV2(item)) return null
  var rows = arrayValues(sourceItems)
  if (!rows.length && item.kind === "item") rows = [item]
  if (!rows.length) return null
  var start = -1
  for (var i = 0; i < rows.length; i++) {
    if (rows[i] === item) {
      start = i
      break
    }
  }
  if (start < 0) {
    var offset = playbackContextOffsetPosition(item, rows)
    if (offset >= 0 && offset < rows.length) start = offset
  }
  if (start < 0) start = 0
  var songs = []
  for (var step = 0; step < rows.length && songs.length < PLAYBACK_URI_LIMIT;
      step++) {
    var song = backendSongRefV2(rows[(start + step) % rows.length])
    if (song) songs.push(song)
  }
  if (!songs.length) return null
  var fields = { songs: songs, play: true }
  var position = Math.floor(Number(resumeMs) || 0)
  if (position > 0) fields.position_ms = position
  return fields
}

// --------------------------------------------------------------------------
// Canonical Subsonic rows
//
// One row shape for every Subsonic-backed surface (home, library, search,
// detail, playlists, queue). The view layer (MediaRow, MediaByline,
// MediaCollection, the panel views) renders these without caring which
// endpoint produced them. Identity is the `savedKeyFor` key (`type:id`);
// row `uri` remains only as an app-local token (`navidrome:<type>:<id>`)
// for the few consumers that want a URI-shaped string. Panel
// and MediaCollection identity plumbing (context menus, playlist identity,
// occurrence matching, restore keys) compare the saved key, never uris.
// Service builds v2 load bodies from `id` alone and never reads row uris.
//
// `art` carries the pinned artwork context {serverUrl, username, password,
// salt}; the same salt for the whole session keeps getCoverArt URLs stable
// across row rebuilds, so revisiting a view triggers no artwork traffic.
// Views still gate every load behind the artwork master switch; building the
// URL itself moves no bytes.

function subsonicArtContext(serverUrl, username, password, salt) {
  return {
    serverUrl: String(serverUrl || ""),
    username: String(username || ""),
    password: String(password || ""),
    salt: String(salt || "")
  }
}

function subsonicArtUrl(art, coverArt, size) {
  if (!art || !art.serverUrl || !art.username || !art.salt) return ""
  var id = String(coverArt || "")
  if (!id) return ""
  var built = Subsonic.coverArtUrl(art.serverUrl, id, size,
    { u: art.username, p: art.password, salt: art.salt })
  return built || ""
}

function navidromeUri(type, id) {
  return "navidrome:" + String(type || "track") + ":" + String(id || "")
}

// Song row (kind "item"). `node` is a Subsonic.normalizeSong result; parent
// lets an album context stand in when the song carries no albumId.
function subsonicSongRow(node, art, parent) {
  if (!node || !node.id) return null
  var artists = []
  if (node.artistId || node.artist) {
    var artist = subsonicArtistRow({
      id: node.artistId || "",
      name: node.artist || "",
      coverArt: node.coverArt,
      starred: node.starred
    }, art)
    if (artist) artists.push(artist)
  }
  var albumRow = null
  if (node.albumId || node.album) {
    albumRow = subsonicAlbumRow({
      id: node.albumId || "",
      name: node.album || "",
      artist: node.artist || "",
      artistId: node.artistId || "",
      coverArt: node.coverArt,
      year: node.year,
      starred: node.starred
    }, art) || parent
  } else if (parent && parent.type === "album") {
    albumRow = parent
  }
  return {
    kind: "item",
    type: "track",
    id: String(node.id),
    uri: navidromeUri("track", node.id),
    name: String(node.title || "Untitled"),
    subtitle: String(node.artist || ""),
    album: String(node.album || ""),
    artists: artists,
    albumItem: albumRow && albumRow.name ? albumRow : null,
    parentContext: parent && parent.type === "album" ? parent : null,
    imageUrl: subsonicArtUrl(art, node.coverArt, 128),
    coverArt: String(node.coverArt || ""),
    durationMs: Math.max(0, Math.floor(Number(node.duration) || 0)) * 1000,
    duration: Math.max(0, Math.floor(Number(node.duration) || 0)),
    trackNumber: Math.max(0, Math.floor(Number(node.track) || 0)),
    discNumber: 1,
    year: node.year || null,
    genre: String(node.genre || ""),
    playlistPosition: undefined,
    starred: node.starred === true
  }
}

// Album row (kind "context"). artist/artistId may be filled later (getAlbum).
function subsonicAlbumRow(node, art) {
  if (!node || !node.id) return null
  var details = []
  var artistName = String(node.artist || "")
  if (artistName) details.push(artistName)
  var year = Math.floor(Number(node.year) || 0)
  if (year > 0) details.push(String(year))
  var artists = []
  if (artistName) {
    var artist = subsonicArtistRow({
      id: node.artistId || "",
      name: artistName,
      coverArt: node.coverArt,
      starred: node.starred
    }, art)
    if (artist) artists.push(artist)
  }
  return {
    kind: "context",
    type: "album",
    id: String(node.id),
    uri: navidromeUri("album", node.id),
    name: String(node.name || "Untitled"),
    subtitle: details.join(" · "),
    description: "",
    artists: artists,
    imageUrl: subsonicArtUrl(art, node.coverArt, 192),
    coverArt: String(node.coverArt || ""),
    total: Math.max(0, Math.floor(Number(node.songCount) || 0)),
    songCount: Math.max(0, Math.floor(Number(node.songCount) || 0)),
    duration: Math.max(0, Math.floor(Number(node.duration) || 0)),
    year: year > 0 ? year : null,
    genre: String(node.genre || ""),
    releaseType: "",
    releaseDate: year > 0 ? String(year) : "",
    ownerId: "",
    ownerName: "",
    collaborative: false,
    public: false,
    snapshotId: "",
    starred: node.starred === true,
    played: typeof node.played === "string" ? node.played : null
  }
}

// Artist row (kind "context"). Also used inline as a song's `artists` entry.
function subsonicArtistRow(node, art) {
  if (!node || !node.id || !node.name) return null
  return {
    kind: "context",
    type: "artist",
    id: String(node.id),
    uri: navidromeUri("artist", node.id),
    name: String(node.name),
    subtitle: "Artist",
    description: "",
    artists: [],
    imageUrl: subsonicArtUrl(art, node.coverArt, 192),
    coverArt: String(node.coverArt || ""),
    total: Math.max(0, Math.floor(Number(node.albumCount) || 0)),
    albumCount: Math.max(0, Math.floor(Number(node.albumCount) || 0)),
    starred: node.starred === true
  }
}

// Playlist row (kind "context"). owner is the Navidrome username; it feeds
// playlistOwned()/editablePlaylists() through ownerId, matching the Web API
// key the consumers already read.
function subsonicPlaylistRow(node, art) {
  if (!node || !node.id) return null
  var owner = String(node.owner || "")
  return {
    kind: "context",
    type: "playlist",
    id: String(node.id),
    uri: navidromeUri("playlist", node.id),
    name: String(node.name || "Untitled"),
    subtitle: owner || "Playlist",
    description: String(node.comment || ""),
    artists: [],
    imageUrl: subsonicArtUrl(art, node.coverArt, 192),
    coverArt: String(node.coverArt || ""),
    total: Math.max(0, Math.floor(Number(node.songCount) || 0)),
    songCount: Math.max(0, Math.floor(Number(node.songCount) || 0)),
    duration: Math.max(0, Math.floor(Number(node.duration) || 0)),
    releaseType: "",
    releaseDate: "",
    ownerId: owner,
    ownerName: owner,
    collaborative: false,
    public: node.public === true,
    snapshotId: "",
    created: String(node.created || ""),
    changed: String(node.changed || ""),
    starred: node.starred === true
  }
}

// A protocol-v2 SongRef (the backend's get_saved_queue answer) mapped back to
// a display row so the queue view shows the same shape as every other list.
// Artists degrade to name-only entries — no ids ride a SongRef.
function subsonicSongRefRow(song) {
  if (!song || typeof song !== "object" || !song.id) return null
  var names = []
  var source = arrayValues(song.artists)
  for (var i = 0; i < source.length; i++) {
    var entry = source[i]
    if (!entry) continue
    var name = String(typeof entry === "object" ? entry.name : entry).trim()
    if (name && names.indexOf(name) < 0) names.push(name)
  }
  var durationMs = Math.max(0, Math.floor(Number(song.duration_ms) || 0))
  return {
    kind: "item",
    type: "track",
    id: String(song.id),
    uri: navidromeUri("track", song.id),
    name: String(song.title || "Untitled"),
    subtitle: names.join(", "),
    album: String(song.album || ""),
    artists: names.map(function(name) {
      return {
        kind: "context", type: "artist", id: "", uri: "", name: name,
        subtitle: "Artist", description: "", artists: [], imageUrl: "",
        coverArt: "", total: 0, albumCount: 0, starred: false
      }
    }),
    albumItem: null,
    parentContext: null,
    imageUrl: String(song.cover_art || ""),
    coverArt: "",
    durationMs: durationMs,
    duration: Math.ceil(durationMs / 1000),
    trackNumber: Math.max(0, Math.floor(Number(song.track) || 0)),
    discNumber: 1,
    year: null,
    genre: "",
    playlistPosition: undefined,
    // A SongRef carries no star information; leaving it undefined keeps
    // checkSavedItems from recording a guess as server truth.
    starred: undefined
  }
}

// ---- Subsonic windows -------------------------------------------------------

// getAlbumList2 → canonical album rows.
function subsonicAlbumListRows(data, art) {
  var albums = Subsonic.parseAlbumList(data)
  var rows = []
  for (var i = 0; i < albums.length; i++) {
    var row = subsonicAlbumRow(albums[i], art)
    if (row) rows.push(row)
  }
  return rows
}

// getStarred2 → the combined starred view: songs first (the "saved tracks"
// surface), then albums and artists (the saved-albums/saved-artists specs).
function subsonicStarredRows(data, art) {
  var starred = Subsonic.parseStarred2(data)
  var songs = []
  for (var i = 0; i < starred.songs.length; i++) {
    var row = subsonicSongRow(starred.songs[i], art)
    if (row) songs.push(row)
  }
  var albums = []
  for (var j = 0; j < starred.albums.length; j++) {
    var album = subsonicAlbumRow(starred.albums[j], art)
    if (album) albums.push(album)
  }
  var artists = []
  for (var k = 0; k < starred.artists.length; k++) {
    var artist = subsonicArtistRow(starred.artists[k], art)
    if (artist) artists.push(artist)
  }
  return { songs: songs, albums: albums, artists: artists }
}

// A saved state key for any canonical row. Uri was the Web API key; ids are
// the Subsonic key, namespaced by type because Subsonic ids are opaque.
function savedKeyFor(item) {
  if (!item || typeof item !== "object") return ""
  var id = String(item.id === undefined || item.id === null ? "" : item.id).trim()
  if (!id) return ""
  return String(item.type || "track") + ":" + id
}

// Search3 → the searchGroups page shape every existing search consumer
// reads: one page per SEARCH_TYPES key, `next` carrying the next window
// offset (as a string, "" when the window came back short), `total` the
// returned count. Subsonic search3 covers artists/albums/songs only; the
// playlist page is filled by the controller from getPlaylists, and the
// podcast-family pages stay empty because the library has no such content.
function subsonicSearchPage(items, nextOffset, windowSize) {
  var limit = Math.max(0, Math.floor(Number(windowSize) || 0))
  return {
    items: items,
    next: limit > 0 && items.length >= limit && nextOffset > 0
      ? String(nextOffset) : "",
    total: items.length
  }
}

// results is Subsonic.parseSearch3 output; type is the API type the user
// asked for ("track" | "artist" | "album"); offset is the window the page
// was requested at, so `next` points at the following window.
function subsonicSearchGroups(results, type, art, windowSize, offset) {
  var parsed = results && typeof results === "object"
    ? results : { artists: [], albums: [], songs: [] }
  var groups = searchGroups()
  var wanted = normalizedSearchType(type)
  var nextOffset = Math.max(0, Math.floor(Number(offset) || 0))
    + Math.max(1, Math.floor(Number(windowSize) || 1))
  if (wanted === "artist") {
    var artists = []
    for (var i = 0; i < parsed.artists.length; i++) {
      var artist = subsonicArtistRow(parsed.artists[i], art)
      if (artist) artists.push(artist)
    }
    groups.artist = subsonicSearchPage(artists, nextOffset, windowSize)
  } else if (wanted === "album") {
    var albums = []
    for (var j = 0; j < parsed.albums.length; j++) {
      var album = subsonicAlbumRow(parsed.albums[j], art)
      if (album) albums.push(album)
    }
    groups.album = subsonicSearchPage(albums, nextOffset, windowSize)
  } else {
    var songs = []
    for (var k = 0; k < parsed.songs.length; k++) {
      var song = subsonicSongRow(parsed.songs[k], art)
      if (song) songs.push(song)
    }
    groups.track = subsonicSearchPage(songs, nextOffset, windowSize)
  }
  return groups
}

// The per-type search3 window: which count/offset pair advances, and the
// bounded page size. Unknown types fall back to songs.
function search3WindowType(type) {
  var value = String(type || "track")
  if (value === "artist") return "artist"
  if (value === "album") return "album"
  return "song"
}

function search3WindowParams(type, offset) {
  var category = search3WindowType(type)
  var count = 20
  var params = {}
  params[category + "Count"] = count
  var skip = Math.max(0, Math.floor(Number(offset) || 0))
  if (skip > 0) params[category + "Offset"] = skip
  return params
}


// panel's own content with no compositor blur of their own. Glass themes set
// the popup colour to a low alpha meant for separate blurred windows, which
// leaves these unreadable. Keep the hue, floor the alpha.
function opaqueSurface(color, minimumAlpha) {
  var floor = Math.max(0, Math.min(1, Number(minimumAlpha) || 0))
  if (!color || color.a === undefined) return color
  return color.a >= floor ? color : Qt.rgba(color.r, color.g, color.b, floor)
}

// Width of the bar slot for a label that measures `fitted` px. A cap trims
// long titles; a fixed slot also pads short ones so the widget, and everything
// laid out after it, keeps its place when the song changes.
function barSlotWidth(fixed, cap, fitted, minimum) {
  var capped = Number(cap) || 0
  var natural = Math.max(0, Number(fitted) || 0)
  var width = capped > 0
    ? (fixed === true ? capped : Math.min(capped, natural))
    : natural
  return Math.max(Number(minimum) || 0, width)
}

// The desktop app keeps the last play loaded in its footer, so Play always has
// somewhere to go. With Navidrome there is no recently-played endpoint to
// consult; Service offers the most recent album window instead, so an idle
// engine can continue there instead of leaving Play dead.
function resumePlaybackAvailable(hasMedia, candidate) {
  return hasMedia !== true && !!candidate && !!candidate.item
    && !!candidate.item.id
}

// Footer text while nothing is loaded: the live value, else the matching field
// of the last played item, else the idle label.
function idleMediaText(current, item, key, fallback) {
  var value = String(current || "")
  if (value) return value
  if (item && typeof item === "object" && item[key]) return String(item[key])
  return String(fallback || "")
}

function playbackSliderFeedbackComplete(sourceValue, pendingValue, sourcePending,
    elapsedMs, tolerance, minimumMs, timeoutMs) {
  var elapsed = Math.max(0, Number(elapsedMs) || 0)
  var timeout = Math.max(1, Number(timeoutMs) || 1)
  if (elapsed >= timeout) return true
  var minimum = Math.max(0, Number(minimumMs) || 0)
  var difference = Math.abs((Number(sourceValue) || 0)
    - (Number(pendingValue) || 0))
  return elapsed >= minimum && sourcePending !== true
    && difference <= Math.max(0, Number(tolerance) || 0)
}

function artistNames(artists) {
  var source = arrayValues(artists)
  var names = []
  for (var i = 0; i < source.length; i++)
    if (source[i] && source[i].name) names.push(String(source[i].name))
  return names.join(", ")
}

function artistSubtitleSuffix(item) {
  var source = item || {}
  var prefix = artistNames(source.artists)
  var subtitle = String(source.subtitle || "")
  return prefix && subtitle.indexOf(prefix) === 0
    ? subtitle.substring(prefix.length) : ""
}

function artistForName(items, name) {
  var rows = arrayValues(items)
  var expected = String(name || "").trim().toLowerCase()
  var fallback = null
  for (var i = 0; i < rows.length; i++) {
    var item = rows[i]
    if (!item || item.type !== "artist" || !item.name) continue
    if (!fallback) fallback = item
    if (expected && String(item.name).trim().toLowerCase() === expected) return item
  }
  return fallback
}

function artistContextAvailable(mediaType, trackId, artists) {
  return String(mediaType || "") === "track"
    || String(trackId || "") !== "" || arrayValues(artists).length > 0
}

// The engine's MPRIS metadata carries only strings, so the now-playing row is
// synthesized from it: the id is the Subsonic song id the engine publishes as
// xesam:url, and the uri is the app-local navidrome token. Library actions on
// this row (star, context buttons) resolve ids through Subsonic reads.
function currentPlaybackTrack(trackId, title, artist, album, coverUrl,
    durationSeconds) {
  var id = String(trackId || "").trim()
  if (!id) return null
  return {
    kind: "item",
    type: "track",
    id: id,
    uri: navidromeUri("track", id),
    name: String(title || "Untitled"),
    subtitle: String(artist || ""),
    album: String(album || ""),
    artists: [],
    albumItem: null,
    parentContext: null,
    imageUrl: String(coverUrl || ""),
    durationMs: Math.max(0, Number(durationSeconds) || 0) * 1000
  }
}

// The built-in lyrics surface receives the plain Subsonic song id plus the
// playback metadata it needs to title the view and place synced lines.
function lyricsSong(trackId, title, artist, album, duration, coverUrl,
    positionSeconds) {
  var id = String(trackId || "").trim()
  var songTitle = String(title || "").trim()
  var songArtist = String(artist || "").trim()
  if (!id || !songTitle || !songArtist) return null
  var songDuration = Math.max(0, Number(duration) || 0)
  var songPosition = Math.max(0, Number(positionSeconds) || 0)
  if (songDuration > 0) songPosition = Math.min(songPosition, songDuration)
  return {
    id: id,
    title: songTitle,
    artist: songArtist,
    album: String(album || "").trim(),
    duration: songDuration,
    coverUrl: String(coverUrl || "").trim(),
    positionSeconds: songPosition
  }
}

// The lyrics surface is built in now (getLyricsBySongId through SubsonicApi):
// no optional plugin, no install intent, and nothing plugin-related to
// persist. lyricsSong above stays the single metadata gate for the surface.

var SESSION_STATE_LIMIT = 16000

// getCoverArt URLs carry token-auth credentials (u/t/s). Rows hold them only
// in memory; anything that reaches persisted session state is scrubbed of
// imageUrl first so no credential-bearing URL is ever written to disk.
function stripImageUrls(value, depth) {
  var level = Math.floor(Number(depth) || 0)
  if (level > 8) return null
  if (value === null || value === undefined) return null
  if (typeof value !== "object") return value
  var out = Array.isArray(value) ? [] : ({})
  for (var key in value) {
    if (!Object.prototype.hasOwnProperty.call(value, key)) continue
    if (key === "imageUrl") continue
    var child = stripImageUrls(value[key], level + 1)
    if (child !== null) out[key] = child
  }
  return out
}

function normalizedSessionState(value) {
  var session = value
  if (typeof session === "string") session = parseJson(session, ({}))
  if (!session || typeof session !== "object" || Array.isArray(session)) session = ({})
  var scrubbed = stripImageUrls(session, 0)
  return JSON.stringify(scrubbed).length <= SESSION_STATE_LIMIT ? scrubbed : ({})
}

function sessionRecord(sessionState, searchHistory) {
  return {
    sessionState: normalizedSessionState(sessionState),
    searchHistory: parseStringList(searchHistory, 12)
  }
}

function emptySessionRecord() {
  return sessionRecord(({}), [])
}

function parseSessionRecord(raw) {
  var parsed = parseJson(String(raw || ""), null)
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed))
    return emptySessionRecord()
  return sessionRecord(parsed.sessionState, parsed.searchHistory)
}

function encodeSessionRecord(sessionState, searchHistory) {
  var record = sessionRecord(sessionState, searchHistory)
  record.version = 1
  return JSON.stringify(record, null, 2) + "\n"
}

function sessionRecordIsEmpty(record) {
  var value = record && typeof record === "object" ? record : emptySessionRecord()
  var session = value.sessionState
  var history = value.searchHistory
  var hasSession = !!session && typeof session === "object" && !Array.isArray(session)
    && Object.keys(session).length > 0
  var hasHistory = Array.isArray(history) && history.length > 0
  return !hasSession && !hasHistory
}

function pluginSettingsHaveSessionKeys(source) {
  if (!source || typeof source !== "object") return false
  return source.sessionState !== undefined || source.searchHistory !== undefined
}

function sessionRecordFromPluginSettings(source) {
  var values = source && typeof source === "object" ? source : ({})
  return sessionRecord(values.sessionState, values.searchHistory)
}

function searchShortcutAction(searchFocused, scopeAvailable, searchInContext) {
  if (searchFocused === true)
    return scopeAvailable === true ? "toggle-scope" : "focus"
  if (scopeAvailable === true && searchInContext === true) return "enter-global"
  return "focus"
}

function cursorActionList(actions) {
  var list = Array.isArray(actions) ? actions : []
  var result = []
  for (var i = 0; i < list.length; i++) {
    var action = String(list[i] || "")
    if (action) result.push(action)
  }
  return result
}

function ensureCursorAction(actions, current, fallback) {
  var list = cursorActionList(actions)
  if (!list.length) return ""
  var value = String(current || "")
  if (list.indexOf(value) >= 0) return value
  var preferred = String(fallback || "")
  if (preferred && list.indexOf(preferred) >= 0) return preferred
  return list[0]
}

function moveCursorAction(actions, current, delta) {
  var list = cursorActionList(actions)
  if (!list.length) return ""
  var index = list.indexOf(String(current || ""))
  if (index < 0) index = 0
  var step = delta < 0 ? -1 : 1
  return list[(index + step + list.length) % list.length]
}

function cursorNavHint(query) {
  var spec = query && typeof query === "object" ? query : {}
  var region = String(spec.region || "")
  var action = String(spec.action || "")
  if (!region || !action) return ""
  if (region === String(spec.tabRegion || "")
      && action === String(spec.tabAction || ""))
    return "Tab"
  if (region === String(spec.backtabRegion || "")
      && action === String(spec.backtabAction || ""))
    return "⇧Tab"
  if (spec.cursorActive === false) return ""
  if (spec.modifiersHeld === true) return ""
  var currentRegion = String(spec.currentRegion || "")
  var current = String(spec.currentAction || "")
  var listAction = String(spec.listAction || "")
  var listIndex = Math.floor(Number(spec.listIndex))
  var listCount = Math.max(0, Math.floor(Number(spec.listCount) || 0))
  var atList = listAction !== "" && current === listAction
  if (region === currentRegion && action === current) {
    if (atList) return ""
    return "↵"
  }
  if (region === currentRegion) {
    var neighbors = cursorActionList(spec.regionActions)
    if (action === moveCursorAction(neighbors, current, -1)) {
      if (atList && listIndex > 0) return ""
      return "↑"
    }
    if (action === moveCursorAction(neighbors, current, 1)) {
      if (atList && listIndex >= 0 && listIndex < listCount - 1) return ""
      return "↓"
    }
  }
  return ""
}

function isCursorListAction(action) {
  var value = String(action || "")
  return value === "list" || value.indexOf("list-") === 0
}

function pageListActions(actions) {
  var list = cursorActionList(actions)
  var result = []
  for (var i = 0; i < list.length; i++) {
    if (isCursorListAction(list[i])) result.push(list[i])
  }
  return result
}

function listHintRowIndex(count, firstVisible) {
  var n = Math.max(0, Math.floor(Number(count) || 0))
  if (n <= 0) return -1
  var row = Math.floor(Number(firstVisible))
  if (row >= 0 && row < n) return row
  return 0
}

function regionTabLanding(region, actions, query) {
  var spec = query && typeof query === "object" ? query : {}
  var list = cursorActionList(actions)
  if (!list.length) return ""
  var area = String(region || "")
  if (area === "footer")
    return ensureCursorAction(list, "play", list[0])
  if (area === "header")
    return ensureCursorAction(list, "search", list[0])
  if (area === "page") {
    var preferred = String(spec.pageLanding || "")
    if (preferred && list.indexOf(preferred) >= 0) return preferred
    var lists = pageListActions(list)
    var count = Math.floor(Number(spec.listCount))
    var listEmpty = isFinite(count) && count === 0
    if (lists.length) {
      if (lists[0] !== "list" || !listEmpty) return lists[0]
    }
    var chrome = []
    for (var i = 0; i < list.length; i++) {
      if (!isCursorListAction(list[i])) chrome.push(list[i])
    }
    if (chrome.length)
      return spec.back === true ? chrome[chrome.length - 1] : chrome[0]
    return ""
  }
  if (spec.back === true) return list[list.length - 1]
  return list[0]
}

function tabCursorDestination(query) {
  var spec = query && typeof query === "object" ? query : {}
  var regions = cursorActionList(spec.regions)
  if (!regions.length) return { region: "", action: "" }
  var back = spec.back === true
  var currentRegion = String(spec.currentRegion || "")
  var currentAction = String(spec.currentAction || "")
  var byRegion = spec.actionsByRegion && typeof spec.actionsByRegion === "object"
    ? spec.actionsByRegion : {}
  var pageActions = cursorActionList(spec.pageActions || byRegion.page)
  var lists = pageListActions(pageActions)

  if (spec.cursorActive === false) {
    var footer = cursorActionList(byRegion.footer)
    var play = ensureCursorAction(footer, "play", footer[0] || "")
    if (play) return { region: "footer", action: play }
    if (regions.length) {
      var first = regions[0]
      return {
        region: first,
        action: regionTabLanding(first, cursorActionList(byRegion[first]), spec)
      }
    }
    return { region: "", action: "" }
  }

  if (regions.length === 1) {
    var only = regions[0]
    return {
      region: only,
      action: moveCursorAction(cursorActionList(byRegion[only]), currentAction,
        back ? -1 : 1)
    }
  }

  if (currentRegion === "page" && lists.length) {
    var actionIndex = pageActions.indexOf(currentAction)
    var currentList = lists.indexOf(currentAction)
    var firstListAt = pageActions.indexOf(lists[0])
    var lastListAt = pageActions.indexOf(lists[lists.length - 1])
    if (!back) {
      if (currentList >= 0 && currentList < lists.length - 1)
        return { region: "page", action: lists[currentList + 1] }
      if (currentList < 0 && (actionIndex < 0 || actionIndex < firstListAt))
        return { region: "page", action: lists[0] }
    } else if (currentList > 0) {
      return { region: "page", action: lists[currentList - 1] }
    } else if (currentList === 0) {
      if (firstListAt > 0)
        return { region: "page", action: pageActions[firstListAt - 1] }
    } else if (actionIndex > lastListAt) {
      return { region: "page", action: lists[lists.length - 1] }
    }
  }

  var nextRegion = moveCursorAction(regions, currentRegion, back ? -1 : 1)
  return {
    region: nextRegion,
    action: regionTabLanding(nextRegion, cursorActionList(byRegion[nextRegion]), {
      back: back,
      listCount: spec.listCount,
      pageLanding: spec.pageLanding
    })
  }
}

function cursorListRowHint(query) {
  var spec = query && typeof query === "object" ? query : {}
  var row = Math.floor(Number(spec.rowIndex))
  var count = Math.max(0, Math.floor(Number(spec.count) || 0))
  var current = Math.floor(Number(spec.currentIndex))
  if (count <= 0 || row < 0 || row >= count) return ""
  if (!(current >= 0 && current < count)) current = 0
  var tabRow = listHintRowIndex(count, spec.tabRowIndex)
  if (spec.atList !== true) {
    if (spec.tabIsList === true && row === tabRow) return "Tab"
    if (spec.backtabIsList === true && row === tabRow) return "⇧Tab"
  }
  if (spec.modifiersHeld === true) return ""
  if (spec.atList === true) {
    if (row === current) return "↵"
    if (row === current - 1) return "↑"
    if (row === current + 1) return "↓"
    return ""
  }
  if (spec.previousIsCurrent === true && row === 0) return "↓"
  if (spec.nextIsCurrent === true && row === count - 1) return "↑"
  return ""
}

function listIndexAfterMove(count, current, delta) {
  var n = Math.max(0, Math.floor(Number(count) || 0))
  if (n <= 0) return -1
  var index = Math.floor(Number(current))
  var step = delta < 0 ? -1 : 1
  if (!(index >= 0 && index < n)) return step < 0 ? n - 1 : 0
  var next = index + step
  if (next < 0 || next >= n) return -1
  return next
}

function searchEscapeAction(barVisible, searchFocused, queryText,
    universalOverlay) {
  if (barVisible !== true) return ""
  if (String(queryText || "").trim() !== "" || universalOverlay === true)
    return "dismiss"
  if (searchFocused === true) return "blur"
  return ""
}

function universalSearchVisible(tab, active) {
  var area = String(tab || "")
  return area === "search"
    || (active === true && area !== "login" && area !== "setup")
}

function isUtilityTab(tab) {
  var area = String(tab || "")
  return area === "setup" || area === "login"
}

function rememberContentTab(tab) {
  var area = String(tab || "")
  return !area || isUtilityTab(area) ? "" : area
}

// Settings sits on top of the last real page. Esc returns there and skips
// any intervening Settings visit so two Esc presses cannot close the window
// from that menu.
function previousContentTab(currentTab, lastContentTab) {
  if (currentTab !== "setup") return ""
  var previous = rememberContentTab(lastContentTab)
  return previous || "home"
}

function searchScope(tab, detailItem, selectedPlaylist, homeType, libraryType) {
  var area = String(tab || "")
  var item = null
  var label = ""
  var key = ""
  var mode = "filter"

  if (area === "detail" && detailItem) {
    item = detailItem
    label = String(item.name || "").trim()
    key = "detail:" + savedKeyFor(item)
    mode = item.type === "artist" ? "artist" : "filter"
  } else if (area === "playlists" && selectedPlaylist) {
    item = selectedPlaylist
    label = String(item.name || "").trim()
    // The area prefix already names the type; the id is the identity.
    key = "playlist:" + String(item.id || "")
  } else if (area === "home") {
    var homeLabels = {
      recent: "Recently played",
      frequent: "Frequently played",
      newest: "Newest albums",
      starred: "Starred"
    }
    var selectedHome = String(homeType || "recent")
    if (homeLabels[selectedHome] !== undefined) {
      label = homeLabels[selectedHome]
      key = "home:" + selectedHome
    }
  } else if (area === "discover") {
    label = "Explore"
    key = "discover"
  } else if (area === "library") {
    var libraryLabels = {
      tracks: "Starred",
      albums: "Saved albums",
      artists: "Saved artists"
    }
    var selectedLibrary = String(libraryType || "tracks")
    if (libraryLabels[selectedLibrary] !== undefined) {
      label = libraryLabels[selectedLibrary]
      key = "library:" + selectedLibrary
    }
  } else if (area === "queue") {
    label = "Queue"
    key = "queue"
  }

  return {
    available: label !== "" && key !== "",
    key: key,
    label: label,
    mode: mode,
    item: item
  }
}

function sanitizeSearchTerm(value) {
  return String(value || "").replace(/["\\]/g, " ").replace(/\s+/g, " ").trim()
}

function mediaRowShouldCompact(titleWidth, availableWidth, actionCount) {
  var title = Math.max(0, Number(titleWidth) || 0)
  var available = Math.max(0, Number(availableWidth) || 0)
  var actions = Math.max(0, Math.floor(Number(actionCount) || 0))
  return actions > 0 && title > available
}

function responsiveResultColumns(width, twoColumnWidth) {
  var available = Math.max(0, Number(width) || 0)
  var breakpoint = Math.max(1, Number(twoColumnWidth) || 1)
  return available >= breakpoint ? 2 : 1
}

// Flatten grouped search results into rows for one virtualized ListView. Each
// media row contains at most `columnCount` items, so the view creates only the
// rows around its viewport instead of every result in several nested grids.
function sectionedMediaRows(sections, columnCount) {
  var groups = Array.isArray(sections) ? sections : []
  var columns = Math.max(1, Math.min(4, Math.floor(Number(columnCount) || 1)))
  var rows = []
  for (var sectionIndex = 0; sectionIndex < groups.length; sectionIndex++) {
    var section = groups[sectionIndex] || {}
    var items = arrayValues(section.items)
    var loading = section.loading === true
    var hasMore = section.hasMore === true
    if (!items.length && !loading && !hasMore) continue

    var id = String(section.id || sectionIndex)
    rows.push({
      kind: "heading",
      sectionId: id,
      heading: String(section.heading || "RESULTS"),
      count: items.length,
      loading: loading
    })
    for (var start = 0; start < items.length; start += columns) {
      rows.push({
        kind: "items",
        sectionId: id,
        startIndex: start,
        items: items.slice(start, start + columns)
      })
    }
    if (loading || hasMore) rows.push({
      kind: "more",
      sectionId: id,
      loading: loading,
      hasMore: hasMore
    })
  }
  return rows
}

function comparablePlaylistTitle(value) {
  return String(value || "").toLowerCase()
    .replace(/[’‘`]/g, "'")
    .replace(/[-–—_:.,!?()[\]{}"'\/\\]+/g, " ")
    .replace(/\s+/g, " ").trim()
}

// Playlist search has no server verb in Subsonic (search3 covers artists,
// albums, and songs), so the controller filters the loaded playlist list by
// name. Matching ignores punctuation and case.
function playlistMatchesTerm(playlist, term) {
  var expected = comparablePlaylistTitle(term)
  if (!expected) return true
  return comparablePlaylistTitle(playlist && playlist.name) === expected
    || comparablePlaylistTitle(playlist && playlist.name).indexOf(expected) >= 0
}

function playlistItemIds(items) {
  var rows = Array.isArray(items) ? items : []
  var ids = []
  for (var i = 0; i < rows.length; i++) {
    var item = rows[i] || {}
    if (item.id && String(item.type || "") === "track") ids.push(String(item.id))
  }
  return ids
}

// Playlist objects are replaced when their snapshots refresh. Resolve the
// backing collection by stable ID and never fall through to an unrelated
// detail page.
function playlistBackingItems(contextPlaylist, selectedPlaylist, selectedItems,
    detailPlaylist, detailItems) {
  var contextId = contextPlaylist
    ? String(contextPlaylist.id || "") : ""
  if (!contextId) return []
  if (selectedPlaylist
      && String(selectedPlaylist.id || "") === contextId)
    return arrayValues(selectedItems)
  if (detailPlaylist && String(detailPlaylist.type || "") === "playlist"
      && String(detailPlaylist.id || "") === contextId)
    return arrayValues(detailItems)
  return []
}

// Playlist payloads can contain unavailable entries that normalize out of the
// visible list. Prefer the raw API position retained by Service in that case.
function playlistPositionAt(items, index) {
  var rows = Array.isArray(items) ? items : []
  var visibleIndex = Math.floor(Number(index))
  if (!isFinite(visibleIndex) || visibleIndex < 0 || visibleIndex >= rows.length)
    return -1
  var explicitValue = rows[visibleIndex]
    ? rows[visibleIndex].playlistPosition : undefined
  var explicitPosition = Number(explicitValue)
  return explicitValue !== null && explicitValue !== undefined
    && isFinite(explicitPosition) && explicitPosition >= 0
    ? Math.floor(explicitPosition) : visibleIndex
}

function reorderedPlaylistItemsAtPositions(items, sourcePosition,
    destinationPosition) {
  var rows = Array.isArray(items) ? items.slice() : []
  var source = Math.floor(Number(sourcePosition))
  var destination = Math.floor(Number(destinationPosition))
  if (!isFinite(source) || !isFinite(destination) || source < 0
      || destination < 0 || source === destination) return rows
  var sourceIndex = -1
  var destinationIndex = -1
  for (var i = 0; i < rows.length; i++) {
    var position = playlistPositionAt(rows, i)
    if (position === source) sourceIndex = i
    if (position === destination) destinationIndex = i
  }
  if (sourceIndex < 0 || destinationIndex < 0) return rows

  var positioned = []
  for (var r = 0; r < rows.length; r++) {
    var item = rows[r]
    var oldPosition = playlistPositionAt(rows, r)
    var newPosition = oldPosition
    if (oldPosition === source) newPosition = destination
    else if (source < destination && oldPosition > source
        && oldPosition <= destination) newPosition = oldPosition - 1
    else if (source > destination && oldPosition >= destination
        && oldPosition < source) newPosition = oldPosition + 1
    if (item && typeof item === "object" && newPosition !== oldPosition) {
      var copy = ({})
      for (var propertyName in item) copy[propertyName] = item[propertyName]
      copy.playlistPosition = newPosition
      positioned.push(copy)
    } else {
      positioned.push(item)
    }
  }
  var moved = positioned.splice(sourceIndex, 1)
  positioned.splice(destinationIndex, 0, moved[0])
  return positioned
}

// Playlist rows are loaded explicitly a page at a time. Keep every requested
// page, including duplicate tracks, instead of applying the shared UI cache
// cap. `next` carries the following window offset ("": the list is complete).
function playlistPageState(existing, incoming, append, next) {
  var current = arrayValues(existing)
  var page = arrayValues(incoming)
  return {
    items: append === true ? current.concat(page) : page,
    next: String(next || "")
  }
}

var PLAYLIST_RESTORE_ITEM_LIMIT = 10000

function normalizedPlaylistRestoreCount(value) {
  var count = Math.floor(Number(value) || 0)
  return Math.max(0, Math.min(PLAYLIST_RESTORE_ITEM_LIMIT, count))
}

function playlistRestorePending(itemCount, targetCount, loading, next) {
  var loaded = Math.max(0, Math.floor(Number(itemCount) || 0))
  var target = normalizedPlaylistRestoreCount(targetCount)
  if (target <= loaded) return false
  return loading === true || String(next || "") !== ""
}

function playlistRestoreShouldContinue(itemCount, targetCount, next) {
  return playlistRestorePending(itemCount, targetCount, false, next)
}

// The empty per-type page shape that search3 window merges build on:
// one page per SEARCH_TYPES key, `next` the following window offset (a
// string, "" when the window came back short), `total` the returned count.
function searchGroups() {
  var result = ({})
  for (var i = 0; i < SEARCH_TYPES.length; i++)
    result[SEARCH_TYPES[i]] = { items: [], next: "", total: 0 }
  return result
}

function mergeSearchGroups(existing, incoming) {
  var result = ({})
  var oldGroups = existing || {}
  var newGroups = incoming || {}
  for (var i = 0; i < SEARCH_TYPES.length; i++) {
    var type = SEARCH_TYPES[i]
    var oldPage = oldGroups[type] || { items: [], next: "", total: 0 }
    if (!newGroups[type]) {
      result[type] = oldPage
      continue
    }
    var nextPage = newGroups[type]
    result[type] = {
      items: mergeUnique(oldPage.items, nextPage.items),
      next: String(nextPage.next || ""),
      total: Math.max(Number(oldPage.total) || 0, Number(nextPage.total) || 0)
    }
  }
  return result
}

function filteredSorted(items, filterText, sortKey) {
  var source = Array.isArray(items) ? items : []
  var term = String(filterText || "").trim().toLowerCase()
  var key = String(sortKey || "default")
  if (!term && key === "default") {
    var complete = true
    for (var candidate = 0; candidate < source.length; candidate++) {
      if (!source[candidate]) {
        complete = false
        break
      }
    }
    if (complete) return source
  }

  var rows = []
  for (var i = 0; i < source.length; i++) {
    var item = source[i]
    if (!item) continue
    if (term) {
      var haystack = [item.name, item.subtitle, item.album, item.description,
        item.releaseDate, item.addedAt].join(" ").toLowerCase()
      if (haystack.indexOf(term) < 0) continue
    }
    rows.push({ item: item, index: i })
  }
  if (key !== "default") {
    rows.sort(function(a, b) {
      var left
      var right
      if (key === "duration") {
        left = Number(a.item.durationMs) || 0
        right = Number(b.item.durationMs) || 0
      } else if (key === "date" || key === "date-asc") {
        left = String(a.item.addedAt || a.item.playedAt || a.item.releaseDate || "")
        right = String(b.item.addedAt || b.item.playedAt || b.item.releaseDate || "")
        // Keep unknown dates at the end in both directions.
        if (!left && right) return 1
        if (left && !right) return -1
        if (left < right) return key === "date-asc" ? -1 : 1
        if (left > right) return key === "date-asc" ? 1 : -1
        return a.index - b.index
      } else {
        left = String(key === "artist" ? a.item.subtitle
          : (key === "album" ? a.item.album : a.item.name) || "").toLowerCase()
        right = String(key === "artist" ? b.item.subtitle
          : (key === "album" ? b.item.album : b.item.name) || "").toLowerCase()
      }
      if (left < right) return -1
      if (left > right) return 1
      return a.index - b.index
    })
  }
  var result = []
  for (var r = 0; r < rows.length; r++) result.push(rows[r].item)
  return result
}

function parseStringList(value, maximum) {
  var source = value
  if (typeof source === "string") source = parseJson(source, [])
  if (!Array.isArray(source)) return []
  var limit = Math.max(1, Number(maximum) || 50)
  var result = []
  var seen = ({})
  for (var i = 0; i < source.length && result.length < limit; i++) {
    var entry = String(source[i] || "").trim()
    if (!entry || seen[entry]) continue
    seen[entry] = true
    result.push(entry)
  }
  return result
}

function touchHistory(values, term, maximum) {
  var normalized = String(term || "").trim()
  var source = parseStringList(values, maximum || 12)
  if (!normalized) return source
  var result = [normalized]
  for (var i = 0; i < source.length && result.length < (maximum || 12); i++)
    if (source[i].toLowerCase() !== normalized.toLowerCase()) result.push(source[i])
  return result
}

var PLAYBACK_URI_LIMIT = 100

// Subsonic playback is a complete song list in visible order: the engine's
// queue is built from the rows the user sees, so a filter or a non-default
// sort must always play that displayed order. Context headers (album,
// playlist, artist) carry the full list behind them instead of a server
// context, so they never force the "original" order.
function playbackUsesVisibleOrder(filterText, sortKey) {
  return String(filterText || "").trim() !== ""
    || String(sortKey || "default") !== "default"
}

function visibleOrderPlaybackMessage(itemCount) {
  var count = Math.max(0, Math.floor(Number(itemCount) || 0))
  return count > PLAYBACK_URI_LIMIT
    ? "Playing the displayed order for " + PLAYBACK_URI_LIMIT + " items"
    : "Playing the displayed order"
}

// Context offset for the v2 load builder. Subsonic rows play the visible
// list in order, so the only position that matters is where the clicked row
// sits in that list (matched by row identity first, then by the type:id
// saved key — playlist rows can repeat a track, so the first match wins).
function playbackContextOffsetPosition(item, sourceItems) {
  var values = Array.isArray(sourceItems) ? sourceItems : []
  var wanted = savedKeyFor(item)
  if (!wanted) return -1
  for (var i = 0; i < values.length; i++) {
    if (values[i] && savedKeyFor(values[i]) === wanted) return i
  }
  return -1
}

function millisecondsToClock(milliseconds) {
  var seconds = Math.max(0, Math.floor((Number(milliseconds) || 0) / 1000))
  var minutes = Math.floor(seconds / 60)
  var remainder = seconds % 60
  return minutes + ":" + (remainder < 10 ? "0" : "") + remainder
}

// Merge pages of canonical rows without duplicates. The stable key is the
// type:id saved key (with a uri/id fallback for rows without a type), and
// keyless rows pass through untouched.
function mergeUnique(existing, incoming) {
  var result = Array.isArray(existing) ? existing.slice() : []
  var seen = {}
  var i
  for (i = 0; i < result.length; i++) {
    var oldKey = rowIdentityKey(result[i])
    if (oldKey) seen[oldKey] = true
  }
  var values = Array.isArray(incoming) ? incoming : []
  for (i = 0; i < values.length; i++) {
    var key = rowIdentityKey(values[i])
    if (key && seen[key]) continue
    if (key) seen[key] = true
    result.push(values[i])
  }
  return result
}

function rowIdentityKey(item) {
  if (!item || typeof item !== "object") return ""
  return savedKeyFor(item) || String(item.uri || item.id || "")
}
