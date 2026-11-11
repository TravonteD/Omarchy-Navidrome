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

  // ------ backend error-code typing (protocol v2) ------

  function test_backendErrorCategory_typesCredentialClassFailures() {
    compare(Subsonic.backendErrorCategory("missing_credentials"), "missingCredentials")
    compare(Subsonic.backendErrorCategory("invalid_configuration"), "invalidConfiguration")
    compare(Subsonic.backendErrorCategory("stream_rejected"), "wrongCredentials")
    compare(Subsonic.backendErrorCategory("stream_unavailable"), "generic")
    compare(Subsonic.backendErrorCategory("engine_busy"), "generic")
    compare(Subsonic.backendErrorCategory("unsupported_version"), "generic")
    compare(Subsonic.backendErrorCategory(""), "generic")
    compare(Subsonic.backendErrorCategory(null), "generic")
    // Unknown codes never masquerade as credential failures.
    compare(Subsonic.backendErrorCategory("missing_credential"), "generic")
  }

  function test_isTerminalCredentialCategory_splitsRetryBudgets() {
    verify(Subsonic.isTerminalCredentialCategory("wrongCredentials"))
    verify(Subsonic.isTerminalCredentialCategory("tokenAuthRejected"))
    verify(Subsonic.isTerminalCredentialCategory("missingCredentials"))
    verify(Subsonic.isTerminalCredentialCategory("invalidConfiguration"))
    verify(Subsonic.isTerminalCredentialCategory("invalidServerUrl"))
    verify(!Subsonic.isTerminalCredentialCategory("generic"))
    verify(!Subsonic.isTerminalCredentialCategory("notAuthorized"))
    verify(!Subsonic.isTerminalCredentialCategory("serverError"))
    verify(!Subsonic.isTerminalCredentialCategory(""))
  }

  function test_backendCredentialMessage_namesOnlyTerminalCodes() {
    compare(Subsonic.backendCredentialMessage("missing_credentials"),
      "Set up your Navidrome server in Settings to play on this computer.")
    verify(Subsonic.backendCredentialMessage("invalid_configuration")
      .indexOf("invalid") >= 0)
    verify(Subsonic.backendCredentialMessage("stream_rejected")
      .indexOf("rejected") >= 0)
    compare(Subsonic.backendCredentialMessage("stream_unavailable"), "")
    compare(Subsonic.backendCredentialMessage(""), "")
  }

  // The terminal message must stay credential-free: no URL, username, token,
  // or salt may ride in the typed UI text.
  function test_backendCredentialMessages_stayCredentialFree() {
    var codes = ["missing_credentials", "invalid_configuration", "stream_rejected"]
    for (var i = 0; i < codes.length; i++) {
      var message = Subsonic.backendCredentialMessage(codes[i])
      verify(message.indexOf("http") < 0)
      verify(message.indexOf("password") < 0)
      verify(message.indexOf("salt") < 0)
      verify(message.indexOf("token") < 0)
    }
  }

  // ------ credential entry validation and keyring payload ------

  function test_validateConnectionEntry_appliesTypedRules() {
    var good = Subsonic.validateConnectionEntry(
      "https://Music.Example.com/", " alice ", "pw")
    verify(good.ok)
    compare(good.url, "https://music.example.com")
    verify(!good.insecure)
    compare(good.error, "")

    var insecure = Subsonic.validateConnectionEntry(
      "http://10.0.0.5:4533/nav/", "alice", "pw")
    verify(insecure.ok)
    compare(insecure.url, "http://10.0.0.5:4533/nav")
    verify(insecure.insecure)

    var badUrl = Subsonic.validateConnectionEntry(
      "ftp://music.example.com", "alice", "pw")
    verify(!badUrl.ok)
    verify(badUrl.error.indexOf("http or https") >= 0)
    verify(!Subsonic.validateConnectionEntry("", "alice", "pw").ok)
    verify(!Subsonic.validateConnectionEntry("music.example.com", "alice", "pw").ok)

    var noUser = Subsonic.validateConnectionEntry("https://music.example.com", "  ", "pw")
    verify(!noUser.ok)
    verify(noUser.error.indexOf("username") >= 0)

    var noPass = Subsonic.validateConnectionEntry("https://music.example.com", "alice", "")
    verify(!noPass.ok)
    verify(noPass.error.indexOf("password") >= 0)
  }

  function test_parseCredentialPayload_staysDefensive() {
    compare(Subsonic.parseCredentialPayload(""), null)
    compare(Subsonic.parseCredentialPayload("not json"), null)
    compare(Subsonic.parseCredentialPayload('{"v":2,"url":"x","username":"a","password":"b"}'), null)
    compare(Subsonic.parseCredentialPayload('{"v":1,"url":"x","username":"a"}'), null)
    compare(Subsonic.parseCredentialPayload('{"v":1,"url":"x","username":"a","password":""}'), null)
    var parsed = Subsonic.parseCredentialPayload(
      '{"v":1,"url":"https://music.example.com","username":"alice","password":"pw"}')
    verify(!!parsed)
    compare(parsed.url, "https://music.example.com")
    compare(parsed.username, "alice")
    compare(parsed.password, "pw")
  }

  // ------ connection probe parsing ------

  function test_parseLicense_acceptsValidTrialAndMissing() {
    var licensed = Subsonic.parseLicense({
      license: {valid: true, email: "alice@example.net",
        expires: "2027-01-01T00:00:00Z"}})
    verify(licensed.ok)
    verify(!licensed.trial)
    compare(licensed.expires, "2027-01-01T00:00:00Z")
    var trial = Subsonic.parseLicense({
      license: {valid: true, trialExpires: "2026-12-01T00:00:00Z"}})
    verify(trial.ok)
    verify(trial.trial)
    compare(trial.expires, "2026-12-01T00:00:00Z")
    var invalid = Subsonic.parseLicense({
      license: {valid: false, email: "alice@example.net"}})
    verify(!invalid.ok)
    verify(!invalid.trial)
    verify(invalid.expires === null)
    // Missing or malformed nodes parse defensively to not-ok.
    verify(Subsonic.parseLicense({}).ok === false)
    verify(Subsonic.parseLicense(null).ok === false)
    verify(Subsonic.parseLicense("garbage").ok === false)
  }

  function test_parseUser_readsRolesAsStrictBooleans() {
    var parsed = Subsonic.parseUser({
      user: {
        username: "alice",
        adminRole: true,
        settingsRole: false,
        streamRole: true,
        downloadRole: "true",
        uploadRole: false,
        playlistRole: true,
        coverArtRole: false,
        commentRole: false,
        podcastRole: false,
        shareRole: false,
        jukeboxRole: false,
        scanRole: true
      }})
    compare(parsed.username, "alice")
    verify(parsed.adminRole)
    verify(!parsed.settingsRole)
    verify(parsed.streamRole)
    // The string "true" is not a Subsonic boolean.
    verify(!parsed.downloadRole)
    verify(parsed.playlistRole)
    verify(parsed.scanRole)
    verify(!parsed.coverArtRole)
    verify(Subsonic.parseUser({}) === null)
    verify(Subsonic.parseUser({"user": "alice"}) === null)
  }

  function test_describeProbeError_staysWithinKnownCategories() {
    compare(Subsonic.describeProbeError({ok: false, errorCode: 40}),
      "Wrong username or password")
    compare(Subsonic.describeProbeError({ok: false, errorCode: 41}),
      "The server rejected token authentication")
    compare(Subsonic.describeProbeError({ok: false, errorCode: 60}),
      "The server license has expired")
    compare(Subsonic.describeProbeError({ok: false, errorCode: 0}),
      "Could not reach the server")
    compare(Subsonic.describeProbeError({ok: false, errorCode: 1234}),
      "Could not reach the server")
    compare(Subsonic.describeProbeError(null), "Could not reach the server")
    compare(Subsonic.describeProbeError({ok: true, errorCode: 0}), "")
  }

  // ------ search3 ------

  function test_search3Params_trimsQueryAndOmitsZeroWindows() {
    var params = Subsonic.search3Params("  AC/DC  ", {
      artistCount: 5, artistOffset: 0, albumCount: 20, albumOffset: 40,
      songCount: 0, songOffset: undefined, musicFolderId: "7"})
    compare(params.q, "AC/DC")
    compare(params.artistCount, 5)
    compare(params.albumCount, 20)
    compare(params.albumOffset, 40)
    compare(params.musicFolderId, "7")
    verify(params.artistOffset === undefined)
    verify(params.songCount === undefined)
    verify(params.songOffset === undefined)
    verify(Subsonic.search3Params("   ", {}) === null)
    verify(Subsonic.search3Params("", null) === null)
    verify(Subsonic.search3Params(undefined) === null)
  }

  function test_parseSearch3_normalizesCoercesAndDrops() {
    var data = Subsonic.parseResponse({"subsonic-response": {
      status: "ok",
      searchResult3: {
        artist: [
          {id: 42, name: "Example Quartet", coverArt: "ar-42",
            albumCount: "5", starred: true},
          {name: "No identity"}
        ],
        album: [
          {id: "al-1", name: "First Light", artist: "Example Quartet",
            artistId: "42", coverArt: "al-1", songCount: 8,
            duration: "1680", year: 2019, genre: "Ambient", starred: true,
            played: "2026-01-02T03:04:05Z"}
        ],
        song: [
          {id: 9001, title: "Opening", artist: "Example Quartet",
            artistId: "42", album: "First Light", albumId: "al-1",
            duration: 210, track: 1, year: 2019, genre: "Ambient",
            coverArt: "al-1", starred: true,
            played: "2026-01-02T03:04:05Z", suffix: "flac",
            bitRate: "991", size: 32400000, contentType: "audio/flac",
            isVideo: false,
            path: "Example Quartet/First Light/01 Opening.flac"},
          {title: "Identity-less", duration: 30}
        ]
      }}}).data
    var parsed = Subsonic.parseSearch3(data)
    compare(parsed.artists.length, 1)
    compare(parsed.artists[0].id, "42")
    compare(parsed.artists[0].name, "Example Quartet")
    compare(parsed.artists[0].albumCount, 5)
    verify(parsed.artists[0].starred)
    compare(parsed.albums.length, 1)
    compare(parsed.albums[0].id, "al-1")
    compare(parsed.albums[0].duration, 1680)
    compare(parsed.albums[0].year, 2019)
    compare(parsed.albums[0].played, "2026-01-02T03:04:05Z")
    compare(parsed.songs.length, 1)
    compare(parsed.songs[0].id, "9001")
    compare(parsed.songs[0].bitRate, 991)
    compare(parsed.songs[0].size, 32400000)
    compare(parsed.songs[0].track, 1)
    compare(parsed.songs[0].contentType, "audio/flac")
    verify(!parsed.songs[0].isVideo)
    verify(parsed.songs[0].starred)
  }

  function test_parseSearch3_toleratesMalformedInput() {
    var empty = Subsonic.parseSearch3(null)
    compare(empty.artists.length, 0)
    compare(empty.albums.length, 0)
    compare(empty.songs.length, 0)
    var bare = Subsonic.parseSearch3({"subsonic-response": {status: "ok"}})
    compare(bare.songs.length, 0)
    // Single nodes where arrays are expected, junk entries, and a
    // string container must all survive without throwing.
    var weird = Subsonic.parseSearch3({searchResult3: {
      artist: {id: "42", name: "Solo", albumCount: 1},
      album: ["junk", {id: "al-1", name: "First Light"}],
      song: "not a list"
    }})
    compare(weird.artists.length, 1)
    compare(weird.artists[0].id, "42")
    compare(weird.albums.length, 1)
    compare(weird.albums[0].name, "First Light")
    compare(weird.songs.length, 0)
  }

  function test_parseSearch3_appliesDefaultsForMissingSongFields() {
    var parsed = Subsonic.parseSearch3({searchResult3: {
      song: [{id: "t-1", title: "Only Id And Title"}]}})
    var song = parsed.songs[0]
    compare(song.id, "t-1")
    compare(song.duration, 0)
    compare(song.track, 0)
    verify(song.year === null)
    verify(song.played === null)
    verify(!song.starred)
    verify(!song.isVideo)
    compare(song.artist, "")
    compare(song.album, "")
    compare(song.path, "")
  }

  // ------ album windows ------

  function test_albumList2Params_rejectsUnknownTypeAndOmitsZeroSize() {
    var params = Subsonic.albumList2Params("newest", 20, 0, {})
    compare(params.type, "newest")
    compare(params.size, 20)
    verify(params.offset === undefined)
    verify(Subsonic.albumList2Params("recentlyAdded", 20) === null)
    verify(Subsonic.albumList2Params(undefined, 20) === null)
  }

  function test_albumList2Params_carriesExtraFilters() {
    var byYear = Subsonic.albumList2Params("byYear", 10, 30,
      {fromYear: 2019, toYear: "2021"})
    compare(byYear.fromYear, "2019")
    compare(byYear.toYear, "2021")
    compare(byYear.offset, 30)
    var byGenre = Subsonic.albumList2Params("byGenre", 10, 0,
      {genre: "Ambient", musicFolderId: "7"})
    compare(byGenre.genre, "Ambient")
    compare(byGenre.musicFolderId, "7")
    verify(Subsonic.albumList2Params("random", 10, 0, null).genre === undefined)
  }

  function test_parseAlbumList_acceptsCurrentAndLegacyContainers() {
    var current = Subsonic.parseResponse({"subsonic-response": {
      status: "ok",
      albumList2: {album: [
        {id: "al-1", name: "First Light", artist: "Example Quartet",
          artistId: "42", songCount: 8, duration: 1680, year: 2019},
        {id: "al-3", name: "Later", songCount: "2", duration: "300"}
      ]}}}).data
    var albums = Subsonic.parseAlbumList(current)
    compare(albums.length, 2)
    compare(albums[0].id, "al-1")
    compare(albums[1].songCount, 2)
    var legacy = Subsonic.parseAlbumList({albumList: {
      album: [{id: "al-9", name: "Old Shape", songCount: 1}]}})
    compare(legacy.length, 1)
    compare(legacy[0].id, "al-9")
    compare(Subsonic.parseAlbumList(null).length, 0)
    compare(Subsonic.parseAlbumList({}).length, 0)
  }

  // ------ artist and album detail ------

  function test_parseArtist_splitsNodeAndNestedAlbums() {
    var parsed = Subsonic.parseArtist({artist: {
        id: "42", name: "Example Quartet", coverArt: "ar-42",
        albumCount: 2, starred: true,
        album: [
          {id: "al-1", name: "First Light", songCount: 8, duration: 1680},
          {id: "al-2", name: "Second Light", songCount: 6, duration: 1500}
        ]
      }})
    compare(parsed.artist.id, "42")
    compare(parsed.artist.name, "Example Quartet")
    compare(parsed.artist.albumCount, 2)
    verify(parsed.artist.starred)
    compare(parsed.albums.length, 2)
    compare(parsed.albums[1].id, "al-2")
    var missing = Subsonic.parseArtist(null)
    verify(missing.artist === null)
    compare(missing.albums.length, 0)
  }

  function test_parseAlbum_splitsNodeAndNestedSongs() {
    var parsed = Subsonic.parseAlbum({album: {
        id: "al-1", name: "First Light", artist: "Example Quartet",
        artistId: "42", coverArt: "al-1", songCount: 2, duration: 420,
        year: 2019, genre: "Ambient",
        song: [
          {id: "t-1", title: "Opening", duration: 210, track: 1,
            suffix: "flac", contentType: "audio/flac",
            path: "Example Quartet/First Light/01 Opening.flac"},
          {id: "t-2", title: "Closing", duration: "210", track: "2"}
        ]
      }})
    compare(parsed.album.id, "al-1")
    compare(parsed.album.songCount, 2)
    compare(parsed.album.duration, 420)
    compare(parsed.album.year, 2019)
    compare(parsed.songs.length, 2)
    compare(parsed.songs[0].id, "t-1")
    compare(parsed.songs[0].track, 1)
    compare(parsed.songs[1].track, 2)
    compare(parsed.songs[1].duration, 210)
    var missing = Subsonic.parseAlbum("junk")
    verify(missing.album === null)
    compare(missing.songs.length, 0)
  }

  function test_parseTopSongs_dropsIdentitylessSongs() {
    var parsed = Subsonic.parseTopSongs({artist: {
        id: "42", name: "Example Quartet",
        topSongs: {song: [
          {id: "t-9", title: "Everyone's Favourite", duration: 200,
            album: "First Light", albumId: "al-1"},
          {title: "No identity"}
        ]}}})
    compare(parsed.length, 1)
    compare(parsed[0].id, "t-9")
    compare(parsed[0].albumId, "al-1")
    // An artist without top songs parses to an empty list.
    compare(Subsonic.parseTopSongs({artist: {id: "42"}}).length, 0)
    compare(Subsonic.parseTopSongs(null).length, 0)
  }

  function test_parseStarred2_splitsTheThreeGroups() {
    var parsed = Subsonic.parseStarred2({ starred2: {
      song: [{ id: "tr-1", title: "So What", duration: 540 },
        { title: "no id" }],
      album: [{ id: "al-1", name: "Kind of Blue" }],
      artist: [{ id: "ar-1", name: "Miles Davis" }]
    }})
    compare(parsed.songs.length, 1)
    compare(parsed.songs[0].id, "tr-1")
    compare(parsed.songs[0].duration, 540)
    compare(parsed.albums.length, 1)
    compare(parsed.albums[0].id, "al-1")
    compare(parsed.artists.length, 1)
    compare(parsed.artists[0].id, "ar-1")
    // Malformed and missing shapes parse empty, never an error.
    compare(Subsonic.parseStarred2(null).songs.length, 0)
    compare(Subsonic.parseStarred2({}).albums.length, 0)
    compare(Subsonic.parseStarred2({ starred2: "junk" }).artists.length, 0)
  }

  function test_parseGenres_keysOnValueAndDropsEmpty() {
    var parsed = Subsonic.parseGenres({genres: {genre: [
        {value: "Ambient", songCount: 120, albumCount: 9},
        {value: "Jazz", songCount: "3", albumCount: "1"},
        {songCount: 5, albumCount: 1},
        "junk"
      ]}})
    compare(parsed.length, 2)
    compare(parsed[0].value, "Ambient")
    compare(parsed[0].songCount, 120)
    compare(parsed[0].albumCount, 9)
    compare(parsed[1].value, "Jazz")
    compare(parsed[1].songCount, 3)
    compare(parsed[1].albumCount, 1)
    compare(Subsonic.parseGenres(null).length, 0)
  }

  // ------ playlists ------

  function test_parsePlaylists_normalizesEveryPlaylist() {
    var parsed = Subsonic.parsePlaylists({playlists: {playlist: [
        {id: "pl-1", name: "Road Trip", comment: "Long drives",
          owner: "alice", public: true, songCount: 12, duration: 3600,
          created: "2026-01-01T00:00:00Z", changed: "2026-02-01T00:00:00Z",
          coverArt: "pl-1", starred: true},
        {id: "pl-2", name: "Private Mix", public: false}
      ]}})
    compare(parsed.length, 2)
    compare(parsed[0].id, "pl-1")
    compare(parsed[0].comment, "Long drives")
    verify(parsed[0].public)
    verify(parsed[0].starred)
    compare(parsed[0].songCount, 12)
    compare(parsed[0].duration, 3600)
    verify(!parsed[1].public)
    compare(Subsonic.parsePlaylists(null).length, 0)
  }

  function test_parsePlaylist_extractsNormalizedEntries() {
    var parsed = Subsonic.parsePlaylist({playlist: {
        id: "pl-1", name: "Road Trip", owner: "alice", songCount: 2,
        duration: 420,
        entry: [
          {id: "t-1", title: "Opening", duration: 210,
            artist: "Example Quartet"},
          {id: "t-2", title: "Closing", duration: "210"}
        ]
      }})
    compare(parsed.playlist.id, "pl-1")
    compare(parsed.entries.length, 2)
    compare(parsed.entries[0].id, "t-1")
    compare(parsed.entries[0].artist, "Example Quartet")
    compare(parsed.entries[1].duration, 210)
    var missing = Subsonic.parsePlaylist({})
    verify(missing.playlist === null)
    compare(missing.entries.length, 0)
  }

  function test_createPlaylistParams_requiresNameWithoutPlaylistId() {
    var fresh = Subsonic.createPlaylistParams("  Road Trip  ",
      ["t-1", "t-2", ""], null)
    compare(fresh.name, "Road Trip")
    compare(fresh.songId.length, 2)
    compare(fresh.songId[0], "t-1")
    var update = Subsonic.createPlaylistParams("Ignored Name", "t-3", "pl-9")
    compare(update.playlistId, "pl-9")
    compare(update.songId[0], "t-3")
    verify(update.name === undefined)
    verify(Subsonic.createPlaylistParams("   ", [], null) === null)
    verify(Subsonic.createPlaylistParams("", []) === null)
  }

  function test_updatePlaylistParams_expandsRepeatedKeysThroughRequestUrl() {
    var params = Subsonic.updatePlaylistParams("pl-9", {
      name: "Road Trip",
      comment: "",
      public: true,
      songIdToAdd: ["t-1", "t-2"],
      songIndexToRemove: 3})
    compare(params.playlistId, "pl-9")
    compare(params.name, "Road Trip")
    compare(params.public, "true")
    verify(params.comment === undefined)
    // Repeated keys ride the existing query builder end to end.
    var built = Subsonic.requestUrl("https://n.example.com", "updatePlaylist",
      {u: "alice", p: "sesame", salt: "c19b2d"}, params)
    compare(built.url, "https://n.example.com/rest/updatePlaylist"
      + "?c=omarchy-navidrome&f=json&name=Road%20Trip&playlistId=pl-9"
      + "&public=true&s=c19b2d&songIdToAdd=t-1&songIdToAdd=t-2"
      + "&songIndexToRemove=3&t=" + Subsonic.authToken("sesame", "c19b2d")
      + "&u=alice&v=1.16.1")
    verify(Subsonic.updatePlaylistParams("", {}) === null)
  }

  function test_deletePlaylistParams_wrapsTheId() {
    var params = Subsonic.deletePlaylistParams(9)
    compare(params.id, "9")
    verify(Subsonic.deletePlaylistParams(null) === null)
    verify(Subsonic.deletePlaylistParams("") === null)
  }

  // ------ star, rating, scrobble ------

  function test_starParams_expandRepeatedKeysThroughRequestUrl() {
    var star = Subsonic.starParams({id: ["t-1", "t-2"], albumId: "al-1"})
    compare(star.id.length, 2)
    compare(star.albumId[0], "al-1")
    verify(star.artistId === undefined)
    var built = Subsonic.requestUrl("https://n.example.com", "star",
      {u: "alice", p: "sesame", salt: "c19b2d"}, star)
    compare(built.url, "https://n.example.com/rest/star"
      + "?albumId=al-1&c=omarchy-navidrome&f=json&id=t-1&id=t-2"
      + "&s=c19b2d&t=" + Subsonic.authToken("sesame", "c19b2d")
      + "&u=alice&v=1.16.1")
    // unstar builds the same shape over its own endpoint.
    var unstar = Subsonic.requestUrl("https://n.example.com", "unstar",
      {u: "alice", p: "sesame", salt: "c19b2d"},
      Subsonic.unstarParams({artistId: "42"}))
    compare(unstar.url, "https://n.example.com/rest/unstar"
      + "?artistId=42&c=omarchy-navidrome&f=json&s=c19b2d"
      + "&t=" + Subsonic.authToken("sesame", "c19b2d")
      + "&u=alice&v=1.16.1")
    verify(Subsonic.starParams({}) === null)
    verify(Subsonic.starParams({id: []}) === null)
    verify(Subsonic.starParams(null) === null)
  }

  function test_setRatingParams_clampsAndValidates() {
    compare(Subsonic.setRatingParams("t-1", 7).rating, "5")
    compare(Subsonic.setRatingParams("t-1", -3).rating, "0")
    compare(Subsonic.setRatingParams("t-1", 3.4).rating, "3")
    compare(Subsonic.setRatingParams("t-1", "2").rating, "2")
    compare(Subsonic.setRatingParams(12, 0).id, "12")
    verify(Subsonic.setRatingParams("t-1", "not a number") === null)
    verify(Subsonic.setRatingParams("t-1", null) === null)
    verify(Subsonic.setRatingParams("", 4) === null)
  }

  function test_scrobbleParams_omitsAbsentSubmissionAndTime() {
    var now = Subsonic.scrobbleParams("t-1", true, 1770000000000)
    compare(now.id, "t-1")
    compare(now.submission, "true")
    compare(now.time, "1770000000000")
    var start = Subsonic.scrobbleParams("t-1", false)
    compare(start.submission, "false")
    verify(start.time === undefined)
    var bare = Subsonic.scrobbleParams("t-1")
    verify(bare.submission === undefined)
    verify(bare.time === undefined)
    var startedAt = Subsonic.scrobbleParams("t-1", false, "1770000000000.4")
    compare(startedAt.time, "1770000000000")
    verify(Subsonic.scrobbleParams("t-1", true, -5).time === undefined)
    verify(Subsonic.scrobbleParams("", true) === null)
    verify(Subsonic.scrobbleParams(null, true) === null)
  }

  // ------ artwork ------

  function test_coverArtUrl_buildsOverRequestUrlWithPinnedSalt() {
    var url = Subsonic.coverArtUrl("https://n.example.com", "al-1", 300,
      {u: "alice", p: "sesame", salt: "c19b2d"})
    compare(url, "https://n.example.com/rest/getCoverArt"
      + "?c=omarchy-navidrome&f=json&id=al-1&s=c19b2d&size=300"
      + "&t=" + Subsonic.authToken("sesame", "c19b2d")
      + "&u=alice&v=1.16.1")
    // Size 0 means "server default" and stays off the wire.
    var unsized = Subsonic.coverArtUrl("https://n.example.com", "al-1", 0,
      {u: "alice", p: "sesame", salt: "c19b2d"})
    verify(unsized.indexOf("size=") < 0)
    // Invalid server or id is the UI's "no artwork" signal.
    verify(Subsonic.coverArtUrl("not a url", "al-1", 300,
      {u: "alice", p: "sesame"}) === null)
    verify(Subsonic.coverArtUrl("https://n.example.com", "", 300,
      {u: "alice", p: "sesame"}) === null)
    verify(Subsonic.coverArtUrl("https://n.example.com", null, 300,
      {u: "alice", p: "sesame"}) === null)
  }

  // ------ bookmarks and saved play queue (resume machinery) ------

  function test_bookmarkParams_rejectsEmptyAndCarriesPosition() {
    var targeted = Subsonic.bookmarkParams("tr-1", 42000)
    compare(targeted.id, "tr-1")
    compare(targeted.position, "42000")
    var bare = Subsonic.bookmarkParams("tr-1")
    compare(bare.id, "tr-1")
    verify(bare.position === undefined)
    // Invalid positions stay off the wire; empty ids are rejected.
    verify(Subsonic.bookmarkParams("tr-1", -5).position === undefined)
    verify(Subsonic.bookmarkParams("tr-1", "not a number").position === undefined)
    verify(Subsonic.bookmarkParams("", 100) === null)
    verify(Subsonic.bookmarkParams(null, 100) === null)
  }

  function test_parseBookmarks_normalizesAndSortsNewestFirst() {
    var parsed = Subsonic.parseBookmarks({"bookmarks": {"bookmark": [
      {entry: {id: "tr-1", title: "Old", duration: 180}, position: 1000,
       username: "alice", created: "2026-01-02T10:00:00Z"},
      {entry: {id: "tr-2", title: "New", duration: 200}, position: 2500,
       created: "2026-01-05T10:00:00Z"},
      {entry: [{id: "tr-3", title: "ListNode"}], position: 300,
       username: "bob", created: "2026-01-04T10:00:00Z"},
      {position: 900, created: "2026-01-06T10:00:00Z"},
      {entry: {id: "tr-4"}, created: "2027-01-01T00:00:00Z"},
      {entry: {id: "tr-5"}, created: ""}
    ]}})
    // Newest first; undated bookmarks sort last; id-less entries drop.
    compare(parsed.length, 5)
    compare(parsed[0].id, "tr-4")
    compare(parsed[1].id, "tr-2")
    compare(parsed[2].id, "tr-3")
    compare(parsed[3].id, "tr-1")
    compare(parsed[4].id, "tr-5")
    compare(parsed[1].position, 2500)
    compare(parsed[1].username, "")
    compare(parsed[0].created, "2027-01-01T00:00:00Z")
    compare(parsed[1].song.title, "New")
    // Defensive defaults: nothing, garbage, or a failed status parse empty.
    compare(Subsonic.parseBookmarks(null).length, 0)
    compare(Subsonic.parseBookmarks({}).length, 0)
    compare(Subsonic.parseBookmarks("garbage").length, 0)
    compare(Subsonic.parseBookmarks({"bookmarks": {"bookmark": {}}}).length, 0)
  }

  function test_parsePlayQueue_defensiveNormalizedSongsCurrentAndPosition() {
    var parsed = Subsonic.parsePlayQueue({"playQueue": {
      current: "tr-2",
      position: "42000",
      entry: [
        {id: "tr-1", title: "A", artist: "Art", album: "Al", duration: 180,
         coverArt: "c1", track: 3},
        {id: "tr-2", title: "B"}
      ]
    }})
    compare(parsed.songs.length, 2)
    compare(parsed.songs[0].id, "tr-1")
    compare(parsed.songs[0].artist, "Art")
    compare(parsed.songs[0].duration, 180)
    compare(parsed.songs[0].coverArt, "c1")
    compare(parsed.current, "tr-2")
    compare(parsed.position, 42000)
    // Single-entry and missing-node shapes parse defensively.
    var single = Subsonic.parsePlayQueue({"playQueue": {
      entry: {id: "tr-9", title: "Solo"}, current: "tr-9", position: 5}})
    compare(single.songs.length, 1)
    compare(single.current, "tr-9")
    compare(Subsonic.parsePlayQueue(null).songs.length, 0)
    compare(Subsonic.parsePlayQueue(null).current, "")
    compare(Subsonic.parsePlayQueue(null).position, 0)
    compare(Subsonic.parsePlayQueue({}).position, 0)
    compare(Subsonic.parsePlayQueue("garbage").current, "")
  }

  function test_restoreLoadPlan_prefersTheSavedQueueWithCurrentAndPosition() {
    var queue = {
      songs: [{id: "tr-1"}, {id: "tr-2"}, {id: "tr-3"}],
      current: "tr-2",
      position: 42000
    }
    var plan = Subsonic.restoreLoadPlan(queue, [], 100)
    compare(plan.songs.length, 3)
    compare(plan.offset_index, 1)
    compare(plan.position_ms, 42000)
    // Unknown current song: the queue still restores from the top.
    plan = Subsonic.restoreLoadPlan(
      {songs: [{id: "tr-1"}, {id: "tr-2"}], current: "gone", position: 9000}, [], 100)
    compare(plan.offset_index, 0)
    compare(plan.position_ms, 9000)
    // A missing position defaults to 0, which the load treats as "from start".
    plan = Subsonic.restoreLoadPlan(
      {songs: [{id: "tr-1"}], current: "", position: 0}, [], 100)
    compare(plan.position_ms, 0)
    compare(plan.offset_index, 0)
  }

  function test_restoreLoadPlan_inheritsBookmarkPositionForUnstartedCurrentSong() {
    var queue = {
      songs: [{id: "tr-1"}, {id: "tr-2"}],
      current: "tr-2",
      position: 0
    }
    var marks = [
      {id: "tr-9", position: 5000},
      {id: "tr-2", position: 123000}
    ]
    var plan = Subsonic.restoreLoadPlan(queue, marks, 100)
    compare(plan.offset_index, 1)
    compare(plan.position_ms, 123000)
    // Without a bookmark the queue position stays 0.
    plan = Subsonic.restoreLoadPlan(queue, [{id: "tr-9", position: 5000}], 100)
    compare(plan.position_ms, 0)
  }

  function test_restoreLoadPlan_fallsBackToTheNewestBookmark() {
    var marks = [
      {id: "tr-1", position: 1000, created: "2026-01-02",
       song: {id: "tr-1", title: "Old"}},
      {id: "tr-2", position: 42000, created: "2026-01-05",
       song: {id: "tr-2", title: "New"}}
    ]
    var plan = Subsonic.restoreLoadPlan(null, marks, 100)
    compare(plan.songs.length, 1)
    compare(plan.songs[0].id, "tr-2")
    compare(plan.offset_index, 0)
    compare(plan.position_ms, 42000)
    // Nothing anywhere: no restore at all.
    verify(Subsonic.restoreLoadPlan(null, [], 100) === null)
    verify(Subsonic.restoreLoadPlan({songs: []}, [{id: "tr-1"}], 100) === null)
    verify(Subsonic.restoreLoadPlan({songs: []}, [], 100) === null)
  }

  function test_restoreLoadPlan_capsTheLoadedQueue() {
    var queue = {
      songs: [{id: "tr-1"}, {id: "tr-2"}, {id: "tr-3"}, {id: "tr-4"}],
      current: "tr-3",
      position: 1000
    }
    var plan = Subsonic.restoreLoadPlan(queue, [], 2)
    compare(plan.songs.length, 2)
    // The current index clamps inside the capped load.
    compare(plan.offset_index, 1)
    compare(plan.position_ms, 1000)
  }
}
