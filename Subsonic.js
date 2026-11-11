.pragma library

// Subsonic/OpenSubsonic request helpers shared by the API layer and its
// tests. Everything here is pure: no XMLHttpRequest, no Quickshell imports.
// Transport lives in the QML files; this module owns token mathematics,
// URL building, response parsing, and typed error classification.

var API_VERSION = "1.16.1"
var CLIENT_ID = "omarchy-navidrome"
var SALT_ALPHABET = "abcdef0123456789"
var SALT_MIN_LENGTH = 6

// `t` is md5(password + salt). The password therefore must exist in clear
// text on this side; it lives in the keyring, never in settings or logs.
function authToken(password, salt) {
  return md5(String(password) + String(salt))
}

// ≥6 hexadecimal characters. The generator is injectable so tests can pin
// output while production keeps unpredictability.
function randomSalt(randomSource) {
  var source = randomSource || Math.random
  var salt = ""
  for (var i = 0; i < 16; i++) {
    salt += SALT_ALPHABET.charAt(Math.floor(source() * 16))
  }
  if (salt.length < SALT_MIN_LENGTH) return SALT_ALPHABET + salt
  return salt
}

// Auth params for one request. Fresh salt per request — a reused salt makes
// replay trivial if a URL leaks.
function authParams(username, password, salt) {
  return {
    u: String(username),
    t: authToken(password, salt),
    s: String(salt),
    v: API_VERSION,
    c: CLIENT_ID,
    f: "json"
  }
}

// Accepts "http://host:port/base", "https://host", Bracketed IPv6 plus port.
// Scheme-less or empty input is rejected; callers report it as invalid.
function normalizeServerUrl(raw) {
  var url = String(raw === undefined || raw === null ? "" : raw).trim()
  var parsed = splitServerUrl(url)
  if (!parsed) return null
  var path = (parsed.path || "/").replace(/\/+$/, "")
  return parsed.scheme + "://" + parsed.host + (parsed.port ? ":" + parsed.port : "") + path
}

function isInsecureServerUrl(raw) {
  var parsed = splitServerUrl(String(raw || "").trim())
  return parsed !== null && parsed.scheme === "http"
}

function splitServerUrl(candidate) {
  if (!candidate) return null
  var match = /^([a-zA-Z][a-zA-Z0-9+.-]*):\/\/([^/?#]*)([^#]*)?$/.exec(candidate)
  if (!match) return null
  var scheme = match[1].toLowerCase()
  if (scheme !== "http" && scheme !== "https") return null
  var authority = match[2]
  var host = authority
  var port = ""
  if (host.charAt(0) === "[") {
    var close = host.indexOf("]")
    if (close < 0) return null
    var rest = host.slice(close + 1)
    host = host.slice(0, close + 1)
    if (rest.charAt(0) === ":") port = rest.slice(1)
    else if (rest !== "") return null
  } else if (host.indexOf(":") >= 0) {
    var parts = host.split(":")
    if (parts.length !== 2) return null
    host = parts[0]
    port = parts[1]
  }
  if (!host) return null
  if (port !== "" && !/^[0-9]{1,5}$/.test(port)) return null
  var path = match[3] || ""
  if (path.indexOf("?") >= 0) path = path.slice(0, path.indexOf("?"))
  // Canonical host case; the path keeps its casing.
  var lowered = host.toLowerCase()
  return {scheme: scheme, host: lowered, port: port, path: path}
}

function endpointUrl(serverUrl, endpoint) {
  var base = normalizeServerUrl(serverUrl)
  if (base === null) return null
  var name = String(endpoint || "").replace(/^\/+/, "").replace(/\.view$/, "")
  return base + (base.charAt(base.length - 1) === "/" ? "" : "/") + "rest/" + name
}

// Endpoint parameters may be string, number, boolean, array (repeated keys —
// Subsonic uses repeated `id=` for many-value verbs), or null/"" (omitted).
// Keys are sorted for stable, testable URLs.
function buildQuery(auth, endpointParams, randomSource) {
  var salt = (auth && auth.salt) ? String(auth.salt) : randomSalt(randomSource)
  var salted = authParams(auth ? auth.u : "", auth ? auth.p : "", salt)
  var all = {}
  var key
  for (key in salted) all[key] = salted[key]
  if (endpointParams) {
    for (key in endpointParams) {
      var value = endpointParams[key]
      if (value === null || value === undefined || value === "") continue
      if (value instanceof Array) {
        var strings = []
        for (var i = 0; i < value.length; i++) {
          if (value[i] !== null && value[i] !== undefined && value[i] !== "") {
            strings.push(String(value[i]))
          }
        }
        if (strings.length) all[key] = strings
      } else {
        all[key] = String(value)
      }
    }
  }
  var keys = []
  for (key in all) keys.push(key)
  keys.sort()
  var parts = []
  for (var j = 0; j < keys.length; j++) {
    var item = all[keys[j]]
    if (item instanceof Array) {
      for (var k = 0; k < item.length; k++) {
        parts.push(queryEscape(keys[j], item[k]))
      }
    } else {
      parts.push(queryEscape(keys[j], item))
    }
  }
  return {salt: salt, query: parts.join("&")}
}

function requestUrl(serverUrl, endpoint, auth, endpointParams, randomSource) {
  var base = endpointUrl(serverUrl, endpoint)
  if (base === null) return null
  var built = buildQuery(auth, endpointParams, randomSource)
  return {url: base + "?" + built.query, salt: built.salt}
}

// A Subsonic response is {"subsonic-response": {"status": "ok"|"failed", ...,
// "error": {"code": n, "message": "..."}}}. Collections sit beside "status".
function parseResponse(json) {
  var root = null
  if (json && json["subsonic-response"]) root = json["subsonic-response"]
  else root = json
  if (!root || typeof root !== "object") {
    return {ok: false, errorCode: 0, errorMessage: "Malformed server response"}
  }
  if (root.status === "ok") {
    // A failed status must never be reported as ok even with OK collateral.
    return {ok: true, errorCode: 0, errorMessage: "", data: root}
  }
  var error = root.error && typeof root.error === "object" ? root.error : {}
  var code = typeof error.code === "number" ? error.code : 0
  return {
    ok: false,
    errorCode: code,
    errorMessage: String(error.message || errorMessageForCode(code))
  }
}

// Typed categories for setup/UI handling. Never invent a recovery strategy
// per code here; the category names the failure, the UI explains it.
var ERROR_CATEGORIES = {
  0: "generic",
  10: "missingParameter",
  20: "serverError",
  30: "outdatedClient",
  40: "wrongCredentials",
  41: "tokenAuthRejected",
  42: "tokenAuthRejected",
  50: "notAuthorized",
  60: "subscriptionExpired",
  70: "notFound"
}

function errorCategory(code) {
  if (Object.prototype.hasOwnProperty.call(ERROR_CATEGORIES, code)) {
    return ERROR_CATEGORIES[code]
  }
  return "generic"
}

function errorMessageForCode(code) {
  switch (errorCategory(code)) {
    case "missingParameter": return "The server reported a missing parameter"
    case "serverError": return "The server hit an internal error"
    case "outdatedClient": return "The server requires a newer client version"
    case "wrongCredentials": return "Wrong username or password"
    case "tokenAuthRejected": return "The server rejected token authentication"
    case "notAuthorized": return "The user is not authorized for this action"
    case "notFound": return "The requested item was not found"
    case "subscriptionExpired": return "The server subscription expired"
    default: return "The server reported an error"
  }
}

// ------ backend error-code typing (protocol v2) --------------------------------

// The Rust stream engine reports stable error codes. Credential-class ones are
// terminal: they must never consume a reconnect or retry budget, only surface
// a typed state the UI can explain. Everything else stays generic/network and
// keeps the retry behavior.
var BACKEND_CREDENTIAL_CODES = {
  missing_credentials: "missingCredentials",
  invalid_configuration: "invalidConfiguration",
  // "bad credentials or permissions; no retry is attempted" per the engine.
  stream_rejected: "wrongCredentials"
}

function backendErrorCategory(code) {
  var key = String(code === undefined || code === null ? "" : code)
  if (Object.prototype.hasOwnProperty.call(BACKEND_CREDENTIAL_CODES, key)) {
    return BACKEND_CREDENTIAL_CODES[key]
  }
  return "generic"
}

// Terminal categories stop the reconnect push; generic/network ones consume
// the retry budget. wrongCredentials/tokenAuthRejected come from Subsonic
// error codes, missingCredentials/invalidServerUrl are the transport's local
// fail-fast categories, invalidConfiguration is the backend's configure_server
// rejection.
function isTerminalCredentialCategory(category) {
  return category === "wrongCredentials"
    || category === "tokenAuthRejected"
    || category === "missingCredentials"
    || category === "invalidConfiguration"
    || category === "invalidServerUrl"
}

// One short line per terminal backend code; "" for non-credential codes so
// callers can branch on truthiness.
function backendCredentialMessage(code) {
  switch (backendErrorCategory(code)) {
    case "missingCredentials":
      return "Set up your Navidrome server in Settings to play on this computer."
    case "invalidConfiguration":
      return "The Navidrome server settings are invalid. Review them in Settings."
    case "wrongCredentials":
      return "The Navidrome server rejected the credentials or permissions for this song."
    default:
      return ""
  }
}

// ------ credential entry validation and keyring payload ------------------------

// Pure setup-entry validation shared by AuthManager, the setup script's
// expectations, and tests. The URL goes through normalizeServerUrl: an
// invalid address is a typed error, and a plain http:// target stays allowed
// but is flagged insecure (consumers decide the display; the flag is always
// set).
function validateConnectionEntry(rawUrl, rawUsername, rawPassword) {
  var url = String(rawUrl === undefined || rawUrl === null ? "" : rawUrl).trim()
  var username = String(rawUsername === undefined || rawUsername === null
    ? "" : rawUsername).trim()
  var password = String(rawPassword === undefined || rawPassword === null
    ? "" : rawPassword)
  var normalized = normalizeServerUrl(url)
  if (!normalized) {
    return {ok: false, url: "", username: username, password: password,
      insecure: false,
      error: "The server address is not a valid http or https URL."}
  }
  if (username === "") {
    return {ok: false, url: normalized, username: "", password: password,
      insecure: isInsecureServerUrl(normalized),
      error: "Enter your Navidrome username."}
  }
  if (password === "") {
    return {ok: false, url: normalized, username: username, password: "",
      insecure: isInsecureServerUrl(normalized),
      error: "Enter your Navidrome password."}
  }
  return {ok: true, url: normalized, username: username, password: password,
    insecure: isInsecureServerUrl(normalized), error: ""}
}

// One credential set rides the keyring as a single-line JSON payload under
// fixed attributes. Malformed shapes mean "no stored session", never an
// error; the password only ever lives inside this payload.
function parseCredentialPayload(raw) {
  var line = String(raw === undefined || raw === null ? "" : raw).trim()
  if (line === "" || line.charAt(0) !== "{") return null
  var parsed = null
  try { parsed = JSON.parse(line) } catch (error) { parsed = null }
  if (!parsed || typeof parsed !== "object" || parsed.v !== 1) return null
  if (typeof parsed.url !== "string" || parsed.url === "") return null
  if (typeof parsed.username !== "string" || parsed.username === "") return null
  if (typeof parsed.password !== "string" || parsed.password === "") return null
  return parsed
}

function queryEscape(key, value) {
  return encodeURIComponent(key) + "=" + encodeURIComponent(value)
}

// ------ defensive node parsing shared by every endpoint normalizer -----------

// Bounded numeric coercion: empty and non-finite input yields the fallback
// (0 unless given), negatives clamp to zero. Some servers send numbers as
// strings; both shapes must land on the same value.
function boundedNumber(value, fallback) {
  if (value === "" || value === null || value === undefined) {
    return fallback === undefined ? 0 : fallback
  }
  var n = Number(value)
  if (!isFinite(n)) return fallback === undefined ? 0 : fallback
  if (n < 0) return 0
  return n
}

function text(value) {
  return value === null || value === undefined ? "" : String(value)
}

// Subsonic JSON uses real booleans; the string "false" must stay false.
function strictTrue(value) {
  return value === true
}

function hasId(node) {
  return !!node && node.id !== null && node.id !== undefined
    && String(node.id) !== ""
}

// Flattens a repeated-key container (array, single node, or absent) through
// `normalize`, dropping everything it rejects.
function listOf(node, key, normalize) {
  if (!node || typeof node !== "object") return []
  var child = node[key]
  if (!child || typeof child !== "object") return []
  var items = child instanceof Array ? child : [child]
  var out = []
  for (var i = 0; i < items.length; i++) {
    var normalized = normalize(items[i])
    if (normalized !== null) out.push(normalized)
  }
  return out
}

// Any mix of scalars and arrays into a clean string list (repeated keys).
function idList(value) {
  var items = value instanceof Array ? value
    : (value === null || value === undefined ? [] : [value])
  var out = []
  for (var i = 0; i < items.length; i++) {
    if (items[i] !== null && items[i] !== undefined && String(items[i]) !== "") {
      out.push(String(items[i]))
    }
  }
  return out
}

// ------ node shapes -----------------------------------------------------------

// IDs are always strings; entries without one are dropped by the callers.
function normalizeSong(node) {
  if (!hasId(node)) return null
  return {
    id: String(node.id),
    title: text(node.title),
    artist: text(node.artist),
    artistId: text(node.artistId),
    album: text(node.album),
    albumId: text(node.albumId),
    duration: boundedNumber(node.duration, 0),
    track: boundedNumber(node.track, 0),
    year: boundedNumber(node.year, null),
    genre: text(node.genre),
    coverArt: text(node.coverArt),
    starred: strictTrue(node.starred),
    played: typeof node.played === "string" ? node.played : null,
    suffix: text(node.suffix),
    bitRate: boundedNumber(node.bitRate, 0),
    size: boundedNumber(node.size, 0),
    contentType: text(node.contentType),
    isVideo: strictTrue(node.isVideo),
    path: text(node.path)
  }
}

function normalizeAlbum(node) {
  if (!hasId(node)) return null
  return {
    id: String(node.id),
    name: text(node.name),
    artist: text(node.artist),
    artistId: text(node.artistId),
    coverArt: text(node.coverArt),
    songCount: boundedNumber(node.songCount, 0),
    duration: boundedNumber(node.duration, 0),
    year: boundedNumber(node.year, null),
    genre: text(node.genre),
    starred: strictTrue(node.starred),
    played: typeof node.played === "string" ? node.played : null
  }
}

function normalizeArtist(node) {
  if (!hasId(node)) return null
  return {
    id: String(node.id),
    name: text(node.name),
    coverArt: text(node.coverArt),
    albumCount: boundedNumber(node.albumCount, 0),
    starred: strictTrue(node.starred)
  }
}

function normalizePlaylist(node) {
  if (!hasId(node)) return null
  return {
    id: String(node.id),
    name: text(node.name),
    comment: text(node.comment),
    owner: text(node.owner),
    public: strictTrue(node.public),
    songCount: boundedNumber(node.songCount, 0),
    duration: boundedNumber(node.duration, 0),
    created: text(node.created),
    changed: text(node.changed),
    coverArt: text(node.coverArt),
    starred: strictTrue(node.starred)
  }
}

// ------ connection probe: license, user, typed probe errors -------------------

// ping + getUser + getLicense run before any heavy listing; each parses
// defensively so a hostile server can never throw in the probe path.
function parseLicense(data) {
  var node = data && typeof data === "object" ? data.license : null
  if (!node || typeof node !== "object") {
    return {ok: false, trial: false, expires: null}
  }
  var expires = typeof node.expires === "string" && node.expires !== ""
    ? node.expires
    : (typeof node.trialExpires === "string" && node.trialExpires !== ""
      ? node.trialExpires : null)
  return {
    ok: strictTrue(node.valid),
    trial: node.trialExpires !== null && node.trialExpires !== undefined,
    expires: expires
  }
}

var USER_ROLES = [
  "adminRole", "settingsRole", "streamRole", "downloadRole", "uploadRole",
  "playlistRole", "coverArtRole", "commentRole", "podcastRole", "shareRole",
  "jukeboxRole", "scanRole"
]

// getUser nests under `user`; roles are strictly-true booleans.
function parseUser(data) {
  var node = data && typeof data === "object" ? data.user : null
  if (!node || typeof node !== "object") return null
  var user = {username: text(node.username)}
  for (var i = 0; i < USER_ROLES.length; i++) {
    user[USER_ROLES[i]] = strictTrue(node[USER_ROLES[i]])
  }
  return user
}

// One short line per existing error category; a passing probe reports none.
function describeProbeError(parsed) {
  if (parsed && typeof parsed === "object" && parsed.ok === true) return ""
  var category = errorCategory(
    parsed && typeof parsed === "object" ? parsed.errorCode : 0)
  switch (category) {
    case "wrongCredentials": return "Wrong username or password"
    case "tokenAuthRejected": return "The server rejected token authentication"
    case "notAuthorized": return "This user is not authorized to use the server"
    case "subscriptionExpired": return "The server license has expired"
    case "outdatedClient": return "The server needs a newer client version"
    case "serverError": return "The server hit an internal error"
    case "missingParameter": return "The server rejected the request"
    case "notFound": return "The server endpoint was not found"
    default: return "Could not reach the server"
  }
}

// ------ search3 and album windows ---------------------------------------------

var SEARCH3_WINDOWS = [
  "artistCount", "artistOffset", "albumCount", "albumOffset",
  "songCount", "songOffset"
]

// Per-category windows, no Lucene: the trimmed query is the only required
// input; zero and absent counts/offsets are omitted entirely.
function search3Params(query, limits) {
  var trimmed = text(query).trim()
  if (trimmed === "") return null
  var params = {q: trimmed}
  var source = limits && typeof limits === "object" ? limits : {}
  for (var i = 0; i < SEARCH3_WINDOWS.length; i++) {
    var count = boundedNumber(source[SEARCH3_WINDOWS[i]], 0)
    if (count > 0) params[SEARCH3_WINDOWS[i]] = count
  }
  var folder = source.musicFolderId
  if (folder !== null && folder !== undefined && String(folder) !== "") {
    params.musicFolderId = String(folder)
  }
  return params
}

function parseSearch3(data) {
  var node = data && typeof data === "object" ? data.searchResult3 : null
  return {
    artists: listOf(node, "artist", normalizeArtist),
    albums: listOf(node, "album", normalizeAlbum),
    songs: listOf(node, "song", normalizeSong)
  }
}

var ALBUM_LIST_TYPES = [
  "random", "newest", "highest", "frequent", "recent", "starred",
  "alphabeticalByName", "alphabeticalByArtist", "byYear", "byGenre"
]

// getAlbumList2 window; unknown types are rejected so typos never build
// URLs. `extra` carries genre/fromYear/toYear/musicFolderId for the types
// that need them.
function albumList2Params(type, size, offset, extra) {
  var known = false
  for (var i = 0; i < ALBUM_LIST_TYPES.length; i++) {
    if (ALBUM_LIST_TYPES[i] === type) known = true
  }
  if (!known) return null
  var params = {type: type}
  var wanted = boundedNumber(size, 0)
  if (wanted > 0) params.size = wanted
  var skip = boundedNumber(offset, 0)
  if (skip > 0) params.offset = skip
  var source = extra && typeof extra === "object" ? extra : {}
  if (text(source.genre) !== "") params.genre = text(source.genre)
  if (text(source.fromYear) !== "") params.fromYear = text(source.fromYear)
  if (text(source.toYear) !== "") params.toYear = text(source.toYear)
  if (source.musicFolderId !== null && source.musicFolderId !== undefined
    && String(source.musicFolderId) !== "") {
    params.musicFolderId = String(source.musicFolderId)
  }
  return params
}

// getAlbumList2, with the legacy getAlbumList container also accepted.
function parseAlbumList(data) {
  if (!data || typeof data !== "object") return []
  var node = data.albumList2 ? data.albumList2 : data.albumList
  return listOf(node, "album", normalizeAlbum)
}

// ------ artist, album detail, top songs, genres -------------------------------

function parseArtist(data) {
  var node = data && typeof data === "object" ? data.artist : null
  var artist = normalizeArtist(node)
  return {
    artist: artist,
    albums: artist === null ? [] : listOf(node, "album", normalizeAlbum)
  }
}

function parseAlbum(data) {
  var node = data && typeof data === "object" ? data.album : null
  var album = normalizeAlbum(node)
  return {
    album: album,
    songs: album === null ? [] : listOf(node, "song", normalizeSong)
  }
}

// getTopSongs arrives under artist.topSongs in Navidrome; an artist without
// top songs parses to [].
function parseTopSongs(data) {
  var artist = data && typeof data === "object" ? data.artist : null
  var top = artist && typeof artist === "object" ? artist.topSongs : null
  return listOf(top, "song", normalizeSong)
}

// Genres key on `value`, not on an id.
function parseGenres(data) {
  return listOf(data && typeof data === "object" ? data.genres : null,
    "genre", function(node) {
      var value = node && typeof node === "object" ? text(node.value) : ""
      if (value === "") return null
      return {
        value: value,
        songCount: boundedNumber(node.songCount, 0),
        albumCount: boundedNumber(node.albumCount, 0)
      }
    })
}

// getStarred2 returns the user's starred songs, albums, and artists in one
// response; each group normalizes through the shared node shapes and an absent
// group parses empty, never an error.
function parseStarred2(data) {
  var node = data && typeof data === "object" ? data.starred2 : null
  return {
    songs: listOf(node, "song", normalizeSong),
    albums: listOf(node, "album", normalizeAlbum),
    artists: listOf(node, "artist", normalizeArtist)
  }
}

// ------ playlists --------------------------------------------------------------

function parsePlaylists(data) {
  return listOf(data && typeof data === "object" ? data.playlists : null,
    "playlist", normalizePlaylist)
}

function parsePlaylist(data) {
  var node = data && typeof data === "object" ? data.playlist : null
  var playlist = normalizePlaylist(node)
  return {
    playlist: playlist,
    entries: playlist === null ? [] : listOf(node, "entry", normalizeSong)
  }
}

// createPlaylist updates when playlistId is given; otherwise a non-empty
// name is required. songId rides repeated keys.
function createPlaylistParams(name, songIds, playlistId) {
  var params = {}
  if (playlistId !== null && playlistId !== undefined
    && String(playlistId) !== "") {
    params.playlistId = String(playlistId)
  } else {
    var trimmed = text(name).trim()
    if (trimmed === "") return null
    params.name = trimmed
  }
  var ids = idList(songIds)
  if (ids.length) params.songId = ids
  return params
}

// updatePlaylist patches in place: repeated songIdToAdd/songIndexToRemove
// keys, an explicit "true"/"false" for public, and only present changes.
function updatePlaylistParams(playlistId, changes) {
  var id = playlistId === null || playlistId === undefined ? "" : String(playlistId)
  if (id === "") return null
  var source = changes && typeof changes === "object" ? changes : {}
  var params = {playlistId: id}
  if (text(source.name).trim() !== "") params.name = text(source.name).trim()
  if (text(source.comment).trim() !== "") params.comment = text(source.comment).trim()
  if (source.public === true) params.public = "true"
  else if (source.public === false) params.public = "false"
  var adds = idList(source.songIdToAdd)
  if (adds.length) params.songIdToAdd = adds
  var removals = idList(source.songIndexToRemove)
  if (removals.length) params.songIndexToRemove = removals
  return params
}

function deletePlaylistParams(id) {
  var key = id === null || id === undefined ? "" : String(id)
  return key === "" ? null : {id: key}
}

// ------ star, rating, scrobble -------------------------------------------------

// Any mix of song, album, and artist ids, repeated keys per id kind. A call
// with no ids at all is rejected so empty stars never hit the wire.
function starParams(ids) {
  return starActionParams(ids)
}

function unstarParams(ids) {
  return starActionParams(ids)
}

function starActionParams(ids) {
  if (!ids || typeof ids !== "object") return null
  var params = {}
  var count = 0
  var kinds = ["id", "albumId", "artistId"]
  for (var i = 0; i < kinds.length; i++) {
    var list = idList(ids[kinds[i]])
    if (list.length) {
      params[kinds[i]] = list
      count += list.length
    }
  }
  return count ? params : null
}

// Rating is an integer 0..5: rounded, clamped, rejected when absent.
function setRatingParams(id, rating) {
  var key = id === null || id === undefined ? "" : String(id)
  if (key === "") return null
  if (rating === null || rating === undefined || rating === "") return null
  var value = Number(rating)
  if (!isFinite(value)) return null
  value = Math.round(value)
  if (value < 0) value = 0
  if (value > 5) value = 5
  return {id: key, rating: String(value)}
}

// submission=true is the scrobble; submission=false marks a play start. time
// is an optional millisecond epoch.
function scrobbleParams(id, submission, time) {
  var key = id === null || id === undefined ? "" : String(id)
  if (key === "") return null
  var params = {id: key}
  if (submission === true) params.submission = "true"
  else if (submission === false) params.submission = "false"
  var at = Number(time)
  if (time !== null && time !== undefined && isFinite(at) && at >= 0) {
    params.time = String(Math.round(at))
  }
  return params
}

// ------ bookmarks and saved play queue (resume machinery) ---------------------

// bookmarkParams(id, position?): {id} for a targeted bookmark action, plus
// the millisecond position when one is given. A call without an id is
// rejected so empty bookmark writes never hit the wire. getBookmarks and
// getPlayQueue take no endpoint parameters at all.
function bookmarkParams(id, position) {
  var key = id === null || id === undefined ? "" : String(id)
  if (key === "") return null
  var params = { id: key }
  var at = Number(position)
  if (position !== null && position !== undefined && isFinite(at) && at >= 0) {
    params.position = String(Math.round(at))
  }
  return params
}

// A Subsonic bookmark nests the song under `entry` (single node or array).
// Bookmarks without any song id are dropped, matching the shared id rule.
function normalizeBookmark(node) {
  if (!node || typeof node !== "object") return null
  var entry = node.entry !== undefined ? node.entry : node.song
  if (entry instanceof Array) entry = entry[0]
  var song = normalizeSong(entry)
  if (!song) return null
  return {
    id: song.id,
    position: boundedNumber(node.position, 0),
    username: text(node.username),
    created: text(node.created),
    song: song
  }
}

// getBookmarks → normalized [{id, position, username, created, song}]
// sorted newest-first. ISO-8601 timestamps sort lexicographically, so the
// newest date wins; missing dates sort last. Malformed shapes parse empty,
// never an error.
function parseBookmarks(data) {
  var node = data && typeof data === "object" ? data.bookmarks : null
  var items = listOf(node, "bookmark", normalizeBookmark)
  items.sort(function(a, b) {
    if (a.created === b.created) return 0
    if (a.created === "") return 1
    if (b.created === "") return -1
    return a.created < b.created ? 1 : -1
  })
  return items
}

// getPlayQueue → {songs, current, position}: entries normalized in queue
// order, the current song's id (the Subsonic contract stores the id, not an
// index), and the position within it in milliseconds. Missing nodes parse to
// an empty queue, never an error.
function parsePlayQueue(data) {
  var node = data && typeof data === "object" ? data.playQueue : null
  if (!node || typeof node !== "object") {
    return {songs: [], current: "", position: 0}
  }
  return {
    songs: listOf(node, "entry", normalizeSong),
    current: text(node.current),
    position: boundedNumber(node.position, 0)
  }
}

// Pure saved-session restore decision. Preference order: a saved play queue
// (any non-empty list) restores with the current song's index and position;
// a queue at position 0 with a bookmark for the current song inherits the
// bookmark's exact position; with no saved queue at all, the newest bookmark
// resumes that single song. Rows pass through untouched — both
// Subsonic-normalized rows and protocol SongRefs carry the id this decision
// needs — and the caller maps them through the v2 load builder. Returns null
// when there is nothing to restore. maxSongs bounds the load the same way
// the playback body caps do.
function restoreLoadPlan(playQueue, bookmarks, maxSongs) {
  var queue = playQueue && typeof playQueue === "object"
    ? playQueue : {songs: [], current: "", position: 0}
  var marks = bookmarks instanceof Array ? bookmarks : []
  var cap = Math.max(1, Math.floor(Number(maxSongs) || 1))
  var best = null
  if (queue.songs instanceof Array && queue.songs.length) {
    var index = 0
    if (String(queue.current || "") !== "") {
      for (var i = 0; i < queue.songs.length; i++) {
        if (queue.songs[i] && String(queue.songs[i].id) === String(queue.current)) {
          index = i
          break
        }
      }
    }
    var position = Math.max(0, Math.floor(Number(queue.position) || 0))
    if (position <= 0) {
      var currentId = String(queue.current || "") !== ""
        ? String(queue.current) : String(queue.songs[index].id)
      for (var j = 0; j < marks.length; j++) {
        if (marks[j] && String(marks[j].id) === currentId) {
          position = Math.max(0, Math.floor(Number(marks[j].position) || 0))
          break
        }
      }
    }
    return {
      songs: queue.songs.slice(0, cap),
      offset_index: Math.min(index, cap - 1),
      position_ms: position
    }
  }
  for (var k = 0; k < marks.length; k++) {
    var mark = marks[k]
    if (!mark || !mark.song || !mark.song.id) continue
    // Newest wins by its date, so an unsorted bookmark list still resumes
    // the most recent play; undated bookmarks only win when nothing is dated.
    if (!best || (String(mark.created || "") !== ""
        && String(mark.created || "") > String(best.created || ""))) {
      best = mark
    }
  }
  if (best) {
    return {
      songs: [best.song],
      offset_index: 0,
      position_ms: Math.max(0, Math.floor(Number(best.position) || 0))
    }
  }
  return null
}

// ------ artwork URLs -----------------------------------------------------------

// Full getCoverArt URL, built over the pinned-salt request builder. Null is
// the UI contract for "no artwork"; a missing server or id yields null.
function coverArtUrl(serverUrl, coverArtId, size, auth, randomSource) {
  var id = coverArtId === null || coverArtId === undefined ? "" : String(coverArtId)
  if (id === "") return null
  var params = {id: id}
  var wanted = boundedNumber(size, 0)
  if (wanted > 0) params.size = wanted
  var built = requestUrl(serverUrl, "getCoverArt", auth, params, randomSource)
  return built ? built.url : null
}

// ------ md5 (RFC 1321) over UTF-8 text; reference vectors live in the tests ----

var MD5_K = [
  0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
  0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
  0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
  0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
  0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
  0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
  0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
  0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391
]

function md5Rounds() {
  return [
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21
  ]
}

function add32(a, b) {
  return (a + b) | 0
}

function rotl32(x, s) {
  return (x << s) | (x >>> (32 - s))
}

function md5Hex(bytes) {
  var a = 0x67452301 | 0
  var b = (0xefcdab89 | 0)
  var c = 0x98badcfe | 0
  var d = 0x10325476 | 0
  var shifts = md5Rounds()
  var lengthBits = bytes.length * 8
  var padded = appendPaddingAndLength(bytes, lengthBits)
  var words = padded
  for (var block = 0; block < words.length; block += 16) {
    var aa = a, bb = b, cc = c, dd = d
    for (var i = 0; i < 64; i++) {
      var f = 0
      if (i < 16) f = (b & c) | (~b & d)
      else if (i < 32) f = (d & b) | (~d & c)
      else if (i < 48) f = b ^ c ^ d
      else f = c ^ (b | ~d)
      var g = (
        i < 16 ? i :
        i < 32 ? (5 * i + 1) % 16 :
        i < 48 ? (3 * i + 5) % 16 :
        (7 * i) % 16
      )
      var tmp = d
      d = c
      c = b
      var sum = add32(add32(f, words[block + g]), MD5_K[i])
      b = add32(b, rotl32(add32(a, sum), shifts[i]))
      a = tmp
    }
    a = add32(a, aa)
    b = add32(b, bb)
    c = add32(c, cc)
    d = add32(d, dd)
  }
  return hex4(a) + hex4(b) + hex4(c) + hex4(d)
}

// Appends 0x80, zero-fills to 56 mod 64 and appends the 64-bit message
// length in bits, little-endian; returns 32-bit little-endian words.
function appendPaddingAndLength(bytes, lengthBits) {
  var totalLength = ((bytes.length + 9 + 63) >> 6) << 6
  var words = new Array(totalLength >> 2)
  var i
  for (i = 0; i < words.length; i++) words[i] = 0
  for (i = 0; i < bytes.length; i++) {
    words[i >> 2] |= bytes[i] << ((i & 3) * 8)
  }
  words[bytes.length >> 2] |= 0x80 << ((bytes.length & 3) * 8)
  words[(totalLength >> 2) - 2] = lengthBits | 0
  words[(totalLength >> 2) - 1] = Math.floor(lengthBits / 4294967296) | 0
  return words
}

// Produces the lowercase 8-char chunk of a 32-bit number, MD5 prints d, c,
// b, a in that final order.
function hex4(x) {
  var out = ""
  for (var i = 0; i < 4; i++) {
    var byte = (x >>> (i * 8)) & 0xff
    out += (byte < 16 ? "0" : "") + byte.toString(16)
  }
  return out
}

function utf8Bytes(text) {
  var out = []
  for (var i = 0; i < text.length; i++) {
    var code = text.charCodeAt(i)
    if (code < 0x80) {
      out.push(code)
    } else if (code < 0x800) {
      out.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f))
    } else if (code >= 0xd800 && code <= 0xdbff && i + 1 < text.length) {
      var lo = text.charCodeAt(i + 1)
      if (lo >= 0xdc00 && lo <= 0xdfff) {
        var cp = 0x10000 + ((code - 0xd800) << 10) + (lo - 0xdc00)
        out.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3f),
          0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f))
        i++
      } else {
        out.push(0xef, 0xbf, 0xbd)
      }
    } else {
      out.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f))
    }
  }
  return out
}

function md5(text) {
  return md5Hex(utf8Bytes(String(text)))
}
