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

function queryEscape(key, value) {
  return encodeURIComponent(key) + "=" + encodeURIComponent(value)
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
