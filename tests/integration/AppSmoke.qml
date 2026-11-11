import QtQuick
import Quickshell
import "plugin" as Plugin

ShellRoot {
  Plugin.Service { id: navidromeService }
  Plugin.Panel { id: panel; service: navidromeService; width: 1280; height: 800 }
  Plugin.BarWidget { id: widget }

  // A raw XHR stand-in with exactly the surface SubsonicApi drives
  // (tst_subsonic_api.qml uses the same shape). The connect-form scenario
  // completes each request by hand, so the whole guided flow — probe
  // failure, probe success, keyring save, gateway flip — runs hermetically
  // with no network and no real credentials.
  function newProbeXhr() {
    var xhr = {
      readyState: 0,
      status: 0,
      responseText: "",
      url: "",
      aborted: false,
      onreadystatechange: null,
      open: function(method, url) {
        this.url = url
        this.readyState = 1
      },
      setRequestHeader: function() {},
      send: function() {},
      abort: function() { this.aborted = true }
    }
    connectScenario.probeRequests.push(xhr)
    return xhr
  }

  function completeXhr(xhr, status, body) {
    xhr.status = status
    xhr.responseText = body || "{}"
    xhr.readyState = 4
    if (xhr.onreadystatechange) xhr.onreadystatechange()
  }

  // Like Panel.findNamedItem, but also reaches visible:false children (the
  // probe transport is a hidden child of the panel root).
  function findHiddenNamed(item, name) {
    if (!item) return null
    if (item.objectName === name) return item
    var kids = item.children
    for (var i = 0; kids && i < kids.length; i++) {
      var found = findHiddenNamed(kids[i], name)
      if (found) return found
    }
    return null
  }

  Timer {
    interval: 20
    running: true
    onTriggered: {
      // The smoke runs as a plain config, so no plugin host manifest is
      // injected. Supply the one the host would provide — pointed at this
      // config root, which carries the harness's scripts/ stubs — so the
      // service's keyring and playback-runtime machinery is live.
      var pluginDir = Quickshell.env("OMARCHY_SMOKE_PLUGIN_DIR")
      if (pluginDir !== "" && !navidromeService.manifest)
        navidromeService.manifest = {
          id: "quickshell.navidrome", __sourceDir: pluginDir
        }
      navidromeService.search("smoke-test", "track")
      if (navidromeService.searchLoading || !navidromeService.searchError)
        throw new Error("Search service did not return the authorization error")
      if (!panel.primaryNavigationItems().some(function(item) { return item.id === "search" }))
        throw new Error("Search navigation is missing")
      if (panel.primaryNavigationItems().some(function(item) { return item.id === "devices" }))
        throw new Error("The Connect-era Devices view should be gone")
      navidromeService.clearSearch()
      if (navidromeService.searchQuery !== "") throw new Error("Search state did not clear")
      // Package 5 Part B: the podcast-family library collections are gone,
      // and the Navidrome view state exposes the Subsonic windows instead.
      if (navidromeService.savedShows !== undefined
          || navidromeService.savedEpisodes !== undefined
          || navidromeService.savedAudiobooks !== undefined)
        throw new Error("Podcast-family collections should have been removed")
      if (navidromeService.artistThisIsPlaylist !== undefined)
        throw new Error("The artist This-Is slot should have been removed")
      if (typeof navidromeService.homeItems !== "function"
          || !Array.isArray(navidromeService.homeItems("starred")))
        throw new Error("Home windows are missing")
      if (!Array.isArray(navidromeService.discoverGenres)
          || navidromeService.discoverGenre !== "")
        throw new Error("Genre browsing state is missing")
      // Genre browsing must exist and fail fast (no credentials in the
      // smoke environment) without throwing.
      navidromeService.openDiscoverGenre("Jazz")
      if (navidromeService.discoverGenre !== "Jazz")
        throw new Error("Genre selection did not apply")
      if (navidromeService.genreAlbums.length !== 0
          || navidromeService.genreAlbumsNext !== "")
        throw new Error("Genre albums did not reset")
      navidromeService.clearGenreBrowse()
      if (navidromeService.discoverGenre !== "")
        throw new Error("Genre browsing did not clear")
      // PANEL_PAGE_BOOT_BEGIN — the harness strips this block when no
      // compositor exists; instantiating every page surfaces loader-time
      // binding errors in the smoke log.
      var pageTabs = ["search", "discover", "library", "playlists", "queue",
        "setup", "home"]
      for (var p = 0; p < pageTabs.length; p++) panel.currentTab = pageTabs[p]
      panel.currentTab = "home"
      // PANEL_PAGE_BOOT_END
      // PANEL_CONNECT_BOOT_BEGIN — the harness strips this block when no
      // compositor exists; the guided-connection scenario below needs the
      // real panel tree, so it takes over the pass signal from here.
      panel.currentTab = "login"
      connectScenario.start()
      return
      // PANEL_CONNECT_BOOT_END
      console.log("APP_SMOKE_PASS")
      Qt.quit()
    }
  }

  Timer {
    id: connectScenario
    interval: 20
    repeat: true
    property int step: 0
    property int attempts: 0
    property var probeRequests: []
    running: false

    function fail(message) {
      running = false
      throw new Error(message)
    }

    onTriggered: {
      // Page content lives inside the panel's window, not under the panel
      // item itself; findNamedItem starts from the loaded page root.
      var pageRoot = panel.pageRoot()
      var connectButton = panel.findNamedItem(pageRoot, "loginConnectButton")
      var playbackGlyph = panel.findNamedItem(pageRoot, "loginPlaybackStepGlyph")
      var playbackLabel = panel.findNamedItem(pageRoot, "loginPlaybackStepLabel")

      if (step === 0) {
        // The plugin-dir machinery (keyring lookup, playback runtime
        // checks) starts when the manifest lands; wait for it so the
        // gateway is read in a settled state.
        if (navidromeService.sessionPending
            || !navidromeService.daemon.requirementsChecked) {
          if (++attempts > 200)
            fail("The smoke plugin dir never initialized")
          return
        }
        // Gateway state with the backend installed but no credentials
        // stored (the state the dead-button bug was reported in): the
        // button must exist and the playback step must NOT read as done —
        // the old binding keyed the checkmark on playbackReady alone.
        if (!connectButton) fail("The Connect Navidrome button is missing")
        if (!playbackGlyph || !playbackLabel)
          fail("The playback step row is missing")
        if (playbackGlyph.text === "\uF864")
          fail("The playback step read as done without a connection")
        if (playbackLabel.text !== "Playback on this computer")
          fail("The playback step label was '" + playbackLabel.text + "'")
        if (panel.connectionHeadline() !== "Connect your Navidrome server")
          fail("The gateway headline was '" + panel.connectionHeadline() + "'")
        if (panel.connectionButtonText() !== "Connect Navidrome")
          fail("The gateway button label was '" + panel.connectionButtonText() + "'")
        if (connectButton.text !== "Connect Navidrome")
          fail("The button label was '" + connectButton.text + "'")
        if (!connectButton.enabled) fail("The Connect button is disabled")
        if (panel.connectionFormOpen) fail("The connection form started open")
        if (panel.findNamedItem(pageRoot, "loginConnectionForm"))
          fail("The connection form was visible before Connect was clicked")
        // The reported dead button: clicking must reveal the credential form.
        connectButton.clicked()
        step = 1
        attempts = 0
        return
      }

      if (step === 1) {
        if (!panel.connectionFormOpen)
          fail("Clicking Connect did not open the connection form")
        var form = panel.findNamedItem(pageRoot, "loginConnectionForm")
        var serverField = panel.findNamedItem(pageRoot, "loginServerUrlField")
        var usernameField = panel.findNamedItem(pageRoot, "loginUsernameField")
        var passwordField = panel.findNamedItem(pageRoot, "loginPasswordField")
        if (!form || !serverField || !usernameField || !passwordField)
          fail("The credential form fields did not appear")
        if (connectButton.text !== "Verify and connect")
          fail("The open form did not retitle the button: '" + connectButton.text + "'")
        if (serverField.text !== "" || usernameField.text !== ""
            || passwordField.text !== "")
          fail("The form fields were not empty with no stored credentials")
        // Field wiring: every edit lands in the panel's entry drafts.
        serverField.text = "ftp://music.example.com"
        usernameField.text = "alice"
        passwordField.text = "test-pass-123"
        if (panel.draftServerUrl !== "ftp://music.example.com"
            || panel.draftUsername !== "alice"
            || panel.draftPassword !== "test-pass-123")
          fail("The form fields did not wire into the entry drafts")
        connectButton.clicked()
        step = 2
        attempts = 0
        return
      }

      if (step === 2) {
        // An invalid address is a typed inline error: the form stays open,
        // nothing was probed or stored, and the auth state stays clean.
        if (!panel.connectionFormOpen) fail("Validation closed the form")
        if (!panel.connectionFormError
            || panel.connectionFormMessage.indexOf("http or https") < 0)
          fail("The invalid address did not produce the typed error: '"
            + panel.connectionFormMessage + "'")
        if (navidromeService.auth.loggedIn)
          fail("Validation stored credentials")
        if (navidromeService.auth.lastError !== "")
          fail("Validation leaked into the auth error state")
        // A valid-shaped entry now starts the live probe. The transport is
        // pointed at an XHR stand-in so the walk is hermetic; a refused
        // ping still has to surface as the typed unreachable-server error.
        var probeApi = findHiddenNamed(panel, "loginProbeApi")
        if (!probeApi) fail("The connection probe transport is missing")
        probeRequests = []
        probeApi.xhrFactory = function() { return newProbeXhr() }
        panel.findNamedItem(pageRoot, "loginServerUrlField").text = "http://127.0.0.1:1"
        connectButton.clicked()
        step = 3
        attempts = 0
        return
      }

      if (step === 3) {
        if (probeRequests.length !== 1)
          fail("The probe did not start by walking ping")
        completeXhr(probeRequests[0], 0, "")
        if (panel.connectionFormBusy)
          fail("The probe stayed busy after failing")
        if (panel.connectionFormMessage !== "Could not reach the server")
          fail("The unreachable-server message was '"
            + panel.connectionFormMessage + "'")
        if (!panel.connectionFormError)
          fail("The probe failure was not shown as an error")
        if (!panel.connectionFormOpen) fail("A failed probe closed the form")
        if (navidromeService.auth.loggedIn)
          fail("A failed probe stored credentials")
        if (navidromeService.auth.navidromeUrl !== "")
          fail("A failed probe touched the stored credentials")
        // Success pass: same transport, live answers. The URL carries a
        // trailing slash and casing so the normalized storage is proven.
        probeRequests = []
        panel.findNamedItem(pageRoot, "loginServerUrlField").text = "http://127.0.0.1:1/"
        connectButton.clicked()
        step = 4
        attempts = 0
        return
      }

      if (step === 4) {
        if (probeRequests.length !== 1)
          fail("The second probe did not start by walking ping")
        completeXhr(probeRequests[0], 200, '{"subsonic-response":{"status":"ok"}}')
        if (probeRequests.length !== 2)
          fail("The probe did not continue to getUser")
        completeXhr(probeRequests[1], 200,
          '{"subsonic-response":{"status":"ok","user":{"username":"alice",'
          + '"streamRole":true}}}')
        if (probeRequests.length !== 3)
          fail("The probe did not continue to getLicense")
        completeXhr(probeRequests[2], 200,
          '{"subsonic-response":{"status":"ok","license":{"valid":true}}}')
        // A verified entry is applied immediately; the keyring write runs.
        if (!navidromeService.auth.loggedIn)
          fail("A verified probe did not apply the credentials")
        if (panel.connectionFormMessage.indexOf("keyring") < 0)
          fail("The form did not report the keyring save: '"
            + panel.connectionFormMessage + "'")
        step = 5
        attempts = 0
        return
      }

      if (step === 5) {
        // The keyring round-trip runs through scripts/keyring-store.sh and
        // the stubbed secret-tool (same pattern as the AuthIdentity run).
        // The gateway reads Connected only once the local readiness checks
        // and the save have both landed.
        if (panel.connectionFormOpen || panel.connectionFormBusy
            || !navidromeService.fullyConnected) {
          if (++attempts > 200)
            fail("The credential save never completed")
          return
        }
        if (!navidromeService.auth.loggedIn)
          fail("The keyring save did not complete the connection")
        if (navidromeService.auth.navidromeUrl !== "http://127.0.0.1:1")
          fail("The stored URL was not normalized: '"
            + navidromeService.auth.navidromeUrl + "'")
        if (navidromeService.auth.navidromeUsername !== "alice")
          fail("The stored username was lost")
        if (panel.connectionButtonText() !== "Connected")
          fail("The gateway did not report Connected: '"
            + panel.connectionButtonText() + "'")
        if (panel.connectionHeadline() !== "You're connected")
          fail("The gateway headline was '" + panel.connectionHeadline() + "'")
        if (playbackLabel.text !== "Playback on this computer is ready")
          fail("The connected playback step label was '" + playbackLabel.text + "'")
        if (playbackGlyph.text !== "\uF864")
          fail("The connected playback step was not marked done")
        running = false
        console.log("APP_SMOKE_PASS")
        Qt.quit()
      }
    }
  }
}
