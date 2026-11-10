import QtQuick
import QtTest

import "../Subsonic.js" as Subsonic

TestCase {
  name: "SubsonicLogic"

  function test_md5_matchesReferenceVectors() {
    // RFC 1321 test suite and the Subsonic authentication example.
    compare(Subsonic.md5(""), "d41d8cd98f00b204e9800998ecf8427e")
    compare(Subsonic.md5("abc"), "900150983cd24fb0d6963f7d28e17f72")
    compare(Subsonic.md5("sesamec19b2d"), "26719a1196d2a940705a59634eb18eab")
    // UTF-8 password bytes, not code points.
    compare(Subsonic.md5("héllo de wörld"),
      "3f8bc920a7626b6f019b55eb82f1d634")
    // Crosses the second padded block (length ≥ 447 bits).
    compare(Subsonic.md5("a".repeat(1000)),
      "cabe45dcc9ae5b66ba86600cca6b8ba8")
  }

  function test_authToken_usesTheSpecExample() {
    // token = md5("sesame" + "c19b2d")
    compare(Subsonic.authToken("sesame", "c19b2d"),
      "26719a1196d2a940705a59634eb18eab")
    // Same password with a different salt must not reuse the token.
    compare(Subsonic.authToken("sesame", "d20b2a"),
      Subsonic.md5("sesamed20b2a"))
    verify(Subsonic.authToken("sesame", "c19b2d")
      !== Subsonic.authToken("sesame", "d20b2a"))
  }

  function test_randomSalt_honorsLengthAndAlphabet() {
    var counter = 0
    var source = function() {
      counter++
      return (counter * 0.5) % 16 / 16
    }
    var salt = Subsonic.randomSalt(source)
    compare(salt.length, 16)
    for (var i = 0; i < salt.length; i++) {
      verify(salt.charAt(i) !== "")
    }
    // Degenerate generator never produces a salt below the minimum length.
    compare(Subsonic.randomSalt(function() { return 0 }).length, 16)
    compare(Subsonic.randomSalt(function() { return 1 }).length, 16)
  }

  function test_authParams_carriesClientIdentityAndFreshSalt() {
    var pinned = Subsonic.authParams("alice", "sesame", "c19b2d")
    compare(pinned.u, "alice")
    compare(pinned.t, Subsonic.authToken("sesame", "c19b2d"))
    compare(pinned.s, "c19b2d")
    compare(pinned.v, Subsonic.API_VERSION)
    compare(pinned.c, "omarchy-navidrome")
    compare(pinned.f, "json")
  }

  function test_normalizeServerUrl_trimsAndRejectsInvalid() {
    compare(Subsonic.normalizeServerUrl(
      "https://music.example.net:4533/home/"),
      "https://music.example.net:4533/home")
    compare(Subsonic.normalizeServerUrl("HTTP://Example.COM"),
      "http://example.com")
    compare(Subsonic.normalizeServerUrl("http://[::1]:4533/base"),
      "http://[::1]:4533/base")
    compare(Subsonic.normalizeServerUrl("  https://nav.example.org  "),
      "https://nav.example.org")
    verify(Subsonic.normalizeServerUrl("") === null)
    verify(Subsonic.normalizeServerUrl("music.example.net") === null)
    verify(Subsonic.normalizeServerUrl("ftp://example.net") === null)
    verify(Subsonic.normalizeServerUrl("https://") === null)
    verify(Subsonic.normalizeServerUrl(null) === null)
  }

  function test_isInsecureServerUrl_flagsPlainHttpOnly() {
    verify(Subsonic.isInsecureServerUrl("http://192.168.1.10/"))
    verify(!Subsonic.isInsecureServerUrl("https://192.168.1.10/"))
    verify(!Subsonic.isInsecureServerUrl("not a url"))
  }

  function test_endpointUrl_insertsRestTrailingView() {
    compare(Subsonic.endpointUrl("https://n.example.com", "ping"),
      "https://n.example.com/rest/ping")
    compare(Subsonic.endpointUrl("https://n.example.com/nav", "ping.view"),
      "https://n.example.com/nav/rest/ping")
    compare(Subsonic.endpointUrl("https://n.example.com/", "getAlbumList2"),
      "https://n.example.com/rest/getAlbumList2")
  }

  function test_requestUrl_sortsKeysAndExpandsArrays() {
    var result = Subsonic.requestUrl("https://n.example.com", "search3",
      {u: "alice", p: "sesame", salt: "c19b2d"},
      {q: "AC/DC & friends", albumCount: 20, id: ["ab", "cd"]})
    // Parameter order is sorted; the token derives from the pinned salt.
    compare(result.url, "https://n.example.com/rest/search3"
      + "?albumCount=20&c=omarchy-navidrome&f=json&id=ab&id=cd"
      + "&q=AC%2FDC%20%26%20friends&s=c19b2d"
      + "&t=" + Subsonic.authToken("sesame", "c19b2d")
      + "&u=alice&v=1.16.1")
    compare(result.salt, "c19b2d")
  }

  function test_buildQuery_generatesFreshSaltWhenNotPinned() {
    var result = Subsonic.buildQuery({u: "alice", p: "x"}, {}, function() {
      return 0.25
    })
    compare(result.salt, "e".repeat(16))
    // Sorted keys: c, f, s, t, u, v.
    compare(result.query, "c=omarchy-navidrome&f=json&s=" + result.salt
      + "&t=" + Subsonic.authToken("x", result.salt)
      + "&u=alice&v=" + Subsonic.API_VERSION)
  }

  function test_parseResponse_acceptsOkAndRejectsFailed() {
    verify(Subsonic.parseResponse(
      {"subsonic-response": {status: "ok", albums: {size: 1}}}).ok)
    var bad = Subsonic.parseResponse(
      {"subsonic-response": {status: "failed",
        error: {code: 40, message: "Wrong"}}})
    verify(!bad.ok)
    compare(bad.errorCode, 40)
    compare(bad.errorMessage, "Wrong")
    // Missing error object still yields a typed generic failure.
    var vague = Subsonic.parseResponse({"subsonic-response":
      {status: "failed"}})
    verify(!vague.ok)
    compare(vague.errorCode, 0)
    verify(vague.errorMessage !== "")
    verify(Subsonic.parseResponse("not json").ok === false)
  }

  function test_errorCategory_typesAuthenticationFailures() {
    compare(Subsonic.errorCategory(40), "wrongCredentials")
    compare(Subsonic.errorCategory(41), "tokenAuthRejected")
    compare(Subsonic.errorCategory(42), "tokenAuthRejected")
    compare(Subsonic.errorCategory(50), "notAuthorized")
    compare(Subsonic.errorCategory(70), "notFound")
    compare(Subsonic.errorCategory(1234), "generic")
  }
}
