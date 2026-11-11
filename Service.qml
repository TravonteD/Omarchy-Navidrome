import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.Mpris

import "Api.js" as Api
import "Subsonic.js" as Subsonic

// Shared state for the bar widget and the lazy full panel. MPRIS supplies
// local playback changes from the plugin's stream engine.
Item {
  id: root

  visible: false
  width: 0
  height: 0

  property var shell: null
  property var manifest: null
  property var pluginRegistry: null

  readonly property string pluginId: manifest && manifest.id
    ? String(manifest.id) : "quickshell.navidrome"
  readonly property string pluginDir: manifest && manifest.__sourceDir
    ? String(manifest.__sourceDir) : ""
  readonly property string homeDirectory: Quickshell.env("HOME") || ""
  readonly property string stateHome: {
    var explicit = String(Quickshell.env("XDG_STATE_HOME") || "").trim()
    if (explicit) return explicit
    return homeDirectory ? homeDirectory + "/.local/state" : ".local/state"
  }
  readonly property string stateDir: stateHome + "/omarchy-navidrome"
  readonly property string sessionPath: stateDir + "/session.json"

  readonly property var defaultSettingValues: ({
    deviceName: "Omarchy Navidrome",
    idleShutdownMinutes: 15,
    showMiniPlayer: "On",
    showVinylRecord: "Off",
    shortcutPlayer: "Omarchy Music app",
    shortcutHints: "On",
    showLyrics: "On",
    showArtwork: "On",
    showTrackTitle: "On",
    showArtistName: "Off",
    showPausedTrack: "On",
    scrollBarText: "Off",
    scrollSpeed: "1",
    maxBarTextWidth: "240",
    fixedBarWidth: "Off",
    audioQuality: "320 kbps"
  })
  property var settings: Api.shallowCopy(defaultSettingValues)

  // One pinned salt per session for getCoverArt URLs: stable URLs keep
  // artwork caches valid across row rebuilds, so revisiting a view causes
  // no artwork traffic. The credentials ride only inside the URL builder
  // (Subsonic.coverArtUrl) and never in logs or persisted state; persisted
  // session state is scrubbed of imageUrl by Api.normalizedSessionState.
  property string artworkSalt: Subsonic.randomSalt()
  readonly property var subsonicArt: Api.subsonicArtContext(
    authManager.navidromeUrl, authManager.navidromeUsername,
    authManager.navidromePassword, artworkSalt)

  readonly property string deviceName: String(settings.deviceName || "Omarchy Navidrome").trim() || "Omarchy Navidrome"
  readonly property int idleShutdownMinutes: Math.max(0, Math.min(1440,
    Math.floor(Number(settings.idleShutdownMinutes) || 0)))
  readonly property bool showMiniPlayer: String(settings.showMiniPlayer || "On") !== "Off"
  readonly property bool showVinylRecord: String(settings.showVinylRecord || "Off") === "On"
  readonly property string shortcutPlayer: Api.normalizedShortcutPlayer(
    settings.shortcutPlayer)
  readonly property bool shortcutHintsEnabled: String(settings.shortcutHints || "On") !== "Off"
  readonly property bool showLyrics: String(settings.showLyrics || "On") !== "Off"
  readonly property bool artworkEnabled: String(settings.showArtwork || "On") !== "Off"
  readonly property bool showTrackTitle: String(settings.showTrackTitle || "On") !== "Off"
  readonly property bool showArtistName: String(settings.showArtistName || "Off") === "On"
  readonly property bool showPausedTrack: String(settings.showPausedTrack || "On") !== "Off"
  readonly property bool scrollBarText: String(settings.scrollBarText || "Off") === "On"
  readonly property real scrollSpeed: Api.normalizedScrollSpeed(settings.scrollSpeed)
  // Bar label cap in unscaled px; 0 means no cap.
  readonly property real maxBarTextWidth: Api.normalizedMaxBarTextWidth(
    settings.maxBarTextWidth)
  // Reserve the whole cap while a track is shown so the bar does not shift
  // between songs of different lengths. Meaningless without a cap.
  readonly property bool fixedBarWidth: maxBarTextWidth > 0
    && String(settings.fixedBarWidth || "Off") === "On"
  readonly property int bitrateKbps: {
    var quality = String(settings.audioQuality || "320 kbps")
    return quality.indexOf("96") === 0 ? 96
      : (quality.indexOf("160") === 0 ? 160 : 320)
  }
  readonly property string audioQuality: bitrateKbps + " kbps"
  property var searchHistory: []
  property var sessionState: ({})
  property bool sessionFileReady: false
  property bool sessionFileHadData: false
  property bool sessionFileDirty: false
  property bool pluginSessionKeysPendingStrip: false

  readonly property alias auth: authManager
  readonly property alias daemon: daemonManager
  readonly property alias backend: backendClient
  readonly property bool accountConnected: authManager.loggedIn
  readonly property bool sessionPending: !authManager.sessionChecked
  readonly property bool fullyConnected: daemonManager.playbackReady
    && authManager.loggedIn
  readonly property bool loginBusy: daemonManager.setupBusy
    || authManager.loginBusy
    || authManager.sessionBusy || !authManager.sessionChecked
    || !daemonManager.requirementsChecked
  readonly property string loginProgress: loginProgressText()

  readonly property var mprisPlayers: Mpris.players ? Mpris.players.values : []
  property real pendingSliderVolume: -1
  property double pendingSliderUntil: 0
  property bool volumeFlushQueued: false
  property real queuedVolumeSlider: 0
  property bool volumeFlushCooling: false
  property bool volumeLiveActive: false
  readonly property int sliderGraceMs: 8000
  property int playbackPositionTick: 0
  readonly property var activePlayer: enginePlayer()
  readonly property bool hasLocalPlayer: activePlayer !== null
  readonly property bool hasPlayer: hasLocalPlayer
  readonly property bool hasMedia: hasLocalPlayer
    && !!(activePlayer.trackTitle || activePlayer.trackArtist)
  readonly property bool playing: hasLocalPlayer && activePlayer.isPlaying
  readonly property int playbackState: hasPlayer
    ? activePlayer.playbackState : MprisPlaybackState.Stopped
  readonly property string title: hasLocalPlayer
    ? String(activePlayer.trackTitle || "") : ""
  readonly property string artist: hasLocalPlayer
    ? String(activePlayer.trackArtist || "") : ""
  readonly property string album: hasLocalPlayer
    ? String(activePlayer.trackAlbum || "") : ""
  readonly property string artUrl: hasLocalPlayer
    ? String(activePlayer.trackArtUrl || "") : ""
  readonly property real positionSeconds: {
    playbackPositionTick
    return hasLocalPlayer && activePlayer.positionSupported
      ? Math.max(0, Number(activePlayer.position) || 0) : 0
  }
  readonly property real lengthSeconds: hasLocalPlayer
    && activePlayer.lengthSupported
    ? Math.max(0, Number(activePlayer.length) || 0) : 0
  readonly property real playbackVolume: hasLocalPlayer
    && activePlayer.volumeSupported
    ? Math.max(0, Math.min(1, Number(activePlayer.volume) || 0)) : 0
  readonly property real reportedSliderVolume: playbackVolume
  readonly property real volume: pendingSliderVolume >= 0
    ? pendingSliderVolume : reportedSliderVolume
  readonly property bool volumePending: pendingSliderVolume >= 0
  onReportedSliderVolumeChanged: reconcilePendingSliderVolume()
  readonly property var currentLyricsSong: Api.lyricsSong(currentTrackId,
    title, artist, album, lengthSeconds, artUrl, positionSeconds)
  readonly property bool lyricsAvailable: showLyrics && currentLyricsSong !== null
  readonly property string lyricsPluginId: "stappmus.lyrics"
  readonly property string lyricsPluginUrl: "https://github.com/stappmus/Omasing.git"
  readonly property string lyricsPluginAvailability: {
    var plugins = pluginRegistry && pluginRegistry.installedPlugins
      ? pluginRegistry.installedPlugins : ({})
    var installed = !!plugins[lyricsPluginId]
    var enabled = installed && pluginRegistry
      && typeof pluginRegistry.inBar === "function"
      && pluginRegistry.inBar(lyricsPluginId)
    return Api.optionalPluginState(installed, enabled)
  }
  property bool lyricsPluginBusy: false
  property string lyricsPluginOperation: ""
  property string lyricsPluginError: ""
  property string lyricsPluginRequestSurface: ""
  property var pendingLyricsSong: null
  property int lyricsPluginLaunchAttempts: 0
  property double lyricsPluginInstallStartedAt: 0
  readonly property bool shuffle: hasLocalPlayer && activePlayer.shuffleSupported
    ? activePlayer.shuffle === true : false
  readonly property string repeatMode: mprisRepeatMode()
  readonly property string currentUri: metadataString("xesam:url")
  readonly property string currentTrackId: {
    // The Navidrome stream engine publishes the Subsonic song id as xesam:url
    // (the MPRIS track id is a lossy object path).
    return String(currentUri || "").trim()
  }
  readonly property var currentTrackItem: Api.currentPlaybackTrack(
    currentTrackId, title, artist, album, artUrl, lengthSeconds)
  readonly property string currentTrackItemUri: currentTrackItem
    ? String(currentTrackItem.uri || "") : ""
  readonly property bool currentTrackSaved: isSaved(currentTrackItem)
  readonly property bool currentTrackSaveChecking: isSavedChecking(currentTrackItem)
  readonly property bool currentTrackSaveBusy: currentTrackSaveChecking
    || isSavedBusy(currentTrackItem)
  readonly property bool currentTrackSaveAvailable: !!currentTrackItem
    && authManager.loggedIn && !currentTrackSaveBusy
  readonly property bool playbackControllable: hasLocalPlayer
  readonly property bool volumeSupported: hasLocalPlayer
    && activePlayer.volumeSupported
  readonly property string playbackDeviceName: hasLocalPlayer ? deviceName : ""
  // The current track's artist/album context rows: MPRIS metadata carries no
  // ids, so the footer's go-to-artist/go-to-album buttons resolve by name
  // through bounded search3 reads (currentContext below).
  readonly property var currentArtists: []
  readonly property var currentAlbumItem: null
  readonly property bool currentArtistContextAvailable: Api.artistContextAvailable(
    "track", currentTrackId, currentArtists)
  readonly property bool currentAlbumContextAvailable: album !== ""
    && currentTrackId !== ""

  property var playlists: []
  property string playlistsNext: ""
  property var savedTracks: []
  property string savedTracksNext: ""
  property var savedAlbums: []
  property string savedAlbumsNext: ""
  property var followedArtists: []
  property string followedArtistsNext: ""
  property var playlistItems: []
  property string playlistItemsNext: ""
  property string playlistItemsError: ""
  property int playlistItemsStatus: 0
  property int playlistItemsSerial: 0
  property int playlistRestoreTargetCount: 0
  property var selectedPlaylist: null
  property string currentUserId: ""
  property string currentUserName: ""
  readonly property string playlistItemsEmptyMessage: Api.playlistItemsEmptyMessage(
    selectedPlaylist, playlistItems.length, playlistItemsError)
  property var queue: []
  property alias searchQuery: searchController.searchQuery
  property alias searchGroups: searchController.searchGroups
  property alias searchError: searchController.searchError
  property alias searchResultQuery: searchController.searchResultQuery
  property alias searchActiveType: searchController.searchActiveType
  property alias searchPendingType: searchController.searchPendingType
  property alias searchLoadedTypes: searchController.searchLoadedTypes
  property alias searchGeneration: searchController.searchGeneration
  property var savedUris: ({})
  property var savedUriCheckedAt: ({})
  property var savedUriOrder: []
  property var savedUrisChecking: ({})
  property var savedUrisBusy: ({})
  // The maps stay stable to avoid full copies; revisions keep QML lookups
  // reactive when individual entries change. Keys are the canonical
  // savedKeyFor(item) ("<type>:<id>") instead of the Web API uri.
  property int savedUrisRevision: 0
  property int savedUrisCheckingRevision: 0
  property int savedUrisBusyRevision: 0
  readonly property int savedUriCacheLimit: 4096
  readonly property int savedUriFreshnessMs: 300000

  // Home windows (getAlbumList2) and the starred-song window (getStarred2).
  property var homeRecent: []
  property var homeFrequent: []
  property var homeNewest: []
  property var homeStarred: []
  // Most recent album window, kept while nothing is loaded so Play can
  // continue there the way the desktop app's footer does.
  property var resumeCandidate: null
  property bool resumeCandidateLoading: false
  property real resumeCandidateLoadedAt: 0
  readonly property bool canResumeLastPlayed: Api.resumePlaybackAvailable(
    hasMedia, resumeCandidate)
  readonly property var lastPlayedItem: canResumeLastPlayed
    ? resumeCandidate.item : null
  // Play is usable either with live media or with a last play to fall back to.
  // Seek, skip, shuffle, and repeat stay tied to playbackControllable.
  readonly property bool playbackStartable: playbackControllable
    || canResumeLastPlayed
  property bool homeLoaded: false
  property int homeRequestsPending: 0
  readonly property bool homeLoading: homeRequestsPending > 0

  // Explore: random albums from getAlbumList2, plus the genre list for the
  // genre browser (rendering lands with the view pass; the scan machinery
  // from FilterScanController stays for long genre lists).
  property var discoverAlbums: []
  property var discoverGenres: []
  property bool discoverLoaded: false
  property int discoverRequestsPending: 0
  property int discoverRequestsFailed: 0
  property int discoverSerial: 0
  property string discoverMessage: ""
  readonly property bool discoverLoading: discoverRequestsPending > 0

  property var detailItem: null
  property var detailItems: []
  property string detailNext: ""
  property bool detailLoading: false
  property string detailMessage: ""
  property int detailSerial: 0
  property int detailRestoreTargetCount: 0
  property var artistAlbums: []
  property string artistAlbumsNext: ""
  property bool artistAlbumsLoading: false
  property var artistSongs: []
  property string artistSongsNext: ""
  property bool artistSongsLoading: false
  property string artistCatalogQuery: ""
  property int artistCatalogSerial: 0
  readonly property bool artistCatalogLoading: artistAlbumsLoading
    || artistSongsLoading

  property bool playlistActionBusy: false
  property bool playlistConversionBusy: false
  property string pendingPlaylistName: ""

  property string sleepMode: "off"
  property double sleepEndsAt: 0
  property string sleepTrackUri: ""
  readonly property bool sleepActive: sleepMode !== "off"
  property int sleepRemainingSeconds: 0

  property string activeView: "search"
  property bool playlistsLoaded: false
  property bool savedTracksLoaded: false
  property bool savedAlbumsLoaded: false
  property bool followedArtistsLoaded: false
  property bool queueLoaded: false
  property bool playlistsLoading: false
  property bool savedTracksLoading: false
  property bool savedAlbumsLoading: false
  property bool followedArtistsLoading: false
  property bool playlistItemsLoading: false
  property bool queueLoading: false
  property alias searchLoading: searchController.searchLoading
  // Subsonic has no rate-limit cooldown machinery; the scan controller keeps
  // its cooldown input shape and simply never waits.
  readonly property double searchCooldownUntil: 0
  function searchProgressText(timestamp) { return searchController.progressText(timestamp) }
  property string lastError: ""
  property string statusMessage: ""

  readonly property bool playlistRestorePending: Api.playlistRestorePending(
    playlistItems.length, playlistRestoreTargetCount, playlistItemsLoading,
    playlistItemsNext)
  readonly property int playlistRememberedItemCount:
    Api.normalizedPlaylistRestoreCount(Math.max(playlistItems.length,
      playlistRestoreTargetCount))
  readonly property bool detailRestorePending: !!detailItem
    && detailItem.type === "playlist" && Api.playlistRestorePending(
      detailItems.length, detailRestoreTargetCount, detailLoading, detailNext)
  readonly property int detailRememberedItemCount:
    Api.normalizedPlaylistRestoreCount(Math.max(detailItems.length,
      detailRestoreTargetCount))

  property int dataSerial: 0
  property var visibleSurfaces: ({})
  readonly property bool uiVisible: Object.keys(visibleSurfaces).length > 0
  property double lastActivityAt: Date.now()
  // Protocol v2 load body derived from the same play request; the local
  // socket path sends it.
  property var pendingPlaybackLoad: null
  property string pendingPlaybackMessage: ""
  property var pendingPlaybackRadio: null
  property int pendingPlaybackSerial: 0
  property int radioSerial: 0
  property var lastRadioPlaylist: null
  readonly property bool lastRadioPlaying: !!lastRadioPlaylist && playing
  property bool localActivationRequested: false
  property int localSocketWaitAttempts: 0
  property bool loginFlowActive: false

  readonly property int cacheLimit: 200

  signal operationFailed(string reason)
  signal radioPlaylistReady(var playlist)
  signal lyricsPluginPromptRequested(string surface, string availability)
  signal lyricsPluginOpened(string surface)

  function loginProgressText() {
    if (daemonManager.setupBusy) return "Preparing playback on this computer"
    if (authManager.loginBusy) return "Saving your Navidrome connection"
    if (authManager.sessionBusy || !authManager.sessionChecked)
      return "Checking your saved Navidrome connection"
    if (!daemonManager.requirementsChecked)
      return "Checking local playback"
    return fullyConnected ? "Connected to Navidrome" : "Ready to connect"
  }

  function defaults() {
    var fallback = Api.shallowCopy(defaultSettingValues)
    var source = manifest && manifest.barWidget && manifest.barWidget.defaults
      ? manifest.barWidget.defaults : null
    return source ? Api.assign(fallback, source) : fallback
  }

  function normalizedSettings(values) {
    var next = defaults()
    var source = values || {}
    var keys = ["deviceName", "idleShutdownMinutes", "showMiniPlayer",
      "showVinylRecord", "shortcutPlayer", "shortcutHints", "showLyrics", "showArtwork", "showTrackTitle", "showArtistName",
      "showPausedTrack", "scrollBarText", "scrollSpeed", "maxBarTextWidth",
      "fixedBarWidth", "audioQuality"]
    for (var i = 0; i < keys.length; i++) {
      var key = keys[i]
      if (source[key] !== undefined) next[key] = source[key]
    }
    next.deviceName = String(next.deviceName || "Omarchy Navidrome").trim() || "Omarchy Navidrome"
    next.idleShutdownMinutes = Math.max(0, Math.min(1440,
      Math.floor(Number(next.idleShutdownMinutes) || 0)))
    next.showMiniPlayer = String(next.showMiniPlayer || "On") === "Off" ? "Off" : "On"
    next.showVinylRecord = String(next.showVinylRecord || "Off") === "On" ? "On" : "Off"
    next.shortcutPlayer = Api.normalizedShortcutPlayer(next.shortcutPlayer)
    next.shortcutHints = Api.normalizedShortcutHints(next.shortcutHints)
    next.showLyrics = String(next.showLyrics || "On") === "Off" ? "Off" : "On"
    next.showArtwork = String(next.showArtwork || "On") === "Off" ? "Off" : "On"
    next.showTrackTitle = String(next.showTrackTitle || "On") === "Off" ? "Off" : "On"
    next.showArtistName = String(next.showArtistName || "Off") === "On" ? "On" : "Off"
    next.showPausedTrack = String(next.showPausedTrack || "On") === "Off" ? "Off" : "On"
    next.scrollBarText = String(next.scrollBarText || "Off") === "On" ? "On" : "Off"
    if (!Api.canScrollBarText(next.showTrackTitle === "On", next.showArtistName === "On"))
      next.scrollBarText = "Off"
    next.scrollSpeed = String(Api.normalizedScrollSpeed(next.scrollSpeed))
    next.maxBarTextWidth = String(Api.normalizedMaxBarTextWidth(next.maxBarTextWidth))
    // An uncapped slot always fits its text, so the marquee could never run.
    if (Number(next.maxBarTextWidth) === 0) next.scrollBarText = "Off"
    next.fixedBarWidth = String(next.fixedBarWidth || "Off") === "On" ? "On" : "Off"
    if (Number(next.maxBarTextWidth) === 0) next.fixedBarWidth = "Off"
    var quality = String(next.audioQuality || "320 kbps")
    next.audioQuality = quality.indexOf("96") === 0 ? "96 kbps"
      : (quality.indexOf("160") === 0 ? "160 kbps" : "320 kbps")
    return next
  }

  function applySettings(values) {
    var previousDeviceName = deviceName
    var next = normalizedSettings(values)
    if (JSON.stringify(next) !== JSON.stringify(settings)) settings = next
    // The backend re-reads device_name/bitrate when the next playback start
    // writes its configuration (DaemonManager.configureDeviceName).
    void previousDeviceName
  }

  function persistSettings(values) {
    var next = normalizedSettings(Api.assign(Api.shallowCopy(settings), values))
    applySettings(next)
    if (shell && typeof shell.updateEntryInline === "function")
      shell.updateEntryInline(pluginId, next)
  }

  function persistSession(values) {
    var next = Api.normalizedSessionState(values || ({}))
    if (JSON.stringify(next) === JSON.stringify(sessionState)) return
    sessionState = next
    scheduleSessionSave()
  }

  function rememberSearch(term) {
    var next = Api.touchHistory(searchHistory, term, 12)
    if (JSON.stringify(next) === JSON.stringify(searchHistory)) return
    searchHistory = next
    scheduleSessionSave()
  }

  function clearSearchHistory() {
    if (searchHistory.length === 0) return
    searchHistory = []
    scheduleSessionSave()
  }

  function currentSessionRecord() {
    return Api.sessionRecord(sessionState, searchHistory)
  }

  function applySessionFile(raw) {
    if (sessionFileReady) return
    var fromFile = Api.parseSessionRecord(raw)
    sessionFileHadData = !Api.sessionRecordIsEmpty(fromFile)
    if (!sessionFileDirty && sessionFileHadData) {
      sessionState = fromFile.sessionState
      searchHistory = fromFile.searchHistory
    }
    sessionFileReady = true
    reconcileSessionPersistence()
    resumeLyricsInstallIntent()
  }

  function scheduleSessionSave() {
    sessionFileDirty = true
    if (sessionFileReady) sessionSaveTimer.restart()
  }

  function flushSessionFile() {
    if (!sessionFileReady) return
    sessionSaveTimer.stop()
    sessionFile.setText(Api.encodeSessionRecord(sessionState, searchHistory))
  }

  function stripPluginSessionKeys() {
    if (!pluginSessionKeysPendingStrip) return
    var entry = configuredEntry()
    if (!entry || !shell || typeof shell.updateEntryInline !== "function") return
    pluginSessionKeysPendingStrip = false
    persistSettings(entry)
  }

  function reconcileSessionPersistence() {
    if (!sessionFileReady) return
    var entry = configuredEntry() || {}
    var pluginHasKeys = Api.pluginSettingsHaveSessionKeys(entry)
    if (pluginHasKeys) {
      if (Api.sessionRecordIsEmpty(currentSessionRecord()) && !sessionFileDirty) {
        var fromPlugin = Api.sessionRecordFromPluginSettings(entry)
        sessionState = fromPlugin.sessionState
        searchHistory = fromPlugin.searchHistory
      }
      pluginSessionKeysPendingStrip = true
    }
    var shouldWrite = sessionFileDirty
      || (pluginHasKeys && !sessionFileHadData
        && !Api.sessionRecordIsEmpty(currentSessionRecord()))
    if (shouldWrite) flushSessionFile()
    else if (pluginHasKeys) stripPluginSessionKeys()
  }

  function configuredEntry() {
    var config = shell && shell.shellConfig ? shell.shellConfig : null
    if (!config) return null
    var layout = config.bar && config.bar.layout ? config.bar.layout : null
    var sections = ["left", "center", "right"]
    if (layout) {
      for (var s = 0; s < sections.length; s++) {
        var rows = Array.isArray(layout[sections[s]]) ? layout[sections[s]] : []
        for (var i = 0; i < rows.length; i++)
          if (rows[i] && String(rows[i].id || "") === pluginId) return rows[i]
      }
    }
    var plugins = Array.isArray(config.plugins) ? config.plugins : []
    for (var p = 0; p < plugins.length; p++)
      if (plugins[p] && String(plugins[p].id || "") === pluginId) return plugins[p]
    return null
  }

  function syncSettings() {
    applySettings(configuredEntry() || {})
    reconcileSessionPersistence()
    resumeLyricsInstallIntent()
  }

  // The Navidrome stream engine publishes its own MPRIS player; match it by
  // identity, desktop entry, or bus name.
  function isEnginePlayer(player) {
    if (!player) return false
    var identity = [player.dbusName, player.desktopEntry, player.identity]
      .join(" ").toLowerCase()
    return identity.indexOf("navidrome") !== -1
      || identity.indexOf("omarchy") !== -1
  }

  function enginePlayer() {
    var fallback = null
    for (var i = 0; i < mprisPlayers.length; i++) {
      var player = mprisPlayers[i]
      if (!isEnginePlayer(player)) continue
      if (player.isPlaying) return player
      if (!fallback) fallback = player
    }
    return fallback
  }

  function metadataString(key) {
    var metadata = activePlayer && activePlayer.metadata ? activePlayer.metadata : null
    return metadata && metadata[key] !== undefined ? String(metadata[key]) : ""
  }

  function mprisRepeatMode() {
    if (!hasLocalPlayer || !activePlayer.loopSupported) return "off"
    if (activePlayer.loopState === MprisLoopState.Track) return "track"
    if (activePlayer.loopState === MprisLoopState.Playlist) return "context"
    return "off"
  }

  function safeError(reason) {
    return Api.redact(String(reason || "The server operation failed"))
  }

  function fail(reason) {
    statusClearTimer.stop()
    lastError = safeError(reason)
    statusMessage = ""
    operationFailed(lastError)
  }

  function succeed(message) {
    lastError = ""
    statusMessage = String(message || "")
    if (statusMessage) statusClearTimer.restart()
    else statusClearTimer.stop()
  }

  function requestLyrics(surface) {
    if (!currentLyricsSong) return "unavailable"
    lyricsPluginRequestSurface = String(surface || "")
    pendingLyricsSong = currentLyricsSong
    lyricsPluginError = ""
    lyricsPluginLaunchAttempts = 0
    if (lyricsPluginAvailability === "ready") {
      launchLyricsPlugin()
      return "opening"
    }
    lyricsPluginPromptRequested(lyricsPluginRequestSurface,
      lyricsPluginAvailability)
    return lyricsPluginAvailability
  }

  function pendingLyricsInstall() {
    var pending = sessionState && sessionState.pendingLyricsInstall
    return pending && typeof pending === "object" ? pending : null
  }

  function persistLyricsInstallIntent() {
    if (!pendingLyricsSong) return
    var state = Api.shallowCopy(sessionState)
    state.pendingLyricsInstall = Api.lyricsInstallIntent(pendingLyricsSong,
      lyricsPluginRequestSurface, Date.now())
    persistSession(state)
  }

  function clearLyricsInstallIntent() {
    if (!pendingLyricsInstall()) return
    persistSession(Api.sessionWithoutLyricsInstall(sessionState))
  }

  function confirmLyricsPlugin(surface) {
    if (lyricsPluginBusy) return false
    if (surface) lyricsPluginRequestSurface = String(surface)
    if (!pendingLyricsSong) pendingLyricsSong = currentLyricsSong
    if (!pendingLyricsSong) {
      lyricsPluginError = "Play a song first, then try lyrics again."
      return false
    }
    lyricsPluginError = ""

    if (lyricsPluginAvailability === "ready") {
      lyricsPluginLaunchAttempts = 0
      launchLyricsPlugin()
      return true
    }

    var command = Api.optionalPluginSetupCommand(lyricsPluginAvailability,
      lyricsPluginId, lyricsPluginUrl)
    if (!command.length) {
      lyricsPluginError = "Omasing could not be prepared for installation."
      return false
    }
    lyricsPluginOperation = lyricsPluginAvailability
    lyricsPluginBusy = true
    persistLyricsInstallIntent()

    // Adding a plugin writes into ~/.config/omarchy/plugins, which reloads
    // the shell and would kill a child Process before enable finishes.
    // Detach the add and resume from the saved intent after reload.
    if (lyricsPluginAvailability === "missing") {
      lyricsPluginInstallStartedAt = Date.now()
      Quickshell.execDetached(command)
      lyricsPluginInstallPoll.restart()
      return true
    }

    lyricsPluginSetupProcess.command = command
    lyricsPluginSetupProcess.running = true
    return true
  }

  function resumeLyricsInstallIntent() {
    var intent = pendingLyricsInstall()
    if (!intent) return
    if (!Api.lyricsInstallIntentIsFresh(intent, Date.now(), 180000)) {
      clearLyricsInstallIntent()
      return
    }
    if (!pendingLyricsSong) pendingLyricsSong = intent.song
    if (!lyricsPluginRequestSurface)
      lyricsPluginRequestSurface = String(intent.surface || "")

    if (lyricsPluginAvailability === "ready") {
      lyricsPluginInstallPoll.stop()
      lyricsPluginBusy = false
      lyricsPluginError = ""
      lyricsPluginLaunchAttempts = 0
      clearLyricsInstallIntent()
      launchLyricsPlugin()
      return
    }

    if (lyricsPluginBusy || lyricsPluginSetupProcess.running
        || lyricsPluginInstallPoll.running)
      return

    if (lyricsPluginAvailability === "disabled") {
      confirmLyricsPlugin(lyricsPluginRequestSurface)
      return
    }

    lyricsPluginBusy = true
    lyricsPluginOperation = "missing"
    lyricsPluginInstallStartedAt = Number(intent.startedAt) || Date.now()
    lyricsPluginInstallPoll.restart()
  }

  function finishLyricsPluginInstallWatch() {
    if (lyricsPluginAvailability === "ready") {
      lyricsPluginBusy = false
      lyricsPluginError = ""
      lyricsPluginLaunchAttempts = 0
      clearLyricsInstallIntent()
      launchLyricsPlugin()
      return true
    }
    if (lyricsPluginAvailability === "disabled") {
      lyricsPluginBusy = false
      confirmLyricsPlugin(lyricsPluginRequestSurface)
      return true
    }
    if (Date.now() - lyricsPluginInstallStartedAt < 90000) return false
    lyricsPluginBusy = false
    lyricsPluginError = "Omasing could not be installed. Check your network and try again."
    clearLyricsInstallIntent()
    lyricsPluginPromptRequested(lyricsPluginRequestSurface,
      lyricsPluginAvailability)
    return true
  }

  function cancelLyricsPlugin(surface) {
    if (lyricsPluginBusy) return
    if (surface && String(surface) !== lyricsPluginRequestSurface) return
    lyricsPluginInstallPoll.stop()
    lyricsPluginRequestSurface = ""
    pendingLyricsSong = null
    lyricsPluginError = ""
    clearLyricsInstallIntent()
  }

  function launchLyricsPlugin() {
    if (!pendingLyricsSong || lyricsPluginLaunchProcess.running) return
    lyricsPluginLaunchAttempts++
    lyricsPluginLaunchProcess.command = ["/usr/bin/omarchy-shell",
      lyricsPluginId, "lyrics", JSON.stringify(pendingLyricsSong)]
    lyricsPluginLaunchProcess.running = true
  }

  function finishLyricsPluginLaunch(exitCode) {
    if (Number(exitCode) === 0) {
      var openedSurface = lyricsPluginRequestSurface
      pendingLyricsSong = null
      lyricsPluginRequestSurface = ""
      lyricsPluginError = ""
      lyricsPluginLaunchAttempts = 0
      lyricsPluginOpened(openedSurface)
      return
    }
    if (lyricsPluginLaunchAttempts < 20) {
      lyricsPluginLaunchRetry.restart()
      return
    }
    var detail = String(lyricsPluginLaunchStderr.text || "").trim()
    lyricsPluginError = safeError(detail
      || "Omasing is installed, but its lyrics window could not be opened.")
    lyricsPluginPromptRequested(lyricsPluginRequestSurface,
      lyricsPluginAvailability)
  }

  function noteActivity() {
    lastActivityAt = Date.now()
  }

  property bool localPlaybackStopped: false

  // While a player surface is open, keep the local engine up so the mini
  // player and media keys keep working; the configured idle timeout begins
  // only after every surface closes.
  function ensureVisibleLocalReceiver() {
    if (localPlaybackStopped || daemonManager.terminalFailure) return
    var action = Api.visibleLocalReceiverAction(uiVisible, fullyConnected,
      daemonManager.running, daemonManager.busy)
    if (action === "start") daemonManager.start()
  }

  function setUiVisible(key, value) {
    var name = String(key || "surface")
    var next = ({})
    for (var oldKey in visibleSurfaces)
      if (oldKey !== name && visibleSurfaces[oldKey]) next[oldKey] = true
    if (value) next[name] = true
    visibleSurfaces = next
    if (value) {
      noteActivity()
      // An opened surface refreshes the local MPRIS view; the Subsonic
      // resume candidate rides the same cadence.
      loadPlaybackState()
    }
  }

  function refreshPosition() {
    if (activePlayer && activePlayer.positionSupported)
      activePlayer.positionChanged()
    else playbackPositionTick++
  }

  function beginPendingSliderVolume(value) {
    pendingSliderVolume = Math.max(0, Math.min(1, Number(value) || 0))
    pendingSliderUntil = Date.now() + sliderGraceMs
    if (volumeHoldTimer) volumeHoldTimer.restart()
  }

  function clearPendingSliderVolume() {
    pendingSliderVolume = -1
    pendingSliderUntil = 0
    if (volumeHoldTimer) volumeHoldTimer.stop()
  }

  function reconcilePendingSliderVolume() {
    if (pendingSliderVolume < 0) return
    if (!Api.pendingSliderVolumeShouldHold(reportedSliderVolume, {
      slider: pendingSliderVolume,
      expiresAt: pendingSliderUntil
    }, Date.now()))
      clearPendingSliderVolume()
  }

  function sendVolumeCommand(sliderValue) {
    if (!hasLocalPlayer || !activePlayer.volumeSupported) {
      // Nothing to talk to: release the pending slider so the displayed
      // value stops pretending the command was accepted.
      clearPendingSliderVolume()
      return true
    }
    activePlayer.volume = Api.clampUnit(sliderValue)
    return true
  }

  function flushVolume() {
    if (!volumeFlushQueued) {
      volumeFlushCooling = false
      return
    }
    var sliderValue = queuedVolumeSlider
    beginPendingSliderVolume(sliderValue)
    if (sendVolumeCommand(sliderValue)) volumeFlushQueued = false
    volumeFlushCooling = true
    if (volumeFlushTimer) volumeFlushTimer.restart()
  }

  // The Web API current-playback fetch died with the Spotify transport.
  // Playback state comes from the engine's MPRIS player; this remains as the
  // waiters/refresh hook so callers keep their shape, and it refreshes the
  // Navidrome resume candidate whenever nothing is playing.
  function loadPlaybackState(callback) {
    if (typeof callback === "function") callback(false)
    if (!hasMedia) root.loadResumeCandidate()
  }

  // The Web API remote-control paths died with the Spotify transport; with
  // only the engine's MPRIS player left, every control below acts on the
  // local player directly. apiAction stays as a typed inert no-op so no
  // caller can accidentally reach a network path that no longer exists.
  function apiAction(method, path, query, body, successText, callback) {
    void method; void path; void query; void body; void successText
    if (typeof callback === "function") callback(false)
  }

  function normalizedView(view) {
    var value = String(view || "search")
    return ["home", "discover", "search", "library", "playlists", "detail", "queue", "setup"].indexOf(value) >= 0
      ? value : "search"
  }

  // Fetch only the dataset represented by the visible page. An empty but
  // successfully loaded list is tracked separately so revisiting it causes no
  // network request; the explicit refresh control can still force one.
  function openView(view, force) {
    activeView = normalizedView(view)
    if (!authManager.loggedIn) return
    if (activeView === "home" && (force || !homeLoaded))
      loadHome()
    else if (activeView === "discover" && (force || !discoverLoaded))
      loadDiscover()
    else if (activeView === "search" && force && searchQuery)
      search(searchQuery, searchActiveType, true)
    else if (activeView === "library" && (force || !savedTracksLoaded))
      loadSavedTracks(false)
    else if (activeView === "playlists" && (force || !playlistsLoaded))
      loadPlaylists(false)
    else if (activeView === "queue" && (force || !queueLoaded))
      loadQueue()
  }

  function refreshView(view) {
    loadPlaybackState()
    openView(view, true)
  }

  function loadSidebarPlaylists() {
    if (!playlistsLoaded && !playlistsLoading) loadPlaylists(false)
  }

  function loadProfile() {
    // Subsonic identity is the authenticated username; playlist ownership
    // compares that name against a playlist's owner field. No profile fetch.
    currentUserId = String(authManager.navidromeUsername || "")
    currentUserName = currentUserId
  }

  function playlistById(id) {
    var key = String(id || "")
    for (var i = 0; i < playlists.length; i++)
      if (String(playlists[i].id || "") === key) return playlists[i]
    return null
  }

  function playlistEditable(item) {
    if (!item || item.type !== "playlist") return false
    return item.collaborative === true
      || playlistOwned(item)
  }

  function playlistOwned(item) {
    return !!item && item.type === "playlist"
      && Api.playlistOwnedByUser(item, currentUserId)
  }

  function editablePlaylists() {
    var result = []
    for (var i = 0; i < playlists.length; i++)
      if (playlistEditable(playlists[i])) result.push(playlists[i])
    return result
  }

  function sidebarPlaylists() {
    return playlists
  }

  function validRadioPlaylist(value) {
    return !!value && value.type === "playlist" && !!value.id && !!value.uri
  }

  function restoreLastRadioPlaylist(value) {
    if (!lastRadioPlaylist && validRadioPlaylist(value))
      lastRadioPlaylist = value
  }

  function rememberRadioPlaylist(value) {
    if (!validRadioPlaylist(value)) return
    lastRadioPlaylist = value
    var state = Api.shallowCopy(sessionState)
    state.lastRadioPlaylist = value
    persistSession(state)
  }

  // Opening a panel surface refreshes the login-driven state only then; the
  // widget on the bar and local MPRIS controls stay request-free. Navidrome
  // credentials live in the keyring; there is no token exchange to await.
  function activate(view) {
    activeView = normalizedView(view)
    if (!authManager.loggedIn) return
    root.loadProfile()
    root.loadSidebarPlaylists()
    root.openView(root.activeView, false)
  }

  // Every library collection is one Subsonic read. getStarred2 answers
  // songs/albums/artists in a single response, so its three surfaces share
  // one fetch per pass; playlists are one-shot getPlaylists. There is no
  // cursor pagination anywhere — `next` is always "" and the bounded
  // FilterScanController still handles filtering long lists.
  function libraryCollectionSpec(kind) {
    var value = String(kind || "tracks")
    if (value === "playlists")
      return {
        items: "playlists", next: "playlistsNext",
        loading: "playlistsLoading", loaded: "playlistsLoaded",
        endpoint: "getPlaylists", savedKey: "playlist",
        row: function(node) { return Api.subsonicPlaylistRow(node, root.subsonicArt) },
        checkSaved: true
      }
    if (value === "albums")
      return {
        items: "savedAlbums", next: "savedAlbumsNext",
        loading: "savedAlbumsLoading", loaded: "savedAlbumsLoaded",
        endpoint: "starred2", savedKey: "album",
        row: function(node) { return Api.subsonicAlbumRow(node, root.subsonicArt) }
      }
    if (value === "artists")
      return {
        items: "followedArtists", next: "followedArtistsNext",
        loading: "followedArtistsLoading", loaded: "followedArtistsLoaded",
        endpoint: "starred2", savedKey: "artist",
        row: function(node) { return Api.subsonicArtistRow(node, root.subsonicArt) }
      }
    return {
      items: "savedTracks", next: "savedTracksNext",
      loading: "savedTracksLoading", loaded: "savedTracksLoaded",
      endpoint: "starred2", savedKey: "song",
      row: function(node) { return Api.subsonicSongRow(node, root.subsonicArt) }
    }
  }

  function libraryMapper(kind) {
    var spec = libraryCollectionSpec(kind)
    return spec.row
  }

  function loadLibraryCollection(kind, append, callback, serial) {
    var spec = libraryCollectionSpec(kind)
    if (root[spec.loading]) {
      if (typeof callback === "function") callback()
      return
    }
    // Subsonic windows have no continuation; an append request has nothing
    // more to load.
    var expected = serial === undefined ? dataSerial : serial
    root[spec.loading] = true
    if (spec.endpoint === "starred2") {
      // One fetch fills the three starred collections of this pass; the
      // others read the same parsed result without their own requests.
      root.loadStarred2IfNeeded(expected, function(filled) {
        if (expected !== root.dataSerial) {
          if (typeof callback === "function") callback()
          return
        }
        root[spec.loading] = false
        if (!filled) {
          root[spec.items] = []
          root[spec.next] = ""
          root[spec.loaded] = false
          if (typeof callback === "function") callback()
          return
        }
        var rows = filled[spec.savedKey === "song" ? "songs"
          : (spec.savedKey === "album" ? "albums" : "artists")]
        root[spec.items] = rows
        root[spec.next] = ""
        root[spec.loaded] = true
        if (typeof callback === "function") callback()
      })
    } else {
      subsonicApi.request(spec.endpoint, {}, function(result) {
        if (expected !== root.dataSerial) {
          root[spec.loading] = false
          if (typeof callback === "function") callback()
          return
        }
        root[spec.loading] = false
        if (!result || result.ok !== true) {
          root.fail(String(result && result.errorMessage || "The server request failed"))
          if (typeof callback === "function") callback()
          return
        }
        var normalized = Subsonic.parsePlaylists(result.data)
        var rows = []
        for (var i = 0; i < normalized.length; i++) {
          var row = spec.row(normalized[i])
          if (row) rows.push(row)
        }
        root[spec.items] = rows
        root[spec.next] = ""
        root[spec.loaded] = true
        if (spec.checkSaved === true) root.checkSavedItems(rows)
        if (typeof callback === "function") callback()
      }, { priority: "interactive" })
    }
  }

  // getStarred2 fills savedTracks/savedAlbums/followedArtists in one pass.
  // A short-lived cache keyed by the request serial keeps concurrent loads
  // from tripling the request; every caller still updates its own list.
  property int starred2Serial: 0
  property bool starred2Loading: false
  property var starred2Waiters: []

  function loadStarred2IfNeeded(expected, callback) {
    starred2Waiters = starred2Waiters.concat([callback])
    if (starred2Loading) return
    starred2Loading = true
    var requestSerial = ++starred2Serial
    subsonicApi.request("getStarred2", {}, function(result) {
      var stale = expected !== root.dataSerial || requestSerial !== root.starred2Serial
      root.starred2Loading = false
      if (stale) {
        root.finishStarred2Waiters(null)
        return
      }
      if (!result || result.ok !== true) {
        root.fail(String(result && result.errorMessage || "The server request failed"))
        root.finishStarred2Waiters(null)
        return
      }
      root.finishStarred2Waiters(Api.subsonicStarredRows(result.data, root.subsonicArt))
    }, { priority: "interactive" })
  }

  function finishStarred2Waiters(rows) {
    var waiters = starred2Waiters
    starred2Waiters = []
    for (var i = 0; i < waiters.length; i++) {
      var waiter = waiters[i]
      if (typeof waiter === "function") {
        try { waiter(rows) } catch (e) { /* consumers own their callbacks */ }
      }
    }
  }

  function loadPlaylists(append, callback, serial) {
    loadLibraryCollection("playlists", append, callback, serial)
  }

  function loadMorePlaylists() {
    loadPlaylists(true)
  }

  function loadSavedTracks(append, callback, serial) {
    loadLibraryCollection("tracks", append, callback, serial)
  }

  function setSavedState(key, value) {
    var id = String(key || "")
    if (!id) return
    rememberSavedStates([id], value === true)
  }

  function rememberSavedStates(keys, values) {
    var rows = Array.isArray(keys) ? keys : []
    var results = Array.isArray(values) ? values : null
    var checkedAt = Date.now()
    var changed = false
    for (var i = 0; i < rows.length; i++) {
      var key = String(rows[i] || "")
      if (!key) continue
      savedUris[key] = results ? results[i] === true : values === true
      savedUriCheckedAt[key] = checkedAt
      var evicted = Api.touchBoundedOrder(savedUriOrder, key,
        savedUriCacheLimit)
      if (evicted) {
        delete savedUris[evicted]
        delete savedUriCheckedAt[evicted]
      }
      changed = true
    }
    if (changed) savedUrisRevision++
  }

  function savedStateIsFresh(key, now) {
    var id = String(key || "")
    if (!id || savedUris[id] === undefined) return false
    return Api.timestampIsFresh(savedUriCheckedAt[id], now,
      savedUriFreshnessMs)
  }

  function markSavedUrisChecking(keys, value) {
    var rows = Array.isArray(keys) ? keys : []
    var changed = false
    for (var i = 0; i < rows.length; i++) {
      var key = String(rows[i] || "")
      if (!key) continue
      if (value === true && savedUrisChecking[key] !== true) {
        savedUrisChecking[key] = true
        changed = true
      } else if (value !== true && savedUrisChecking[key] === true) {
        delete savedUrisChecking[key]
        changed = true
      }
    }
    if (changed) savedUrisCheckingRevision++
  }

  function isSavedChecking(item) {
    return savedUrisCheckingRevision >= 0 && !!item
      && savedUrisChecking[Api.savedKeyFor(item)] === true
  }

  function setSavedBusy(key, value) {
    var id = String(key || "")
    if (!id) return
    if (value === true && savedUrisBusy[id] !== true) {
      savedUrisBusy[id] = true
      savedUrisBusyRevision++
    } else if (value !== true && savedUrisBusy[id] === true) {
      delete savedUrisBusy[id]
      savedUrisBusyRevision++
    }
  }

  function isSavedBusy(item) {
    return savedUrisBusyRevision >= 0 && !!item
      && savedUrisBusy[Api.savedKeyFor(item)] === true
  }

  function markItemsSaved(items, value) {
    var rows = Array.isArray(items) ? items : []
    var keys = []
    for (var i = 0; i < rows.length; i++) {
      var key = Api.savedKeyFor(rows[i])
      if (key) keys.push(key)
    }
    rememberSavedStates(keys, value !== false)
  }

  function isSaved(item) {
    return savedUrisRevision >= 0 && !!item
      && savedUris[Api.savedKeyFor(item)] === true
  }

  // Subsonic rows carry `starred` from the server, so the "is it saved?"
  // check is a read of row state, not a Web API contains round-trip. Rows
  // without star information (an MPRIS-derived now-playing item, say) are
  // skipped entirely so they never overwrite a known state. The bounded
  // cache and freshness machinery stay: fresh entries win, stale ones are
  // refreshed from whatever rows arrive next.
  function checkSavedItems(items, force) {
    var rows = Array.isArray(items) ? items : []
    var values = ({})
    var order = []
    var now = Date.now()
    for (var i = 0; i < rows.length; i++) {
      var item = rows[i]
      if (!item || typeof item !== "object") continue
      var key = Api.savedKeyFor(item)
      if (!key || (item.starred !== true && item.starred !== false)) continue
      if (force !== true && savedStateIsFresh(key, now)) continue
      values[key] = item.starred === true
      order.push(key)
    }
    if (!order.length) return
    rememberSavedStates(order, order.map(function(key) {
      return values[key]
    }))
  }

  // Star actions go through SubsonicApi's mutating-verb path: a write is
  // applied to the local view only after the server confirms it, and an
  // unconfirmed write is reported uncertain without flipping any state.
  function toggleSaved(item) {
    var key = Api.savedKeyFor(item)
    if (!key || isSavedBusy(item)) return
    var type = String((item && item.type) || "track")
    if (["track", "album", "artist"].indexOf(type) < 0) return
    var removing = isSaved(item)
    var params = type === "album" ? { albumId: [String(item.id)] }
      : (type === "artist" ? { artistId: [String(item.id)] }
        : { id: [String(item.id)] })
    setSavedBusy(key, true)
    subsonicApi.request(removing ? "unstar" : "star", params, function(result) {
      root.setSavedBusy(key, false)
      if (!result || result.ok !== true) {
        // Uncertain writes must not flip local state; the typed message
        // explains that the server did not confirm the action.
        root.fail(String(result && result.errorMessage
          || "The server did not confirm the change"))
        return
      }
      root.setSavedState(key, !removing)
      if (type === "song" || type === "track") {
        if (root.savedTracksLoaded) root.loadSavedTracks(false)
        if (root.homeLoaded && root.homeRequestsPending === 0)
          root.loadHomeStarred()
      } else if (type === "album" && root.savedAlbumsLoaded) {
        root.loadSavedAlbums(false)
      } else if (type === "artist" && root.followedArtistsLoaded) {
        root.loadFollowedArtists(false)
      }
    }, { mutating: true, priority: "interactive" })
  }

  // The now-playing row's own star state: checkSavedItems only stores truth
  // a row already carries (a `starred` field), and rows rebuilt from engine
  // state or bare MPRIS metadata carry none. refreshTrackSavedTruth closes
  // that gap with one bounded getSong read per unknown track — the same
  // no-optimistic discipline as every other star surface: nothing flips
  // until the server answers, and a failed read leaves the cache alone.
  property int trackTruthSerial: 0

  function syncCurrentTrackSaved(force) {
    var item = currentTrackItem
    if (!uiVisible || !authManager.loggedIn || !item) return
    checkSavedItems([item], force === true)
    refreshTrackSavedTruth(item)
  }

  function refreshTrackSavedTruth(item) {
    var key = Api.savedKeyFor(item)
    if (!key || String(item.type || "track") !== "track") return
    if (isSavedBusy(item)) return
    if (savedStateIsFresh(key, Date.now())) return
    if (savedUrisChecking[key] === true) return
    var expected = ++trackTruthSerial
    markSavedUrisChecking([key], true)
    subsonicApi.request("getSong", { id: String(item.id) }, function(result) {
      // Clear the checking marker even when a newer track has taken over,
      // so a returning track can still be re-checked later.
      root.markSavedUrisChecking([key], false)
      if (expected !== root.trackTruthSerial) return
      if (!result || result.ok !== true) return
      var song = Subsonic.normalizeSong(result.data && result.data.song
        ? result.data.song : null)
      root.rememberSavedStates([key], [!!song && song.starred === true])
    }, { priority: "interactive" })
  }

  function toggleCurrentTrackSaved() {
    if (!currentTrackSaveAvailable) return
    toggleSaved(currentTrackItem)
  }

  function loadSavedAlbums(append) {
    loadLibraryCollection("albums", append)
  }

  function loadFollowedArtists(append) {
    loadLibraryCollection("artists", append)
  }

  function libraryItems(kind) {
    var value = String(kind || "tracks")
    if (value === "albums") return savedAlbums
    if (value === "artists") return followedArtists
    return savedTracks
  }

  function libraryNext(kind) {
    var value = String(kind || "tracks")
    if (value === "albums") return savedAlbumsNext
    if (value === "artists") return followedArtistsNext
    return savedTracksNext
  }

  function libraryLoading(kind) {
    var value = String(kind || "tracks")
    if (value === "albums") return savedAlbumsLoading
    if (value === "artists") return followedArtistsLoading
    return savedTracksLoading
  }

  function libraryLoaded(kind) {
    var value = String(kind || "tracks")
    if (value === "albums") return savedAlbumsLoaded
    if (value === "artists") return followedArtistsLoaded
    return savedTracksLoaded
  }

  function loadLibrary(kind, append, force) {
    var value = String(kind || "tracks")
    if (append !== true && force !== true && libraryLoaded(value)) return
    loadLibraryCollection(value, append === true)
  }

  function openPlaylist(playlist, restoredItemCount) {
    if (!playlist || !playlist.id) return
    succeed("")
    playlistItemsSerial++
    playlistItemsLoading = false
    playlistRestoreTargetCount = Api.normalizedPlaylistRestoreCount(
      restoredItemCount)
    selectedPlaylist = playlist
    playlistItems = []
    playlistItemsNext = ""
    playlistItemsError = ""
    playlistItemsStatus = 0
    loadPlaylistItems(false)
  }

  function loadPlaylistItems(append) {
    if (!selectedPlaylist || !selectedPlaylist.id || playlistItemsLoading) return
    if (append === true) {
      // getPlaylist is a one-shot read: everything is loaded on the first
      // request, so an append has nothing to fetch.
      playlistRestoreTargetCount = 0
      return
    }
    var playlistId = String(selectedPlaylist.id)
    var expected = dataSerial
    var requestSerial = playlistItemsSerial
    playlistItemsLoading = true
    subsonicApi.request("getPlaylist", { id: playlistId }, function(result) {
      if (expected !== root.dataSerial) return
      if (requestSerial !== root.playlistItemsSerial) return
      if (!root.selectedPlaylist || String(root.selectedPlaylist.id) !== playlistId) return
      root.playlistItemsLoading = false
      if (!result || result.ok !== true) {
        root.playlistRestoreTargetCount = 0
        if (result) {
          root.playlistItemsStatus = 0
          root.playlistItemsError = String(result.errorMessage || "The server request failed")
          root.fail(root.playlistItemsError)
        }
        return
      }
      var parsed = Subsonic.parsePlaylist(result.data)
      if (parsed.playlist) {
        var refreshed = Api.subsonicPlaylistRow(parsed.playlist, root.subsonicArt)
        if (refreshed) root.selectedPlaylist = refreshed
      }
      var rows = []
      for (var i = 0; i < parsed.entries.length; i++) {
        var row = Api.subsonicSongRow(parsed.entries[i], root.subsonicArt)
        if (row) {
          // A playlist can contain the same track more than once; keep every
          // occurrence with its explicit entry position.
          row.playlistPosition = i
          rows.push(row)
        }
      }
      root.playlistItemsError = ""
      root.playlistItemsStatus = 0
      var playlistPage = Api.playlistPageState(root.playlistItems, rows, false, "")
      root.playlistItems = playlistPage.items
      root.playlistItemsNext = ""
      if (Api.playlistRestoreShouldContinue(root.playlistItems.length,
          root.playlistRestoreTargetCount, root.playlistItemsNext))
        root.loadPlaylistItems(true)
      else root.playlistRestoreTargetCount = 0
    }, { priority: "interactive" })
  }

  function loadMorePlaylistItems() {
    loadPlaylistItems(true)
  }

  function ensurePlaylistItemCount(value) {
    if (!selectedPlaylist || !selectedPlaylist.id) return
    var target = Api.normalizedPlaylistRestoreCount(value)
    if (target <= playlistItems.length) return
    playlistRestoreTargetCount = Math.max(playlistRestoreTargetCount, target)
    if (playlistItemsLoading) return
    if (playlistItems.length === 0) loadPlaylistItems(false)
    else if (playlistItemsNext) loadPlaylistItems(true)
    else playlistRestoreTargetCount = 0
  }

  // Playlist verbs map to Subsonic's createPlaylist/updatePlaylist/
  // deletePlaylist param builders. Every write goes through the mutating
  // path: unconfirmed writes report uncertain and never pretend success.
  function createPlaylist(name, callback) {
    var normalized = String(name || "").trim()
    if (!normalized || playlistActionBusy) return
    playlistActionBusy = true
    subsonicApi.request("createPlaylist",
      Subsonic.createPlaylistParams(normalized.slice(0, 100)), function(result) {
        root.playlistActionBusy = false
        if (!result || result.ok !== true) {
          root.fail(String(result && result.errorMessage || "The playlist could not be created"))
          return
        }
        var playlist = Api.subsonicPlaylistRow(
          Subsonic.parsePlaylist(result.data).playlist, root.subsonicArt)
        if (playlist) {
          root.playlists = [playlist].concat(root.playlists)
          root.succeed("Playlist created")
          if (typeof callback === "function") callback(playlist)
        } else {
          root.fail("The playlist was created, but it could not be opened")
          root.loadPlaylists(false)
        }
      }, { mutating: true, priority: "interactive" })
  }

  // Appending uses updatePlaylist's songIdToAdd: createPlaylist with an
  // existing playlist id replaces the whole playlist with the given songs,
  // which is the last-writer-wins primitive used for reorders below.
  function addItemToPlaylist(item, playlist) {
    if (!item || item.type !== "track" || !item.id
        || !playlist || !playlist.id
        || playlistActionBusy) return
    playlistActionBusy = true
    subsonicApi.request("updatePlaylist",
      Subsonic.updatePlaylistParams(String(playlist.id),
        { songIdToAdd: [String(item.id)] }),
      function(result) {
        root.playlistActionBusy = false
        if (!result || result.ok !== true) {
          root.fail(String(result && result.errorMessage || "The song could not be added"))
          return
        }
        root.succeed("Added to " + String(playlist.name || "playlist"))
        if (root.selectedPlaylist && root.selectedPlaylist.id === playlist.id)
          root.loadPlaylistItems(false)
        if (root.detailItem && root.detailItem.id === playlist.id) root.openDetail(root.detailItem)
      }, { mutating: true, priority: "interactive" })
  }

  function registerPlaylistCopy(playlist) {
    if (!playlist) return
    var next = [playlist]
    for (var i = 0; i < playlists.length; i++)
      if (String(playlists[i].id || "") !== String(playlist.id || ""))
        next.push(playlists[i])
    playlists = next
  }

  function finishPlaylistConversion(error) {
    playlistConversionBusy = false
    playlistActionBusy = false
    statusMessage = ""
    if (error) fail(error)
  }

  function removeOriginalAfterCopy(original, copy, expected, callback) {
    subsonicApi.request("deletePlaylist",
      Subsonic.deletePlaylistParams(original.id), function(result) {
        if (expected !== root.dataSerial) return
        var next = []
        for (var i = 0; i < root.playlists.length; i++) {
          var candidate = root.playlists[i]
          if (String(candidate.id || "") !== String(original.id || "")) next.push(candidate)
        }
        root.playlists = next
        if (!result || result.ok !== true) {
          // Uncertain delete: the copy exists; removing the original did not
          // confirm, so say exactly that and let the user look at the list.
          root.finishPlaylistConversion("Your copy is ready, but removing the original did not confirm. Check your playlists.")
          return
        }
        root.finishPlaylistConversion("")
        root.succeed("Your playlist is ready")
        if (typeof callback === "function") callback(copy)
      }, { mutating: true, priority: "interactive" })
  }

  function makePlaylistYourOwn(playlist, callback) {
    if (!playlist || playlist.type !== "playlist" || !playlist.id
        || playlistOwned(playlist) || playlistActionBusy) return
    var expected = dataSerial
    playlistActionBusy = true
    playlistConversionBusy = true
    lastError = ""
    statusClearTimer.stop()
    statusMessage = "Reading " + String(playlist.name || "playlist") + "…"
    // getPlaylist is one shot, so the copy flow needs no paging dance.
    subsonicApi.request("getPlaylist", { id: String(playlist.id) },
      function(readResult) {
        if (expected !== root.dataSerial) return
        if (!readResult || readResult.ok !== true) {
          root.finishPlaylistConversion(String(readResult && readResult.errorMessage
            || "This playlist could not be copied. The original was left untouched."))
          return
        }
        var entries = Subsonic.parsePlaylist(readResult.data).entries
        var ids = Api.playlistItemIds(entries.map(function(node) {
          var row = Api.subsonicSongRow(node, root.subsonicArt)
          return row
        }))
        root.statusMessage = "Creating your playlist…"
        subsonicApi.request("createPlaylist",
          Subsonic.createPlaylistParams(
            String(playlist.name || "My playlist").slice(0, 100), ids),
          function(createResult) {
            if (expected !== root.dataSerial) return
            if (!createResult || createResult.ok !== true) {
              root.finishPlaylistConversion(String(createResult && createResult.errorMessage
                || "The playlist could not be created. The original was left untouched."))
              return
            }
            var copy = Api.subsonicPlaylistRow(
              Subsonic.parsePlaylist(createResult.data).playlist, root.subsonicArt)
            if (!copy) {
              root.finishPlaylistConversion("The playlist was created, but it could not be opened")
              return
            }
            root.registerPlaylistCopy(copy)
            root.statusMessage = "Removing the original from your library…"
            root.removeOriginalAfterCopy(playlist, copy, expected, callback)
          }, { mutating: true, priority: "interactive" })
      }, { priority: "interactive" })
  }

  function reloadPlaylist(playlist) {
    if (!playlist) return
    var restoredDetailItemCount = detailRememberedItemCount
    if (selectedPlaylist && selectedPlaylist.id === playlist.id) {
      var restoredItemCount = playlistRememberedItemCount
      playlistItemsSerial++
      playlistItemsLoading = false
      playlistRestoreTargetCount = restoredItemCount
      playlistItems = []
      playlistItemsNext = ""
      playlistItemsError = ""
      playlistItemsStatus = 0
      loadPlaylistItems(false)
    }
    if (detailItem && detailItem.type === "playlist" && detailItem.id === playlist.id)
      openDetail(detailItem, "", restoredDetailItemCount)
  }

  // Subsonic removes by index inside updatePlaylist; the index is the entry
  // position, which the playlist rows carry as playlistPosition.
  function removePlaylistItem(item, index, playlist) {
    var target = playlist || selectedPlaylist
    if (!item || !item.id || !playlistEditable(target) || playlistActionBusy) return
    var position = item.playlistPosition !== undefined
      && item.playlistPosition !== null
      ? Math.floor(Number(item.playlistPosition) || 0)
      : Math.floor(Number(index) || 0)
    if (position < 0) return
    playlistActionBusy = true
    subsonicApi.request("updatePlaylist",
      Subsonic.updatePlaylistParams(String(target.id),
        { songIndexToRemove: [String(position)] }), function(result) {
        root.playlistActionBusy = false
        if (!result || result.ok !== true) {
          root.fail(String(result && result.errorMessage || "The server did not confirm the removal"))
          return
        }
        root.succeed("Removed from playlist")
        root.reloadPlaylist(target)
      }, { mutating: true, priority: "interactive" })
  }

  function requestPlaylistItemReorder(sourceIndex, destinationIndex, playlist, count,
      sourceItems) {
    var target = playlist || selectedPlaylist
    if (!playlistEditable(target) || playlistActionBusy) return
    var orderingItems = Array.isArray(sourceItems) && sourceItems.length
      ? sourceItems
      : (selectedPlaylist && String(selectedPlaylist.id || "") === String(target.id || "")
        ? playlistItems : [])
    var length = Math.max(0, Math.floor(Number(count) || orderingItems.length))
    if (orderingItems.length < 2 || sourceIndex < 0 || sourceIndex >= orderingItems.length
        || destinationIndex < 0 || destinationIndex >= orderingItems.length
        || sourceIndex === destinationIndex) return
    // Subsonic has no positional reorder. The pattern proven across Subsonic
    // clients (play:Sub, DSub) is last-writer-wins: re-issue createPlaylist
    // with the existing playlist id and the full song list in the new order,
    // which replaces the playlist contents in one write.
    var reordered = Api.reorderedPlaylistItemsAtPositions(orderingItems,
      sourceIndex, destinationIndex)
    var ids = []
    for (var i = 0; i < reordered.length; i++) {
      var id = String((reordered[i] && reordered[i].id) || "")
      if (id) ids.push(id)
    }
    if (!ids.length) return

    var playlistId = String(target.id || "")
    var previousPlaylistItems = playlistItems
    var previousDetailItems = detailItems
    var selectedMatches = selectedPlaylist
      && String(selectedPlaylist.id || "") === playlistId
    var detailMatches = detailItem && detailItem.type === "playlist"
      && String(detailItem.id || "") === playlistId
    if (selectedMatches)
      playlistItems = Api.reorderedPlaylistItemsAtPositions(playlistItems,
        sourceIndex, destinationIndex)
    if (detailMatches)
      detailItems = Api.reorderedPlaylistItemsAtPositions(detailItems,
        sourceIndex, destinationIndex)

    playlistActionBusy = true
    subsonicApi.request("createPlaylist",
      Subsonic.createPlaylistParams(null, ids, playlistId),
      function(result) {
        root.playlistActionBusy = false
        if (!result || result.ok !== true) {
          // Uncertain write: restore the displayed order so the view never
          // claims a mutation the server did not confirm.
          if (selectedMatches && root.selectedPlaylist
              && String(root.selectedPlaylist.id || "") === playlistId)
            root.playlistItems = previousPlaylistItems
          if (detailMatches && root.detailItem && root.detailItem.type === "playlist"
              && String(root.detailItem.id || "") === playlistId)
            root.detailItems = previousDetailItems
          root.fail(String(result && result.errorMessage || "The server did not confirm the move"))
          return
        }
        root.succeed("Playlist order updated")
        root.reloadPlaylist(target)
      }, { mutating: true, priority: "interactive" })
  }

  function reorderPlaylistItem(sourceIndex, destinationIndex, playlist, count,
      sourceItems) {
    var target = playlist || selectedPlaylist
    if (!playlistOwned(target)) return
    requestPlaylistItemReorder(sourceIndex, destinationIndex, target, count,
      sourceItems)
  }

  function movePlaylistItem(index, delta, playlist, count) {
    var source = Math.max(0, Math.floor(Number(index) || 0))
    var direction = Number(delta || 0) < 0 ? -1 : 1
    requestPlaylistItemReorder(source, source + direction,
      playlist || selectedPlaylist, count)
  }

  // Detail pages map one Subsonic verb each: album → getAlbum (its tracks),
  // playlist → getPlaylist (its entries), artist → getArtist + getTopSongs.
  // All are one-shot reads; `detailNext` stays "" and there is no cursor
  // pagination anywhere.
  function openDetail(item, requestedArtistQuery, restoredItemCount) {
    if (!item || !item.id || item.kind !== "context") return
    var type = String(item.type || "")
    if (["artist", "album", "playlist"].indexOf(type) < 0) return
    var serial = ++detailSerial
    detailRestoreTargetCount = 0
    detailItem = item
    detailItems = []
    detailNext = ""
    detailMessage = ""
    artistCatalogSerial++
    var initialArtistQuery = type === "artist" ? String(requestedArtistQuery || "") : ""
    artistCatalogQuery = initialArtistQuery
    artistAlbums = []
    artistAlbumsNext = ""
    artistAlbumsLoading = false
    artistSongs = []
    artistSongsNext = ""
    artistSongsLoading = false
    detailLoading = true
    activeView = "detail"
    checkSavedItems([item])

    if (type === "artist") {
      // getArtist answers the discography; getTopSongs answers the popular
      // songs the artist page's songs section shows.
      root.findArtistMusic(initialArtistQuery, serial, item)
      return
    }
    var endpoint = type === "album" ? "getAlbum" : "getPlaylist"
    var params = type === "album" ? { id: String(item.id) } : { id: String(item.id) }
    subsonicApi.request(endpoint, params, function(result) {
      if (serial !== root.detailSerial) return
      root.detailLoading = false
      if (!result || result.ok !== true) {
        root.detailRestoreTargetCount = 0
        root.fail(String(result && result.errorMessage || "The server request failed"))
        return
      }
      if (endpoint === "getAlbum") {
        var parsedAlbum = Subsonic.parseAlbum(result.data)
        if (parsedAlbum.album) {
          var refreshed = Api.subsonicAlbumRow(parsedAlbum.album, root.subsonicArt)
          if (refreshed) root.detailItem = refreshed
        }
        var rows = []
        for (var i = 0; i < parsedAlbum.songs.length; i++) {
          var row = Api.subsonicSongRow(parsedAlbum.songs[i], root.subsonicArt,
            root.detailItem)
          if (row) rows.push(row)
        }
        root.detailItems = rows
      } else {
        var parsedPlaylist = Subsonic.parsePlaylist(result.data)
        if (parsedPlaylist.playlist) {
          var playlist = Api.subsonicPlaylistRow(parsedPlaylist.playlist,
            root.subsonicArt)
          if (playlist) root.detailItem = playlist
        }
        var entries = []
        for (var j = 0; j < parsedPlaylist.entries.length; j++) {
          var entry = Api.subsonicSongRow(parsedPlaylist.entries[j],
            root.subsonicArt)
          if (entry) {
            entry.playlistPosition = j
            entries.push(entry)
          }
        }
        root.detailItems = entries
      }
      root.checkSavedItems(root.detailItems)
    }, { priority: "interactive" })
  }

  // Artist page data: the discography comes from getArtist's album list,
  // and the songs section from getTopSongs. While the artist page filter is
  // active, both sections become bounded search3 windows over a plain text
  // query (artist name + filter) — Subsonic has no artist-scoped Lucene.
  function findArtistMusic(query, serial, artist) {
    var parent = artist || detailItem
    if (!parent || parent.type !== "artist" || !parent.name) return
    var expectedDetail = serial === undefined ? detailSerial : serial
    var expectedCatalog = ++artistCatalogSerial
    artistCatalogQuery = String(query || "").trim()
    artistAlbums = []
    artistAlbumsNext = ""
    artistAlbumsLoading = false
    artistSongs = []
    artistSongsNext = ""
    artistSongsLoading = false
    detailMessage = ""
    detailLoading = true
    requestArtistCatalog(false, expectedDetail, expectedCatalog, parent)
    requestArtistTopSongs(false, expectedDetail, expectedCatalog, parent, 0)
  }

  function artistSearchTerm(artist) {
    var name = String(artist && artist.name || "").trim()
    var filter = Api.sanitizeSearchTerm(artistCatalogQuery)
    return name && filter ? name + " " + filter : name
  }

  // The artist discography: getArtist answers the album list without a
  // filter; with one, a bounded search3 window over "artist name + filter"
  // stands in (Subsonic has no artist-scoped Lucene).
  function requestArtistCatalog(append, expectedDetail, expectedCatalog,
      artist) {
    if (!artist || !artist.id) return
    artistAlbumsLoading = true
    if (!artistCatalogQuery) {
      subsonicApi.request("getArtist", { id: String(artist.id) },
        function(result) {
          if (expectedDetail !== root.detailSerial
              || expectedCatalog !== root.artistCatalogSerial) return
          root.artistAlbumsLoading = false
          root.detailLoading = root.artistCatalogLoading
          if (!result || result.ok !== true) {
            root.fail(String(result && result.errorMessage || "The server request failed"))
            return
          }
          var parsed = Subsonic.parseArtist(result.data)
          var rows = []
          for (var i = 0; i < parsed.albums.length; i++) {
            var row = Api.subsonicAlbumRow(parsed.albums[i], root.subsonicArt)
            if (row) rows.push(row)
          }
          root.applyArtistCatalogPage(append, { items: rows, next: "" })
        }, { priority: "interactive" })
      return
    }
    subsonicApi.search3(root.artistSearchTerm(artist),
      Api.search3WindowParams("album", 0), function(result) {
        if (expectedDetail !== root.detailSerial
            || expectedCatalog !== root.artistCatalogSerial) return
        root.artistAlbumsLoading = false
        root.detailLoading = root.artistCatalogLoading
        if (!result || result.ok !== true) {
          root.fail(String(result && result.errorMessage || "The server request failed"))
          return
        }
        var rows = []
        var albumsFound = result.results && result.results.albums
          ? result.results.albums : []
        for (var i = 0; i < albumsFound.length; i++) {
          var row = Api.subsonicAlbumRow(albumsFound[i], root.subsonicArt)
          if (row) rows.push(row)
        }
        root.applyArtistCatalogPage(append, { items: rows, next: "" })
      })
  }

  function applyArtistCatalogPage(append, page) {
    var items = (append ? Api.mergeUnique(artistAlbums, page.items) : page.items)
    artistAlbums = items
    artistAlbumsNext = page.next
    checkSavedItems(page.items)
  }

  function requestArtistTopSongs(append, expectedDetail, expectedCatalog, artist,
      automaticPage) {
    if (!artist || !artist.id) return
    artistSongsLoading = true
    if (!artistCatalogQuery) {
      // getTopSongs arrives under artist.topSongs in Navidrome's getArtist
      // answer; it needs Last.fm integration on the server, so an artist
      // without one parses to an empty list, never an error.
      subsonicApi.request("getTopSongs", { artist: String(artist.id) },
        function(result) {
          if (expectedDetail !== root.detailSerial || expectedCatalog !== root.artistCatalogSerial)
            return
          if (result && result.ok !== true) {
            root.artistSongsLoading = false
            root.detailLoading = root.artistCatalogLoading
            root.fail(String(result.errorMessage || "The server request failed"))
            return
          }
          var topSongs = Subsonic.parseTopSongs(result.data)
          var matching = []
          for (var i = 0; i < topSongs.length && matching.length < 10; i++) {
            var row = Api.subsonicSongRow(topSongs[i], root.subsonicArt)
            if (row) matching.push(row)
          }
          root.artistSongs = Api.mergeUnique(append ? root.artistSongs : [],
            matching).slice(0, 10)
          root.checkSavedItems(matching)
          root.artistSongsNext = ""
          root.artistSongsLoading = false
          root.detailLoading = root.artistCatalogLoading
        }, { priority: "interactive" })
      return
    }
    subsonicApi.search3(root.artistSearchTerm(artist),
      Api.search3WindowParams("track", 0), function(result) {
        if (expectedDetail !== root.detailSerial || expectedCatalog !== root.artistCatalogSerial)
          return
        if (result && result.ok !== true) {
          root.artistSongsLoading = false
          root.detailLoading = root.artistCatalogLoading
          root.fail(String(result.errorMessage || "The server request failed"))
          return
        }
        var found = result.results && result.results.songs
          ? result.results.songs : []
        var matching = []
        for (var i = 0; i < found.length && matching.length < 10; i++) {
          var row = Api.subsonicSongRow(found[i], root.subsonicArt)
          if (row) matching.push(row)
        }
        root.artistSongs = Api.mergeUnique(append ? root.artistSongs : [],
          matching).slice(0, 10)
        root.checkSavedItems(matching)
        root.artistSongsNext = ""
        root.artistSongsLoading = false
        root.detailLoading = root.artistCatalogLoading
      })
  }

  function loadMoreArtistAlbums() {
    if (artistAlbumsLoading || !detailItem) return
    requestArtistCatalog(true, detailSerial, artistCatalogSerial, detailItem)
  }

  function loadMoreArtistSongs() {
    // Top songs arrive complete; there is no continuation window.
    if (artistSongsLoading || !detailItem) return
    requestArtistTopSongs(true, detailSerial, artistCatalogSerial, detailItem, 0)
  }

  function loadMoreDetail() {
    // Every Subsonic detail page is a one-shot read; the restore loop the
    // Web API playlist pages needed simply drains.
    detailRestoreTargetCount = 0
  }

  function ensureDetailItemCount(value) {
    if (!detailItem) return
    detailRestoreTargetCount = 0
  }

  // Footer context buttons: "go to artist" and "go to album" of the current
  // track. A live row (library playback) carries ids directly; metadata from
  // MPRIS alone resolves through a bounded search3 by name.
  function currentContext(kind, callback) {
    if (typeof callback !== "function") return
    if (kind === "artist" && currentArtists.length) {
      var cachedArtist = currentArtists[0]
      if (cachedArtist.id) callback(cachedArtist)
      else resolveArtist(cachedArtist.name, callback)
      return
    }
    if (kind === "album" && currentAlbumItem && currentAlbumItem.id) {
      callback(currentAlbumItem)
      return
    }
    if (kind === "artist" && currentArtistContextAvailable) {
      resolveArtist(artist, callback)
      return
    }
    if (kind === "album" && album) resolveAlbum(album, callback)
  }

  function resolveArtist(name, callback) {
    var term = String(name || "").trim()
    if (!term || typeof callback !== "function") return
    subsonicApi.search3(term, Api.search3WindowParams("artist", 0),
      function(result) {
        if (!result || result.ok !== true) {
          root.fail(String(result && result.errorMessage || "The server request failed"))
          return
        }
        var rows = result.results && result.results.artists
          ? result.results.artists : []
        var match = Api.artistForName(
          rows.map(function(node) {
            var row = Api.subsonicArtistRow(node, root.subsonicArt)
            return row
          }).filter(function(row) { return !!row }), term)
        if (!match) {
          root.fail("The server could not find that artist")
          return
        }
        root.checkSavedItems([match])
        callback(match)
      })
  }

  function resolveAlbum(name, callback) {
    var term = String(name || "").trim()
    if (!term || typeof callback !== "function") return
    subsonicApi.search3(term, Api.search3WindowParams("album", 0),
      function(result) {
        if (!result || result.ok !== true) {
          root.fail(String(result && result.errorMessage || "The server request failed"))
          return
        }
        var found = result.results && result.results.albums
          ? result.results.albums : []
        var rows = []
        for (var i = 0; i < found.length; i++) {
          var row = Api.subsonicAlbumRow(found[i], root.subsonicArt)
          if (row) rows.push(row)
        }
        var wanted = term.toLowerCase()
        var match = null
        for (var j = 0; j < rows.length; j++) {
          if (String(rows[j].name || "").trim().toLowerCase() === wanted) {
            match = rows[j]
            break
          }
        }
        if (!match && rows.length) match = rows[0]
        if (!match) {
          root.fail("The server could not find that album")
          return
        }
        root.checkSavedItems([match])
        callback(match)
      })
  }

  // Home becomes the plan's getAlbumList2 windows — recently played,
  // frequently played, and newest albums — plus the starred-song window from
  // getStarred2. Four bounded reads, one per window, all user-priority.
  function finishHomeRequest(error) {
    homeRequestsPending = Math.max(0, homeRequestsPending - 1)
    if (error) fail(error)
    if (homeRequestsPending === 0) {
      homeLoaded = true
      checkSavedItems(homeRecent.concat(homeFrequent).concat(homeNewest)
        .concat(homeStarred))
    }
  }

  function requestHomeAlbumWindow(listName, type, expected) {
    subsonicApi.request("getAlbumList2",
      Subsonic.albumList2Params(type, 30, 0), function(result) {
        if (expected !== root.dataSerial) {
          root.finishHomeRequest(null)
          return
        }
        if (result && result.ok === true) {
          root[listName] = Api.subsonicAlbumListRows(result.data, root.subsonicArt)
        } else {
          root[listName] = []
        }
        root.finishHomeRequest(result && result.ok === true
          ? null : String(result && result.errorMessage || "The server request failed"))
      }, { priority: "interactive" })
  }

  function loadHome() {
    if (homeLoading) return
    var expected = dataSerial
    homeLoaded = false
    homeRequestsPending = 4
    requestHomeAlbumWindow("homeRecent", "recent", expected)
    requestHomeAlbumWindow("homeFrequent", "frequent", expected)
    requestHomeAlbumWindow("homeNewest", "newest", expected)
    loadHomeStarred(expected)
  }

  // The starred window shares the single getStarred2 pass with the library
  // collections: one server read, several consumers.
  function loadHomeStarred(expected) {
    var serial = expected === undefined ? dataSerial : expected
    loadStarred2IfNeeded(serial, function(filled) {
      if (serial !== root.dataSerial) {
        root.finishHomeRequest(null)
        return
      }
      root.homeStarred = filled ? filled.songs.slice(0, 100) : []
      root.finishHomeRequest(filled ? null
        : "The starred list could not be loaded")
    })
  }

  function homeItems(kind) {
    var value = String(kind || "recent")
    if (value === "frequent") return homeFrequent
    if (value === "newest") return homeNewest
    if (value === "starred") return homeStarred
    return homeRecent
  }

  // Genre browsing (Explore): one genre name drives a byGenre getAlbumList2
  // window; "Load more" and the FilterScanController pacing in the view ask
  // for the next offset until a window comes back short.
  property string discoverGenre: ""
  property var genreAlbums: []
  property string genreAlbumsNext: ""
  property bool genreAlbumsLoading: false
  property int genreSerial: 0

  function openDiscoverGenre(name) {
    var value = String(name || "").trim()
    // Re-selecting the current genre re-fetches, so Refresh stays honest.
    var expected = ++genreSerial
    discoverGenre = value
    genreAlbums = []
    genreAlbumsNext = ""
    genreAlbumsLoading = value !== ""
    if (!value) return
    requestGenreAlbumWindow(value, 0, expected)
  }

  function requestGenreAlbumWindow(genre, offset, expected) {
    subsonicApi.request("getAlbumList2",
      Subsonic.albumList2Params("byGenre", 30, offset, { genre: genre }),
      function(result) {
        if (expected !== root.genreSerial) return
        root.genreAlbumsLoading = false
        if (!result || result.ok !== true) {
          root.fail(String(result && result.errorMessage || "The server request failed"))
          return
        }
        var rows = Api.subsonicAlbumListRows(result.data, root.subsonicArt)
        // A full window promises a continuation; a short one is the end.
        root.genreAlbumsNext = rows.length >= 30 ? String(offset + 30) : ""
        root.genreAlbums = offset > 0
          ? Api.mergeUnique(root.genreAlbums, rows) : rows
        root.checkSavedItems(rows)
      }, { priority: "interactive" })
  }

  function loadMoreGenreAlbums() {
    if (!discoverGenre || genreAlbumsLoading || genreAlbumsNext === "") return
    var expected = genreSerial
    var offset = Math.max(0, Math.floor(Number(genreAlbumsNext) || 0))
    genreAlbumsLoading = true
    requestGenreAlbumWindow(discoverGenre, offset, expected)
  }

  function clearGenreBrowse() {
    genreSerial++
    discoverGenre = ""
    genreAlbums = []
    genreAlbumsNext = ""
    genreAlbumsLoading = false
  }

  // Explore keeps the discovery role with Navidrome content: a random-album
  // window and the genre list. The genre scan machinery from
  // FilterScanController stays for the genre browser (view pass).
  function finishDiscoverRequest(error) {
    if (error) discoverRequestsFailed++
    discoverRequestsPending = Math.max(0, discoverRequestsPending - 1)
    if (discoverRequestsPending > 0) return
    discoverLoaded = true
    checkSavedItems(discoverAlbums)
    if (!discoverAlbums.length) {
      discoverMessage = discoverRequestsFailed > 0
        ? "The server could not load random albums. Try Refresh."
        : "No random albums were returned. Try Refresh later."
    }
  }

  function loadDiscover() {
    if (discoverLoading) return
    var expectedData = dataSerial
    var expectedDiscover = ++discoverSerial
    discoverLoaded = false
    discoverMessage = ""
    discoverRequestsFailed = 0
    discoverRequestsPending = 2
    subsonicApi.request("getAlbumList2",
      Subsonic.albumList2Params("random", 30, 0), function(result) {
        if (expectedData !== root.dataSerial
            || expectedDiscover !== root.discoverSerial) {
          root.finishDiscoverRequest(null)
          return
        }
        if (result && result.ok === true)
          root.discoverAlbums = Api.subsonicAlbumListRows(result.data, root.subsonicArt)
        else root.discoverAlbums = []
        root.finishDiscoverRequest(result && result.ok === true
          ? null : String(result && result.errorMessage || "The server request failed"))
      }, { priority: "interactive" })
    subsonicApi.request("getGenres", {}, function(result) {
      if (expectedData !== root.dataSerial
          || expectedDiscover !== root.discoverSerial) {
        root.finishDiscoverRequest(null)
        return
      }
      root.discoverGenres = result && result.ok === true
        ? Subsonic.parseGenres(result.data) : []
      root.finishDiscoverRequest(null)
    }, { priority: "interactive" })
  }

  // The live queue is engine-owned; its honest QML-side source is the
  // server-persisted play queue the engine keeps saving (bounded debounce).
  // SongRefs map back to canonical rows so the queue view renders like any
  // other list.
  function loadQueue(callback, serial) {
    if (queueLoading) {
      if (typeof callback === "function") callback()
      return
    }
    var expected = serial === undefined ? dataSerial : serial
    queueLoading = true
    backendClient.sendCommand("get_saved_queue", null, function(ok, result, error) {
      if (expected !== root.dataSerial) {
        root.queueLoading = false
        if (typeof callback === "function") callback()
        return
      }
      root.queueLoading = false
      if (!ok) {
        root.fail(error || "The queue could not be read")
        if (typeof callback === "function") callback()
        return
      }
      var saved = result && typeof result === "object" ? result : ({})
      var songs = Api.arrayValues(saved.songs)
      var next = []
      for (var i = 0; i < songs.length && next.length < Api.PLAYBACK_URI_LIMIT; i++) {
        var row = Api.subsonicSongRefRow(songs[i])
        if (row) next.push(row)
      }
      root.queue = next
      root.queueLoaded = true
      if (typeof callback === "function") callback()
    })
  }

  SearchController {
    id: searchController
    api: subsonicApi
    subsonicArt: root.subsonicArt
    dataSerial: root.dataSerial
    onRememberSearch: term => root.rememberSearch(term)
    onCheckSavedItems: items => root.checkSavedItems(items)
  }

  property var playerSurfaces: []
  function registerPlayerSurface(surface) {
    if (playerSurfaces.indexOf(surface) < 0)
      playerSurfaces = playerSurfaces.concat([surface])
  }
  function unregisterPlayerSurface(surface) {
    playerSurfaces = playerSurfaces.filter(function(item) { return item && item !== surface })
  }
  function shortcutSurface() {
    var focused = Hyprland.focusedMonitor
    for (var i = 0; i < playerSurfaces.length; i++) {
      var surface = playerSurfaces[i]
      var window = surface ? surface.QsWindow.window : null
      if (window && window.screen && focused && window.screen.name === focused.name)
        return surface
    }
    return playerSurfaces.length ? playerSurfaces[0] : null
  }
  function invokePlayerShortcut(method) {
    var surface = shortcutSurface()
    return surface && typeof surface[method] === "function"
      ? surface[method]() : "unavailable"
  }
  IpcHandler {
    target: "quickshell.navidrome.player"
    function configuredPlayer(): string { return root.shortcutPlayer }
    function togglePlayer(): string { return root.invokePlayerShortcut("toggleConfiguredPlayerShortcut") }
    function toggleMiniPlayer(): string { return root.invokePlayerShortcut("toggleMiniPlayerShortcut") }
    function toggleFullPlayer(): string { return root.invokePlayerShortcut("toggleFullPlayerShortcut") }
    function volumeUp(): string {
      var surface = root.shortcutSurface()
      return surface && surface.adjustVolume(0.05) ? "ok" : "unavailable"
    }
    function volumeDown(): string {
      var surface = root.shortcutSurface()
      return surface && surface.adjustVolume(-0.05) ? "ok" : "unavailable"
    }
  }

  function search(term, type, force) { return searchController.search(term, type, force) }
  function searchItems(type) { return searchController.searchItems(type) }
  function searchNext(type) { return searchController.searchNext(type) }
  function loadMoreSearch(type) { return searchController.loadMoreSearch(type) }
  function retrySearch(type) { return searchController.retrySearch(type) }
  function clearSearch() { return searchController.clearSearch() }
  function cancelSearch(clearResults) { return searchController.cancelSearch(clearResults) }

  function cancelArtistCatalog() {
    artistCatalogSerial++
    artistAlbumsLoading = false
    artistSongsLoading = false
    detailLoading = false
  }

  function clearPendingPlayback(keepActivation) {
    pendingPlaybackLoad = null
    pendingPlaybackMessage = ""
    pendingPlaybackRadio = null
    pendingPlaybackSerial = 0
    if (keepActivation !== true) localActivationRequested = false
  }

  // Playback starts on this computer only: the Navidrome engine is the
  // receiver. Bring it up when needed and hand the v2 load over as soon as
  // the socket is ready.
  function dispatchPendingPlayback(playbackSerial) {
    if (playbackSerial !== pendingPlaybackSerial || !pendingPlaybackLoad) return
    if (backendClient.ready || daemonManager.playbackReady) {
      waitForLocalSocketThenPlay(playbackSerial)
      return
    }
    if (!daemonManager.binaryAvailable || !daemonManager.unitAvailable) {
      fail("Playback on this computer needs to be set up in Settings")
      clearPendingPlayback()
      return
    }
    daemonManager.start()
    waitForLocalSocketThenPlay(playbackSerial)
  }

  function waitForLocalSocketThenPlay(playbackSerial) {
    if (playbackSerial !== pendingPlaybackSerial || !pendingPlaybackLoad) return
    if (backendClient.ready) {
      sendLocalSocketPlayback(playbackSerial)
      return
    }
    if (!daemonManager.binaryAvailable || !daemonManager.unitAvailable) {
      fail("Playback on this computer needs to be set up in Settings")
      clearPendingPlayback()
      return
    }
    if (!daemonManager.running && !daemonManager.busy) daemonManager.start()
    localSocketWaitAttempts = 0
    localSocketWaitTimer.restart()
  }

  function sendLocalSocketPlayback(playbackSerial) {
    if (playbackSerial !== pendingPlaybackSerial || !pendingPlaybackLoad) return
    var load = pendingPlaybackLoad
    var successMessage = pendingPlaybackMessage
    clearPendingPlayback()
    localSocketWaitTimer.stop()
    // Credentials must precede load/add_to_queue on a fresh connection.
    ensureBackendServerConfigured()
    localLoadInFlight = true
    backendClient.loadPlayback(load, function(ok, result, error) {
      localLoadInFlight = false
      if (ok) {
        if (successMessage) root.succeed(successMessage)
        root.loadQueue()
        return
      }
      if (backendClient.credentialFailure) {
        // Credential-class failures are terminal: no retry loop — the typed
        // state is surfaced for the setup UI instead.
        root.clearPendingPlayback()
        root.fail(Subsonic.backendCredentialMessage(backendClient.commandErrorCode)
          || error || "Playback on this computer is not set up")
        return
      }
      root.clearPendingPlayback()
      root.fail(error || "Playback on this computer could not start this song")
    })
  }

  // Playback rows are Subsonic songs. The v2 load body is built from the
  // visible list starting at the clicked row, so Next walks the displayed
  // order exactly as before. Context rows (album/playlist/artist) have no
  // server-side context to hand over: their full list is fetched first, then
  // queued from the top.
  function playItem(item, sourceItems, successMessage) {
    localPlaybackStopped = false
    var playbackSerial = ++radioSerial
    if (item && item.kind === "context") {
      playContextItem(item, successMessage, playbackSerial)
      return
    }
    var load = Api.playbackLoadBodyV2(item, sourceItems,
      item ? item.resumeMs : 0)
    if (!load) {
      fail("This song cannot be played")
      return
    }
    beginPlaybackLoad(load, item, successMessage, playbackSerial)
  }

  function beginPlaybackLoad(load, anchorItem, successMessage, playbackSerial) {
    void anchorItem
    pendingPlaybackLoad = load
    pendingPlaybackMessage = String(successMessage || "")
    pendingPlaybackRadio = null
    pendingPlaybackSerial = playbackSerial
    localActivationRequested = true
    noteActivity()

    dispatchPendingPlayback(playbackSerial)
  }

  function playContextItem(item, successMessage, playbackSerial) {
    if (!item || !item.id) {
      fail("This collection cannot be played")
      return
    }
    var type = String(item.type || "")
    var endpoint = type === "album" ? "getAlbum"
      : (type === "playlist" ? "getPlaylist"
        : (type === "artist" ? "getTopSongs" : ""))
    if (!endpoint) {
      fail("This collection cannot be played")
      return
    }
    var params = endpoint === "getTopSongs" ? { artist: String(item.id) }
      : { id: String(item.id) }
    succeed("Queuing " + String(item.name || "the collection") + "…")
    subsonicApi.request(endpoint, params, function(result) {
      if (playbackSerial !== root.radioSerial) return
      if (!result || result.ok !== true) {
        root.fail(String(result && result.errorMessage || "The collection could not be loaded"))
        return
      }
      var songs = endpoint === "getAlbum" ? Subsonic.parseAlbum(result.data).songs
        : (endpoint === "getPlaylist" ? Subsonic.parsePlaylist(result.data).entries
          : Subsonic.parseTopSongs(result.data))
      var rows = []
      for (var i = 0; i < songs.length && rows.length < Api.PLAYBACK_URI_LIMIT; i++) {
        var row = Api.subsonicSongRow(songs[i], root.subsonicArt)
        if (row) rows.push(row)
      }
      var load = Api.backendLoadFieldsV2(rows, { play: true, offset_index: 0 })
      if (!load) {
        root.fail("This collection has no playable songs")
        return
      }
      root.beginPlaybackLoad(load, rows[0], successMessage, playbackSerial)
    }, { priority: "interactive" })
  }

  // Protocol v2: configure_server must be sent once per backend connection
  // before any load/add_to_queue. Runs whenever the backend becomes ready
  // (including after a reconnect, whose credentials re-send hooks off the
  // serverConfigured flag). Empty credentials mean setup has not landed yet;
  // the backend then answers playback commands with `missing_credentials`.
  // Inputs are deliberately never logged.
  function ensureBackendServerConfigured() {
    if (!backendClient.connected || backendClient.serverConfigured) return
    if (backendClient.lifecycle !== "ready") return
    var credentials = authManager.navidromeCredentials()
    if (!credentials.url || !credentials.username || !credentials.password)
      return
    backendClient.configureServer(credentials.url, credentials.username,
      credentials.password, function(ok, result, error) {
        if (!ok) {
          root.fail(error || "Could not configure the Navidrome server")
          return
        }
        // Interim restore trigger (package 5 binds the real resume UI):
        // once the backend knows the server, offer the saved queue back.
        root.restoreSavedSession(null)
      })
  }

  // Saved-session restore (package 4 machinery; package 5 binds the button):
  // the backend's get_saved_queue answer is the preferred source — the play
  // queue and its position come straight from the server while the
  // credentials never leave the engine — and a bookmark refines the exact
  // position of a partially played current song. The queue is loaded paused
  // through the regular v2 path, so pressing Play resumes where the last
  // session stopped. The one-attempt-per-session guard plus the idle check
  // keep a reconnect from clobbering live playback.
  property bool restoreAttempted: false
  // A v2 load push is on the wire: no restore may race it.
  property bool localLoadInFlight: false

  function backendIdleForRestore() {
    if (hasMedia) return false
    var state = backendClient.lastState
    if (state && (state.playback === "playing" || state.playback === "loading"))
      return false
    return !pendingPlaybackLoad && !localLoadInFlight && !localActivationRequested
  }

  function restoreSavedSession(callback) {
    if (!backendClient.connected || !backendClient.serverConfigured
        || !authManager.loggedIn || restoreAttempted || !backendIdleForRestore()) {
      if (typeof callback === "function") callback(false)
      return false
    }
    restoreAttempted = true
    backendClient.sendCommand("get_saved_queue", null, function(ok, result, error) {
      if (!ok) {
        if (typeof callback === "function") callback(false)
        return
      }
      var saved = result && typeof result === "object" ? result : ({})
      var queuePlan = {
        songs: Api.arrayValues(saved.songs),
        current: String(saved.current_id || ""),
        position: Number(saved.position_ms) || 0
      }
      subsonicApi.request("getBookmarks", {}, function(bookmarkResult) {
        var marks = bookmarkResult && bookmarkResult.ok === true
          ? Subsonic.parseBookmarks(bookmarkResult.data) : []
        var plan = Subsonic.restoreLoadPlan(queuePlan, marks,
          Api.PLAYBACK_URI_LIMIT)
        if (!plan) {
          if (typeof callback === "function") callback(false)
          return
        }
        localLoadInFlight = true
        backendClient.loadPlayback({
          items: plan.songs,
          offset_index: plan.offset_index,
          position_ms: plan.position_ms,
          play: false
        }, function(loadOk) {
          localLoadInFlight = false
          if (typeof callback === "function") callback(loadOk === true)
        })
      })
    })
    return true
  }

  // Resume candidates: Navidrome has no client-visible play history, so the
  // "continue where you were" offer is the most recent album window
  // (getAlbumList2 type=recent). Exact-position resume is the saved-session
  // restore above; this candidate is the footer's idle Play target.
  function loadResumeCandidate(force) {
    if (resumeCandidateLoading) return
    if (!authManager.loggedIn) return
    if (force !== true && resumeCandidateLoadedAt > 0
        && Date.now() - resumeCandidateLoadedAt < 30000) return
    var expected = dataSerial
    resumeCandidateLoading = true
    resumeCandidateLoadedAt = Date.now()
    subsonicApi.request("getAlbumList2",
      Subsonic.albumList2Params("recent", 1, 0), function(result) {
        if (expected !== root.dataSerial) return
        root.resumeCandidateLoading = false
        if (result && result.ok === true) {
          var rows = Api.subsonicAlbumListRows(result.data, root.subsonicArt)
          root.resumeCandidate = rows.length
            ? { item: rows[0], playedAt: "" } : null
        } else {
          root.resumeCandidate = null
        }
        root.resumeCandidateLoadedAt = Date.now()
      }, { priority: "interactive" })
  }

  // Nothing is loaded, so a plain resume has no queue to continue. Start the
  // most recent album through the regular playback path, which also brings up
  // the local engine when it has idled out.
  function resumeLastPlayed() {
    var candidate = resumeCandidate
    if (!Api.resumePlaybackAvailable(hasMedia, candidate)) return false
    playItem(candidate.item, null,
      "Resuming " + String(candidate.item.name || ""))
    return true
  }

  // Playback controls act on the engine's MPRIS player only. Play with
  // nothing loaded resumes the most recent album through the regular playback
  // path, which also brings up the local engine when it has idled out.
  function togglePlayback() {
    noteActivity()
    if (!hasMedia && resumeLastPlayed()) return
    if (hasLocalPlayer && activePlayer.canTogglePlaying)
      activePlayer.togglePlaying()
  }

  function next() {
    noteActivity()
    if (hasLocalPlayer && activePlayer.canGoNext) activePlayer.next()
  }

  function previous() {
    noteActivity()
    if (hasLocalPlayer && activePlayer.canGoPrevious) activePlayer.previous()
  }

  function seekSeconds(seconds) {
    var value = Math.max(0, Math.min(lengthSeconds || Number.MAX_VALUE,
      Number(seconds) || 0))
    noteActivity()
    if (hasLocalPlayer && activePlayer.canSeek && activePlayer.positionSupported)
      activePlayer.position = value
  }

  function setVolume(value, live) {
    var sliderValue = Math.max(0, Math.min(1, Number(value) || 0))
    noteActivity()
    if (live === true) {
      volumeLiveActive = true
      volumeLiveIdleTimer.restart()
    }
    beginPendingSliderVolume(sliderValue)
    queuedVolumeSlider = sliderValue
    volumeFlushQueued = true
    if (!volumeFlushCooling) flushVolume()
  }

  function setShuffle(value) {
    var enabled = value === true
    noteActivity()
    if (hasLocalPlayer && activePlayer.shuffleSupported)
      activePlayer.shuffle = enabled
  }

  function cycleRepeat() {
    var nextMode = repeatMode === "off" ? "context" : (repeatMode === "context" ? "track" : "off")
    noteActivity()
    if (hasLocalPlayer && activePlayer.loopSupported) {
      activePlayer.loopState = nextMode === "track" ? MprisLoopState.Track
        : (nextMode === "context" ? MprisLoopState.Playlist : MprisLoopState.None)
    }
  }

  function setSleepMinutes(minutes) {
    var value = Math.max(1, Math.min(720, Math.floor(Number(minutes) || 0)))
    sleepContextTimer.stop()
    sleepMode = "minutes"
    sleepEndsAt = Date.now() + value * 60000
    sleepRemainingSeconds = value * 60
    sleepTrackUri = ""
    scheduleSleepDeadline()
    succeed("Sleep timer set for " + value + " minutes")
  }

  function sleepAfterTrack() {
    if (!currentUri || !playing) {
      fail("Play something before setting an end-of-track timer")
      return
    }
    sleepDeadlineTimer.stop()
    sleepMode = "track"
    sleepTrackUri = currentUri
    sleepEndsAt = 0
    sleepRemainingSeconds = 0
    succeed("Playback will pause after this item")
  }

  function sleepAfterContext() {
    if (!playing) {
      fail("Play something before setting an end-of-context timer")
      return
    }
    sleepDeadlineTimer.stop()
    sleepMode = "context"
    sleepTrackUri = ""
    sleepEndsAt = 0
    sleepRemainingSeconds = 0
    succeed("Playback will pause after this album or playlist")
  }

  function cancelSleepTimer(showStatus) {
    sleepDeadlineTimer.stop()
    sleepMode = "off"
    sleepEndsAt = 0
    sleepTrackUri = ""
    sleepRemainingSeconds = 0
    sleepContextTimer.stop()
    if (showStatus !== false) succeed("Sleep timer cancelled")
  }

  function finishSleepTimer() {
    if (!sleepActive) return
    if (playing) togglePlayback()
    cancelSleepTimer(false)
    succeed("Sleep timer finished")
  }

  function updateSleepCountdown() {
    if (sleepMode !== "minutes") {
      sleepRemainingSeconds = 0
      return
    }
    sleepRemainingSeconds = Api.deadlineRemainingSeconds(sleepEndsAt,
      Date.now())
  }

  function scheduleSleepDeadline() {
    sleepDeadlineTimer.stop()
    if (sleepMode !== "minutes") return
    var remaining = sleepEndsAt - Date.now()
    if (remaining <= 0) {
      updateSleepCountdown()
      finishSleepTimer()
      return
    }
    sleepDeadlineTimer.interval = Math.max(1, Math.ceil(remaining))
    sleepDeadlineTimer.restart()
  }

  function sleepStatusText() {
    if (sleepMode === "minutes") {
      var minutes = Math.floor(sleepRemainingSeconds / 60)
      var seconds = sleepRemainingSeconds % 60
      return "Sleep in " + minutes + ":" + (seconds < 10 ? "0" : "") + seconds
    }
    if (sleepMode === "track") return "Sleep after this item"
    if (sleepMode === "context") return "Sleep after this album or playlist"
    return "Sleep timer"
  }

  function addToQueue(item) {
    // The queue is the engine's; add_to_queue carries one SongRef.
    if (!item || item.type !== "track" || !Api.backendSongRefV2(item)) {
      fail("Only songs can be added to the queue")
      return
    }
    if (backendClient.ready) {
      ensureBackendServerConfigured()
      backendClient.sendCommand("add_to_queue",
        { song: Api.backendSongRefV2(item) },
        function(ok, result, error) {
          if (ok) {
            root.succeed("Added to queue")
            root.loadQueue()
          } else root.fail(error || "Could not add that item to the queue")
        })
      return
    }
    // With no local engine there is nothing to append to.
    fail("Playback on this computer is not ready, so the queue cannot take songs yet")
  }

  function startEngine() {
    localPlaybackStopped = false
    noteActivity()
    localActivationRequested = true
    daemonManager.start(true)
  }

  function stopEngine() {
    localPlaybackStopped = true
    clearPendingPlayback()
    localSocketWaitTimer.stop()
    localSocketWaitAttempts = 0
    daemonManager.stop()
  }

  function login() {
    if (authManager.loginBusy || authManager.sessionBusy
        || daemonManager.setupBusy) return
    noteActivity()
    lastError = ""
    statusClearTimer.stop()
    statusMessage = ""
    loginFlowActive = true
    if (!authManager.loggedIn) {
      authManager.beginLogin()
      return
    }
    continueLocalPlaybackSetup()
  }

  function continueLocalPlaybackSetup() {
    if (!daemonManager.playbackReady) {
      daemonManager.setupPlayback()
      return
    }
    // The Navidrome backend takes its credentials from the keyring through
    // configure_server, so no extra local authorization step exists.
    finishLoginFlow()
  }

  function cancelLogin() {
    loginFlowActive = false
    lastError = ""
    statusMessage = ""
    authManager.cancelLogin()
  }

  function reconnectAccount() {
    if (loginBusy) return
    noteActivity()
    lastError = ""
    statusClearTimer.stop()
    statusMessage = ""
    loginFlowActive = true
    authManager.beginLogin()
  }

  function finishLoginFlow() {
    loginFlowActive = false
    succeed("Connected to Navidrome")
    loadPlaybackState()
    loadProfile()
    loadSidebarPlaylists()
    openView(activeView, true)
  }

  function logout() {
    if (loginBusy || daemonManager.busy) return
    loginFlowActive = false
    dataSerial++
    clearPendingPlayback()
    // Drain any in-flight Subsonic reads/writes: a stale starred or playlist
    // write must not land after the credentials are gone.
    subsonicApi.cancelAll()
    authManager.logout()
    clearData()
  }

  function clearData() {
    radioSerial++
    playlistItemsSerial++
    clearPendingPlayback()
    restoreAttempted = false
    resumeCandidate = null
    resumeCandidateLoadedAt = 0
    playlists = []
    playlistsLoaded = false
    playlistsNext = ""
    savedTracks = []
    savedTracksLoaded = false
    savedTracksNext = ""
    savedAlbums = []
    savedAlbumsLoaded = false
    savedAlbumsNext = ""
    followedArtists = []
    followedArtistsLoaded = false
    followedArtistsNext = ""
    playlistItems = []
    playlistItemsNext = ""
    playlistItemsError = ""
    playlistItemsStatus = 0
    playlistRestoreTargetCount = 0
    selectedPlaylist = null
    currentUserId = ""
    currentUserName = ""
    queue = []
    queueLoaded = false
    clearPendingSliderVolume()
    volumeFlushQueued = false
    volumeFlushCooling = false
    volumeLiveActive = false
    volumeFlushTimer.stop()
    volumeLiveIdleTimer.stop()
    playbackPositionTick++
    searchController.clearSearch()
    savedUris = ({})
    savedUriCheckedAt = ({})
    savedUriOrder = []
    savedUrisChecking = ({})
    savedUrisBusy = ({})
    savedUrisRevision++
    savedUrisCheckingRevision++
    savedUrisBusyRevision++
    homeRecent = []
    homeFrequent = []
    homeNewest = []
    homeStarred = []
    homeLoaded = false
    homeRequestsPending = 0
    starred2Loading = false
    starred2Waiters = []
    discoverSerial++
    discoverAlbums = []
    discoverGenres = []
    discoverLoaded = false
    discoverRequestsPending = 0
    discoverRequestsFailed = 0
    discoverMessage = ""
    genreSerial++
    discoverGenre = ""
    genreAlbums = []
    genreAlbumsNext = ""
    genreAlbumsLoading = false
    trackTruthSerial++
    detailSerial++
    detailItem = null
    detailItems = []
    detailNext = ""
    detailLoading = false
    detailMessage = ""
    detailRestoreTargetCount = 0
    artistCatalogSerial++
    artistCatalogQuery = ""
    artistAlbums = []
    artistAlbumsNext = ""
    artistAlbumsLoading = false
    artistSongs = []
    artistSongsNext = ""
    artistSongsLoading = false
    playlistsLoading = false
    savedTracksLoading = false
    savedAlbumsLoading = false
    followedArtistsLoading = false
    playlistItemsLoading = false
    playlistActionBusy = false
    playlistConversionBusy = false
    queueLoading = false
    searchLoading = false
    localSocketWaitAttempts = 0
    localSocketWaitTimer.stop()
    cancelSleepTimer(false)
  }

  onPlayingChanged: noteActivity()
  onPlaybackStateChanged: {
    if ((sleepMode === "context" || sleepMode === "track")
        && playbackState === MprisPlaybackState.Stopped) sleepContextTimer.restart()
    else sleepContextTimer.stop()
  }
  onCurrentUriChanged: {
    if (sleepMode === "track" && sleepTrackUri && currentUri
        && currentUri !== sleepTrackUri) finishSleepTimer()
  }
  onCurrentTrackItemUriChanged: syncCurrentTrackSaved(false)
  onLyricsPluginAvailabilityChanged: resumeLyricsInstallIntent()
  onShellChanged: settingsSync.restart()
  onUiVisibleChanged: {
    if (uiVisible) {
      ensureVisibleLocalReceiver()
      syncCurrentTrackSaved(true)
      updateSleepCountdown()
    }
  }
  onFullyConnectedChanged: {
    if (fullyConnected && uiVisible) ensureVisibleLocalReceiver()
  }

  Component.onCompleted: {
    ensureStateDir.running = true
    settingsSync.start()
    daemonManager.refreshStatus()
  }

  Connections {
    target: root.shell
    ignoreUnknownSignals: true
    function onShellConfigChanged() { root.syncSettings() }
  }

  Connections {
    target: authManager
    function onLoginSucceeded() {
      root.syncCurrentTrackSaved(true)
      var continueSetup = root.loginFlowActive && !root.daemon.playbackReady
      root.finishLoginFlow()
      if (continueSetup) {
        root.loginFlowActive = true
        root.succeed("Navidrome connected · finishing playback on this computer")
        root.continueLocalPlaybackSetup()
      }
    }
    function onLoggedOut() {
      root.clearData()
    }
    function onSessionUnavailable(reason) {
      root.loginFlowActive = false
      if (reason) root.lastError = root.safeError(reason)
    }
  }

  Connections {
    target: daemonManager
    function onSetupSucceeded() {
      if (root.loginFlowActive) root.continueLocalPlaybackSetup()
      else root.succeed("Playback on this computer is ready")
    }
    function onSetupFailed(reason) {
      root.loginFlowActive = false
      root.fail(reason)
    }
    function onStarted() {
      root.succeed("Playback started on this computer")
      if (root.uiVisible) root.ensureVisibleLocalReceiver()
    }
    function onStopped() { root.succeed("Playback stopped on this computer") }
  }

  Timer {
    id: settingsSync
    interval: 0
    onTriggered: root.syncSettings()
  }

  Timer {
    id: sessionSaveTimer
    interval: 200
    repeat: false
    onTriggered: root.flushSessionFile()
  }

  FileView {
    id: sessionFile
    path: root.sessionPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.applySessionFile(text())
    onLoadFailed: root.applySessionFile("")
    onSaved: {
      root.sessionFileHadData = !Api.sessionRecordIsEmpty(root.currentSessionRecord())
      root.sessionFileDirty = false
      root.stripPluginSessionKeys()
    }
    onSaveFailed: {
      if (!ensureStateDir.running) ensureStateDir.running = true
    }
  }

  Process {
    id: ensureStateDir
    running: false
    command: ["/usr/bin/mkdir", "-p", root.stateDir]
    onExited: {
      if (!root.sessionFileReady) sessionFile.reload()
      else if (root.sessionFileDirty) root.flushSessionFile()
    }
  }

  Timer {
    id: lyricsPluginLaunchRetry
    interval: 250
    repeat: false
    onTriggered: root.launchLyricsPlugin()
  }

  Timer {
    id: lyricsPluginInstallPoll
    interval: 400
    repeat: true
    onTriggered: if (root.finishLyricsPluginInstallWatch()) stop()
  }

  Process {
    id: lyricsPluginSetupProcess
    running: false
    command: []
    stdout: StdioCollector { id: lyricsPluginSetupStdout; waitForEnd: true }
    stderr: StdioCollector { id: lyricsPluginSetupStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.lyricsPluginBusy = false
      if (Number(exitCode) === 0) {
        root.lyricsPluginOperation = ""
        root.lyricsPluginError = ""
        root.lyricsPluginLaunchAttempts = 0
        lyricsPluginLaunchRetry.restart()
        return
      }
      var detail = String(lyricsPluginSetupStderr.text
        || lyricsPluginSetupStdout.text || "").trim()
      root.lyricsPluginError = root.safeError(detail
        || "Omasing could not be installed.")
    }
  }

  Process {
    id: lyricsPluginLaunchProcess
    running: false
    command: []
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: lyricsPluginLaunchStderr; waitForEnd: true }
    onExited: function(exitCode) { root.finishLyricsPluginLaunch(exitCode) }
  }

  Timer {
    id: statusClearTimer
    interval: 4500
    onTriggered: if (!root.lastError) root.statusMessage = ""
  }

  Timer {
    id: localSocketWaitTimer
    interval: 200
    repeat: true
    onTriggered: {
      if (root.backend.ready && root.pendingPlaybackLoad) {
        stop()
        root.localSocketWaitAttempts = 0
        root.sendLocalSocketPlayback(root.pendingPlaybackSerial)
        return
      }
      root.localSocketWaitAttempts++
      if (root.localSocketWaitAttempts >= 25) {
        stop()
        root.localSocketWaitAttempts = 0
        if (root.pendingPlaybackLoad) {
          root.clearPendingPlayback()
          root.fail("The local player did not become ready in time. Check Settings, then try again")
        }
      }
    }
  }

  Timer {
    id: volumeFlushTimer
    interval: Api.VOLUME_FLUSH_MS
    repeat: false
    onTriggered: root.flushVolume()
  }

  Timer {
    id: volumeLiveIdleTimer
    interval: 400
    repeat: false
    onTriggered: root.volumeLiveActive = false
  }

  Timer {
    id: volumeHoldTimer
    interval: 200
    repeat: true
    onTriggered: root.reconcilePendingSliderVolume()
  }

  Timer {
    id: idleTimer
    interval: 60000
    repeat: true
    running: Api.idleShutdownShouldRun(root.daemon.running, root.hasMedia,
      root.uiVisible, root.idleShutdownMinutes)
    onTriggered: {
      if (Date.now() - root.lastActivityAt >= root.idleShutdownMinutes * 60000)
        root.stopEngine()
    }
  }

  Timer {
    id: sleepDeadlineTimer
    repeat: false
    onTriggered: {
      root.updateSleepCountdown()
      if (root.sleepRemainingSeconds <= 0) root.finishSleepTimer()
      else root.scheduleSleepDeadline()
    }
  }

  Timer {
    id: sleepCountdown
    interval: 1000
    repeat: true
    running: root.sleepMode === "minutes" && root.uiVisible
    onRunningChanged: if (running) root.updateSleepCountdown()
    onTriggered: {
      root.updateSleepCountdown()
      if (root.sleepRemainingSeconds <= 0) root.finishSleepTimer()
    }
  }

  Timer {
    id: sleepContextTimer
    interval: 1800
    repeat: false
    onTriggered: if ((root.sleepMode === "context" || root.sleepMode === "track")
        && root.playbackState === MprisPlaybackState.Stopped)
      root.finishSleepTimer()
  }

  AuthManager {
    id: authManager
    pluginDir: root.pluginDir
  }

  SubsonicApi {
    id: subsonicApi
    // The QML-side Subsonic transport. The saved-session restore uses it for
    // getBookmarks only: the play queue itself is read through the backend's
    // get_saved_queue command so the credentials never leave the engine.
    // Inert when idle — no polling, no requests without an explicit call.
    serverUrl: authManager.navidromeUrl
    username: authManager.navidromeUsername
    password: authManager.navidromePassword
  }

  // SpotifyConnectManager died with the Spotify Connect machinery; the
  // engine unit below is the only playback runtime.

  DaemonManager {
    id: daemonManager
    pluginDir: root.pluginDir
    deviceName: root.deviceName
    bitrateKbps: root.bitrateKbps
    mprisPresent: root.hasLocalPlayer
  }

  BackendClient {
    id: backendClient
    wanted: daemonManager.running
    // The initial state event flips lifecycle to "ready": the single point
    // where a fresh connection (or a reconnect) gets configured.
    onLifecycleChanged: root.ensureBackendServerConfigured()
    onErrorCodeChanged: {
      if (backendClient.credentialFailure) {
        // Typed credential-class state from the engine: terminal, so the
        // pending playback push stops and the UI explains the actual failure.
        root.clearPendingPlayback()
        root.fail(Subsonic.backendCredentialMessage(errorCode)
          || errorMessage || "Playback on this computer is not set up")
      }
    }
  }
}
