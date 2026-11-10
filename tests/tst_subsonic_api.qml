pragma ComponentBehavior: Bound

import QtQuick
import QtTest

import ".." as Plugin
import "../Subsonic.js" as Subsonic

TestCase {
  id: testCase
  name: "SubsonicApiTransport"

  property var requests: []
  property double clock: 1000
  property string serverUrl: "https://nav.example.test"
  property string username: "alice"
  property string password: "sesame"
  property int saltCalls: 0
  // Diagnostics folded in from every test so the redaction assertion covers
  // the whole battery, not just its own requests.
  property var harvestedDiagnostics: []

  Component {
    id: apiComponent

    Plugin.SubsonicApi {
      serverUrl: testCase.serverUrl
      username: testCase.username
      password: testCase.password
      now: function() { return testCase.clock }
      // Pinned salt source: consecutive calls differ, so every request
      // provably builds a fresh salt. 97 is not a multiple of 16, so two
      // consecutive 16-character windows never repeat.
      randomSource: function() {
        testCase.saltCalls++
        return (testCase.saltCalls % 97) / 97
      }
      xhrFactory: function() { return testCase.newRequest() }
    }
  }

  function newRequest() {
    var xhr = {
      readyState: XMLHttpRequest.UNSENT,
      status: 0,
      responseText: "",
      url: "",
      method: "",
      aborted: false,
      onreadystatechange: null,
      open: function(method, url) {
        this.method = method
        this.url = url
        this.readyState = XMLHttpRequest.OPENED
      },
      setRequestHeader: function() {},
      send: function() {},
      abort: function() { this.aborted = true }
    }
    requests.push(xhr)
    return xhr
  }

  function complete(xhr, status, body) {
    xhr.status = status
    xhr.responseText = body || "{}"
    xhr.readyState = XMLHttpRequest.DONE
    xhr.onreadystatechange()
  }

  function saltOf(url) {
    var match = /[?&]s=([^&]*)/.exec(String(url))
    return match ? decodeURIComponent(match[1]) : ""
  }

  function harvest(api) {
    harvestedDiagnostics = harvestedDiagnostics.concat(api.diagnostics)
  }

  function init() {
    requests = []
    clock = 1000
    serverUrl = "https://nav.example.test"
    username = "alice"
    password = "sesame"
    saltCalls = 0
  }

  function test_requestBuildsFreshSaltsAndDeliversParsedData() {
    var api = createTemporaryObject(apiComponent, testCase)
    verify(api)
    var first = null
    var second = null
    api.request("getAlbumList2", {type: "newest", size: 10},
      function(result) { first = result })
    api.request("ping", {}, function(result) { second = result })
    compare(requests.length, 2)
    var saltA = saltOf(requests[0].url)
    var saltB = saltOf(requests[1].url)
    verify(saltA !== "")
    verify(saltA !== saltB)
    // The URL is exactly what Subsonic.requestUrl builds: sorted params,
    // token auth over the fresh salt, and the plugin's client identity.
    verify(requests[0].url.indexOf(
      "https://nav.example.test/rest/getAlbumList2?") === 0)
    verify(requests[0].url.indexOf("c=omarchy-navidrome") > 0)
    verify(requests[0].url.indexOf("size=10") > 0)
    verify(requests[0].url.indexOf("type=newest") > 0)
    verify(requests[0].url.indexOf("u=alice") > 0)
    verify(requests[0].url.indexOf("t=" + Subsonic.authToken("sesame", saltA)) > 0)
    complete(requests[0], 200,
      '{"subsonic-response":{"status":"ok","albumList2":{"album":'
      + '[{"id":"al-1","name":"First Light"}]}}}')
    verify(first !== null)
    verify(first.ok)
    compare(first.errorCode, 0)
    compare(first.data.albumList2.album.length, 1)
    compare(first.data.albumList2.album[0].name, "First Light")
    complete(requests[1], 200, '{"subsonic-response":{"status":"ok"}}')
    verify(second.ok)
    harvest(api)
  }

  function test_failedResponseYieldsTypedError() {
    var api = createTemporaryObject(apiComponent, testCase)
    verify(api)
    var result = null
    api.request("getUser", {}, function(r) { result = r })
    complete(requests[0], 200,
      '{"subsonic-response":{"status":"failed",'
      + '"error":{"code":40,"message":"Wrong username or password"}}}')
    verify(result.ok === false)
    compare(result.errorCode, 40)
    compare(result.errorCategory, "wrongCredentials")
    compare(result.errorMessage, "Wrong username or password")
    verify(result.data === undefined)
    verify(result.xhr === requests[0])
    harvest(api)
  }

  function test_newerSearchAbortsStaleRequest() {
    var api = createTemporaryObject(apiComponent, testCase)
    verify(api)
    var staleCalls = 0
    var current = null
    api.search3("old query", {songCount: 5}, function() { staleCalls++ })
    var stale = requests[0]
    api.search3("new query", {songCount: 5},
      function(result) { current = result })
    verify(stale.aborted)
    compare(requests.length, 2)
    verify(requests[1].url.indexOf("q=new%20query") > 0)
    // The stale response must never reach the stale callback.
    complete(stale, 200, '{"subsonic-response":{"status":"ok"}}')
    compare(staleCalls, 0)
    complete(requests[1], 200,
      '{"subsonic-response":{"status":"ok","searchResult3":'
      + '{"song":[{"id":"t-1","title":"Hit"}]}}}')
    compare(staleCalls, 0)
    verify(current !== null)
    verify(current.ok)
    compare(current.results.songs.length, 1)
    compare(current.results.songs[0].id, "t-1")
    harvest(api)
  }

  function test_pageRaceDeliversEachResponseToItsOwnCallback() {
    var api = createTemporaryObject(apiComponent, testCase)
    verify(api)
    var results = []
    api.request("getAlbumList2", {type: "newest", size: 10},
      function(result) { results.push({page: 1, result: result}) })
    api.request("getAlbumList2", {type: "newest", size: 20},
      function(result) { results.push({page: 2, result: result}) })
    compare(requests.length, 2)
    // The later page answers first; each callback still sees only its own
    // body, never the other request's payload.
    complete(requests[1], 200,
      '{"subsonic-response":{"status":"ok","albumList2":{"album":'
      + '[{"id":"al-2","name":"Second"}]}}}')
    complete(requests[0], 200,
      '{"subsonic-response":{"status":"ok","albumList2":{"album":'
      + '[{"id":"al-1","name":"First"}]}}}')
    compare(results.length, 2)
    var firstPage = results[0].page === 1 ? results[0] : results[1]
    var secondPage = results[0].page === 1 ? results[1] : results[0]
    verify(firstPage.result.ok)
    verify(secondPage.result.ok)
    compare(firstPage.result.data.albumList2.album[0].name, "First")
    compare(secondPage.result.data.albumList2.album[0].name, "Second")
    harvest(api)
  }

  function test_timeoutExpiresOnceAndReleasesSlot() {
    var api = createTemporaryObject(apiComponent, testCase)
    verify(api)
    var calls = 0
    var result = null
    api.request("getAlbumList2", {type: "random"},
      function(r) { calls++; result = r }, {timeoutMs: 2000})
    compare(api.requestsInFlight, 1)
    clock = 1500
    api.expireTimedOutRequests(clock)
    compare(calls, 0)
    verify(!requests[0].aborted)
    clock = 3000
    api.expireTimedOutRequests(clock)
    compare(calls, 1)
    verify(requests[0].aborted)
    verify(result.ok === false)
    compare(result.errorCategory, "generic")
    verify(result.errorMessage.indexOf("too long") >= 0)
    compare(api.requestsInFlight, 0)
    compare(api.timedJobs.length, 0)
    // The expired job can never deliver again, not even on a late response.
    complete(requests[0], 200, '{"subsonic-response":{"status":"ok"}}')
    compare(calls, 1)
    // The sweep released the slot: a fresh request proceeds immediately.
    var second = null
    api.request("ping", {}, function(r) { second = r })
    compare(requests.length, 2)
    complete(requests[1], 200, '{"subsonic-response":{"status":"ok"}}')
    verify(second.ok)
    harvest(api)
  }

  function test_mutatingFailureIsUncertainAndSuccessIsNot() {
    var api = createTemporaryObject(apiComponent, testCase)
    verify(api)
    var failed = null
    api.request("star", {id: ["t-1"]}, function(r) { failed = r },
      {mutating: true})
    complete(requests[0], 500, "{}")
    verify(failed.ok === false)
    verify(failed.uncertain === true)
    compare(failed.errorCategory, "serverError")
    verify(failed.errorMessage.indexOf("did not confirm") >= 0)

    var interrupted = null
    api.request("scrobble", {id: "t-1", submission: true},
      function(r) { interrupted = r }, {mutating: true})
    complete(requests[1], 0)
    verify(interrupted.ok === false)
    verify(interrupted.uncertain === true)
    verify(interrupted.errorMessage.indexOf("did not confirm") >= 0)

    var succeeded = null
    api.request("star", {id: ["t-2"]}, function(r) { succeeded = r },
      {mutating: true})
    complete(requests[2], 200, '{"subsonic-response":{"status":"ok"}}')
    verify(succeeded.ok === true)
    verify(succeeded.uncertain !== true)
    harvest(api)
  }

  function test_probeWalksEndpointsAndShortCircuitsOnCredentialFailure() {
    var api = createTemporaryObject(apiComponent, testCase)
    verify(api)
    var result = null
    var calls = 0
    api.probe(function(r) { calls++; result = r })
    compare(requests.length, 1)
    verify(requests[0].url.indexOf("rest/ping?") > 0)
    complete(requests[0], 200, '{"subsonic-response":{"status":"ok"}}')
    compare(requests.length, 2)
    verify(requests[1].url.indexOf("rest/getUser?") > 0)
    complete(requests[1], 200,
      '{"subsonic-response":{"status":"ok","user":{"username":"alice",'
      + '"streamRole":true}}}')
    compare(requests.length, 3)
    verify(requests[2].url.indexOf("rest/getLicense?") > 0)
    complete(requests[2], 200,
      '{"subsonic-response":{"status":"ok","license":{"valid":true}}}')
    compare(calls, 1)
    verify(result.ok)
    compare(result.username, "alice")
    verify(!result.trial)

    // Wrong credentials at getUser short-circuit the walk: no getLicense.
    var failure = null
    var failureCalls = 0
    api.probe(function(r) { failureCalls++; failure = r })
    compare(requests.length, 4)
    complete(requests[3], 200, '{"subsonic-response":{"status":"ok"}}')
    compare(requests.length, 5)
    complete(requests[4], 200,
      '{"subsonic-response":{"status":"failed",'
      + '"error":{"code":40,"message":"Wrong"}}}')
    compare(requests.length, 5)
    compare(failureCalls, 1)
    verify(failure.ok === false)
    compare(failure.errorCategory, "wrongCredentials")
    compare(failure.errorMessage, "Wrong username or password")
    compare(failure.step, "getUser")
    harvest(api)
  }

  function test_diagnosticsNeverCarryCredentials() {
    // A self-contained battery of every shape above, so the assertion holds
    // even if only this function runs.
    var api = createTemporaryObject(apiComponent, testCase)
    verify(api)
    api.request("getAlbumList2", {type: "newest"}, function() {})
    complete(requests[0], 200,
      '{"subsonic-response":{"status":"ok","albumList2":{"album":[]}}}')
    api.request("getUser", {}, function() {})
    complete(requests[1], 200,
      '{"subsonic-response":{"status":"failed","error":{"code":40}}}')
    api.search3("secret query", {}, function() {})
    complete(requests[2], 200, '{"subsonic-response":{"status":"ok"}}')
    api.request("star", {id: ["t-1"]}, function() {}, {mutating: true})
    complete(requests[3], 0)
    api.request("ping", {}, function() {}, {timeoutMs: 1000})
    clock = 2000
    api.expireTimedOutRequests(clock)
    serverUrl = "music.example.net"
    api.request("ping", {}, function() {})
    serverUrl = "https://nav.example.test"
    username = ""
    api.request("ping", {}, function() {})
    api.probe(function() {})
    harvest(api)
    api.destroy()

    var snapshot = JSON.stringify(harvestedDiagnostics)
    // No username, no password, no salt/token parameters, no query string of
    // any kind: the whole log is only endpoint names and counters.
    verify(snapshot.indexOf("alice") < 0)
    verify(snapshot.indexOf("sesame") < 0)
    verify(snapshot.indexOf("secret query") < 0)
    verify(snapshot.indexOf("=") < 0)
    verify(snapshot.indexOf("?") < 0)
    verify(snapshot.indexOf("&") < 0)
  }

  function test_cancelAllAbortsAndSilencesCallbacks() {
    var api = createTemporaryObject(apiComponent, testCase)
    verify(api)
    var calls = 0
    var searchCalls = 0
    var probeCalls = 0
    api.request("getAlbumList2", {type: "newest"}, function() { calls++ })
    api.search3("term", {}, function() { searchCalls++ })
    api.probe(function() { probeCalls++ })
    compare(requests.length, 3)
    api.cancelAll()
    verify(requests[0].aborted)
    verify(requests[1].aborted)
    verify(requests[2].aborted)
    compare(api.requestsInFlight, 0)
    compare(api.requestQueue.length, 0)
    complete(requests[0], 200, '{"subsonic-response":{"status":"ok"}}')
    complete(requests[1], 200, '{"subsonic-response":{"status":"ok"}}')
    complete(requests[2], 200, '{"subsonic-response":{"status":"ok"}}')
    compare(calls, 0)
    compare(searchCalls, 0)
    compare(probeCalls, 0)
    harvest(api)
  }

  function test_localFailuresNeverTouchNetwork() {
    serverUrl = "music.example.net"
    var api = createTemporaryObject(apiComponent, testCase)
    verify(api)
    var bad = null
    api.request("ping", {}, function(r) { bad = r })
    verify(bad !== null)
    verify(bad.ok === false)
    compare(bad.errorCategory, "invalidServerUrl")
    verify(bad.errorMessage !== "")
    compare(requests.length, 0)
    compare(api.requestsInFlight, 0)

    serverUrl = "https://nav.example.test"
    username = ""
    var missing = null
    api.request("ping", {}, function(r) { missing = r })
    verify(missing.ok === false)
    compare(missing.errorCategory, "missingCredentials")
    var write = null
    api.request("star", {id: ["t-1"]}, function(r) { write = r },
      {mutating: true})
    verify(write.ok === false)
    compare(write.errorCategory, "missingCredentials")
    compare(requests.length, 0)
    compare(api.requestsInFlight, 0)
    harvest(api)
  }

  function test_mutatingVerbWaitsForReadsToDrain() {
    var api = createTemporaryObject(apiComponent, testCase)
    verify(api)
    var calls = 0
    var starred = null
    api.request("getAlbumList2", {type: "newest"}, function() { calls++ })
    api.request("getAlbumList2", {type: "recent"}, function() { calls++ })
    api.request("star", {id: ["t-1"]}, function(r) { starred = r },
      {mutating: true})
    // The write queues ahead of future reads but behind the draining reads.
    compare(requests.length, 2)
    compare(api.requestQueue.length, 1)
    complete(requests[0], 200, '{"subsonic-response":{"status":"ok"}}')
    compare(requests.length, 2)
    complete(requests[1], 200, '{"subsonic-response":{"status":"ok"}}')
    compare(requests.length, 3)
    verify(requests[2].url.indexOf("rest/star?") > 0)
    complete(requests[2], 200, '{"subsonic-response":{"status":"ok"}}')
    compare(calls, 2)
    verify(starred.ok)
    harvest(api)
  }

  function test_cancelProbeStopsTheSequence() {
    var api = createTemporaryObject(apiComponent, testCase)
    verify(api)
    var calls = 0
    api.probe(function() { calls++ })
    compare(requests.length, 1)
    api.cancelProbe()
    verify(requests[0].aborted)
    complete(requests[0], 200, '{"subsonic-response":{"status":"ok"}}')
    compare(calls, 0)
    compare(api.requestsInFlight, 0)
    // A fresh probe runs the whole sequence again from the start.
    api.probe(function() { calls++ })
    complete(requests[1], 200, '{"subsonic-response":{"status":"ok"}}')
    complete(requests[2], 200,
      '{"subsonic-response":{"status":"ok","user":{"username":"alice"}}}')
    complete(requests[3], 200,
      '{"subsonic-response":{"status":"ok","license":{"valid":true}}}')
    compare(calls, 1)
    harvest(api)
  }
}
