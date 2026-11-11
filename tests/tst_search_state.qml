import QtQuick
import QtTest
import ".." as Plugin
import "../Api.js" as Api
import "../Subsonic.js" as Subsonic

TestCase {
  id: testCase
  name: "SearchState"
  property var calls: []
  QtObject {
    id: transport
    // Search3-shaped mock: one serialized request per call, the same
    // handle/abort contract SubsonicApi exposes.
    function search3(term, limits, callback) {
      var handle = { term: term, limits: limits, callback: callback, aborted: false }
      testCase.calls.push(handle)
      return handle
    }
    function cancelSearch() {}
    function abortRequest(handle) { if (handle) handle.aborted = true }
    function request(endpoint, params, callback, options) {
      var handle = { endpoint: endpoint, params: params, callback: callback,
        options: options, aborted: false }
      testCase.calls.push(handle)
      return handle
    }
  }
  Component { id: controller; Plugin.SearchController { api: transport } }
  function init() { calls = [] }
  // search3 window fixtures: parseSearch3-shaped results, one category each.
  function test_pendingAndEmptyResultsAreReused() {
    var state = createTemporaryObject(controller, testCase)
    state.search("hello", "track")
    state.search("hello", "track")
    compare(calls.length, 1)
    calls[0].callback({ ok: true, results: Subsonic.parseSearch3({
      searchResult3: { song: [{ id: "tr-1", title: "Song" }] }
    }) })
    compare(state.searchItems("track").length, 1)
    state.search("hello", "album")
    calls[1].callback({ ok: true, results: Subsonic.parseSearch3({
      searchResult3: { album: [{ id: "al-1", name: "Album" }] }
    }) })
    state.search("hello", "track")
    compare(calls.length, 2)
    state.search("hello", "track", true)
    compare(calls.length, 3)
    calls[2].callback({ ok: true, results: Subsonic.parseSearch3({
      searchResult3: { song: [{ id: "tr-2", title: "Again" }] }
    }) })
    state.search("hello", "album")
    compare(calls.length, 3)
  }
  function test_obsoletePaginationIsAbortedAndIgnored() {
    var state = createTemporaryObject(controller, testCase)
    state.search("first", "track")
    calls[0].callback({ ok: true, results: Subsonic.parseSearch3({
      searchResult3: { song: [] }
    }) })
    // A short window has no continuation, so fill a full window first.
    state.clearSearch()
    calls = []
    state.search("second", "track")
    calls[0].callback({ ok: true, results: fullWindow("song") })
    compare(state.searchNext("track"), "20")
    state.loadMoreSearch("track")
    var page = calls[1]
    compare(page.endpoint, "search3")
    state.search("third", "track")
    verify(page.aborted)
    page.callback({ ok: false, errorMessage: "late failure" })
    verify(state.searchLoading)
    compare(state.searchError, "")
    state.clearSearch()
    calls[1].callback({ ok: true, results: Subsonic.parseSearch3({
      searchResult3: { song: [] }
    }) })
    compare(state.searchQuery, "")
    compare(state.searchLoadedTypes.track, undefined)
  }
  function fullWindow(container) {
    var songs = []
    for (var i = 0; i < 20; i++) songs.push({ id: "tr-" + i, title: "Song " + i })
    return Subsonic.parseSearch3({ searchResult3: { song: songs } })
  }
  function test_emptyPageFailureRetriesPageAndAccountChangeClears() {
    var state = createTemporaryObject(controller, testCase)
    state.search("first", "track")
    calls[0].callback({ ok: true, results: fullWindow("song") })
    state.loadMoreSearch("track")
    calls[1].callback({ ok: false, errorMessage: "failed" })
    state.retrySearch("track")
    compare(calls[2].endpoint, "search3")
    state.dataSerial++
    verify(calls[2].aborted)
    compare(state.searchQuery, "")
    verify(!state.searchLoading)
  }
  function test_searchFailureReportsTheTypedError() {
    var state = createTemporaryObject(controller, testCase)
    state.search("miles", "track")
    calls[0].callback({ ok: false, errorCategory: "wrongCredentials",
      errorMessage: "Wrong username or password" })
    verify(!state.searchLoading)
    compare(state.searchError, "Wrong username or password")
    compare(state.searchItems("track").length, 0)
    verify(!state.searchLoadedTypes.track)
  }
  function test_playlistSearchFiltersTheServerListByName() {
    var state = createTemporaryObject(controller, testCase)
    state.search("night", "playlist")
    compare(calls.length, 1)
    compare(calls[0].endpoint, "getPlaylists")
    calls[0].callback({ ok: true, data: {
      playlists: {
        playlist: [
          { id: "pl-1", name: "Night drive", owner: "me" },
          { id: "pl-2", name: "Party hits", owner: "me" },
          { id: "pl-3", name: "Another Night Shift", owner: "me" }
        ]
      }
    } })
    var rows = state.searchItems("playlist")
    compare(rows.length, 2)
    compare(rows[0].id, "pl-1")
    compare(rows[1].id, "pl-3")
    compare(rows[0].type, "playlist")
    compare(rows[0].ownerId, "me")
    compare(state.searchNext("playlist"), "")
  }
}
