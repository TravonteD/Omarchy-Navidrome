import QtQuick
import Quickshell
import "plugin" as Plugin

ShellRoot {
  Plugin.Service { id: navidromeService }
  Plugin.Panel { id: panel; service: navidromeService; width: 1280; height: 800 }
  Plugin.BarWidget { id: widget }

  // A stand-in host bar with exactly the surface BarWidget drives. The
  // harness cannot use the real bar host, so the widget scenario injects
  // this one to exercise the click wiring: serviceFor hands over the real
  // service, and summon/hide/run record what the widget asked the host to
  // do instead of moving real windows.
  QtObject {
    id: fakeShell

    property var bar: fakeBar

    function serviceFor(id) {
      return id === "quickshell.navidrome" ? navidromeService : null
    }
    function isPluginOpen(id) { return false }
    function hide(id) { fakeBar.hideCalls.push(id) }
    function summon(id, payload) {
      fakeBar.summonCalls.push({ id: id, payload: payload })
      return true
    }
    function toggle(id, payload) {
      fakeBar.summonCalls.push({ id: id, payload: payload })
      return true
    }
  }

  QtObject {
    id: fakeBar

    property var shell: fakeShell
    property bool vertical: false
    property int barSize: 48
    property string fontFamily: ""
    property color foreground: "#000000"
    property color barForeground: "#000000"
    property color background: "#000000"
    property color urgent: "#000000"
    property bool foregroundAnimationEnabled: true
    property string position: "top"
    property var activePopout: null
    property var clickTargets: null
    property var runCalls: []
    property var summonCalls: []
    property var hideCalls: []

    function run(command) { runCalls.push(command) }
    function summonBarWidget(id) { return true }
    function hideBarWidget(id) { return true }
    function isBarWidgetOpen(id) { return false }
    function requestPopout(key) {}
    function releasePopout(key) {}
    function notePopoutCard(card) {}
    function popoutCardFor(key) { return null }
    function barSizeFor(screenName) { return 48 }
    function targetBelongsToWindow(target, window) { return true }
  }

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
      // BAR_WIDGET_BOOT_BEGIN — the harness strips this block when no
      // compositor exists: the bar-widget scenario below opens the real
      // mini-player popup surface, which needs a windowing compositor. It
      // runs first, in the signed-out state the dead-button bug was
      // reported in, and hands over to the connect scenario afterwards.
      barWidgetScenario.start()
      return
      // BAR_WIDGET_BOOT_END
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

  // The bar-widget audit scenario: every interactive element on the widget
  // surface is driven through its real handler while signed out, with the
  // fake host bar recording what the widget asks for. This is the mechanical
  // reproduction of "the button on the widget still doesn't work".
  Timer {
    id: barWidgetScenario
    interval: 20
    repeat: true
    running: false
    property int step: 0
    property int attempts: 0

    function fail(message) {
      running = false
      throw new Error(message)
    }

    // Buttons here are shell Ui controls whose only identifying state is
    // their label; walk the widget tree (including hidden popup content and
    // the popup's window contentItem) until the labeled one turns up.
    function childItems(item) {
      if (!item) return []
      var list = (item.children || []).slice()
      if (item.contentItem) list = list.concat(item.contentItem.children || [])
      return list
    }

    function findLabeled(item, label) {
      if (!item) return null
      // Only controls are interesting: a Text label also carries `.text`
      // but cannot be activated.
      if (item.text === label && typeof item.clicked === "function")
        return item
      var kids = childItems(item)
      for (var i = 0; kids && i < kids.length; i++) {
        var found = findLabeled(kids[i], label)
        if (found) return found
      }
      return null
    }

    // The popup is a layer-shell Window: its `contentItem` is a list of the
    // content roots rather than one Item (a QVariantList — index it, it is
    // not a JS Array).
    function popupRoots() {
      var mp = widget.miniPopup
      if (!mp || !mp.contentItem) return []
      var ci = mp.contentItem
      if (ci.length === undefined) return [ci]
      var list = []
      for (var i = 0; i < ci.length; i++) list.push(ci[i])
      return list
    }

    function findPopupLabeled(label) {
      var roots = popupRoots()
      for (var i = 0; i < roots.length; i++) {
        var found = findLabeled(roots[i], label)
        if (found) return found
      }
      return null
    }

    function lastPayload() {
      var call = fakeBar.summonCalls[fakeBar.summonCalls.length - 1]
      if (!call) return null
      try { return JSON.parse(call.payload) } catch (e) { return null }
    }

    onTriggered: {
      if (step === 0) {
        // Same settled-state wait as the connect scenario, but asserted in
        // the signed-out direction: no stored credentials yet.
        if (navidromeService.sessionPending
            || !navidromeService.daemon.requirementsChecked) {
          if (++attempts > 200)
            fail("The smoke plugin dir never initialized")
          return
        }
        if (navidromeService.accountConnected)
          fail("The widget scenario must run before any connection exists")
        // Attach the stand-in bar: the widget resolves its service through
        // it exactly like it does against the real host.
        widget.bar = fakeBar
        if (widget.service !== navidromeService)
          fail("The widget did not resolve the service through the fake bar")
        if (typeof widget.openSetupPanel !== "function")
          fail("The signed-out setup handover is missing")
        var actions = widget.miniKeyboardActions
        if (actions.indexOf("setup") < 0 || actions.indexOf("open") < 0)
          fail("The signed-out keyboard actions were "
            + JSON.stringify(actions))
        if (widget.popupOpen) fail("The mini-player started open")
        step = 1
        return
      }

      if (step === 1) {
        // The main bar button, signed out: a left click must open the
        // mini-player popup (its setup column is the login affordance).
        widget.toggle()
        step = 2
        return
      }

      if (step === 2) {
        if (!widget.popupOpen)
          fail("The bar button's open path did not open the mini-player popup")
        // The popup surface builds its content on first open; the signed-out
        // state must show the setup column inside it. The popup is a
        // layer-shell Window, so its content hangs off the contentItem.
        var setup = findLabeled(widget, "Set up and continue")
          || findPopupLabeled("Set up and continue")
        if (!setup) {
          if (++attempts > 100)
            fail("The mini-player setup button is missing")
          return
        }
        var open = findLabeled(widget, "Open") || findPopupLabeled("Open")
        if (!open) fail("The mini-player Open button is missing")
        if (!setup.visible) fail("The setup column was hidden while signed out")
        if (!setup.enabled) fail("The setup button was disabled while signed out")
        attempts = 0
        step = 3
        return
      }

      if (step === 3) {
        // The reported dead button, signed out: click the widget's own
        // Set-up affordance. It must hand over to the full panel's login
        // gateway, not silently re-read an empty keyring.
        var setup = findLabeled(widget, "Set up and continue")
          || findPopupLabeled("Set up and continue")
        if (!setup) fail("The setup button disappeared before the click")
        setup.clicked()
        step = 4
        return
      }

      if (step === 4) {
        if (widget.popupOpen)
          fail("The setup handover left the mini-player open")
        if (fakeBar.hideCalls.indexOf("quickshell.navidrome") < 0)
          fail("The setup handover did not dismiss the popup first")
        var payload = lastPayload()
        if (!payload || payload.tab !== "setup")
          fail("Clicking Set up did not summon the panel with the setup tab: "
            + JSON.stringify(payload))
        if (fakeBar.runCalls.length !== 0)
          fail("The setup handover ran a shell command: "
            + JSON.stringify(fakeBar.runCalls))
        step = 5
        return
      }

      if (step === 5) {
        // The configured-player shortcut's default target ("Omarchy Music
        // app") must open this plugin's own player, never an external
        // launcher command.
        var result = widget.toggleConfiguredPlayerShortcut()
        if (result !== "opened")
          fail("The configured-player shortcut returned " + result)
        var payload = lastPayload()
        if (!payload || payload.shortcutLatch !== true)
          fail("The configured-player shortcut did not latch the panel: "
            + JSON.stringify(payload))
        step = 6
        return
      }

      if (step === 6) {
        if (widget.popupOpen)
          fail("The configured-player shortcut left the mini-player open")
        if (fakeBar.runCalls.length !== 0)
          fail("The configured-player shortcut ran a shell command: "
            + JSON.stringify(fakeBar.runCalls))
        // Hand the signed-out state to the guided-connection scenario.
        fakeBar.summonCalls = []
        fakeBar.hideCalls = []
        panel.currentTab = "login"
        connectScenario.start()
        running = false
      }
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
