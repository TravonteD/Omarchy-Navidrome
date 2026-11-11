import QtQuick
import Quickshell
import Quickshell.Io

import "Api.js" as Api
import "Subsonic.js" as Subsonic

// Private Unix-socket client for the plugin backend. Local load/control uses
// this when the supervised process is running; MPRIS supplies playback state
// when the socket is absent. Protocol v2 requests are {"v":2,...}; before any
// load the Navidrome server must be configured once per connection via
// configure_server.
Item {
  id: root

  visible: false
  width: 0
  height: 0

  property bool wanted: false
  readonly property var activeSocket: socketLoader.item
  readonly property bool connected: !!(activeSocket && activeSocket.connected)
  property string lifecycle: ""
  property bool sessionConnected: false
  property string errorCode: ""
  property string errorMessage: ""
  property var lastState: null
  property int nextId: 1
  property var pending: ({})
  property int reconnectAttempt: 0
  // Protocol v2: configure_server must be re-sent after every socket
  // (re)connect — the engine keeps credentials in process memory only. The
  // flag flips true once the backend acknowledges a configuration; the
  // Service layer re-sends before resuming playback whenever it is false.
  property bool serverConfigured: false

  // Error code from the last failed command response ("" after a success).
  // State-event codes stay on errorCode; both are typed through Subsonic.js.
  property string commandErrorCode: ""
  readonly property string errorCategory:
    Subsonic.backendErrorCategory(commandErrorCode || errorCode)
  // Credential-class failures are terminal: they never consume a reconnect
  // budget and the UI shows a typed state instead of retrying.
  readonly property bool credentialFailure:
    Subsonic.isTerminalCredentialCategory(errorCategory)

  readonly property string socketPath: {
    var runtime = Quickshell.env("XDG_RUNTIME_DIR")
    return String(runtime || "/tmp") + "/omarchy-navidrome/backend.sock"
  }
  readonly property bool ready: connected
    && (lifecycle === "ready" || lifecycle === "")

  signal stateReceived(var state)

  function resetPending(reason) {
    var waiters = pending
    pending = ({})
    var message = String(reason || "Playback on this computer is unavailable")
    for (var id in waiters) {
      var callback = waiters[id]
      if (typeof callback === "function") callback(false, null, message)
    }
  }

  function sendCommand(name, fields, callback) {
    var socket = activeSocket
    if (!socket || !socket.connected) {
      if (typeof callback === "function")
        callback(false, null, "Playback on this computer is not ready")
      return 0
    }
    var id = nextId++
    var payload = { v: 2, id: id, command: String(name || "") }
    Api.assign(payload, fields || {})
    var nextPending = ({})
    for (var existing in pending) nextPending[existing] = pending[existing]
    nextPending[String(id)] = typeof callback === "function" ? callback : null
    pending = nextPending
    socket.write(JSON.stringify(payload) + "\n")
    socket.flush()
    return id
  }

  // Credentials are sent once per connection and never logged or echoed.
  // Deliberately no console output in the success path: any log line holding
  // url/username/password would leak them.
  function configureServer(url, username, password, callback) {
    return sendCommand("configure_server", {
      url: String(url || ""),
      username: String(username || ""),
      password: String(password || "")
    }, function(ok, result, error) {
      serverConfigured = ok === true
      if (typeof callback === "function") callback(ok, result, error)
    })
  }

  // The body is a v2 load input: either plain UI rows with options
  // ({ items: [...], offset_index, position_ms, play }) or already-built
  // SongRef list ({ songs: [...] }, which the builder passes field by field).
  function loadPlayback(body, callback) {
    var spec = body && typeof body === "object" ? body : null
    var items = spec && Api.arrayValues(spec.items).length
      ? spec.items : (spec ? spec.songs : null)
    var fields = Api.backendLoadFieldsV2(items, spec)
    if (!fields) {
      if (typeof callback === "function")
        callback(false, null, "This song cannot be played")
      return 0
    }
    return sendCommand("load", fields, callback)
  }

  function handleLine(line) {
    var message = Api.parseJson(line, null)
    if (!message || typeof message !== "object") return
    if (message.type === "event" && message.state) {
      lastState = message.state
      lifecycle = String(message.state.lifecycle || "")
      sessionConnected = message.state.session_connected === true
      errorMessage = Api.redact(String(message.state.error || ""))
      errorCode = String(message.state.error_code || "")
      stateReceived(message.state)
      return
    }
    if (message.type !== "response") return
    var id = String(message.id || "")
    var callback = pending[id]
    if (callback === undefined) return
    var nextPending = ({})
    for (var key in pending) if (key !== id) nextPending[key] = pending[key]
    pending = nextPending
    if (typeof callback !== "function") return
    if (message.ok === true) {
      commandErrorCode = ""
      callback(true, message.result || ({}), "")
    } else {
      var error = message.error || {}
      commandErrorCode = String(error.code || "")
      callback(false, null, Api.redact(String(error.message
        || "Playback command failed")))
    }
  }

  onWantedChanged: {
    if (wanted) return
    reconnectTimer.stop()
    socketLoader.active = false
    lifecycle = ""
    sessionConnected = false
    serverConfigured = false
    errorCode = ""
    errorMessage = ""
    commandErrorCode = ""
    lastState = null
    reconnectAttempt = 0
    resetPending("Playback on this computer stopped")
  }

  onConnectedChanged: if (connected) reconnectAttempt = 0

  Component {
    id: socketComponent
    Socket {
      path: root.socketPath
      connected: true
      parser: SplitParser {
        splitMarker: "\n"
        onRead: function(line) { root.handleLine(line) }
      }
      onConnectionStateChanged: {
        if (connected) {
          // Credentials never survive a disconnect: the Service layer
          // re-sends configure_server once the backend reports ready again.
          root.serverConfigured = false
          root.sendCommand("hello", null, null)
        }
        else root.lifecycle = ""
      }
    }
  }

  Loader {
    id: socketLoader
    active: false
    sourceComponent: socketComponent
  }

  // A failed connect leaves Quickshell's Socket holding a dead QLocalSocket.
  // Setting connected=true again is a no-op, so each retry creates a new Socket.
  Timer {
    id: reconnectTimer
    interval: Math.min(1500, 180 + root.reconnectAttempt * 120)
    repeat: true
    triggeredOnStart: true
    running: root.wanted && !root.connected
    onTriggered: {
      root.reconnectAttempt = Math.min(12, root.reconnectAttempt + 1)
      socketLoader.active = false
      socketLoader.active = true
    }
  }
}
