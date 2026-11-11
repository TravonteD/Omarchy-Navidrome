import QtQuick
import Quickshell
import "plugin" as Plugin

ShellRoot {
  Plugin.Service { id: spotifyService }
  Plugin.Panel { id: panel; service: spotifyService; width: 1280; height: 800 }
  Plugin.BarWidget { id: widget }
  Timer {
    interval: 20
    running: true
    onTriggered: {
      spotifyService.search("smoke-test", "track")
      if (spotifyService.searchLoading || !spotifyService.searchError)
        throw new Error("Search service did not return the authorization error")
      if (!panel.primaryNavigationItems().some(function(item) { return item.id === "search" }))
        throw new Error("Search navigation is missing")
      spotifyService.clearSearch()
      if (spotifyService.searchQuery !== "") throw new Error("Search state did not clear")
      // Package 5 Part B: the podcast-family library collections are gone,
      // and the Navidrome view state exposes the Subsonic windows instead.
      if (spotifyService.savedShows !== undefined
          || spotifyService.savedEpisodes !== undefined
          || spotifyService.savedAudiobooks !== undefined)
        throw new Error("Podcast-family collections should have been removed")
      if (spotifyService.artistThisIsPlaylist !== undefined)
        throw new Error("The artist This-Is slot should have been removed")
      if (typeof spotifyService.homeItems !== "function"
          || !Array.isArray(spotifyService.homeItems("starred")))
        throw new Error("Home windows are missing")
      if (!Array.isArray(spotifyService.discoverGenres)
          || spotifyService.discoverGenre !== "")
        throw new Error("Genre browsing state is missing")
      // Genre browsing must exist and fail fast (no credentials in the
      // smoke environment) without throwing.
      spotifyService.openDiscoverGenre("Jazz")
      if (spotifyService.discoverGenre !== "Jazz")
        throw new Error("Genre selection did not apply")
      if (spotifyService.genreAlbums.length !== 0
          || spotifyService.genreAlbumsNext !== "")
        throw new Error("Genre albums did not reset")
      spotifyService.clearGenreBrowse()
      if (spotifyService.discoverGenre !== "")
        throw new Error("Genre browsing did not clear")
      // PANEL_PAGE_BOOT_BEGIN — the harness strips this block when no
      // compositor exists; instantiating every page surfaces loader-time
      // binding errors in the smoke log.
      var pageTabs = ["search", "discover", "library", "playlists", "queue",
        "devices", "setup", "home"]
      for (var p = 0; p < pageTabs.length; p++) panel.currentTab = pageTabs[p]
      panel.currentTab = "home"
      // PANEL_PAGE_BOOT_END
      console.log("APP_SMOKE_PASS")
      Qt.quit()
    }
  }
}
