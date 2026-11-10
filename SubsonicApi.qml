import QtQuick

import "Subsonic.js" as Subsonic

// Thin authenticated Subsonic transport. It performs no polling and owns only
// two special request flows: search3, which is cancelled whenever a newer
// query arrives, and the connection probe, which walks ping → getUser →
// getLicense once and is cancellable end to end. Requests share a small
// in-flight cap; mutating verbs (star, scrobble, playlist writes, queue saves)
// are serialized one at a time and only run after every read has drained, so
// an interactive browsing storm can never interleave with a non-idempotent
// write. There is no token refresh, no 401 retry, and no rate-limit cooldown:
// Subsonic token auth is stateless, so every failure is either typed by the
// server's error code or reported honestly as uncertain when a write may have
// landed anyway. Credentials ride inside the request builder only; they never
// appear in diagnostics, results, or log lines.
Item {
  id: root

  visible: false
  width: 0
  height: 0

  required property string serverUrl
  required property string username
  required property string password

  property var searchRequest: null
  property int searchSerial: 0
  property var probeRequest: null
  property int probeSerial: 0
  property var requestQueue: []
  property int requestsInFlight: 0
  property bool pumpingRequests: false
  property bool pumpAgain: false
  property bool cancellingAll: false
  property var timedJobs: []
  property var diagnostics: []
  property int activeTimeoutMs: 15000
  property int searchTimeoutMs: 8000
  // Concurrent cap for reads; a mutating verb owns the whole pipe alone.
  property int maxInFlightReads: 4
  property var xhrFactory: function() { return new XMLHttpRequest() }
  property var now: function() { return Date.now() }
  // Injectable salt source; passed straight through to Subsonic.requestUrl so
  // tests can pin salts. Null keeps production unpredictability.
  property var randomSource: null

  function removeTimedJob(job) {
    var next = []
    for (var i = 0; i < timedJobs.length; i++)
      if (timedJobs[i] !== job) next.push(timedJobs[i])
    timedJobs = next
  }

  function removeQueuedHandle(handle) {
    var next = []
    for (var i = 0; i < requestQueue.length; i++)
      if (!requestQueue[i] || requestQueue[i].handle !== handle)
        next.push(requestQueue[i])
    requestQueue = next
  }

  // Last-line defense for the security contract: error text that could ever
  // carry a URL fragment is scrubbed of the credential parameters before it
  // reaches a log line.
  function redact(value) {
    return String(value || "")
      .replace(/([?&])(u|t|s|p)=[^&\s]*/g, "$1$2=<redacted>")
  }

  function abortXhr(xhr) {
    if (!xhr || typeof xhr.abort !== "function") return
    try {
      xhr.abort()
    } catch (error) {
      console.warn("Subsonic API request abort failed: " + redact(error))
    }
  }

  function markJobFinished(job) {
    if (!job || job.finished === true) return
    job.finished = true
    removeTimedJob(job)
    if (job.handle && job.handle.job === job) job.handle.job = null
    return true
  }

  function jobPriority(job) {
    if (!job) return 0
    if (job.mutating === true) return 2
    return String(job.priority || "") === "interactive" ? 1 : 0
  }

  function enqueueJob(job) {
    var next = requestQueue.slice()
    var priority = jobPriority(job)
    var index = 0
    while (index < next.length && jobPriority(next[index]) >= priority) index++
    next.splice(index, 0, job)
    requestQueue = next
    pumpRequests()
  }

  function dequeueJob() {
    var queue = requestQueue
    while (queue.length) {
      var job = queue[0]
      queue = queue.slice(1)
      if (!job || (job.handle && job.handle.aborted === true)) continue
      requestQueue = queue
      return job
    }
    requestQueue = queue
    return null
  }

  function releaseRequestSlot(handle) {
    if (handle && handle.slotOpen !== true) return
    if (handle) handle.slotOpen = false
    requestsInFlight = Math.max(0, requestsInFlight - 1)
    pumpRequests()
  }

  function pumpRequests() {
    if (cancellingAll) return
    if (pumpingRequests) {
      pumpAgain = true
      return
    }
    pumpingRequests = true
    pumpAgain = false
    while (requestsInFlight < maxInFlightReads) {
      var job = dequeueJob()
      if (!job) break
      if (job.mutating === true && requestsInFlight > 0) {
        // A non-idempotent write runs only once the pipe is fully drained.
        requestQueue = [job].concat(requestQueue)
        break
      }
      job.handle.slotOpen = true
      requestsInFlight += 1
      startJob(job)
    }
    pumpingRequests = false
    if (pumpAgain) pumpRequests()
  }

  function deliverJob(job, status, result, xhr) {
    var entry = {
      // The route is the endpoint name only: no query string, no server
      // address, and never any u/t/s credential parameter.
      route: String(job.endpoint || ""),
      method: "GET",
      status: status,
      durationMs: job.queuedAt !== undefined
        ? Math.max(0, now() - job.queuedAt) : 0,
      queueMs: Math.max(0, (job.startedAt || job.queuedAt) - job.queuedAt),
      httpMs: job.sentAt ? Math.max(0, now() - job.sentAt) : 0,
      outcome: result && result.ok === true ? "success"
        : (result && result.uncertain === true ? "uncertain"
          : (status ? "http-error" : "transport-error"))
    }
    diagnostics = diagnostics.concat([entry]).slice(-100)
    releaseRequestSlot(job.handle)
    callbackIfCurrent(job, result)
  }

  function finishJob(job, status, result, xhr) {
    if (markJobFinished(job) !== true) return
    deliverJob(job, status, result, xhr)
  }

  function callbackIfCurrent(job, result) {
    if (typeof job.callback === "function") job.callback(result)
  }

  function expireTimedOutRequests(timestamp) {
    var current = Number(timestamp)
    if (!isFinite(current)) current = now()
    var jobs = timedJobs.slice()
    for (var i = 0; i < jobs.length; i++) {
      var job = jobs[i]
      if (!job || job.finished === true) continue
      var deadline = job.deadlineAt || job.activeDeadlineAt
      if (!deadline || current < deadline) continue
      var handle = job.handle
      var xhr = handle ? handle.xhr : null
      if (markJobFinished(job) !== true) continue
      if (handle) {
        handle.xhr = null
        handle.aborted = true
        removeQueuedHandle(handle)
      }
      abortXhr(xhr)
      deliverJob(job, 0, failureResult(job, 0, 0, timeoutMessage(), null), null)
    }
  }

  function abortRequest(handle) {
    if (!handle || handle.aborted) return
    handle.aborted = true
    removeQueuedHandle(handle)
    var xhr = handle.xhr
    handle.xhr = null
    if (handle.job && handle.job.finished !== true) {
      handle.job.finished = true
      removeTimedJob(handle.job)
    }
    handle.job = null
    abortXhr(xhr)
    releaseRequestSlot(handle)
  }

  // ------ result shapes ---------------------------------------------------------

  function successResult(data, xhr) {
    return {
      ok: true,
      errorCode: 0,
      errorCategory: "",
      errorMessage: "",
      data: data,
      xhr: xhr
    }
  }

  // A mutating verb that did not return a confirmed ok is uncertain, not
  // merely failed: the write may have landed before the connection broke.
  function failureResult(job, status, errorCode, errorMessage, xhr) {
    var category = Subsonic.errorCategory(errorCode)
    if (errorCode === 0 && status) category = httpErrorCategory(status)
    var message = String(errorMessage || "")
    if (message === "") message = Subsonic.errorMessageForCode(errorCode)
    var result = {
      ok: false,
      errorCode: errorCode,
      errorCategory: category,
      errorMessage: message,
      xhr: xhr
    }
    if (job && job.mutating === true) {
      result.uncertain = true
      result.errorMessage = message + (message ? " " : "")
        + "The server did not confirm this action; check your library before retrying."
    }
    return result
  }

  function httpErrorCategory(status) {
    var code = Number(status) || 0
    if (code === 401) return "wrongCredentials"
    if (code === 403) return "notAuthorized"
    if (code === 404) return "notFound"
    if (code >= 500) return "serverError"
    return "generic"
  }

  function httpErrorMessage(status) {
    var code = Number(status) || 0
    if (!code) return "The server could not be reached. Check your connection and try again."
    return "The server answered with HTTP " + code + "."
  }

  function timeoutMessage() {
    return "The server took too long to respond. Try again."
  }

  // Local typed failures never touch the network, so a mutating verb in this
  // path is definitely unsent — uncertain would overstate the risk.
  function localFailureResult(category, message) {
    return {
      ok: false,
      errorCode: 0,
      errorCategory: category,
      errorMessage: message,
      xhr: null
    }
  }

  function localErrorCategory() {
    if (Subsonic.normalizeServerUrl(serverUrl) === null) return "invalidServerUrl"
    return "missingCredentials"
  }

  function localErrorMessage(category) {
    if (category === "invalidServerUrl")
      return "The server address is not a valid http or https URL."
    return "Server address, username, and password are all required."
  }

  function credentialsIncomplete() {
    return String(serverUrl || "") === "" || String(username || "") === ""
      || String(password || "") === ""
      || Subsonic.normalizeServerUrl(serverUrl) === null
  }

  // Non-2xx answers prefer a typed Subsonic error payload when the body
  // carries one; otherwise the HTTP status names the failure.
  function resultFromResponse(job, status, body, xhr) {
    if (status >= 200 && status < 300) {
      var parsed = Subsonic.parseResponse(body)
      if (parsed.ok === true) return successResult(parsed.data, xhr)
      return failureResult(job, status, parsed.errorCode,
        parsed.errorMessage, xhr)
    }
    var fromBody = body ? Subsonic.parseResponse(body) : null
    if (fromBody && fromBody.ok === false && fromBody.errorCode > 0) {
      return failureResult(job, status, fromBody.errorCode,
        fromBody.errorMessage, xhr)
    }
    return failureResult(job, status, 0, httpErrorMessage(status), xhr)
  }

  function parseJsonText(value, fallback) {
    try {
      var parsed = JSON.parse(String(value || ""))
      return parsed === null ? fallback : parsed
    } catch (error) {
      return fallback
    }
  }

  // ------ request core ----------------------------------------------------------

  function startJob(job) {
    var handle = job.handle
    job.startedAt = now()
    job.activeDeadlineAt = job.startedAt + activeTimeoutMs
    var built = null
    try {
      // A fresh salt is generated inside requestUrl for every request; it is
      // never cached or reused.
      built = Subsonic.requestUrl(serverUrl, job.endpoint,
        {u: username, p: password}, job.params, randomSource)
    } catch (error) {
      built = null
    }
    if (!built) {
      finishJob(job, 0, localFailureResult("invalidServerUrl",
        localErrorMessage("invalidServerUrl")), null)
      return
    }
    job.sentAt = now()
    job.activeDeadlineAt = job.sentAt + activeTimeoutMs
    var xhr = null
    try {
      xhr = xhrFactory()
      handle.xhr = xhr
      xhr.onreadystatechange = function() {
        if (xhr.readyState !== XMLHttpRequest.DONE || handle.xhr !== xhr) return
        handle.xhr = null
        if (handle.aborted || job.finished === true) return
        var body = parseJsonText(xhr.responseText, null)
        finishJob(job, xhr.status,
          resultFromResponse(job, xhr.status, body, xhr), xhr)
      }
      xhr.open("GET", built.url)
      xhr.send()
    } catch (error) {
      if (handle.xhr === xhr) handle.xhr = null
      if (handle.aborted) {
        releaseRequestSlot(handle)
        return
      }
      finishJob(job, 0, failureResult(job, 0, 0, httpErrorMessage(0), null),
        null)
    }
  }

  // endpoint is the Subsonic verb name ("ping", "search3", "star", ...);
  // params are the endpoint parameters without any credential fields. The
  // callback receives one result object and never the request URL.
  function request(endpoint, params, callback, options) {
    var settings = options || ({})
    if (credentialsIncomplete()) {
      var category = localErrorCategory()
      var entry = {
        route: String(endpoint || ""),
        method: "GET",
        status: 0,
        durationMs: 0,
        queueMs: 0,
        httpMs: 0,
        outcome: "local-error"
      }
      diagnostics = diagnostics.concat([entry]).slice(-100)
      if (typeof callback === "function") {
        callback(localFailureResult(category, localErrorMessage(category)))
      }
      return null
    }
    var handle = { aborted: false, xhr: null, job: null }
    var timeoutMs = Math.max(0, Number(settings.timeoutMs) || 0)
    var queuedAt = now()
    var job = {
      endpoint: endpoint,
      params: params,
      callback: callback,
      mutating: settings.mutating === true,
      priority: String(settings.priority || ""),
      timeoutMs: timeoutMs,
      queuedAt: queuedAt,
      deadlineAt: timeoutMs > 0 ? queuedAt + timeoutMs : 0,
      finished: false,
      handle: handle
    }
    handle.job = job
    timedJobs = timedJobs.concat([job])
    enqueueJob(job)
    return handle
  }

  function cancelAll() {
    cancellingAll = true
    var jobs = timedJobs.slice()
    for (var i = 0; i < jobs.length; i++) abortRequest(jobs[i].handle)
    cancelSearch()
    cancelProbe()
    cancellingAll = false
  }

  // ------ search3 ---------------------------------------------------------------

  function cancelSearch() {
    searchSerial = searchSerial + 1
    abortRequest(searchRequest)
    searchRequest = null
  }

  // A newer query aborts the older request, and the stale callback can never
  // fire even if its response had already been produced. An empty query
  // delivers a parsed-empty success without touching the network.
  function search3(query, limits, callback) {
    cancelSearch()
    var serial = root.searchSerial
    var params = Subsonic.search3Params(query, limits)
    if (!params) {
      if (typeof callback === "function") callback(successResult(null, null))
      return
    }
    searchRequest = request("search3", params, function(result) {
      if (serial !== root.searchSerial) return
      if (typeof callback !== "function") return
      if (result && result.ok === true)
        result.results = Subsonic.parseSearch3(result.data)
      callback(result)
    }, {
      priority: "interactive",
      timeoutMs: searchTimeoutMs
    })
  }

  // ------ connection probe ------------------------------------------------------

  function cancelProbe() {
    probeSerial = probeSerial + 1
    abortRequest(probeRequest)
    probeRequest = null
  }

  // Sequential ping → getUser → getLicense over the shared queue; the first
  // failure stops the walk. The callback receives {ok, username, trial} on
  // success and a typed failure with the probed step otherwise.
  function probe(callback) {
    cancelProbe()
    var serial = root.probeSerial
    var steps = ["ping", "getUser", "getLicense"]
    var probeUsername = ""
    var probeTrial = false

    function finish(result) {
      probeRequest = null
      if (typeof callback === "function") callback(result)
    }

    function probeFailure(step, result) {
      var failure = {
        ok: false,
        errorCode: result ? result.errorCode : 0,
        errorCategory: result && result.errorCategory
          ? result.errorCategory : Subsonic.errorCategory(
            result ? result.errorCode : 0),
        errorMessage: Subsonic.describeProbeError(result),
        step: step
      }
      return failure
    }

    function next(index) {
      if (serial !== root.probeSerial) return
      var step = steps[index]
      probeRequest = request(step, {}, function(result) {
        if (serial !== root.probeSerial) return
        if (!result || result.ok !== true) {
          finish(probeFailure(step, result))
          return
        }
        if (step === "getUser") {
          var user = Subsonic.parseUser(result.data)
          if (!user) {
            finish(probeFailure(step, {ok: false, errorCode: 0}))
            return
          }
          probeUsername = user.username
        }
        if (step === "getLicense") {
          var license = Subsonic.parseLicense(result.data)
          probeTrial = license.trial
        }
        if (index + 1 < steps.length) next(index + 1)
        else finish({ok: true, username: probeUsername, trial: probeTrial})
      }, { priority: "interactive" })
    }

    next(0)
  }

  Timer {
    interval: 250
    repeat: true
    running: root.timedJobs.length > 0
    onTriggered: root.expireTimedOutRequests(root.now())
  }
}
