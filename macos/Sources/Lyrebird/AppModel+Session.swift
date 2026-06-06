import Foundation
@preconcurrency import LyrebirdCore

/// Session lifecycle on `AppModel`: network/server retry, login, cold-start
/// session restore, logout, token forgetting, and auth-error interception.
extension AppModel {
    // MARK: - Network

    /// Re-evaluates network reachability and, if a session exists, kicks off a
    /// library refetch. Wired to the offline banner's `Retry` button.
    func retryNetwork() {
        network.retry()
        guard session != nil else { return }
        Task { await refreshLibrary() }
    }

    /// Clears the server-reachability failure counter and retries the library
    /// fetch. Wired to the server-unreachable banner's `Retry` button.
    /// Resetting up-front means the banner disappears while the user waits;
    /// if the refetch fails again, the error flow in `refreshLibrary` will
    /// re-accumulate failures and the banner will come back.
    func retryServer() {
        serverReachability.reset()
        guard session != nil else { return }
        Task { await refreshLibrary() }
    }

    // MARK: - Session

    func login(url: String, username: String, password: String) async {
        isLoggingIn = true
        defer { isLoggingIn = false }
        do {
            let session = try await Task.detached(priority: .userInitiated) { [core] in
                try core.login(url: url, username: username, password: password)
            }.value
            self.session = session
            self.serverURL = url
            self.username = username
            self.errorMessage = nil
            startPolling()
            await refreshLibrary()
            await refreshDownloads()
        } catch {
            self.errorMessage = LyrebirdErrorPresenter.message(for: error, context: .login)
        }
    }

    /// Rehydrate the previous session from on-disk settings + the keychain
    /// token. Called once from `RootView.task` on cold start. No-ops when the
    /// core has nothing to restore (first launch, post-logout, etc.); in that
    /// case `RootView` falls through to `LoginView`.
    ///
    /// Silent on errors: the core's `resume_session` is best-effort, so if the
    /// local state is inconsistent we log and let the user sign in again
    /// rather than blocking the app. Library fetches against the restored
    /// session go through the regular `handleAuthError` flow, so a 401 on the
    /// first call surfaces the auth-expired sheet just like a mid-session
    /// expiry. Silent reauth is the rest of #440.
    func attemptRestoreSession() async {
        // Run at most once per AppModel lifetime. `hasAttemptedRestore`
        // flips the first time this runs so re-renders of `RootView` that
        // re-fire `.task` don't repeat the restore pass.
        guard !hasAttemptedRestore else { return }
        hasAttemptedRestore = true
        guard session == nil else {
            isRestoringSession = false
            return
        }
        defer { isRestoringSession = false }
        do {
            let restored = try await Task.detached(priority: .userInitiated) { [core] in
                try core.resumeSession()
            }.value
            guard let session = restored else { return }
            self.session = session
            self.serverURL = session.server.url
            self.username = session.user.name
            self.errorMessage = nil
            startPolling()
            await refreshLibrary()
            await refreshDownloads()
        } catch {
            // Best-effort: leave `session == nil` so RootView renders LoginView.
            // No banner — the user sees the login form, which is already the
            // recovery path, and the library refetch after a manual sign-in
            // will noisily surface any persistent server problem.
            Log.auth.error("attemptRestoreSession failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func logout() {
        audio.stop()
        // core.logout() does a blocking POST /Sessions/Logout; fire it off
        // the main actor so the UI clears immediately and the user isn't
        // staring at a stalled window for the network round-trip.
        Task.detached(priority: .userInitiated) { [core] in
            try? core.logout()
        }
        session = nil
        imageURLCache.removeAll()
        albums = []
        artists = []
        tracks = []
        playlists = []
        playlistLibraryId = nil
        albumTracks = [:]
        playlistTracks = [:]
        currentPlaylistTracks = []
        pendingPlaylistRemoval = nil
        playlistDescriptions = [:]
        sidebarEditingPlaylistId = nil
        sidebarEditingDraft = ""
        sidebarCopyingPlaylistIds = []
        playlistPendingDelete = nil
        artistTopTracks = [:]
        artistSimilarCache = [:]
        artistPlaylistsCache = [:]
        artistAlbumsCache = [:]
        artistDetailCache = [:]
        resolvedNameCache = [:]
        ambientPaletteCache.removeAll()
        ambientPaletteTasks.values.forEach { $0.cancel() }
        ambientPaletteTasks.removeAll()
        recentlyPlayed = []
        forYou = []
        genresToExplore = []
        browseGenres = []
        jumpBackIn = []
        recentlyAdded = []
        recentlyAddedDates = [:]
        quickPicks = []
        quickPicksPlayCounts = [:]
        favoriteAlbumsAll = []
        favoriteAlbumsVisible = []
        favoriteArtists = []
        recentlyDiscoveredArtists = []
        rediscover = []
        suggestions = []
        searchResults = nil
        searchQuery = ""

        searchPageResults = [:]
        searchPageQuery = ""
        searchPageActiveQuery = ""
        activeSearchScope = .all
        searchPageTotal = 0
        searchPageLoaded = 0
        searchPageExhausted = false
        isLoadingFullSearch = false

        currentTrackPeople = []
        currentTrackPeopleForId = nil
        currentLyrics = nil
        currentLyricsForId = nil
        sessionPlayHistory = []
        // Clear the in-memory download snapshot. On-disk files are intentionally
        // NOT removed — they're keyed by track id and rehydrate via
        // `refreshDownloads()` on the next sign-in. See #819.
        downloadStateById = [:]
        downloads = []
        downloadStats = nil
        downloadsInFlight = []
        resetPaginationState()
        stopPolling()
    }

    /// Drop the stored access token (keychain + in-memory session) without
    /// clearing the remembered server URL / username, so the user can re-auth
    /// against the same server by re-entering only their password. Called
    /// when the user taps "Sign in" on the auth-expired sheet. Note: the
    /// caller still owns toggling `authExpired` off and nilling `session`.
    ///
    /// Unlike `logout`, this goes through the core's `forget_token` which
    /// keeps `last_server_url` / `last_username` on disk for the login-form
    /// prefill and only drops the credential store token plus the id settings
    /// that key into it. So a subsequent `attemptRestoreSession` on next launch
    /// short-circuits to `None` (safe), and the form is pre-populated.
    func forgetToken() {
        audio.stop()
        try? core.forgetToken()
        albums = []
        artists = []
        tracks = []
        playlists = []
        playlistLibraryId = nil
        albumTracks = [:]
        playlistTracks = [:]
        currentPlaylistTracks = []
        pendingPlaylistRemoval = nil
        playlistDescriptions = [:]
        sidebarEditingPlaylistId = nil
        sidebarEditingDraft = ""
        sidebarCopyingPlaylistIds = []
        playlistPendingDelete = nil
        artistTopTracks = [:]
        artistSimilarCache = [:]
        artistPlaylistsCache = [:]
        artistAlbumsCache = [:]
        artistDetailCache = [:]
        resolvedNameCache = [:]
        ambientPaletteCache.removeAll()
        ambientPaletteTasks.values.forEach { $0.cancel() }
        ambientPaletteTasks.removeAll()
        recentlyPlayed = []
        forYou = []
        genresToExplore = []
        browseGenres = []
        jumpBackIn = []
        recentlyAdded = []
        recentlyAddedDates = [:]
        quickPicks = []
        quickPicksPlayCounts = [:]
        favoriteAlbumsAll = []
        favoriteAlbumsVisible = []
        favoriteArtists = []
        recentlyDiscoveredArtists = []
        rediscover = []
        suggestions = []
        searchResults = nil
        searchQuery = ""

        searchPageResults = [:]
        searchPageQuery = ""
        searchPageActiveQuery = ""
        activeSearchScope = .all
        searchPageTotal = 0
        searchPageLoaded = 0
        searchPageExhausted = false
        isLoadingFullSearch = false

        currentTrackPeople = []
        currentTrackPeopleForId = nil
        currentLyrics = nil
        currentLyricsForId = nil
        sessionPlayHistory = []
        resetPaginationState()
        stopPolling()
    }

    /// Clear all pagination counters and in-flight flags. Kept in one place
    /// so the two clear-the-session entry points (`logout`, `forgetToken`)
    /// stay in sync.
    private func resetPaginationState() {
        albumsTotal = 0
        artistsTotal = 0
        tracksTotal = 0
        playlistsTotal = 0
        recentlyPlayedTotal = 0
        searchResultsTotal = 0
        isLoadingMoreAlbums = false
        isLoadingMoreArtists = false
        isLoadingMoreTracks = false
        isLoadingMorePlaylists = false
        isLoadingMoreSearch = false
    }

    /// Flag the session as expired. The UI surfaces this via the auth-expired
    /// modal in `MainShell`. Idempotent — second hits within a session are
    /// no-ops while the prompt is still visible.
    func markAuthExpired() {
        guard !authExpired else { return }
        audio.stop()
        stopPolling()
        authExpired = true
    }

    /// Inspect an error from a core call and, if it's the core's
    /// `NotAuthenticated` / `Auth` variant (both meaning the token's dead
    /// or never existed), mark the session expired and return `true` so the
    /// caller knows to skip its generic error surfacing.
    ///
    /// Post-BATCH-24 the Rust `LyrebirdError` is a typed enum split by HTTP
    /// class — 401 responses surface as `Auth`, the retry-layer fallback is
    /// `AuthExpired`, and a missing token is `NotAuthenticated` — so we can
    /// match variants directly instead of parsing the Display message.
    ///
    /// Call-sites that do NOT match auth go on to call
    /// `LyrebirdErrorPresenter.message(for:context:)` (see #351) to turn the
    /// raw Display string into localized banner copy.
    ///
    /// `internal` (not `private`) so AppModel extension files in other source
    /// files (e.g. `AppModel+Downloads.swift`) can route their FFI failures
    /// through the same auth-expiry interception.
    func handleAuthError(_ error: Error) -> Bool {
        guard let err = error as? LyrebirdError else { return false }
        switch err {
        case .NotAuthenticated, .Auth, .AuthExpired:
            markAuthExpired()
            return true
        default:
            return false
        }
    }
}
