import QtQuick
import Quickshell
import "../.." as Plugin

ShellRoot {
  // Live integration for the Navidrome credential model: the login state,
  // payload parsing, and a full keyring save round-trip against a stubbed
  // secret-tool (OMARCHY_AUTH_TEST_DIR holds a plugin dir with
  // scripts/keyring-store.sh; the stub records argv only).
  Plugin.AuthManager { id: auth; pluginDir: Quickshell.env("OMARCHY_AUTH_TEST_DIR") }
  Plugin.BackendClient { id: backend }

  property int storeCalls: 0

  Timer {
    interval: 1
    running: true
    onTriggered: {
      // "Signed in" means a complete credential set; there is no token.
      if (auth.loggedIn) throw new Error("loggedIn before any credential load")

      // Empty credentials mean "not set up yet".
      var credentials = auth.navidromeCredentials()
      if (credentials.url !== "" || credentials.username !== ""
          || credentials.password !== "")
        throw new Error("Credentials were not empty before the first load")
      if (auth.loggedIn) throw new Error("loggedIn without credentials")

      // Typed validation over Subsonic.js, with the insecure-URL flag set
      // regardless of display.
      var good = auth.validateNavidromeEntry("https://Music.Example.com/", "  alice ", "pw")
      if (!good.ok || good.url !== "https://music.example.com" || good.insecure)
        throw new Error("Valid https entry failed validation")
      var insecure = auth.validateNavidromeEntry("http://10.0.0.5:4533/nav/", "alice", "pw")
      if (!insecure.ok || !insecure.insecure)
        throw new Error("Plain http entry was not flagged insecure")
      var badUrl = auth.validateNavidromeEntry("ftp://music.example.com", "alice", "pw")
      if (badUrl.ok || badUrl.error.indexOf("http or https") < 0)
        throw new Error("Invalid scheme was not a typed error")
      if (auth.validateNavidromeEntry("https://music.example.com", "", "pw").ok)
        throw new Error("Empty username was accepted")
      if (auth.validateNavidromeEntry("https://music.example.com", "alice", "").ok)
        throw new Error("Empty password was accepted")

      // Payload parsing stays defensive: malformed shapes mean "no session".
      if (auth.parseCredentialPayload("") !== null
          || auth.parseCredentialPayload("not json") !== null
          || auth.parseCredentialPayload('{"v":2,"url":"x","username":"a","password":"b"}') !== null
          || auth.parseCredentialPayload('{"v":1,"url":"x","username":"a"}') !== null)
        throw new Error("Malformed payloads were accepted")
      var parsed = auth.parseCredentialPayload(
        '{"v":1,"url":"https://music.example.com","username":"alice","password":"pw"}')
      if (!parsed || parsed.username !== "alice")
        throw new Error("Valid payload was rejected")

      // Credential-class backend failures are typed terminal states; network
      // codes stay generic and keep the retry budget.
      backend.errorCode = "stream_rejected"
      if (backend.errorCategory !== "wrongCredentials" || !backend.credentialFailure)
        throw new Error("stream_rejected was not typed as a terminal credential failure")
      backend.errorCode = "missing_credentials"
      if (backend.errorCategory !== "missingCredentials" || !backend.credentialFailure)
        throw new Error("missing_credentials was not typed")
      backend.errorCode = "invalid_configuration"
      if (backend.errorCategory !== "invalidConfiguration" || !backend.credentialFailure)
        throw new Error("invalid_configuration was not typed")
      backend.errorCode = "stream_unavailable"
      if (backend.credentialFailure)
        throw new Error("stream_unavailable wrongly became terminal")
      backend.errorCode = "missing_credentials"
      backend.commandErrorCode = "stream_unavailable"
      if (backend.credentialFailure)
        throw new Error("A generic command error wrongly became terminal")
      backend.commandErrorCode = ""
      if (!backend.credentialFailure)
        throw new Error("Command/state category fallback broke")

      // Full save round-trip through scripts/keyring-store.sh with the
      // stubbed secret-tool. The http URL keeps its insecure flag.
      auth.saveNavidromeCredentials(
        "http://10.0.0.5:4533/nav/", "alice", "test-pass-123", function(ok, error) {
          if (!ok) throw new Error("Save failed: " + error)
        })
      poll.restart()
    }
  }

  Timer {
    id: poll
    interval: 20
    repeat: true
    property int attempts: 0
    running: false
    onTriggered: {
      if (auth.loggedIn && !auth.loginBusy) {
        running = false
        if (auth.navidromeUrl !== "http://10.0.0.5:4533/nav")
          throw new Error("Stored URL was not normalized")
        if (auth.navidromeUsername !== "alice")
          throw new Error("Stored username was lost")
        if (!auth.navidromeUrlInsecure)
          throw new Error("Stored http URL lost its insecure flag")
        console.log("AUTH_IDENTITY_PASS")
        Qt.quit()
        return
      }
      if (++attempts > 100) {
        running = false
        throw new Error("Credential save never completed")
      }
    }
  }
}
