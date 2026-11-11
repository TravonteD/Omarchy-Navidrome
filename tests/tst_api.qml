import QtQuick
import QtTest

import "../Api.js" as Api
import "../Subsonic.js" as Subsonic

TestCase {
  name: "NavidromeApiLogic"

  function test_barTrackText_respectsIndependentTitleAndArtistSettings() {
    compare(Api.barTrackText("Blue in Green", "Miles Davis", true, false,
      true, true),
      "Blue in Green")
    compare(Api.barTrackText("Blue in Green", "Miles Davis", false, true,
      true, true),
      "Miles Davis")
    compare(Api.barTrackText("Blue in Green", "Miles Davis", true, true,
      true, true),
      "Miles Davis - Blue in Green")
    compare(Api.barTrackText("Blue in Green", "Miles Davis", false, false,
      true, true), "")
    compare(Api.barTrackText("  Blue in Green  ", "  Miles Davis  ", true,
      true, true, true),
      "Miles Davis - Blue in Green")
    compare(Api.barTrackText("Blue in Green", "", true, true, true, true),
      "Blue in Green")
    compare(Api.barTrackText("", "Miles Davis", true, true, true, true),
      "Miles Davis")
  }

  function test_barTrackText_pausedVisibilityIsConfigurable() {
    compare(Api.barTrackText("Blue in Green", "Miles Davis", true, true,
      false, true),
      "Miles Davis - Blue in Green")
    compare(Api.barTrackText("Blue in Green", "Miles Davis", true, true,
      false, false), "")
  }

  function test_idleShutdown_onlyRunsForAnEmptyReceiver() {
    verify(Api.idleShutdownShouldRun(true, false, false, 15))
    verify(!Api.idleShutdownShouldRun(true, true, false, 15))
    verify(!Api.idleShutdownShouldRun(true, false, true, 15))
    verify(!Api.idleShutdownShouldRun(false, false, false, 15))
    verify(!Api.idleShutdownShouldRun(true, false, false, 0))
  }

  function test_scrollAvailability_requiresAtLeastOneBarLabel() {
    verify(Api.canScrollBarText(true, true))
    verify(Api.canScrollBarText(true, false))
    verify(Api.canScrollBarText(false, true))
    verify(!Api.canScrollBarText(false, false))
  }

  function test_normalizedMaxBarTextWidth_defaultsClampsAndSnaps() {
    compare(Api.normalizedMaxBarTextWidth(undefined), 240)
    compare(Api.normalizedMaxBarTextWidth(null), 240)
    compare(Api.normalizedMaxBarTextWidth(""), 240)
    compare(Api.normalizedMaxBarTextWidth("nonsense"), 240)
    compare(Api.normalizedMaxBarTextWidth(-40), 240)
    // 0 is the uncapped sentinel and must survive normalization untouched.
    compare(Api.normalizedMaxBarTextWidth(0), 0)
    compare(Api.normalizedMaxBarTextWidth("0"), 0)
    compare(Api.normalizedMaxBarTextWidth(240), 240)
    compare(Api.normalizedMaxBarTextWidth(247), 240)
    compare(Api.normalizedMaxBarTextWidth(265), 280)
    compare(Api.normalizedMaxBarTextWidth(10), 160)
    compare(Api.normalizedMaxBarTextWidth(9999), 560)
  }

  function test_barTextWidthSlider_notchesCoverEveryNormalizedWidth() {
    var slider = Api.barTextWidthSlider()
    // The uncapped notch must sit past every real width, so no stored value can
    // normalize onto it and be mistaken for "unlimited".
    for (var i = 0; i < slider.ticks; i++) {
      var stop = slider.min + i * slider.step
      if (stop === slider.unlimited) continue
      compare(Api.normalizedMaxBarTextWidth(stop), stop)
    }
    compare(slider.min + (slider.ticks - 1) * slider.step, slider.unlimited)
    verify(Api.normalizedMaxBarTextWidth(slider.unlimited) < slider.unlimited)
    compare(Api.normalizedMaxBarTextWidth(240), 240)
  }

  function test_normalizedScrollSpeed_defaultsClampsAndSnaps() {
    compare(Api.normalizedScrollSpeed(undefined), 1)
    compare(Api.normalizedScrollSpeed("not-a-speed"), 1)
    compare(Api.normalizedScrollSpeed(0), 0.25)
    compare(Api.normalizedScrollSpeed(4), 3)
    compare(Api.normalizedScrollSpeed(1), 1)
    compare(Api.normalizedScrollSpeed(1.12), 1)
    compare(Api.normalizedScrollSpeed(1.13), 1.25)
  }

  function test_cacheFreshnessAndSleepDeadline_boundaries() {
    verify(Api.timestampIsFresh(1000, 5999, 5000))
    verify(!Api.timestampIsFresh(1000, 6000, 5000))
    verify(!Api.timestampIsFresh(1000, 999, 5000))
    verify(!Api.timestampIsFresh(0, 1000, 5000))

    compare(Api.deadlineRemainingSeconds(2501, 1000), 2)
    compare(Api.deadlineRemainingSeconds(2000, 1000), 1)
    compare(Api.deadlineRemainingSeconds(999, 1000), 0)
    compare(Api.deadlineRemainingSeconds("invalid", 1000), 0)
  }

  function test_boundedOrder_mutatesInPlaceAndEvictsOldestKeys() {
    var order = ["one", "two", "three"]
    var sameOrder = order
    compare(Api.touchBoundedOrder(order, "two", 3), "")
    verify(order === sameOrder)
    compare(order, ["one", "three", "two"])

    compare(Api.touchBoundedOrder(order, "four", 3), "one")
    compare(order, ["three", "two", "four"])
    compare(Api.touchBoundedOrder(order, "", 3), "")
  }

  function test_filteredSorted_reusesTheUnchangedDefaultList() {
    var rows = [{ name: "One" }, { name: "Two" }]
    verify(Api.filteredSorted(rows, "", "default") === rows)
    verify(Api.filteredSorted(rows, " two ", "default") !== rows)
    compare(Api.filteredSorted(rows, " two ", "default"), [rows[1]])
    compare(Api.filteredSorted([rows[0], null, rows[1]], "", "default"), rows)
  }

  function test_normalizeVolumePercent_preservesUnknownAndValidMute() {
    compare(Api.normalizeVolumePercent(null), null)
    compare(Api.normalizeVolumePercent(undefined), null)
    compare(Api.normalizeVolumePercent(""), null)
    compare(Api.normalizeVolumePercent("not-a-volume"), null)
    compare(Api.normalizeVolumePercent(0), 0)
    compare(Api.normalizeVolumePercent(47), 47)
    compare(Api.normalizeVolumePercent(120), 100)
  }

  function test_searchTextBuilders_normalizeForPlainQueries() {
    compare(Api.sanitizeSearchTerm("AC/DC \"Live\""), "AC/DC Live")
    compare(Api.playlistMatchesTerm({ name: "Abbey Road Live!" },
      "abbey road"), true)
    compare(Api.playlistMatchesTerm({ name: "Miles Davis Best" }, "miles davis"),
      true)
    compare(Api.playlistMatchesTerm({ name: "Other" }, "miles"), false)
    compare(Api.playlistMatchesTerm({ name: "Anything" }, ""), true)
  }

  function test_volumeAndSeekHelpers_clampMuteAndRemember() {
    compare(Api.nextVolume(0.5, 0.1), 0.6)
    compare(Api.nextVolume(0.98, 0.1), 1)
    compare(Api.nextVolume(0.02, -0.1), 0)
    verify(Api.shouldRememberVolume(0.05))
    verify(!Api.shouldRememberVolume(0.001))
    compare(Api.unmuteVolume(0.4), 0.4)
    compare(Api.unmuteVolume(0), 0.05)
    compare(Api.seekPosition(10, 10, 183), 20)
    compare(Api.seekPosition(180, 10, 183), 183)
    compare(Api.seekPosition(5, -10, 183), 0)
    compare(Api.seekPosition(40, 10, 0), 50)
  }

  function test_volumeFlushInterval_usesTheLocalOnlyCadence() {
    compare(Api.VOLUME_FLUSH_MS, 80)
  }

  function test_pendingSliderVolumeHoldsUntilPlayerAcknowledgesIt() {
    var pending = { slider: 0.55, expiresAt: 9000 }
    verify(Api.pendingSliderVolumeShouldHold(0.5, pending, 2000))
    compare(Api.displayedSliderVolume(0.5, pending, 2000), 0.55)
    verify(!Api.pendingSliderVolumeShouldHold(0.55, pending, 2000))
    compare(Api.displayedSliderVolume(0.55, pending, 2000), 0.55)
    verify(!Api.pendingSliderVolumeShouldHold(0.5, pending, 9000))
    compare(Api.displayedSliderVolume(0.5, pending, 9000), 0.5)
    verify(!Api.pendingSliderVolumeShouldHold(0.5, null, 2000))
    compare(Api.SEARCH_DEBOUNCE_MS, 300)
    compare(Api.SEARCH_REQUEST_TIMEOUT_MS, 8000)
    compare(Api.VOLUME_FLUSH_MS, 80)
  }

  function test_searchTypeLoading_normalizesAndCachesEachCategory() {
    compare(Api.normalizedSearchType("album"), "album")
    compare(Api.normalizedSearchType("episode"), "track")
    compare(Api.normalizedSearchType("unknown"), "track")
    compare(Api.normalizedSearchType(""), "track")
    verify(Api.searchNeedsLoad("miles", "", false))
    verify(Api.searchNeedsLoad(" miles ", "coltrane", true))
    verify(Api.searchNeedsLoad("miles", "miles", false))
    verify(!Api.searchNeedsLoad("miles", "miles", true))
    verify(!Api.searchNeedsLoad("   ", "", false))
  }

  function test_shallowCopyAndAssign_copyWithoutSharingIdentity() {
    var source = { name: "Work", volume: 12 }
    var copy = Api.shallowCopy(source)
    compare(copy.name, "Work")
    verify(copy !== source)
    source.name = "Kitchen"
    compare(copy.name, "Work")
    compare(Api.assign({ a: 1 }, { b: 2, a: 3 }).a, 3)
  }

  function test_responsiveMediaRowsAndSearchColumnsUseMeasuredWidth() {
    verify(Api.mediaRowShouldCompact(220, 180, 4))
    verify(!Api.mediaRowShouldCompact(180, 220, 4))
    verify(!Api.mediaRowShouldCompact(220, 180, 0))
    compare(Api.responsiveResultColumns(1000, 760), 2)
    compare(Api.responsiveResultColumns(500, 760), 1)
  }

  function test_sectionedMediaRows_flattensGroupsForOneVirtualizedView() {
    var songs = [{ id: "one" }, { id: "two" }, { id: "three" }]
    var rows = Api.sectionedMediaRows([
      { id: "songs", heading: "SONGS", items: songs, loading: false, hasMore: true },
      { id: "albums", heading: "ALBUMS", items: [], loading: false, hasMore: false },
      { id: "playlists", heading: "PLAYLISTS", items: [], loading: true, hasMore: false }
    ], 2)

    compare(rows.length, 6)
    compare(rows[0].kind, "heading")
    compare(rows[0].sectionId, "songs")
    compare(rows[1].kind, "items")
    compare(rows[1].items.length, 2)
    compare(rows[1].startIndex, 0)
    compare(rows[2].items.length, 1)
    compare(rows[2].startIndex, 2)
    compare(rows[3].kind, "more")
    compare(rows[4].kind, "heading")
    compare(rows[4].sectionId, "playlists")
    compare(rows[5].kind, "more")
  }

  function test_artistSubtitleSuffix_keepsNonArtistAlbumDetails() {
    compare(Api.artistSubtitleSuffix({
      subtitle: "Jimi Hendrix · Album · 1967",
      artists: [{ name: "Jimi Hendrix" }]
    }), " · Album · 1967")
    compare(Api.artistSubtitleSuffix({ subtitle: "Playlist", artists: [] }), "")
  }

  function test_artistForName_prefersAnExactArtist() {
    var artists = [
      { id: "tribute", type: "artist", name: "The Jimi Hendrix Experience Tribute" },
      { id: "jimi", type: "artist", name: "Jimi Hendrix" }
    ]
    compare(Api.artistForName(artists, "jimi hendrix").id, "jimi")
    compare(Api.artistForName(artists, "unknown").id, "tribute")
    compare(Api.artistForName([{ type: "album", name: "Jimi Hendrix" }],
      "Jimi Hendrix"), null)
  }

  function test_artistContextAvailable_onlyLinksTrackPerformers() {
    verify(Api.artistContextAvailable("track", "", []))
    verify(Api.artistContextAvailable("", "track-id", []))
    verify(Api.artistContextAvailable("", "", [{ name: "Björk" }]))
    verify(!Api.artistContextAvailable("episode", "", []))
    verify(!Api.artistContextAvailable("chapter", "", []))
  }

  function test_lyricsSong_requiresATrackAndPreservesPlaybackMetadata() {
    compare(Api.lyricsSong("", "Episode", "Podcast", "Show", 120, ""), null)
    compare(Api.lyricsSong("track-id", "", "Artist", "Album", 180, ""), null)

    var song = Api.lyricsSong("track-id", " Song ", " Artist ", " Album ",
      183.5, "https://images.example/cover.jpg", 91.75)
    compare(song.id, "track-id")
    compare(song.title, "Song")
    compare(song.artist, "Artist")
    compare(song.album, "Album")
    compare(song.duration, 183.5)
    compare(song.coverUrl, "https://images.example/cover.jpg")
    compare(song.positionSeconds, 91.75)

    compare(Api.lyricsSong("track-id", "Song", "Artist", "", 180, "", -5)
      .positionSeconds, 0)
    compare(Api.lyricsSong("track-id", "Song", "Artist", "", 180, "", 200)
      .positionSeconds, 180)
  }

  function test_currentPlaybackTrack_synthesizesTheEngineRow() {
    // The engine's MPRIS metadata carries only strings; the row is built
    // from them, with the app-local navidrome uri token and no external URL.
    var row = Api.currentPlaybackTrack("tr-9", "Song", "Artist",
      "Album", "https://images.example/cover.jpg", 183)
    compare(row.kind, "item")
    compare(row.type, "track")
    compare(row.id, "tr-9")
    compare(row.uri, "navidrome:track:tr-9")
    compare(row.name, "Song")
    compare(row.subtitle, "Artist")
    compare(row.album, "Album")
    compare(row.imageUrl, "https://images.example/cover.jpg")
    compare(row.durationMs, 183000)
    verify(row.artists.length === 0)
    verify(row.albumItem === null)
    compare(Api.currentPlaybackTrack("", "Song", "Artist", "", "", 0), null)
    compare(Api.currentPlaybackTrack(null, "Song", "Artist", "", "", 0), null)
  }

  function test_audioQualitySettings_normalizeToTheNavidromeChoice() {
    // Stream format: the six server transcode targets plus "source".
    verify(Api.AUDIO_FORMATS.length === 7)
    compare(Api.AUDIO_FORMATS.indexOf("source"), 0)
    compare(Api.normalizedAudioFormat("source"), "source")
    compare(Api.normalizedAudioFormat("mp3"), "mp3")
    compare(Api.normalizedAudioFormat(" flac "), "flac")
    compare(Api.normalizedAudioFormat(""), "source")
    compare(Api.normalizedAudioFormat(undefined), "source")
    compare(Api.normalizedAudioFormat("aiff"), "source")
    compare(Api.normalizedAudioFormat("MP3"), "source")

    // Bit-rate cap: the bounded UI list only.
    verify(JSON.stringify(Api.AUDIO_MAX_BIT_RATES)
      === JSON.stringify([0, 64, 96, 128, 192, 320]))
    compare(Api.normalizedAudioMaxBitRate("0"), 0)
    compare(Api.normalizedAudioMaxBitRate("192"), 192)
    compare(Api.normalizedAudioMaxBitRate(320), 320)
    compare(Api.normalizedAudioMaxBitRate(""), 0)
    compare(Api.normalizedAudioMaxBitRate("not a number"), 0)
    compare(Api.normalizedAudioMaxBitRate(160), 0)
    compare(Api.normalizedAudioMaxBitRate(96.7), 96)
    compare(Api.normalizedAudioMaxBitRate(160.9), 0)

    // Cycle buttons wrap through the option list.
    compare(Api.cycledChoice(Api.AUDIO_MAX_BIT_RATES, 0), 64)
    compare(Api.cycledChoice(Api.AUDIO_MAX_BIT_RATES, 320), 0)
    compare(Api.cycledChoice(Api.AUDIO_FORMATS, "aac"), "source")
    compare(Api.cycledChoice(Api.AUDIO_FORMATS, "nonsense"), "source")
  }

  function test_sessionRecord_roundTripsAndMigratesPluginSettings() {
    compare(Api.sessionRecordIsEmpty(Api.emptySessionRecord()), true)
    compare(Api.sessionRecordIsEmpty(Api.parseSessionRecord("")), true)
    compare(Api.sessionRecordIsEmpty(Api.parseSessionRecord("{")), true)
    compare(Api.sessionRecordIsEmpty(Api.parseSessionRecord("[]")), true)
    compare(Api.pluginSettingsHaveSessionKeys(null), false)
    compare(Api.pluginSettingsHaveSessionKeys({ deviceName: "Omarchy Navidrome" }), false)
    compare(Api.pluginSettingsHaveSessionKeys({ sessionState: "{}" }), true)
    compare(Api.pluginSettingsHaveSessionKeys({ searchHistory: "[]" }), true)

    var encoded = Api.encodeSessionRecord({
      tab: "playlists",
      searchText: "radiohead",
      selectedPlaylist: {
        kind: "context", type: "playlist", id: "playlist-one",
        uri: "navidrome:playlist:playlist-one", name: "Long playlist"
      },
      selectedPlaylistItemCount: 150,
      detailItemCount: 100
    }, ["radiohead", "bjork"])
    compare(JSON.parse(encoded).version, 1)
    var restored = Api.parseSessionRecord(encoded)
    compare(restored.sessionState.tab, "playlists")
    compare(restored.sessionState.searchText, "radiohead")
    compare(restored.sessionState.selectedPlaylist.id, "playlist-one")
    compare(restored.sessionState.selectedPlaylistItemCount, 150)
    compare(restored.sessionState.detailItemCount, 100)
    compare(JSON.stringify(restored.searchHistory),
      JSON.stringify(["radiohead", "bjork"]))
    compare(Api.sessionRecordIsEmpty(restored), false)

    var fromPlugin = Api.sessionRecordFromPluginSettings({
      deviceName: "Office",
      sessionState: "{\"tab\":\"library\",\"libraryType\":\"albums\"}",
      searchHistory: "[\"kid a\", \"kid a\", \"\"]"
    })
    compare(fromPlugin.sessionState.tab, "library")
    compare(fromPlugin.sessionState.libraryType, "albums")
    compare(JSON.stringify(fromPlugin.searchHistory), JSON.stringify(["kid a"]))

    var oversized = { tab: "detail", blob: Array(16001).join("x") }
    compare(JSON.stringify(Api.normalizedSessionState(oversized)), "{}")
    compare(Api.sessionRecordIsEmpty(Api.sessionRecord(oversized, [])), true)
  }

  function test_arrayValues_acceptsQmlSequenceShape() {
    var sequence = ({ length: 2 })
    sequence[0] = { name: "One" }
    sequence[1] = { name: "Two" }

    verify(!Array.isArray(sequence))
    compare(Api.arrayValues(sequence).length, 2)
    compare(Api.artistNames(sequence), "One, Two")
  }

  function test_searchScope_tracksTheOpenAreaAndSearchMode() {
    var artist = Api.searchScope("detail", {
      id: "artist-id", type: "artist", name: "Björk"
    }, null, "recent", "tracks")
    verify(artist.available)
    compare(artist.key, "detail:artist:artist-id")
    compare(artist.label, "Björk")
    compare(artist.mode, "artist")

    var playlist = Api.searchScope("playlists", null, {
      id: "playlist-id", type: "playlist", name: "Night drive"
    }, "recent", "tracks")
    verify(playlist.available)
    compare(playlist.key, "playlist:playlist-id")
    compare(playlist.label, "Night drive")
    compare(playlist.mode, "filter")

    compare(Api.searchScope("home", null, null, "frequent", "albums").label,
      "Frequently played")
    compare(Api.searchScope("home", null, null, "starred", "albums").label,
      "Starred")
    compare(Api.searchScope("library", null, null, "recent", "albums").label,
      "Saved albums")
    compare(Api.searchScope("library", null, null, "recent", "tracks").label,
      "Starred")
    verify(!Api.searchScope("library", null, null, "recent", "shows").available)
    verify(!Api.searchScope("search", null, null, "recent", "tracks").available)
    verify(!Api.searchScope("login", null, null, "recent", "tracks").available)
  }

  function test_universalSearchVisibility_isExplicitAndHiddenFromUtilityTabs() {
    verify(Api.universalSearchVisible("search", false))
    verify(!Api.universalSearchVisible("setup", true))
    verify(!Api.universalSearchVisible("setup", false))
    verify(!Api.universalSearchVisible("login", true))
  }

  function test_previousContentTab_skipsSettings() {
    compare(Api.previousContentTab("setup", "home"), "home")
    compare(Api.previousContentTab("setup", ""), "home")
    compare(Api.previousContentTab("home", "library"), "")
    compare(Api.rememberContentTab("setup"), "")
    compare(Api.rememberContentTab("playlists"), "playlists")
  }

  function test_playlistItemIds_keepsOrderAndDuplicates() {
    var ids = Api.playlistItemIds([
      { type: "track", id: "one" },
      { type: "track", id: "one" },
      { type: "album", id: "nope" },
      { type: "track", id: "" }
    ])
    compare(JSON.stringify(ids), JSON.stringify(["one", "one"]))
  }

  function test_playlistBackingItems_matchesStableIdsOnly() {
    var selectedItems = [{ name: "Selected song" }]
    var detailItems = [{ name: "Detail song" }]
    var refreshedContext = { id: "selected" }

    verify(Api.playlistBackingItems(refreshedContext,
      { id: "selected" }, selectedItems,
      { id: "detail", type: "playlist" }, detailItems) === selectedItems)
    verify(Api.playlistBackingItems({ id: "detail" },
      { id: "selected" }, selectedItems,
      { id: "detail", type: "playlist" }, detailItems) === detailItems)
    compare(Api.playlistBackingItems({ id: "unrelated" },
      { id: "selected" }, selectedItems,
      { id: "detail", type: "playlist" }, detailItems).length, 0)
    compare(Api.playlistBackingItems({ id: "detail" },
      { id: "selected" }, selectedItems,
      { id: "detail", type: "album" }, detailItems).length, 0)
  }

  function test_filteredSorted_filtersAndSortsWithoutMutatingSource() {
    var source = [
      { name: "Zulu", subtitle: "Someone", addedAt: "2026-01-01" },
      { name: "Alpha", subtitle: "Target artist", addedAt: "2026-08-01" },
      { name: "Unknown", subtitle: "No date" }
    ]
    var filtered = Api.filteredSorted(source, "target", "name")
    compare(filtered.length, 1)
    compare(filtered[0].name, "Alpha")

    var newest = Api.filteredSorted(source, "", "date")
    compare(newest[0].name, "Alpha")
    compare(newest[1].name, "Zulu")
    compare(newest[2].name, "Unknown")

    var oldest = Api.filteredSorted(source, "", "date-asc")
    compare(oldest[0].name, "Zulu")
    compare(oldest[1].name, "Alpha")
    compare(oldest[2].name, "Unknown")
    compare(source[0].name, "Zulu")
  }

  function test_touchHistory_deduplicatesAndCaps() {
    var history = Api.touchHistory(["old", "same", "older"], " same ", 3)
    compare(JSON.stringify(history), JSON.stringify(["same", "old", "older"]))
    history = Api.touchHistory(history, "new", 3)
    compare(JSON.stringify(history), JSON.stringify(["new", "same", "old"]))
  }

  function test_playlistPageState_keepsLoadingPastSharedCacheLimit() {
    var existing = []
    var incoming = []
    for (var i = 0; i < 200; i++) existing.push({ playlistPosition: i })
    for (var j = 200; j < 250; j++) incoming.push({ playlistPosition: j })
    var page = Api.playlistPageState(existing, incoming, true, "250")
    compare(page.items.length, 250)
    compare(page.items[0].playlistPosition, 0)
    compare(page.items[249].playlistPosition, 249)
    compare(page.next, "250")

    var refreshed = Api.playlistPageState(existing, incoming, false, "")
    verify(refreshed.items === incoming)
    compare(refreshed.items.length, 50)
    compare(refreshed.next, "")
  }

  function test_playlistRestoreCount_isBoundedAndContinuesOnlyWithNextPage() {
    compare(Api.normalizedPlaylistRestoreCount(undefined), 0)
    compare(Api.normalizedPlaylistRestoreCount(-10), 0)
    compare(Api.normalizedPlaylistRestoreCount(149.9), 149)
    compare(Api.normalizedPlaylistRestoreCount(999999), 10000)

    verify(Api.playlistRestorePending(50, 150, true, ""))
    verify(Api.playlistRestorePending(50, 150, false, "50"))
    verify(!Api.playlistRestorePending(150, 150, true, "50"))
    verify(!Api.playlistRestorePending(50, 150, false, ""))
    verify(Api.playlistRestoreShouldContinue(50, 150, "50"))
    verify(!Api.playlistRestoreShouldContinue(150, 150, "50"))
  }

  function test_playbackLoadBodyV2_preservesOccurrencesAndCapsLongLists() {
    // A playlist containing the same song twice must queue the occurrence
    // the user clicked, matched by row identity.
    var duplicateRows = [
      { kind: "item", id: "duplicate", uri: "navidrome:track:duplicate" },
      { kind: "item", id: "middle", uri: "navidrome:track:middle" },
      { kind: "item", id: "duplicate", uri: "navidrome:track:duplicate" },
      { kind: "item", id: "last", uri: "navidrome:track:last" }
    ]
    var body = Api.playbackLoadBodyV2(duplicateRows[2], duplicateRows, "")
    compare(body.songs[0].id, "duplicate")
    compare(body.songs[1].id, "last")

    var longRows = []
    for (var i = 0; i < 114; i++)
      longRows.push({ kind: "item", id: String(i) })
    var long = Api.playbackLoadBodyV2(longRows[110], longRows, "")
    compare(long.songs.length, Api.PLAYBACK_URI_LIMIT)
    compare(long.songs[0].id, "110")
    compare(long.songs[3].id, "113")
    compare(long.songs[4].id, "0")
    compare(long.songs[99].id, "95")
  }

  function test_visibleUiStartsTheLocalReceiver() {
    compare(Api.visibleLocalReceiverAction(false, true, false, false), "idle")
    compare(Api.visibleLocalReceiverAction(true, false, false, false), "idle")
    compare(Api.visibleLocalReceiverAction(true, true, false, true), "wait")
    compare(Api.visibleLocalReceiverAction(true, true, false, false), "start")
    compare(Api.visibleLocalReceiverAction(true, true, true, false), "idle")
  }

  function test_normalizedShortcutPlayer_mapsLegacyDefault() {
    compare(Api.normalizedShortcutPlayer("Omarchy default"), "Omarchy Music app")
    compare(Api.normalizedShortcutPlayer("Full player"), "Full player")
    compare(Api.normalizedShortcutPlayer("Mini player"), "Mini player")
    compare(Api.normalizedShortcutPlayer(""), "Omarchy Music app")
  }

  function test_repeatAndSearchLabels_areHumanReadable() {
    compare(Api.repeatModeLabel("off"), "Off")
    compare(Api.repeatModeLabel("track"), "This song")
    compare(Api.repeatModeLabel("context"), "All")
    compare(Api.searchTypeLabel("track"), "Songs")
    compare(Api.searchTypeLabel("album"), "Albums")
    compare(Api.searchTypeLabel("artist"), "Artists")
    compare(Api.searchTypeLabel("playlist"), "Playlists")
    // Podcast-family labels are gone with their library tabs; an unknown
    // type degrades to the generic label.
    compare(Api.searchTypeLabel("audiobook"), "results")
    compare(Api.mediaTypeLabel("track"), "Song")
    compare(Api.mediaTypeLabel("playlist"), "Playlist")
    compare(Api.mediaTypeLabel("unknown"), "Library item")
  }

  function test_backendLoadFieldsV2_mapsSubsonicSongs() {
    // A fully-populated Subsonic row keeps its shape under the protocol.
    // `duration` arrives in seconds and becomes duration_ms.
    compare(JSON.stringify(Api.backendLoadFieldsV2([{
      id: 42,
      title: "Song",
      artists: [{ id: "ar-1", name: "Artist" }],
      album: "Album",
      duration: 180,
      coverArt: "cr-9",
      track: 3
    }])), JSON.stringify({
      songs: [{
        id: "42",
        title: "Song",
        artists: ["Artist"],
        album: "Album",
        duration_ms: 180000,
        cover_art: "cr-9",
        track: 3
      }],
      play: true
    }))
    // Empty metadata fields are legal and simply omitted; only a usable id
    // is required for the engine to stream the song.
    compare(JSON.stringify(Api.backendLoadFieldsV2([{ id: "a2" }])),
      JSON.stringify({ songs: [{ id: "a2" }], play: true }))
  }

  function test_backendLoadFieldsV2_appliesOptionsAndDefaults() {
    var rows = [
      { id: "s1", title: "First", duration: 200 },
      { id: "s2", title: "Second", duration: 300 }
    ]
    compare(JSON.stringify(Api.backendLoadFieldsV2(rows, {
      offset_index: 1,
      position_ms: 1500,
      play: false
    })), JSON.stringify({
      songs: [
        { id: "s1", title: "First", duration_ms: 200000 },
        { id: "s2", title: "Second", duration_ms: 300000 }
      ],
      play: false,
      offset_index: 1,
      position_ms: 1500
    }))
    // play defaults to true; a zero resume position and offset are omitted.
    compare(JSON.stringify(Api.backendLoadFieldsV2(rows.slice(0, 1), {
      position_ms: 0
    })), JSON.stringify({
      songs: [{ id: "s1", title: "First", duration_ms: 200000 }],
      play: true
    }))
  }

  function test_backendSongRefV2_degradesPartialRowsSafely() {
    // Rows without normalized Subsonic fields degrade to their closest
    // field (name -> title, artist -> artists). A bare `duration` value at
    // or above 10000 is already milliseconds.
    compare(JSON.stringify(Api.backendSongRefV2({
      id: "subsonic-id",
      name: "Song",
      artist: "Artist",
      album: "Album",
      duration: 240000
    })), JSON.stringify({
      id: "subsonic-id",
      title: "Song",
      artists: ["Artist"],
      album: "Album",
      duration_ms: 240000
    }))
    // artists may be {name} objects or a single string; duplicates are
    // dropped and idless rows are rejected.
    compare(JSON.stringify(Api.backendSongRefV2({
      id: "77",
      artists: ["One", { name: "Two" }, "One", { name: "" }, null]
    })), JSON.stringify({ id: "77", artists: ["One", "Two"] }))
    compare(Api.backendSongRefV2({ title: "No identifier" }), null)
    compare(Api.backendSongRefV2(null), null)
  }

  function test_backendLoadFieldsV2_rejectsUnusableRequests() {
    compare(Api.backendLoadFieldsV2(null), null)
    compare(Api.backendLoadFieldsV2([]), null)
    compare(Api.backendLoadFieldsV2([{ title: "No identifier" }]), null)
  }

  function test_playbackLoadBodyV2_startsAtTheClickedRowAndWraps() {
    var rows = [
      { kind: "item", id: "a", title: "One" },
      { kind: "item", id: "b", title: "Two" },
      { kind: "context", title: "Ignored" },
      { kind: "item", id: "c", title: "Three", duration: 210 }
    ]
    compare(JSON.stringify(Api.playbackLoadBodyV2(rows[1], rows, 0)),
      JSON.stringify({
        songs: [
          { id: "b", title: "Two" },
          { id: "c", title: "Three", duration_ms: 210000 },
          { id: "a", title: "One" }
        ],
        play: true
      }))
    // A resume offset in milliseconds rides along for the clicked song; a
    // lone item without the list still loads; unusable requests return null.
    var solo = { kind: "item", id: "solo", title: "Solo", resumeMs: 9000 }
    compare(JSON.stringify(Api.playbackLoadBodyV2(solo, [solo], 9000)),
      JSON.stringify({
        songs: [{ id: "solo", title: "Solo" }],
        play: true,
        position_ms: 9000
      }))
    // A clicked row that is not list-identical is placed by its saved key.
    var repeated = Api.playbackLoadBodyV2(
      { kind: "item", id: "a", title: "One", resumeMs: 0 },
      [{ kind: "item", id: "x", title: "X" },
       { kind: "item", id: "a", title: "One" }], 0)
    compare(JSON.stringify(repeated.songs), JSON.stringify([
      { id: "a", title: "One" }, { id: "x", title: "X" }]))
    compare(Api.playbackLoadBodyV2(rows[2], rows, 0), null)
    compare(Api.playbackLoadBodyV2(null, rows, 0), null)
  }

  function test_playbackContextOffsetPosition_matchesBySavedKey() {
    var rows = [
      { kind: "item", type: "track", id: "tr-1" },
      { kind: "item", type: "track", id: "tr-2" },
      { kind: "item", type: "track", id: "tr-1" }
    ]
    // Row identity first, then the type:id key; duplicates keep the first
    // occurrence. A row without a usable id never matches.
    compare(Api.playbackContextOffsetPosition(rows[0], rows), 0)
    compare(Api.playbackContextOffsetPosition(
      { kind: "item", type: "track", id: "tr-1" }, rows), 0)
    compare(Api.playbackContextOffsetPosition(
      { kind: "item", type: "track", id: "tr-2" }, rows), 1)
    compare(Api.playbackContextOffsetPosition(
      { kind: "context", type: "album", id: "tr-1" }, rows), -1)
    compare(Api.playbackContextOffsetPosition(null, rows), -1)
  }

  function test_playbackSliderFeedbackWaitsForAuthoritativeValue() {
    verify(!Api.playbackSliderFeedbackComplete(
      0.2, 0.8, false, 100, 0.01, 300, 8000))
    verify(!Api.playbackSliderFeedbackComplete(
      0.8, 0.8, true, 500, 0.01, 300, 8000))
    verify(Api.playbackSliderFeedbackComplete(
      0.8, 0.8, false, 500, 0.01, 300, 8000))
    verify(Api.playbackSliderFeedbackComplete(
      0.2, 0.8, true, 8000, 0.01, 300, 8000))
  }

  function test_mergeUnique_preservesOrder() {
    var merged = Api.mergeUnique([
      { uri: "navidrome:track:a" },
      { uri: "navidrome:track:b" }
    ], [
      { uri: "navidrome:track:b" },
      { uri: "navidrome:track:c" }
    ])
    compare(merged.length, 3)
    compare(merged[0].uri, "navidrome:track:a")
    compare(merged[2].uri, "navidrome:track:c")
    // Canonical Subsonic rows dedupe on the type:id saved key.
    var canonical = Api.mergeUnique([
      { kind: "item", type: "track", id: "tr-1", uri: "navidrome:track:tr-1" },
      { kind: "context", type: "album", id: "al-1", uri: "navidrome:album:al-1" }
    ], [
      { kind: "item", type: "track", id: "tr-1", uri: "navidrome:track:tr-1" },
      { kind: "context", type: "album", id: "al-2", uri: "navidrome:album:al-2" }
    ])
    compare(canonical.length, 3)
    compare(canonical[0].id, "tr-1")
    compare(canonical[2].id, "al-2")
  }

  function test_redact_coversHeadersFormsUrlsAndJson() {
    var raw = [
      "Authorization: Bearer access-value",
      "refresh_token=refresh-value&code=authorization-value",
      "?code_verifier=verifier-value&client_secret=secret-value",
      // Subsonic request credentials and a full getCoverArt art_url: the
      // backend's art URL carries the auth token set and must never reach a
      // log line.
      "https://nav.example/rest/getCoverArt?id=cr-1&u=alice&t=token-value&s=salt-value",
      "{\"access_token\":\"json-token\",\"password\":\"nope\"}"
    ].join("\n")
    var safe = Api.redact(raw)

    verify(safe.indexOf("access-value") === -1)
    verify(safe.indexOf("refresh-value") === -1)
    verify(safe.indexOf("authorization-value") === -1)
    verify(safe.indexOf("verifier-value") === -1)
    verify(safe.indexOf("secret-value") === -1)
    verify(safe.indexOf("token-value") === -1)
    verify(safe.indexOf("salt-value") === -1)
    verify(safe.indexOf("=alice") === -1)
    verify(safe.indexOf("json-token") === -1)
    verify(safe.indexOf("\"nope\"") === -1)
    verify(safe.indexOf("<redacted>") >= 0)
    verify(safe.indexOf("rest/getCoverArt?id=cr-1&") >= 0)
  }

  function test_clockFormatting() {
    compare(Api.millisecondsToClock(0), "0:00")
    compare(Api.millisecondsToClock(61000), "1:01")
    compare(Api.millisecondsToClock(-100), "0:00")
  }

  function test_shortcutHints_matchRequiredModifiersAndKeycaps() {
    compare(Api.normalizedShortcutHints(undefined), "On")
    compare(Api.normalizedShortcutHints("On"), "On")
    compare(Api.normalizedShortcutHints("Off"), "Off")
    compare(Api.normalizedShortcutHints("off"), "On")

    var none = { ctrl: false, shift: false, alt: false }
    var ctrl = { ctrl: true, shift: false, alt: false }
    var shift = { ctrl: false, shift: true, alt: false }
    var ctrlShift = { ctrl: true, shift: true, alt: false }
    var altShift = { ctrl: false, shift: true, alt: true }

    compare(Api.shortcutHintCaption("Space", none, true), "Space")
    compare(Api.shortcutHintCaption("Space", ctrl, true), "")
    compare(Api.shortcutHintCaption("Ctrl+S", ctrl, true), "S")
    compare(Api.shortcutHintCaption("Ctrl+S", none, true), "")
    compare(Api.shortcutHintCaption("Ctrl+S", ctrlShift, true), "")
    compare(Api.shortcutHintCaption("Ctrl+Shift+L", ctrl, true), "")
    compare(Api.shortcutHintCaption("Ctrl+Shift+L", ctrlShift, true), "L")
    compare(Api.shortcutHintCaption("Shift+F10", ctrlShift, true), "")
    compare(Api.shortcutHintCaption("Ctrl+Shift+A", ctrlShift, true), "A")
    compare(Api.shortcutHintCaption("Alt+Shift+H", altShift, true), "H")
    compare(Api.shortcutHintCaption("Ctrl+Shift+A", altShift, true), "")
    compare(Api.shortcutHintCaption("Ctrl+Shift+B", ctrlShift, true), "B")
    compare(Api.shortcutHintCaption("Ctrl+Shift+A", ctrl, true), "")
    compare(Api.shortcutHintCaption("Alt+Left", { ctrl: false, shift: false, alt: true }, true), "←")
    compare(Api.shortcutHintCaption(["Ctrl+Up", "Ctrl+Down"], ctrl, true), "↑ ↓")
    compare(Api.shortcutHintCaption(["/", "Ctrl+F"], none, true), "/")
    compare(Api.shortcutHintCaption(["/", "Ctrl+F"], ctrl, true), "F")
    compare(Api.shortcutHintCaption("Shift+Right", shift, true), "→")
    compare(Api.shortcutHintCaption("Shift+F10", shift, true), "F10")
    compare(Api.shortcutHintCaption("Shift+F10", none, true), "")
    compare(Api.shortcutHintCaption("Menu", none, true), "Menu")
    compare(Api.shortcutOverlayLabel("Shift+F10", shift, true, "↵"), "↵ F10")
    compare(Api.shortcutOverlayLabel("Shift+F10", shift, true, ""), "F10")
    compare(Api.shortcutHintCaption("C", none, true), "C")
    compare(Api.shortcutOverlayLabel("C", none, true, "↵"), "↵ C")
    compare(Api.shortcutHintCaption("Ctrl+,", ctrl, true), ",")
    compare(Api.shortcutHintCaption("Ctrl+/", ctrl, true), "/")
    compare(Api.shortcutHintCaption("Esc", none, true), "Esc")
    compare(Api.shortcutHintCaption("Space", none, false), "")
    compare(Api.shortcutOverlayLabel("Space", none, true, "Tab"), "Tab Space")
    compare(Api.shortcutOverlayLabel(["/", "Ctrl+F"], none, true, "Tab"), "Tab /")
    compare(Api.shortcutOverlayLabel("Space", none, true, ""), "Space")
    compare(Api.shortcutOverlayLabel("Space", none, true, "↵"), "↵ Space")
    compare(Api.shortcutOverlayLabel("Ctrl+S", none, true, ""), "")
    compare(Api.shortcutOverlayLabel("Space", none, false, "Tab"), "")
    compare(Api.shortcutModifierFlagsAfterEvent(0, false, 3, 0), 3)
    compare(Api.shortcutModifierFlagsAfterEvent(3, true, 0, 1), 3)
    compare(Api.shortcutModifierFlagsAfterEvent(3, false, 3, 1), 2)
    compare(Api.shortcutModifierFlagsAfterEvent(1, false, 1, 1), 0)
    compare(Api.shortcutModifierFlagsAfterEvent(3, true, 0, 0), 3)
  }

  function test_searchShortcutAction_startsGlobalThenTogglesScope() {
    compare(Api.searchShortcutAction(false, true, true), "enter-global")
    compare(Api.searchShortcutAction(false, true, false), "focus")
    compare(Api.searchShortcutAction(true, true, true), "toggle-scope")
    compare(Api.searchShortcutAction(true, true, false), "toggle-scope")
    compare(Api.searchShortcutAction(false, false, true), "focus")
    compare(Api.searchShortcutAction(true, false, false), "focus")
  }

  function test_cursorNavigation_wrapsAndLeavesLists() {
    compare(Api.ensureCursorAction(["play", "next"], "shuffle", "play"), "play")
    compare(Api.ensureCursorAction(["play", "next"], "next", "play"), "next")
    compare(Api.moveCursorAction(["shuffle", "play", "next"], "play", 1), "next")
    compare(Api.moveCursorAction(["shuffle", "play", "next"], "next", 1), "shuffle")
    compare(Api.moveCursorAction(["shuffle", "play", "next"], "shuffle", -1), "next")
    compare(Api.listIndexAfterMove(3, 0, 1), 1)
    compare(Api.listIndexAfterMove(3, 2, 1), -1)
    compare(Api.listIndexAfterMove(3, 0, -1), -1)
    compare(Api.listIndexAfterMove(3, -1, 1), 0)
  }

  function test_cursorNavHint_marksTabAndArrowDestinations() {
    var query = {
      currentRegion: "footer",
      currentAction: "play",
      regionActions: ["previous", "play", "next"],
      tabRegion: "sidebar",
      tabAction: "nav-home",
      backtabRegion: "page",
      backtabAction: "list",
      modifiersHeld: false
    }
    compare(Api.cursorNavHint(Api.assign(Api.assign({}, query), {
      region: "footer", action: "play"
    })), "↵")
    compare(Api.cursorNavHint(Api.assign(Api.assign({}, query), {
      region: "footer", action: "next"
    })), "↓")
    compare(Api.cursorNavHint(Api.assign(Api.assign({}, query), {
      region: "footer", action: "previous"
    })), "↑")
    compare(Api.cursorNavHint(Api.assign(Api.assign({}, query), {
      region: "sidebar", action: "nav-home"
    })), "Tab")
    compare(Api.cursorNavHint(Api.assign(Api.assign({}, query), {
      region: "page", action: "list"
    })), "⇧Tab")
    compare(Api.cursorNavHint(Api.assign(Api.assign({}, query), {
      region: "footer", action: "next", modifiersHeld: true
    })), "")
    compare(Api.cursorNavHint(Api.assign(Api.assign({}, query), {
      region: "sidebar", action: "nav-home", modifiersHeld: true
    })), "Tab")
    compare(Api.cursorNavHint({
      region: "popup",
      action: "sleep-30",
      currentRegion: "popup",
      currentAction: "sleep-15",
      regionActions: ["sleep-15", "sleep-30", "sleep-cancel"],
      tabRegion: "popup",
      tabAction: "sleep-30"
    }), "Tab")
    compare(Api.cursorNavHint({
      region: "footer",
      action: "play",
      currentRegion: "footer",
      currentAction: "play",
      tabRegion: "footer",
      tabAction: "play",
      cursorActive: false
    }), "Tab")
  }

  function test_cursorListRowHint_marksTheRowsArrowsWouldPress() {
    var list = {
      count: 5,
      currentIndex: 3,
      atList: true,
      modifiersHeld: false
    }
    compare(Api.cursorListRowHint(Api.assign({ rowIndex: 3 }, list)), "↵")
    compare(Api.cursorListRowHint(Api.assign({ rowIndex: 2 }, list)), "↑")
    compare(Api.cursorListRowHint(Api.assign({ rowIndex: 4 }, list)), "↓")
    compare(Api.cursorListRowHint(Api.assign({ rowIndex: 0 }, list)), "")
    compare(Api.cursorListRowHint({
      rowIndex: 0, count: 5, currentIndex: 3, previousIsCurrent: true
    }), "↓")
    compare(Api.cursorListRowHint({
      rowIndex: 4, count: 5, currentIndex: 3, nextIsCurrent: true
    }), "↑")
    compare(Api.cursorNavHint({
      region: "sidebar",
      action: "nav-settings",
      currentRegion: "sidebar",
      currentAction: "sidebar-playlists",
      regionActions: ["nav-playlists", "sidebar-playlists", "nav-settings"],
      listAction: "sidebar-playlists",
      listIndex: 3,
      listCount: 8
    }), "")
    compare(Api.cursorNavHint({
      region: "sidebar",
      action: "nav-settings",
      currentRegion: "sidebar",
      currentAction: "sidebar-playlists",
      regionActions: ["nav-playlists", "sidebar-playlists", "nav-settings"],
      listAction: "sidebar-playlists",
      listIndex: 7,
      listCount: 8
    }), "↓")
    compare(Api.cursorListRowHint({
      rowIndex: 3, count: 8, currentIndex: 3, tabIsList: true, tabRowIndex: 1
    }), "")
    compare(Api.cursorListRowHint({
      rowIndex: 1, count: 8, currentIndex: 3, tabIsList: true, tabRowIndex: 1
    }), "Tab")
    compare(Api.cursorListRowHint({
      rowIndex: 1, count: 8, currentIndex: 3, tabIsList: true, tabRowIndex: 1,
      modifiersHeld: true
    }), "Tab")
    compare(Api.cursorListRowHint({
      rowIndex: 3, count: 5, currentIndex: 3, atList: true, tabIsList: true
    }), "↵")
    compare(Api.listHintRowIndex(8, 1), 1)
    compare(Api.listHintRowIndex(8, -1), 0)
    compare(Api.listHintRowIndex(0, 0), -1)
  }

  function test_tabCursorDestination_entersTheSongListThenLeaves() {
    var regions = ["sidebar", "header", "page", "footer"]
    var actionsByRegion = {
      sidebar: ["nav-home", "nav-playlists", "sidebar-playlists", "nav-settings"],
      header: ["search", "help", "close"],
      page: ["playlist-play", "playlist-more", "sort", "list", "more"],
      footer: ["shuffle", "play", "next"]
    }
    var base = {
      regions: regions,
      actionsByRegion: actionsByRegion,
      pageActions: actionsByRegion.page,
      listCount: 12
    }
    function dest(region, action, back) {
      return Api.tabCursorDestination(Api.assign(Api.assign({}, base), {
        currentRegion: region,
        currentAction: action,
        back: back === true
      }))
    }
    var next = dest("header", "search")
    compare(next.region, "page")
    compare(next.action, "list")
    next = dest("page", "playlist-play")
    compare(next.region, "page")
    compare(next.action, "list")
    next = dest("page", "sort")
    compare(next.region, "page")
    compare(next.action, "list")
    next = dest("page", "list")
    compare(next.region, "footer")
    compare(next.action, "play")
    next = dest("page", "more")
    compare(next.region, "footer")
    compare(next.action, "play")
    next = dest("footer", "play")
    compare(next.region, "sidebar")
    compare(next.action, "nav-home")
    next = dest("footer", "play", true)
    compare(next.region, "page")
    compare(next.action, "list")
    next = dest("page", "list", true)
    compare(next.region, "page")
    compare(next.action, "sort")
    next = dest("page", "more", true)
    compare(next.region, "page")
    compare(next.action, "list")
    next = dest("page", "playlist-play", true)
    compare(next.region, "header")
    compare(next.action, "search")
    next = dest("header", "search", true)
    compare(next.region, "sidebar")
    compare(next.action, "nav-settings")
    next = Api.tabCursorDestination(Api.assign(Api.assign({}, base), {
      currentRegion: "footer",
      currentAction: "play",
      cursorActive: false
    }))
    compare(next.region, "footer")
    compare(next.action, "play")
    var searchPage = ["search-track", "search-artist", "search-album", "list"]
    next = Api.tabCursorDestination({
      regions: regions,
      currentRegion: "header",
      currentAction: "scope",
      pageActions: searchPage,
      actionsByRegion: {
        sidebar: actionsByRegion.sidebar,
        header: actionsByRegion.header,
        page: searchPage,
        footer: actionsByRegion.footer
      },
      listCount: 8,
      pageLanding: "search-track"
    })
    compare(next.region, "page")
    compare(next.action, "search-track")
    next = Api.tabCursorDestination({
      regions: regions,
      currentRegion: "page",
      currentAction: "search-track",
      pageActions: searchPage,
      actionsByRegion: {
        sidebar: actionsByRegion.sidebar,
        header: actionsByRegion.header,
        page: searchPage,
        footer: actionsByRegion.footer
      },
      listCount: 8,
      pageLanding: "search-track"
    })
    compare(next.region, "page")
    compare(next.action, "list")
    var artistPage = ["detail-play", "list-albums", "list-songs", "detail-thisis"]
    next = Api.tabCursorDestination({
      regions: regions,
      currentRegion: "header",
      currentAction: "search",
      pageActions: artistPage,
      actionsByRegion: {
        sidebar: actionsByRegion.sidebar,
        header: actionsByRegion.header,
        page: artistPage,
        footer: actionsByRegion.footer
      },
      listCount: 6
    })
    compare(next.region, "page")
    compare(next.action, "list-albums")
    next = Api.tabCursorDestination({
      regions: regions,
      currentRegion: "page",
      currentAction: "list-albums",
      pageActions: artistPage,
      actionsByRegion: {
        sidebar: actionsByRegion.sidebar,
        header: actionsByRegion.header,
        page: artistPage,
        footer: actionsByRegion.footer
      },
      listCount: 6
    })
    compare(next.region, "page")
    compare(next.action, "list-songs")
    next = Api.tabCursorDestination({
      regions: regions,
      currentRegion: "page",
      currentAction: "list-songs",
      pageActions: artistPage,
      actionsByRegion: {
        sidebar: actionsByRegion.sidebar,
        header: actionsByRegion.header,
        page: artistPage,
        footer: actionsByRegion.footer
      },
      listCount: 6
    })
    compare(next.region, "footer")
    compare(next.action, "play")
    verify(Api.isCursorListAction("list"))
    verify(Api.isCursorListAction("list-songs"))
    verify(!Api.isCursorListAction("sort"))
  }

  function test_tabCursorDestination_skipsEmptyListsAndCyclesPopups() {
    var empty = Api.tabCursorDestination({
      regions: ["header", "page", "footer"],
      currentRegion: "header",
      currentAction: "search",
      pageActions: ["sort", "list"],
      actionsByRegion: {
        header: ["search"],
        page: ["sort", "list"],
        footer: ["play"]
      },
      listCount: 0
    })
    compare(empty.region, "page")
    compare(empty.action, "sort")
    var popup = Api.tabCursorDestination({
      regions: ["popup"],
      currentRegion: "popup",
      currentAction: "sleep-15",
      actionsByRegion: { popup: ["sleep-15", "sleep-30", "sleep-cancel"] }
    })
    compare(popup.region, "popup")
    compare(popup.action, "sleep-30")
  }

  function test_searchEscapeAction_clearsThenReleasesFocus() {
    compare(Api.searchEscapeAction(true, true, "query", false), "dismiss")
    compare(Api.searchEscapeAction(true, false, "query", false), "dismiss")
    compare(Api.searchEscapeAction(true, false, "", true), "dismiss")
    compare(Api.searchEscapeAction(true, true, "", false), "blur")
    compare(Api.searchEscapeAction(true, true, "   ", false), "blur")
    compare(Api.searchEscapeAction(true, false, "", false), "")
    compare(Api.searchEscapeAction(false, true, "query", true), "")
  }

  function test_opaqueSurface_floorsAlphaAndKeepsHue() {
    var glass = Qt.rgba(0.95, 0.95, 0.97, 0.3)
    var floored = Api.opaqueSurface(glass, 0.96)
    fuzzyCompare(floored.a, 0.96, 0.001)
    fuzzyCompare(floored.r, 0.95, 0.001)
    fuzzyCompare(floored.b, 0.97, 0.001)
    var solid = Qt.rgba(0.1, 0.1, 0.1, 1)
    compare(Api.opaqueSurface(solid, 0.96), solid)
    compare(Api.opaqueSurface(null, 0.96), null)
  }

  function test_barSlotWidth_fixedReservesTheCapAndCappedTrimsOnly() {
    compare(Api.barSlotWidth(false, 240, 180, 32), 180)
    compare(Api.barSlotWidth(false, 240, 400, 32), 240)
    compare(Api.barSlotWidth(true, 240, 180, 32), 240)
    compare(Api.barSlotWidth(true, 240, 400, 32), 240)
    compare(Api.barSlotWidth(true, 0, 180, 32), 180)
    compare(Api.barSlotWidth(false, 0, 400, 32), 400)
    compare(Api.barSlotWidth(true, 240, 0, 32), 240)
    compare(Api.barSlotWidth(false, 240, 10, 32), 32)
    compare(Api.barSlotWidth(false, "240", "180", "32"), 180)
  }

  function test_resumePlaybackAvailable_needsIdleReceiverAndCandidate() {
    var candidate = { item: { id: "al-rec", name: "x" } }
    compare(Api.resumePlaybackAvailable(false, candidate), true)
    compare(Api.resumePlaybackAvailable(true, candidate), false)
    compare(Api.resumePlaybackAvailable(false, null), false)
    compare(Api.resumePlaybackAvailable(false, { item: null }), false)
    compare(Api.resumePlaybackAvailable(false, { item: { id: "" } }), false)
  }

  function test_playbackVisibleOrder_followsFiltersAndSorts() {
    // Subsonic playback is always the displayed list; a filter or a
    // non-default sort is exactly the display the user asked for.
    verify(Api.playbackUsesVisibleOrder("miles", "default"))
    verify(Api.playbackUsesVisibleOrder("", "name"))
    verify(!Api.playbackUsesVisibleOrder("", "default"))
    compare(Api.visibleOrderPlaybackMessage(12), "Playing the displayed order")
    verify(Api.visibleOrderPlaybackMessage(114).indexOf("100 items") >= 0)
    compare(Api.PLAYBACK_URI_LIMIT, 100)
  }

  // ---- canonical Subsonic rows -------------------------------------------------

  function test_subsonicSongRow_carriesTheViewContract() {
    var art = Api.subsonicArtContext("https://nav.example", "user",
      "secret", "salt123")
    var row = Api.subsonicSongRow(Subsonic.normalizeSong({
      id: "tr-1", title: "Blue in Green", artist: "Miles Davis",
      artistId: "ar-1", album: "Kind of Blue", albumId: "al-1",
      duration: 337, track: 3, year: 1959, coverArt: "al-1", starred: true
    }), art)
    compare(row.kind, "item")
    compare(row.type, "track")
    compare(row.id, "tr-1")
    compare(row.uri, "navidrome:track:tr-1")
    compare(row.name, "Blue in Green")
    compare(row.subtitle, "Miles Davis")
    compare(row.album, "Kind of Blue")
    compare(row.artists.length, 1)
    compare(row.artists[0].kind, "context")
    compare(row.artists[0].type, "artist")
    compare(row.artists[0].id, "ar-1")
    compare(row.albumItem.type, "album")
    compare(row.albumItem.id, "al-1")
    compare(row.durationMs, 337000)
    compare(row.duration, 337)
    compare(row.trackNumber, 3)
    verify(row.starred)
    // The artwork URL is a pinned-salt getCoverArt request, so it stays
    // stable across rebuilds and carries no Spotify vocabulary.
    verify(row.imageUrl.indexOf("https://nav.example/rest/getCoverArt") === 0)
    verify(row.imageUrl.indexOf("salt123") > 0)
    verify(Api.subsonicSongRow(null, art) === null)

    var bare = Api.subsonicSongRow(Subsonic.normalizeSong({
      id: "tr-2", title: "So What"
    }), art, { kind: "context", type: "album", id: "al-9", name: "Parent" })
    compare(bare.subtitle, "")
    compare(bare.albumItem.id, "al-9")
    verify(bare.imageUrl === "")
  }

  function test_subsonicCollectionRows_shapeContexts() {
    var art = Api.subsonicArtContext("https://nav.example", "user",
      "secret", "salt123")
    var album = Api.subsonicAlbumRow(Subsonic.normalizeAlbum({
      id: "al-1", name: "Kind of Blue", artist: "Miles Davis",
      artistId: "ar-1", songCount: 5, duration: 1400, year: 1959,
      coverArt: "al-1", starred: true
    }), art)
    compare(album.kind, "context")
    compare(album.type, "album")
    compare(album.uri, "navidrome:album:al-1")
    compare(album.subtitle, "Miles Davis · 1959")
    compare(album.total, 5)
    compare(album.artists[0].id, "ar-1")
    verify(album.starred)

    var artist = Api.subsonicArtistRow(Subsonic.normalizeArtist({
      id: "ar-1", name: "Miles Davis", albumCount: 12
    }), art)
    compare(artist.type, "artist")
    compare(artist.total, 12)
    verify(Api.subsonicArtistRow({ id: "x" }, art) === null)

    var playlist = Api.subsonicPlaylistRow(Subsonic.normalizePlaylist({
      id: "pl-1", name: "Night drive", owner: "tray", songCount: 9,
      duration: 2000, public: true, comment: "notes"
    }), art)
    compare(playlist.type, "playlist")
    compare(playlist.subtitle, "tray")
    compare(playlist.ownerId, "tray")
    compare(playlist.total, 9)
    verify(playlist.public)
    verify(!playlist.collaborative)

    // A SongRef (backend get_saved_queue answer) maps back to a row.
    var refRow = Api.subsonicSongRefRow({
      id: "tr-7", title: "So What", artists: ["Miles Davis"],
      album: "Kind of Blue", duration_ms: 54000
    })
    compare(refRow.type, "track")
    compare(refRow.subtitle, "Miles Davis")
    compare(refRow.durationMs, 54000)
    // A SongRef carries no star truth: the field stays undefined so
    // checkSavedItems never records a guess as server state.
    compare(refRow.starred, undefined)
    verify(Api.subsonicSongRefRow({ title: "no id" }) === null)
  }

  function test_subsonicSearchGroups_fillOnlyTheAskedWindow() {
    var art = Api.subsonicArtContext("https://nav.example", "user",
      "secret", "salt123")
    var songs = []
    for (var i = 0; i < 20; i++)
      songs.push(Subsonic.normalizeSong({ id: "tr-" + i, title: "Song " + i }))
    var parsed = {
      artists: [Subsonic.normalizeArtist({ id: "ar-1", name: "Miles Davis" })],
      albums: [],
      songs: songs
    }
    var trackGroups = Api.subsonicSearchGroups(parsed, "track", art, 20, 0)
    compare(trackGroups.track.items.length, 20)
    compare(trackGroups.track.next, "20")
    compare(trackGroups.track.total, 20)
    compare(trackGroups.artist.items.length, 0)
    verify(trackGroups.show === undefined)

    var shortWindow = Api.subsonicSearchGroups(
      { artists: [], albums: [], songs: [] }, "track", art, 20, 0)
    compare(shortWindow.track.next, "")
    compare(shortWindow.track.items.length, 0)

    compare(Api.search3WindowType("album"), "album")
    compare(Api.search3WindowType("artist"), "artist")
    compare(Api.search3WindowType("episode"), "song")
    compare(Api.search3WindowParams("track", 0).songCount, 20)
    compare(Api.search3WindowParams("album", 40).albumOffset, 40)
  }

  function test_savedKeyFor_namespacesByType() {
    compare(Api.savedKeyFor({ id: "42", type: "track" }), "track:42")
    compare(Api.savedKeyFor({ id: "42", type: "album" }), "album:42")
    compare(Api.savedKeyFor({ id: "42" }), "track:42")
    compare(Api.savedKeyFor({ type: "track" }), "")
    compare(Api.savedKeyFor(null), "")
  }

  function test_starredRows_splitByKind() {
    var art = Api.subsonicArtContext("https://nav.example", "user",
      "secret", "salt123")
    var rows = Api.subsonicStarredRows({
      starred2: {
        song: [{ id: "tr-1", title: "A", duration: 100 }],
        album: [{ id: "al-1", name: "B" }],
        artist: [{ id: "ar-1", name: "C" }]
      }
    }, art)
    compare(rows.songs.length, 1)
    compare(rows.songs[0].type, "track")
    compare(rows.albums.length, 1)
    compare(rows.albums[0].type, "album")
    compare(rows.artists.length, 1)
    compare(rows.artists[0].type, "artist")
    verify(Api.subsonicStarredRows(null, art).songs.length === 0)
  }

  function test_subsonicAlbumListRows_parseTheWindow() {
    var art = Api.subsonicArtContext("https://nav.example", "user",
      "secret", "salt123")
    var rows = Api.subsonicAlbumListRows({
      albumList2: { album: [
        { id: "al-1", name: "One", songCount: 2 },
        { name: "no id" },
        { id: "al-2", name: "Two", songCount: 3 }
      ] }
    }, art)
    compare(rows.length, 2)
    compare(rows[0].id, "al-1")
    compare(rows[1].id, "al-2")
    verify(Subsonic.albumList2Params("recent", 30, 0) !== null)
    compare(Subsonic.albumList2Params("bogus", 30, 0), null)
  }

  function test_stripImageUrls_scrubsCredentialUrlsFromSessionState() {
    var state = {
      detailItem: { name: "Album", imageUrl: "https://nav/rest/getCoverArt?u=u&t=t" },
      nested: [{ imageUrl: "x", keep: 1 }],
      scrollPositions: { "home:recent": 42 }
    }
    var scrubbed = Api.normalizedSessionState(state)
    verify(scrubbed.detailItem.imageUrl === undefined)
    verify(scrubbed.detailItem.name === "Album")
    verify(scrubbed.nested[0].imageUrl === undefined)
    compare(scrubbed.nested[0].keep, 1)
    compare(scrubbed.scrollPositions["home:recent"], 42)
  }

  function test_idleMediaText_prefersLiveThenLastPlayedThenLabel() {
    var item = { name: "Blue in Green", subtitle: "Miles Davis", imageUrl: "" }
    compare(Api.idleMediaText("Live", item, "name", "Nothing playing"), "Live")
    compare(Api.idleMediaText("", item, "name", "Nothing playing"), "Blue in Green")
    compare(Api.idleMediaText("", item, "imageUrl", ""), "")
    compare(Api.idleMediaText("", null, "name", "Nothing playing"), "Nothing playing")
    compare(Api.idleMediaText("", item, "missing", ""), "")
  }
}
