.pragma library

.import "Subsonic.js" as Subsonic

var API_BASE = "https://api.spotify.com/v1"
var TOKEN_URL = "https://accounts.spotify.com/api/token"
var AUTH_URL = "https://accounts.spotify.com/authorize"

// Deliberately omit profile and email scopes. The remaining scopes correspond
// directly to visible library, history, playlist, and playback controls.
var SCOPES = [
  "user-library-read",
  "user-library-modify",
  "user-follow-read",
  "user-follow-modify",
  "user-read-recently-played",
  "user-read-playback-position",
  "user-top-read",
  "playlist-read-private",
  "playlist-read-collaborative",
  "playlist-modify-private",
  "playlist-modify-public",
  "user-read-playback-state",
  "user-modify-playback-state"
]

var SEARCH_TYPES = ["track", "artist", "album", "playlist"]

// spotifyd's software mixer maps its normalized volume over a 60 dB
// logarithmic range. Convert that control to a cubic slider over the same
// range, matching the gentler taper used by common desktop audio mixers.
// Zero remains a true mute in both directions.
var SPOTIFYD_CUBIC_FLOOR = 0.1

function clampUnit(value) {
  return Math.max(0, Math.min(1, Number(value) || 0))
}

function normalizeVolumePercent(value) {
  if (value === null || value === undefined || value === "") return null
  var volume = Number(value)
  return isFinite(volume) ? Math.max(0, Math.min(100, volume)) : null
}

function spotifydVolumeToSlider(value) {
  var volume = clampUnit(value)
  if (volume <= 0) return 0
  var cubicRoot = Math.pow(10, volume - 1)
  return clampUnit((cubicRoot - SPOTIFYD_CUBIC_FLOOR)
    / (1 - SPOTIFYD_CUBIC_FLOOR))
}

function sliderToSpotifydVolume(value) {
  var slider = clampUnit(value)
  if (slider <= 0) return 0
  var cubicRoot = SPOTIFYD_CUBIC_FLOOR
    + (1 - SPOTIFYD_CUBIC_FLOOR) * slider
  return clampUnit(1 + Math.log(cubicRoot) / Math.LN10)
}

function encode(value) {
  return encodeURIComponent(String(value === undefined || value === null ? "" : value))
}

function queryString(values) {
  if (!values) return ""
  var pairs = []
  var keys = Object.keys(values).sort()
  for (var i = 0; i < keys.length; i++) {
    var key = keys[i]
    var value = values[key]
    if (value === undefined || value === null || value === "") continue
    if (Array.isArray(value)) value = value.join(",")
    pairs.push(encode(key) + "=" + encode(value))
  }
  return pairs.join("&")
}

function appendQuery(path, values) {
  var query = queryString(values)
  if (!query) return String(path || "")
  return String(path || "") + (String(path || "").indexOf("?") >= 0 ? "&" : "?") + query
}

function formBody(values) {
  return queryString(values)
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

function safeApiUrl(path) {
  var value = String(path || "")
  if (value.charAt(0) === "/") return API_BASE + value
  if (value === API_BASE || value.indexOf(API_BASE + "/") === 0) return value
  return ""
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

function responseError(status, payload, fallback) {
  var message = ""
  if (payload && typeof payload === "object") {
    if (typeof payload.error === "object" && payload.error) {
      message = payload.error.message || payload.error.status || ""
      if (payload.error.reason && String(payload.error.reason) !== String(message))
        message += (message ? " (" : "") + String(payload.error.reason) + (message ? ")" : "")
    }
    else if (typeof payload.error === "string")
      message = payload.error_description || payload.error
    else
      message = payload.message || ""
  }
  if (!message) message = fallback || "Spotify could not complete this request"
  return redact(message)
}

function rateLimitSuffix(retryAfter) {
  var seconds = Number(String(retryAfter || "").trim())
  if (!isFinite(seconds) || seconds <= 0) return ""
  seconds = Math.max(1, Math.round(seconds))
  return ". Try again in " + seconds + (seconds === 1 ? " second" : " seconds") + "."
}

function rateLimitMessage(retryAfter) {
  var suffix = rateLimitSuffix(retryAfter)
  return suffix ? "Spotify is busy" + suffix
    : "Spotify is busy. Try again in a moment."
}

var API_MAX_IN_FLIGHT = 2
var API_MAX_RATE_LIMIT_RETRIES = 4

function rateLimitRetryMs(retryAfter, attempt) {
  var value = String(retryAfter || "").trim()
  var seconds = Number(value)
  if (!value || !isFinite(seconds) || seconds < 0) return 10000
  var headerMs = Math.round(seconds * 1000)
  var retry = Math.max(0, Math.floor(Number(attempt) || 0))
  var backoffMs = 1000 * Math.pow(2, retry)
  // Spotify often 429s again if we retry at exactly Retry-After, especially
  // when the header is 1 second. Cap our backoff, never the server delay.
  return Math.max(1000, headerMs, Math.min(30000, backoffMs)) + 400
}

function shouldRetryRateLimit(retriesSoFar) {
  return (Number(retriesSoFar) || 0) < API_MAX_RATE_LIMIT_RETRIES
}

function apiInFlightLimit(restricted) {
  return restricted === true ? 1 : API_MAX_IN_FLIGHT
}

function responseRetryAfter(xhr) {
  if (!xhr || typeof xhr.getResponseHeader !== "function") return ""
  var value = xhr.getResponseHeader("Retry-After")
  if (!value) value = xhr.getResponseHeader("retry-after")
  return value ? String(value) : ""
}

function apiRequestIsMutating(method) {
  var value = String(method || "GET").toUpperCase()
  return value !== "GET" && value !== "HEAD"
}

function apiJobPriority(job) {
  if (!job) return 0
  if (apiRequestIsMutating(job.method)) return 2
  return String(job.priority || "") === "interactive" ? 1 : 0
}

function enqueueApiJob(queue, job) {
  var next = arrayValues(queue)
  if (!job) return next
  var priority = apiJobPriority(job)
  var index = 0
  while (index < next.length && apiJobPriority(next[index]) >= priority) index++
  next.splice(index, 0, job)
  return next
}

function dequeueApiJob(queue) {
  var next = arrayValues(queue)
  while (next.length) {
    var job = next.shift()
    if (!job || (job.handle && job.handle.aborted === true)) continue
    return { job: job, queue: next }
  }
  return { job: null, queue: next }
}

function apiCooldownMs(now, until) {
  var wait = (Number(until) || 0) - (Number(now) || 0)
  return wait > 0 ? Math.ceil(wait) : 0
}

function nextRateLimitedUntil(now, retryAfter, currentUntil, attempt) {
  var proposed = (Number(now) || 0) + rateLimitRetryMs(retryAfter, attempt)
  var existing = Number(currentUntil) || 0
  return proposed > existing ? proposed : existing
}

function playlistOwnedByUser(playlist, userId) {
  var user = String(userId || "")
  return !!playlist && !!user && String(playlist.ownerId || "") === user
}

function playlistItemsHiddenByApi(status, owned, collaborative, knownUser) {
  if (owned === true || collaborative === true || knownUser !== true) return false
  var code = Number(status) || 0
  return code === 403 || code === 200
}

function playlistItemsHiddenMessage() {
  return "Spotify does not expose the contents of this playlist unless you own or collaborate on it. You can still play it as a Spotify context."
}

function playlistItemsEmptyMessage(playlist, itemCount, error, status, userId) {
  if (!playlist) return ""
  var count = Number(itemCount) || 0
  var owned = playlistOwnedByUser(playlist, userId)
  var collaborative = !!(playlist && playlist.collaborative === true)
  var knownUser = String(userId || "") !== ""
  if (error) {
    if (playlistItemsHiddenByApi(status, owned, collaborative, knownUser))
      return playlistItemsHiddenMessage()
    return "Couldn't load this playlist. Try again in a moment."
  }
  if (count > 0) return ""
  if (playlistItemsHiddenByApi(200, owned, collaborative, knownUser))
    return playlistItemsHiddenMessage()
  return "This playlist has no visible items."
}

// While a player surface is open, keep this computer registered as a Spotify
// Connect receiver. The configured idle timeout begins only after every player
// surface closes.
function visibleLocalReceiverAction(uiVisible, fullyConnected, running, busy) {
  if (uiVisible !== true || fullyConnected !== true) return "idle"
  if (busy === true) return "wait"
  if (running === true) return "refresh"
  return "start"
}

// A paused item is still an active media session: keep its MPRIS metadata and
// resume controls alive after the UI closes. Only an empty/stopped receiver is
// eligible for the configured background shutdown timeout.
function idleShutdownShouldRun(daemonRunning, hasMedia, uiVisible, idleMinutes) {
  return daemonRunning === true && hasMedia !== true && uiVisible !== true
    && Number(idleMinutes) > 0
}

function remotePlaybackPollShouldRun(loggedIn, loading, uiVisible, useRemote,
    playing) {
  if (loggedIn !== true || loading === true) return false
  if (uiVisible === true) return true
  return useRemote === true && playing === true
}

function remotePlaybackPollInterval(uiVisible, useRemote, hasLocal) {
  return uiVisible === true && (useRemote === true || hasLocal !== true)
    ? 5000 : 15000
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

function spotifyTypeLabel(type) {
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
var VOLUME_FLUSH_REMOTE_MS = 250
var VOLUME_FLUSH_SONOS_MS = 120
var SLIDER_VOLUME_ACK_TOLERANCE = 0.04

function volumeFlushInterval(target) {
  var backend = String(target || "").trim().toLowerCase()
  if (backend === "remote") return VOLUME_FLUSH_REMOTE_MS
  if (backend === "sonos") return VOLUME_FLUSH_SONOS_MS
  return VOLUME_FLUSH_MS
}

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
// Subsonic song durations are whole seconds; interim callers still hand over
// Spotify-shaped rows whose durationMs/duration_ms are already milliseconds.
// Trust the explicit millisecond fields first; a bare `duration` value below
// 10000 is treated as seconds (a real song is never longer than that in ms
// naming, and never that short in seconds), anything at or above it as
// already-converted milliseconds.
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
// source; interim Spotify-shaped rows degrade to their closest field (uri ->
// track id, name -> title, artist -> artists) so the transport boundary keeps
// accepting today's lists until the Subsonic data model lands in package 5.
// Rows without any usable id return null and are dropped by the caller.
function backendSongRefV2(item) {
  if (!item || typeof item !== "object") return null
  var id = String(item.id === undefined || item.id === null ? "" : item.id).trim()
  if (!id) id = spotifyTrackId(item.uri)
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

// Interim bridge (package 5 replaces it with Subsonic rows end to end): turn
// a play request into a v2 load body. The visible list becomes the engine's
// queue starting at the clicked row, mirroring playbackBody's wrap-around so
// Next reaches the list's end the same way the Spotify play endpoint did.
// A resume offset in milliseconds is honored for a row loaded mid-song.
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
// for the few consumers that want a URI-shaped string: the persisted
// last-radio playlist identity in Service (session state and the remote
// playback context check) and the interim Spotify-shaped row shims. Panel
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
  var groups = searchGroups({}, 128)
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

// Preserve Spotify's current playback target unless the user explicitly chose
// another device in this app. The local spotifyd player is only the fallback
// when Spotify has no active device. Keeping a restricted device here avoids
// silently moving playback locally; Spotify can report the unsupported action.
function preferredPlaybackDevice(devices, selectedId, explicitSelection, currentDevice) {
  var values = Array.isArray(devices) ? devices : []
  var key = String(selectedId || "")
  if (explicitSelection && key) {
    for (var i = 0; i < values.length; i++)
      if (String(values[i].id || "") === key && values[i].restricted !== true)
        return values[i]
  }
  var current = currentDevice || null
  if (current && current.active === true) {
    for (var j = 0; j < values.length; j++)
      if (playbackDevicesMatch(values[j], current))
        return values[j]
    return current
  }
  for (var k = 0; k < values.length; k++)
    if (values[k].active === true)
      return values[k]
  for (var l = 0; l < values.length; l++)
    if (values[l].local === true && values[l].restricted !== true && values[l].id)
      return values[l]
  return null
}

// Keep an active remote receiver untouched, but remember an active local
// receiver as the implicit selection so the UI and subsequent playback agree.
function automaticLocalPlaybackDevice(selectedId, preferredDevice, localDevice) {
  if (String(selectedId || "")) return null
  var current = preferredDevice || null
  if (current && current.active === true && current.local !== true) return null
  var candidate = current && current.local === true ? current : (localDevice || null)
  return candidate && candidate.local === true && candidate.id
      && candidate.restricted !== true ? candidate : null
}

// Freeze the chosen receiver for this playback intent. A missing ID remains
// valid for hardware players exposed only through current playback.
function playbackTargetDeviceId(device, explicitSelection) {
  var item = device || null
  if (!item) return ""
  return String(item.id || "")
}

function isLocalPlaybackDevice(device, configuredName, runtimeName, knownId) {
  var item = device || {}
  var id = String(item.id || "")
  var rememberedId = String(knownId || "")
  if (id && rememberedId && id === rememberedId) return true
  var name = String(item.sourceName || item.name || "")
  var configured = String(configuredName || "")
  var runtime = String(runtimeName || "")
  return !!name && (name === configured || (!!runtime && name === runtime))
}

// Spotify may expose an active hardware player through /me/player while
// omitting it from /me/player/devices (Sonos is a common example). Device ids
// are authoritative when both endpoints provide one; otherwise fall back to
// the user-visible name and device type.
function playbackDevicesMatch(left, right) {
  var first = left || {}
  var second = right || {}
  var firstId = String(first.id || "")
  var secondId = String(second.id || "")
  if (firstId && secondId) return firstId === secondId
  var firstName = String(first.name || first.sourceName || "").trim().toLowerCase()
  var secondName = String(second.name || second.sourceName || "").trim().toLowerCase()
  if (!firstName || firstName !== secondName) return false
  var firstType = String(first.type || "").trim().toLowerCase()
  var secondType = String(second.type || "").trim().toLowerCase()
  return !firstType || !secondType || firstType === secondType
}

function pendingRemoteDeviceMatches(pending, device, now) {
  if (!pending || !pending.device || !device) return false
  var expiresAt = Number(pending.expiresAt)
  var current = Number(now)
  if (!isFinite(expiresAt) || !isFinite(current) || current >= expiresAt)
    return false
  return playbackDevicesMatch(pending.device, device)
}

function playbackPositionAt(positionSeconds, receivedAt, playing, now) {
  var value = Math.max(0, Number(positionSeconds) || 0)
  var anchor = Number(receivedAt)
  var current = Number(now)
  if (playing === true && isFinite(anchor) && isFinite(current))
    value += Math.max(0, current - anchor) / 1000
  return value
}

// Spotify can briefly return the pre-command playback state after accepting a
// seek. Keep the requested anchor until the active device reports a position
// close enough to acknowledge it, or until the bounded grace period expires.
function pendingRemoteSeekShouldHold(playback, pending, now) {
  var state = playback || null
  if (!state || !pendingRemoteDeviceMatches(pending, state.device, now))
    return false
  var currentUri = String((state.item && state.item.uri) || "")
  var requestedUri = String(pending.uri || "")
  if (!currentUri || (requestedUri && currentUri !== requestedUri)) return false

  var reported = playbackPositionAt(state.progressSeconds, state.receivedAt,
    state.playing, now)
  var requested = playbackPositionAt(pending.positionSeconds,
    pending.requestedAt, pending.playing, now)
  return Math.abs(reported - requested) > 2
}

function displayedRemotePosition(playback, pending, now) {
  var state = playback || {}
  if (pendingRemoteSeekShouldHold(state, pending, now))
    return playbackPositionAt(pending.positionSeconds, pending.requestedAt,
      pending.playing, now)
  return playbackPositionAt(state.progressSeconds, state.receivedAt,
    state.playing, now)
}

// Volume has no timestamp in Spotify's response. An exact percentage is
// therefore the acknowledgement; null or a different value remains stale for
// the same bounded grace period.
function pendingRemoteVolumeShouldHold(device, pending, now) {
  if (!pendingRemoteDeviceMatches(pending, device, now)) return false
  var requested = normalizeVolumePercent(pending.volumePercent)
  var reported = normalizeVolumePercent((device || {}).volumePercent)
  return requested !== null
    && (reported === null || Math.abs(reported - requested) > 0.5)
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

function spotifyConnectTokenType(value) {
  var tokenType = String(value || "default").trim().toLowerCase()
  return ["default", "accesstoken", "authorization_code"].indexOf(tokenType) >= 0
    ? tokenType : "default"
}

function isSpotifyConnectDeviceId(value) {
  return /^[A-Za-z0-9_.:-]{8,160}$/.test(String(value || ""))
}

// Some hardware receivers expose their device id as their Web API name. Local
// ZeroConf discovery has the user-facing alias and can safely relabel the same
// receiver because playbackDevicesMatch requires equal ids when both exist.
function spotifyDeviceNameNeedsDiscovery(device) {
  var item = device || {}
  var name = String(item.name || "").trim()
  var id = String(item.id || "").trim()
  return !name || (!!id && name.toLowerCase() === id.toLowerCase())
    || /^[a-f0-9]{40}$/i.test(name)
}

function playbackDeviceDisplayName(device, discoveredDevices) {
  var item = device || {}
  var receivers = Array.isArray(discoveredDevices) ? discoveredDevices : []
  for (var i = 0; i < receivers.length; i++) {
    var receiver = receivers[i]
    if (!receiver || !playbackDevicesMatch(receiver, item)) continue
    var discoveredName = String(receiver.name || "").trim()
    if (discoveredName) return discoveredName
  }
  return String(item.name || "").trim()
}

function normalizePlaybackState(value, imageWidth) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null
  var source = value
  var rawDevice = source.device || null
  var device = rawDevice && typeof rawDevice === "object" ? {
    id: String(rawDevice.id || ""),
    name: String(rawDevice.name || "Spotify device"),
    type: String(rawDevice.type || "unknown"),
    active: rawDevice.is_active === true,
    restricted: rawDevice.is_restricted === true,
    // Spotify explicitly permits this field to be null. Preserve that as
    // "unknown" instead of making a missing reading look like a real mute.
    volumePercent: normalizeVolumePercent(rawDevice.volume_percent),
    supportsVolume: rawDevice.supports_volume === true
  } : null
  var item = source.item && typeof source.item === "object"
    ? normalizeTrack(source.item, imageWidth || 192) : null
  if (!device && !item) return null
  return {
    device: device,
    item: item,
    playing: source.is_playing === true,
    progressSeconds: Math.max(0, Number(source.progress_ms) || 0) / 1000,
    receivedAt: Date.now(),
    repeatMode: ["off", "track", "context"].indexOf(String(source.repeat_state)) >= 0
      ? String(source.repeat_state) : "off",
    shuffle: source.shuffle_state === true,
    contextUri: source.context && source.context.uri
      ? String(source.context.uri) : "",
    contextHref: source.context && source.context.href
      ? String(source.context.href) : "",
    contextType: source.context && source.context.type
      ? String(source.context.type) : "",
    disallows: source.actions && source.actions.disallows
      && typeof source.actions.disallows === "object"
      ? source.actions.disallows : ({})
  }
}

function imageFor(images, targetWidth) {
  if (!Array.isArray(images) || images.length === 0) return ""
  var target = Math.max(1, Number(targetWidth) || 128)
  var best = null
  var bestScore = Number.MAX_VALUE
  for (var i = 0; i < images.length; i++) {
    var image = images[i]
    if (!image || !image.url) continue
    var width = Number(image.width) || target
    // Prefer the smallest image that is still large enough. Undersized images
    // get a larger penalty so artwork is not visibly upscaled.
    var score = width >= target ? width - target : (target - width) * 4
    if (score < bestScore) {
      best = image
      bestScore = score
    }
  }
  return best ? String(best.url) : ""
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

function spotifyTrackId(value) {
  var match = String(value || "").match(
    /(?:spotify:track:|spotify\/track\/|open\.spotify\.com\/track\/)([A-Za-z0-9]+)/)
  return match ? match[1] : ""
}

// Playback from another Spotify Connect device already carries a normalized
// item. Local spotifyd playback may expose only MPRIS metadata, so synthesize
// the small track shape needed by library actions in that case. A matching
// episode must not be mistaken for a track when spotifyd's object-path
// fallback supplied its id.
function currentPlaybackTrack(trackId, remoteTrack, title, artist, album,
    coverUrl, durationSeconds, externalUrl) {
  var id = String(trackId || "").trim()
  if (!id) return null

  var remote = remoteTrack && typeof remoteTrack === "object"
    ? remoteTrack : null
  var remoteId = remote
    ? String(remote.id || spotifyTrackId(remote.uri)).trim() : ""
  if (remote && remoteId === id) {
    if (String(remote.type || "track") !== "track") return null
    if (remote.uri) return remote
  }

  return {
    kind: "item",
    type: "track",
    id: id,
    uri: "spotify:track:" + id,
    name: String(title || "Untitled"),
    subtitle: String(artist || ""),
    album: String(album || ""),
    artists: [],
    albumItem: null,
    parentContext: null,
    imageUrl: String(coverUrl || ""),
    durationMs: Math.max(0, Number(durationSeconds) || 0) * 1000,
    externalUrl: String(externalUrl || "")
  }
}

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
    id: "spotify:track:" + id,
    title: songTitle,
    artist: songArtist,
    album: String(album || "").trim(),
    duration: songDuration,
    coverUrl: String(coverUrl || "").trim(),
    positionSeconds: songPosition
  }
}

function optionalPluginState(installed, enabled) {
  if (installed !== true) return "missing"
  return enabled === true ? "ready" : "disabled"
}

// Installation runs non-interactively only after the app's own confirmation
// prompt. Keep the repository and plugin id as separate argv entries so no
// user-controlled text is ever interpreted by a shell.
function optionalPluginSetupCommand(state, pluginId, repositoryUrl) {
  var availability = String(state || "")
  var id = String(pluginId || "").trim()
  var url = String(repositoryUrl || "").trim()
  // Use the absolute binary so a Quickshell Process/execDetached does not
  // depend on the shell's PATH. --yes keeps add non-interactive.
  if (availability === "missing" && url)
    return ["/usr/bin/omarchy", "plugin", "add", url, "--enable", "--yes"]
  if (availability === "disabled" && id)
    return ["/usr/bin/omarchy", "plugin", "enable", id, "--section", "center"]
  return []
}

function lyricsInstallIntent(song, surface, now) {
  if (!song || typeof song !== "object") return null
  return {
    song: song,
    surface: String(surface || ""),
    startedAt: Number(now) || Date.now()
  }
}

function lyricsInstallIntentIsFresh(intent, now, lifetimeMs) {
  if (!intent || typeof intent !== "object" || !intent.song) return false
  return timestampIsFresh(intent.startedAt, now,
    lifetimeMs === undefined ? 180000 : lifetimeMs)
}

function sessionWithoutLyricsInstall(session) {
  var next = shallowCopy(session)
  delete next.pendingLyricsInstall
  return next
}

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
    || (active === true && area !== "login" && area !== "devices"
      && area !== "setup")
}

function isUtilityTab(tab) {
  var area = String(tab || "")
  return area === "setup" || area === "devices" || area === "login"
}

function rememberContentTab(tab) {
  var area = String(tab || "")
  return !area || isUtilityTab(area) ? "" : area
}

// Settings and Devices sit on top of the last real page. Esc returns there
// and skips any intervening Settings/Devices visit so two Esc presses cannot
// close the window from those menus.
function previousContentTab(currentTab, lastContentTab) {
  if (currentTab !== "setup" && currentTab !== "devices") return ""
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
// name. Matching ignores punctuation and case, the way the old Spotify
// title comparisons did.
function playlistMatchesTerm(playlist, term) {
  var expected = comparablePlaylistTitle(term)
  if (!expected) return true
  return comparablePlaylistTitle(playlist && playlist.name) === expected
    || comparablePlaylistTitle(playlist && playlist.name).indexOf(expected) >= 0
}

function albumKind(item) {
  var source = item || {}
  var type = String(source.album_type || source.album_group || "").toLowerCase()
  if (type === "single") return Number(source.total_tracks) > 1 ? "EP / Single" : "Single"
  if (type === "compilation") return "Compilation"
  return type === "album" ? "Album" : "Release"
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

// Spotify's insert_before index is measured against the playlist before the
// selected range is removed. The UI works with the item's final index, so a
// downward move needs to step over the source item once.
function playlistReorderBody(sourceIndex, destinationIndex, itemCount, snapshotId) {
  var sourceNumber = Number(sourceIndex)
  var destinationNumber = Number(destinationIndex)
  var countNumber = Number(itemCount)
  if (!isFinite(sourceNumber) || !isFinite(destinationNumber) || !isFinite(countNumber))
    return null
  var source = Math.floor(sourceNumber)
  var destination = Math.floor(destinationNumber)
  var count = Math.floor(countNumber)
  if (count < 2 || source < 0 || source >= count || destination < 0
      || destination >= count || source === destination) return null
  var body = {
    range_start: source,
    insert_before: source < destination ? destination + 1 : destination,
    range_length: 1
  }
  var snapshot = String(snapshotId || "")
  if (snapshot) body.snapshot_id = snapshot
  return body
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

function playlistReorderBodyForItems(items, sourceIndex, destinationIndex,
    itemCount, snapshotId) {
  var rows = Array.isArray(items) ? items : []
  var sourcePosition = playlistPositionAt(rows, sourceIndex)
  var destinationPosition = playlistPositionAt(rows, destinationIndex)
  if (sourcePosition < 0 || destinationPosition < 0) return null
  var requestedCount = Number(itemCount)
  var count = isFinite(requestedCount) ? Math.floor(requestedCount) : rows.length
  count = Math.max(count, rows.length, sourcePosition + 1, destinationPosition + 1)
  return playlistReorderBody(sourcePosition, destinationPosition, count, snapshotId)
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

function normalizedArtists(artists, imageWidth) {
  var sourceArtists = arrayValues(artists)
  var rows = []
  for (var i = 0; i < sourceArtists.length; i++) {
    var source = sourceArtists[i] || {}
    // Spotify's simplified artist object normally carries `type`, but some
    // playlist and cached payloads omit it. Artist links should still work.
    var artist = normalizeContext({
      id: source.id,
      uri: source.uri,
      type: source.type || "artist",
      name: source.name,
      images: source.images,
      external_urls: source.external_urls
    }, imageWidth)
    if (artist && artist.type === "artist") rows.push(artist)
  }
  return rows
}

function normalizeTrack(value, imageWidth, parentContext) {
  var source = value || {}
  var item = source.item || source.track || source.episode || source.chapter || source
  if (!item || typeof item !== "object") return null
  var album = item.album || {}
  var type = String(item.type || "track")
  if (["track", "episode", "chapter"].indexOf(type) === -1) return null
  var subtitle = type === "episode"
    ? String((item.show && item.show.name) || item.description || "Podcast")
    : (type === "chapter"
      ? String((item.audiobook && item.audiobook.name) || item.description || "Audiobook")
      : artistNames(item.artists))
  var images = type === "track" ? album.images : item.images
  var albumItem = type === "track" && album && album.name
    ? normalizeContext({
      id: album.id,
      uri: album.uri,
      type: album.type || "album",
      name: album.name,
      artists: album.artists,
      images: album.images,
      release_date: album.release_date,
      total_tracks: album.total_tracks,
      external_urls: album.external_urls
    }, imageWidth || 96) : null
  if (!albumItem && type === "track" && parentContext && parentContext.type === "album")
    albumItem = parentContext
  var parentItem = type === "episode" && item.show
    ? normalizeContext(item.show, imageWidth || 96)
    : (type === "chapter" && item.audiobook
      ? normalizeContext(item.audiobook, imageWidth || 96) : null)
  if (!parentItem && parentContext
      && ((type === "episode" && parentContext.type === "show")
        || (type === "chapter" && parentContext.type === "audiobook")))
    parentItem = parentContext
  if ((type === "episode" || type === "chapter") && parentItem)
    subtitle = String(parentItem.name || subtitle)
  var resume = item.resume_point || {}
  return {
    kind: "item",
    type: type,
    id: String(item.id || ""),
    uri: String(item.uri || ""),
    name: String(item.name || "Untitled"),
    subtitle: subtitle,
    album: String(album.name || (albumItem && albumItem.name) || ""),
    artists: normalizedArtists(item.artists, imageWidth || 96),
    albumItem: albumItem,
    parentContext: parentItem,
    imageUrl: imageFor(images, imageWidth || 96)
      || String((parentContext && parentContext.imageUrl) || ""),
    durationMs: Number(item.duration_ms) || 0,
    trackNumber: Number(item.track_number || item.chapter_number) || 0,
    discNumber: Number(item.disc_number) || 0,
    releaseDate: String(item.release_date || album.release_date || ""),
    addedAt: String(source.added_at || ""),
    playedAt: String(source.played_at || ""),
    resumeMs: Math.max(0, Number(resume.resume_position_ms) || 0),
    fullyPlayed: resume.fully_played === true,
    explicit: item.explicit === true,
    externalUrl: item.external_urls && item.external_urls.spotify
      ? String(item.external_urls.spotify) : ""
  }
}

function normalizeContext(value, imageWidth) {
  var source = value || {}
  var item = source.album || source.artist || source.playlist || source.show
    || source.audiobook || source
  var type = String(item.type || "")
  if (["album", "artist", "playlist", "show", "audiobook"].indexOf(type) === -1) return null
  var subtitle = ""
  if (type === "album") {
    var albumDetails = []
    var albumArtists = artistNames(item.artists)
    if (albumArtists) albumDetails.push(albumArtists)
    albumDetails.push(albumKind(item))
    if (item.release_date) albumDetails.push(String(item.release_date).slice(0, 4))
    subtitle = albumDetails.join(" · ")
  }
  else if (type === "playlist") subtitle = String((item.owner && item.owner.display_name) || "Playlist")
  else if (type === "artist") subtitle = "Artist"
  else if (type === "show") subtitle = String(item.publisher || "Podcast")
  else {
    var authors = []
    var sourceAuthors = Array.isArray(item.authors) ? item.authors : []
    for (var a = 0; a < sourceAuthors.length; a++)
      if (sourceAuthors[a] && sourceAuthors[a].name) authors.push(String(sourceAuthors[a].name))
    subtitle = authors.length ? authors.join(", ") : String(item.publisher || "Audiobook")
  }
  var total = Number(item.total_tracks || item.total_episodes || item.total_chapters) || 0
  if (type === "playlist") total = Number((item.items && item.items.total)
    || (item.tracks && item.tracks.total)) || 0
  return {
    kind: "context",
    type: type,
    id: String(item.id || ""),
    uri: String(item.uri || ""),
    name: String(item.name || "Untitled"),
    subtitle: subtitle,
    description: String(item.description || ""),
    artists: normalizedArtists(item.artists, imageWidth || 128),
    imageUrl: imageFor(item.images, imageWidth || 128),
    total: total,
    releaseType: type === "album" ? String(item.album_type || item.album_group || "") : "",
    releaseDate: String(item.release_date || ""),
    ownerId: String((item.owner && (item.owner.account_id || item.owner.id)) || ""),
    ownerName: String((item.owner && item.owner.display_name) || ""),
    collaborative: item.collaborative === true,
    public: item.public === true,
    snapshotId: String(item.snapshot_id || ""),
    addedAt: String(source.added_at || ""),
    externalUrl: item.external_urls && item.external_urls.spotify
      ? String(item.external_urls.spotify) : ""
  }
}

function normalizePlaylist(value, imageWidth) {
  var normalized = normalizeContext(value, imageWidth)
  if (!normalized || normalized.type !== "playlist") return null
  return normalized
}

function normalizePage(page, mapper) {
  var source = page || {}
  var values = Array.isArray(source.items) ? source.items : []
  var items = []
  for (var i = 0; i < values.length; i++) {
    var mapped = mapper(values[i])
    if (mapped) items.push(mapped)
  }
  return {
    items: items,
    next: safeApiUrl(source.next),
    previous: safeApiUrl(source.previous),
    total: Number(source.total) || items.length
  }
}

// Playlist rows are loaded explicitly a page at a time. Keep every requested
// page, including duplicate tracks, and let Spotify's continuation URL decide
// when the collection is complete instead of applying the shared UI cache cap.
function playlistPageState(existing, incoming, append, next) {
  var current = arrayValues(existing)
  var page = arrayValues(incoming)
  return {
    items: append === true ? current.concat(page) : page,
    next: safeApiUrl(next)
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
  return loading === true || safeApiUrl(next) !== ""
}

function playlistRestoreShouldContinue(itemCount, targetCount, next) {
  return playlistRestorePending(itemCount, targetCount, false, next)
}

function searchTypeKey(type) {
  var value = String(type || "track")
  if (value === "artist") return "artists"
  if (value === "album") return "albums"
  if (value === "playlist") return "playlists"
  return "tracks"
}

function normalizeSearchPage(payload, type, imageWidth) {
  var key = searchTypeKey(type)
  var page = payload && payload[key] ? payload[key] : {}
  return normalizePage(page, function(value) {
    return type === "track" || type === "episode"
      ? normalizeTrack(value, imageWidth || 128)
      : normalizeContext(value, imageWidth || 128)
  })
}

function searchGroups(payload, imageWidth) {
  var result = ({})
  for (var i = 0; i < SEARCH_TYPES.length; i++) {
    var type = SEARCH_TYPES[i]
    result[type] = normalizeSearchPage(payload, type, imageWidth || 128)
  }
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
      next: nextPage.next,
      previous: nextPage.previous,
      total: Math.max(Number(oldPage.total) || 0, Number(nextPage.total) || 0)
    }
  }
  return result
}

function normalizeCursorPage(container, mapper) {
  var page = container || {}
  var values = Array.isArray(page.items) ? page.items : []
  var items = []
  for (var i = 0; i < values.length; i++) {
    var mapped = mapper(values[i])
    if (mapped) items.push(mapped)
  }
  return {
    items: items,
    next: safeApiUrl(page.next),
    total: Number(page.total) || items.length,
    after: String((page.cursors && page.cursors.after) || "")
  }
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
// type:id saved key; an interim Spotify-shaped row keeps working through its
// uri/id fallback, and keyless rows pass through untouched.
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
