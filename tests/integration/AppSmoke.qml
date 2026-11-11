import QtQuick
import Quickshell
import "plugin" as Plugin

ShellRoot {
  Plugin.Service { id: navidromeService }
  Plugin.Panel { id: panel; service: navidromeService; width: 1280; height: 800 }
  Plugin.BarWidget { id: widget }
  Timer {
    interval: 20
    running: true
    onTriggered: {
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
      console.log("APP_SMOKE_PASS")
      Qt.quit()
    }
  }
}
