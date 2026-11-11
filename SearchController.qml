import QtQuick
import "Api.js" as Api
import "Subsonic.js" as Subsonic

Item {
  id: root
  required property var api
  // Pinned artwork context ({serverUrl, username, password, salt}) used when
  // building canonical rows; Service supplies it so getCoverArt URLs stay
  // stable across rebuilds.
  property var subsonicArt: null
  property int dataSerial: 0
  signal rememberSearch(string term)
  signal checkSavedItems(var items)
  function safeError(error) { return Api.redact(error) }
  property string searchQuery: ""
  property var searchGroups: Api.searchGroups({}, 128)
  property string searchError: ""
  property string searchResultQuery: ""
  property string searchActiveType: "track"
  property string searchPendingType: ""
  property var searchLoadedTypes: ({})
  property int searchGeneration: 0
  property bool searchLoading: false
  property var pageRequest: null
  property string retryMode: "initial"
  onDataSerialChanged: clearSearch()

  function progressText(timestamp) {
    var handle = pageRequest || api.searchRequest
    var job = handle ? handle.job : null
    if (job && !job.startedAt) return "Search queued…"
    if (job && !job.sentAt) return "Connecting to the server…"
    return "Fetching results from the server…"
  }

  // search3 serves artists, albums, and songs as bounded windows; playlists
  // have no search verb, so that type filters the server's playlist list by
  // name. The public semantics are unchanged: one first page per type,
  // offset pagination for the search3 categories, generation checks, and
  // generation-guarded merges.
  function typeUsesSearch3(value) {
    return value !== "playlist"
  }

  function deliverSearch(groups, error, term, value) {
    root.searchLoading = false
    root.searchPendingType = ""
    if (error) {
      root.searchError = root.safeError(error)
      return
    }
    var incoming = ({})
    incoming[value] = groups[value]
    root.searchGroups = Api.mergeSearchGroups(root.searchGroups, incoming)
    var loaded = Api.shallowCopy(root.searchLoadedTypes)
    loaded[value] = true
    root.searchLoadedTypes = loaded
    root.searchError = ""
    root.rememberSearch(term)
    root.checkSavedItems(root.searchItems(value))
  }

  function search(term, type, force) {
    var normalized = String(term || "").trim()
    var value = Api.normalizedSearchType(type)
    if (force !== true && searchLoading && searchQuery === normalized
        && searchPendingType === value) return
    cancelSearch(false)
    searchQuery = normalized
    searchActiveType = value
    if (!normalized) {
      clearSearch()
      return
    }
    if (searchResultQuery !== normalized) {
      api.cancelSearch()
      searchGeneration++
      searchResultQuery = normalized
      searchGroups = Api.searchGroups({}, 128)
      searchLoadedTypes = ({})
    }
    if (force === true) {
      var refreshedGroups = Api.shallowCopy(searchGroups)
      refreshedGroups[value] = Api.normalizeSearchPage({}, value, 128)
      searchGroups = refreshedGroups
      var refreshedTypes = Api.shallowCopy(searchLoadedTypes)
      refreshedTypes[value] = false
      searchLoadedTypes = refreshedTypes
    }
    if (searchLoadedTypes[value] === true) {
      api.cancelSearch()
      searchGeneration++
      searchPendingType = ""
      searchLoading = false
      searchError = ""
      return
    }
    retryMode = "initial"
    searchLoading = true
    searchError = ""
    searchPendingType = value
    var expected = dataSerial
    var expectedSearch = ++searchGeneration
    if (!typeUsesSearch3(value)) {
      api.request("getPlaylists", {}, function(result) {
        if (expected !== root.dataSerial
            || expectedSearch !== root.searchGeneration) return
        if (root.searchQuery !== normalized) return
        var rows = []
        if (result && result.ok === true) {
          var playlists = Subsonic.parsePlaylists(result.data)
          for (var i = 0; i < playlists.length; i++) {
            if (!Api.playlistMatchesTerm(playlists[i], normalized)) continue
            var row = Api.subsonicPlaylistRow(playlists[i], root.subsonicArt)
            if (row) rows.push(row)
          }
        }
        var groups = Api.searchGroups({}, 128)
        groups[value] = { items: rows, next: "", total: rows.length }
        var error = result && result.ok === true
          ? "" : String(result && result.errorMessage || "Search failed")
        root.deliverSearch(groups, error, normalized, value)
      }, { priority: "interactive", timeoutMs: Api.SEARCH_REQUEST_TIMEOUT_MS })
      return
    }
    api.search3(normalized, Api.search3WindowParams(value, 0),
      function(result) {
        if (expected !== root.dataSerial
            || expectedSearch !== root.searchGeneration) return
        if (root.searchQuery !== normalized) return
        var error = result && result.ok === true
          ? "" : String(result && result.errorMessage || "Search failed")
        var groups = result && result.ok === true
          ? Api.subsonicSearchGroups(result.results, value, root.subsonicArt,
            20, 0)
          : Api.searchGroups({}, 128)
        root.deliverSearch(groups, error, normalized, value)
      })
  }

  function searchItems(type) {
    var page = searchGroups[String(type || "track")]
    return page && Array.isArray(page.items) ? page.items : []
  }

  function searchNext(type) {
    var page = searchGroups[String(type || "track")]
    return page ? String(page.next || "") : ""
  }

  function loadMoreSearch(type) {
    var value = Api.normalizedSearchType(type)
    var path = searchNext(value)
    if (!path || searchLoading) return
    var expected = dataSerial
    var expectedQuery = searchResultQuery
    var expectedSearch = ++searchGeneration
    searchLoading = true
    searchError = ""
    searchPendingType = value
    retryMode = "page"
    var offset = Math.max(0, Math.floor(Number(path) || 0))
    pageRequest = api.request("search3", Api.search3WindowParams(value, offset),
      function(result) {
        if (expected !== root.dataSerial
            || expectedSearch !== root.searchGeneration
            || expectedQuery !== root.searchResultQuery) return
        root.pageRequest = null
        root.searchLoading = false
        root.searchPendingType = ""
        if (result && result.ok !== true) {
          root.searchError = root.safeError(String(result.errorMessage
            || "Search failed"))
          return
        }
        var incoming = ({})
        incoming[value] = Api.subsonicSearchGroups(
          result.results, value, root.subsonicArt, 20, offset)[value]
        var merged = Api.mergeSearchGroups(root.searchGroups, incoming)
        root.searchGroups = merged
        root.searchError = ""
        root.checkSavedItems(root.searchItems(value))
      }, {
        priority: "interactive",
        timeoutMs: Api.SEARCH_REQUEST_TIMEOUT_MS
      })
  }

  function retrySearch(type) {
    var value = Api.normalizedSearchType(type)
    if (!searchQuery) return
    if (retryMode === "page" && searchNext(value) !== "")
      loadMoreSearch(value)
    else search(searchQuery, value, true)
  }

  function clearSearch() {
    searchGeneration++
    api.cancelSearch()
    api.abortRequest(pageRequest)
    pageRequest = null
    searchLoading = false
    searchQuery = ""
    searchGroups = Api.searchGroups({}, 128)
    searchError = ""
    searchResultQuery = ""
    searchActiveType = "track"
    searchPendingType = ""
    searchLoadedTypes = ({})
  }

  function cancelSearch(clearResults) {
    searchGeneration++
    api.cancelSearch()
    api.abortRequest(pageRequest)
    pageRequest = null
    searchLoading = false
    searchPendingType = ""
    searchError = ""
    if (clearResults === true) clearSearch()
  }

}
