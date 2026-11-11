import QtQuick
import Quickshell
import Quickshell.Io

import "Api.js" as Api
import "Subsonic.js" as Subsonic

// Navidrome credentials live here: the server URL, username, and password the
// plugin and its stream backend need. The full credential set is stored in the
// keyring as one JSON payload under fixed, plugin-owned attributes
// (service quickshell-navidrome, kind navidrome-credentials); the URL inside
// the payload is the server identity, so saving again for the same server
// overwrites in place and a different server replaces it. Secrets ride stdin
// only — never argv, never logs, never settings files — and the keyring write
// goes through scripts/keyring-store.sh.
//
// Transitional shim: SpotifyApi.qml still requires an `auth` object with
// withAccessToken()/invalidateAccessToken(); both now fail Web API paths
// immediately so they degrade into their existing fallbacks. Package 5
// deletes SpotifyApi.qml entirely, and this shim with it.
Item {
  id: root

  visible: false
  width: 0
  height: 0

  required property string pluginDir

  // Loaded from the keyring at startup; empty means "not set up yet". Never
  // log these values or the object returned by navidromeCredentials().
  property string navidromeUrl: ""
  property string navidromeUsername: ""
  property string navidromePassword: ""

  // Visible-warning flag for plain http:// servers. It is set from the stored
  // URL regardless of any display decision; consumers own the presentation.
  readonly property bool navidromeUrlInsecure:
    navidromeUrl !== "" && Subsonic.isInsecureServerUrl(navidromeUrl)

  property bool initialized: false
  // "Signed in" for the Navidrome port means: a complete credential set is
  // loaded. There is no token to refresh.
  readonly property bool loggedIn: navidromeUrl !== ""
    && navidromeUsername !== "" && navidromePassword !== ""
  property bool sessionChecked: false
  // A keyring write (save) in progress.
  property bool loginBusy: false
  readonly property bool sessionBusy: secretLookup.running
  property string lastError: ""

  property bool lookupHandled: false
  property bool logoutPendingClear: false
  property string keyringPayload: ""
  property var saveWaiters: []

  signal loginSucceeded()
  signal loggedOut()
  signal sessionUnavailable(string reason)

  Component.onCompleted: {
    initialized = true
    if (pluginDir) loadCredentials()
  }
  onPluginDirChanged: if (initialized && pluginDir) loadCredentials()

  function safeError(value) {
    return Api.redact(String(value || ""))
  }

  // Returns { url, username, password } for the configured Navidrome server.
  // Empty strings mean "not set up yet": callers must treat the credential
  // set as absent, never send empty values over configure_server, and never
  // log the object.
  function navidromeCredentials() {
    return {
      url: String(navidromeUrl || ""),
      username: String(navidromeUsername || ""),
      password: String(navidromePassword || "")
    }
  }

  // Transitional compatibility shim for SpotifyApi.qml, which still requires
  // an `auth` object with this method. Every Web API path now fails
  // immediately and gracefully into its existing fallbacks.
  function withAccessToken(callback) {
    if (typeof callback === "function")
      callback(null, "Spotify Web API was removed in the Navidrome port")
  }

  // Transitional no-op: see withAccessToken().
  function invalidateAccessToken() {}

  function tokenIsFresh() {
    return loggedIn
  }

  // ------ validation ------------------------------------------------------------

  // Pure entry validation shared with the setup UI (Subsonic.js owns the
  // rules): URL validation goes through normalizeServerUrl — an invalid
  // address is a typed error, and a plain http:// target stays allowed but is
  // flagged as insecure.
  function validateNavidromeEntry(rawUrl, rawUsername, rawPassword) {
    return Subsonic.validateConnectionEntry(rawUrl, rawUsername, rawPassword)
  }

  // QML-callable setup flow (the package 5 setup UI reuses it): validate,
  // apply to memory, then persist through scripts/keyring-store.sh. The
  // password reaches the keyring script over stdin only. There is no live
  // probe here; the caller can run SubsonicApi.probe() first.
  function saveNavidromeCredentials(rawUrl, rawUsername, rawPassword, callback) {
    var entry = validateNavidromeEntry(rawUrl, rawUsername, rawPassword)
    if (!entry.ok) {
      lastError = safeError(entry.error)
      if (typeof callback === "function") callback(false, lastError)
      return
    }
    if (pluginDir && keyringStore.running) {
      lastError = "A credential save is already running. Try again in a moment."
      if (typeof callback === "function") callback(false, lastError)
      return
    }
    navidromeUrl = entry.url
    navidromeUsername = entry.username
    navidromePassword = entry.password
    lastError = ""
    if (typeof callback === "function") saveWaiters = saveWaiters.concat([callback])
    if (!pluginDir) {
      // No plugin directory (tests, previews): keep the in-memory values only.
      finishSaveWaiters("")
      return
    }
    keyringPayload = JSON.stringify({
      v: 1,
      url: entry.url,
      username: entry.username,
      password: entry.password
    })
    loginBusy = true
    keyringStore.command = [pluginDir + "/scripts/keyring-store.sh", "navidrome"]
    keyringStore.running = true
  }

  function finishSaveWaiters(error) {
    var waiters = saveWaiters
    saveWaiters = []
    var message = safeError(error)
    for (var i = 0; i < waiters.length; i++) {
      try { waiters[i](message === "", message) }
      catch (e) { /* consumers own their callback errors */ }
    }
  }

  // ------ keyring load and persistence -------------------------------------------

  // Startup load: one credential set per server identity, read from the
  // keyring. Missing or malformed payload simply means signed out.
  function loadCredentials() {
    if (!pluginDir || sessionChecked || secretLookup.running) return
    lookupHandled = false
    keyringTimeout.restart()
    secretLookup.command = [
      "secret-tool", "lookup",
      "service", "quickshell-navidrome",
      "kind", "navidrome-credentials"
    ]
    secretLookup.running = true
  }

  function parseCredentialPayload(raw) {
    return Subsonic.parseCredentialPayload(raw)
  }

  function handleSecretLookup(raw) {
    if (lookupHandled) return
    lookupHandled = true
    keyringTimeout.stop()
    var payload = parseCredentialPayload(raw)
    sessionChecked = true
    if (!payload) {
      // No stored credential set: stay signed out until setup fills the
      // keyring. Deliberately quiet — an unsigned-in state is not an error.
      return
    }
    navidromeUrl = payload.url
    navidromeUsername = payload.username
    navidromePassword = payload.password
    lastError = ""
    loginSucceeded()
  }

  // Transitional alias for the old OAuth entry point: Service.qml's login and
  // reconnect flows call it. It now re-reads the keyring so credentials saved
  // after the last load are picked up.
  function beginLogin() {
    if (loginBusy || secretLookup.running) return
    lastError = ""
    sessionChecked = false
    loadCredentials()
  }

  function cancelLogin() {
    keyringTimeout.stop()
    if (secretLookup.running) secretLookup.running = false
    lookupHandled = true
    if (keyringStore.running) keyringStore.running = false
    loginBusy = false
    keyringPayload = ""
    finishSaveWaiters("Cancelled")
  }

  function logout() {
    lookupHandled = true
    if (secretLookup.running) secretLookup.running = false
    navidromeUrl = ""
    navidromeUsername = ""
    navidromePassword = ""
    sessionChecked = true
    lastError = ""
    if (keyringStore.running) logoutPendingClear = true
    else clearStoredCredentials()
    loggedOut()
  }

  function clearStoredCredentials() {
    if (keyringClear.running) return
    keyringClear.command = [
      "secret-tool", "clear",
      "service", "quickshell-navidrome",
      "kind", "navidrome-credentials"
    ]
    keyringClear.running = true
  }

  Timer {
    id: keyringTimeout
    interval: 15000
    onTriggered: {
      root.lookupHandled = true
      secretLookup.running = false
      root.lastError = "The secure keyring did not respond. Unlock it, then try again."
      root.sessionChecked = true
      root.sessionUnavailable(root.lastError)
    }
  }

  Process {
    id: secretLookup
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) {
        if (root.lookupHandled) return
        if (String(line || "").trim() === "") return
        root.handleSecretLookup(line)
      }
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (!root.lookupHandled) root.handleSecretLookup("")
    }
  }

  Process {
    id: keyringStore
    stdinEnabled: true
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onStarted: {
      write(root.keyringPayload + "\n")
      root.keyringPayload = ""
    }
    onExited: function(exitCode) {
      root.keyringPayload = ""
      root.loginBusy = false
      if (exitCode === 0) {
        root.lastError = ""
        root.finishSaveWaiters("")
        root.loginSucceeded()
      } else {
        root.lastError = "The Navidrome server was verified, but the credentials could not be saved securely. Try saving again."
        root.finishSaveWaiters(root.lastError)
      }
      if (root.logoutPendingClear) {
        root.logoutPendingClear = false
        root.clearStoredCredentials()
      }
    }
  }

  Process {
    id: keyringClear
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
  }
}
