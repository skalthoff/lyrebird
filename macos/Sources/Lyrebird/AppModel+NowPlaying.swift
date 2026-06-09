import AppKit
import Foundation
@preconcurrency import LyrebirdCore
import LyrebirdAudio

/// Playback-session reporting on `AppModel`: last.fm-style scrobbling, the
/// Now-Playing inspector details (track people + lyrics fetched on track
/// change), end-of-track handling (autoplay / stop-after-current / gapless
/// advance), and the 1 Hz status poll that mirrors `core.status()` into the
/// reactive surface.
///
/// The backing state (`scrobbleGate`, `currentTrackPeopleForId`,
/// `currentLyricsForId`, `trackAnnounceTask`, `pollTimer`,
/// `currentTrackPeople`, `currentLyrics`, …) stays declared on the
/// main `AppModel` class — stored properties can't live in an extension.
/// Extensions of a `@MainActor` type inherit its isolation, so every method
/// here is main-actor-bound just like the rest of the class.
extension AppModel {
    // MARK: - Scrobbling (#46)

    /// Persist a ListenBrainz token through the core and refresh the connected
    /// flag. Passing `nil` / blank disconnects. The token never lives in
    /// `UserDefaults` — only the core's settings table — so it stays out of the
    /// diagnostic bundle. Surfaces failures via `errorMessage`.
    func connectScrobbler(token: String?) {
        do {
            try core.setScrobbleToken(token: token)
            scrobbleConnected = core.isScrobbleConfigured()
        } catch {
            errorMessage = LyrebirdErrorPresenter.message(for: error, context: .generic)
        }
    }

    /// Clear the stored token and reset the in-flight gate so a re-connect
    /// starts clean.
    func disconnectScrobbler() {
        scrobbleGate.reset()
        connectScrobbler(token: nil)
    }

    /// Drive the scrobble gate from one status-poll observation and perform
    /// whichever action it returns. Called once per poll tick.
    ///
    /// Both submit paths hop off the main actor via `Task.detached` — they take
    /// the core's `parking_lot` mutex and make a network call, neither of which
    /// belongs on the main thread (gap pattern #2). The threshold *decision*
    /// stays on the main actor: `core.scrobbleThresholdReached` is side-effect
    /// free (no mutex, no I/O), so calling it per tick is cheap.
    ///
    /// Submit errors are swallowed by design — a failed scrobble must never
    /// interrupt playback or surface a toast. A genuinely bad token shows up
    /// in the pane (the connect call validates it); transient network blips
    /// are simply skipped.
    private func driveScrobble() {
        let track = status.currentTrack
        let enabled = ScrobblePreference.enabled && scrobbleConnected
        let action = scrobbleGate.noteTrack(
            track,
            position: status.positionSeconds,
            duration: (track?.runtimeTicks).map { Double($0) / 10_000_000.0 } ?? 0,
            enabled: enabled,
            thresholdReached: { [core] pos, dur in
                core.scrobbleThresholdReached(positionSecs: pos, runtimeSecs: dur)
            }
        )

        switch action {
        case .none:
            break
        case .nowPlaying(let t):
            let core = self.core
            Task.detached { try? core.scrobbleNowPlaying(track: t) }
        case .submitListen(let t, let listenedAt):
            let core = self.core
            Task.detached { try? core.scrobbleSubmitListen(track: t, listenedAt: listenedAt) }
        }
    }

    func handleTrackEnded() {
        // "Stop after current track" (#116): when armed, halt at this
        // track's end instead of advancing, and disarm the one-shot so the
        // queue resumes normally afterwards. Checked before `skipNext()` so
        // the playhead never moves past the track the user wanted to stop on.
        if AppModel.consumeStopAfterCurrent() {
            stop()
            return
        }
        // Advance to the next track in the queue if there is one. Arm the
        // gapless pre-load for the track *after* this new one so the next
        // end-of-track transition is seamless — without this the freshly
        // built single-item player never has a queued-ahead item and every
        // advance falls back to the gap-prone play(track:) rebuild (#931).
        if let next = core.skipNext() {
            playCurrent(next, armPreload: true)
            return
        }
        // Queue ran dry. When "autoplay similar music when queue ends" is on
        // (the default), seed an Instant Mix from the track that just
        // finished and keep playing — matching Apple Music / Spotify's
        // endless listening. When the user has turned it off, do nothing so
        // playback simply stops at the end of what they queued.
        //
        // This only fires once the user's Up Next *and* the source tail (the
        // album / playlist tracks the core queue already held) are exhausted,
        // so it never short-circuits an explicit album-end — `skipNext`
        // walks those first and only returns nil when there's genuinely
        // nothing left.
        guard autoplayWhenQueueEnds, let seed = status.currentTrack else {
            // Playback is genuinely over and we're not autoplaying. Tear the
            // session down so `reportPlaybackStopped` + `stopHeartbeat` run —
            // otherwise the player keeps a stale `currentTrack` and the server
            // shows a frozen "Now Playing" until the next user action (the
            // companion to the core heartbeat Ended-state guard).
            audio.stop()
            return
        }
        playInstantMix(seedId: seed.id, seedName: seed.name)
    }

    // MARK: - Now Playing details

    /// Post a VoiceOver announcement when the playing track changes so VO
    /// users hear the new track without navigating back to the player bar
    /// (#342). Hooked from `MainShell` on changes to
    /// `status.currentTrack?.id`.
    ///
    /// Debounced by 300ms via the cancel-previous idiom: a rapid
    /// next / next / next cancels each pending announcement before
    /// its window elapses, so only the final track is spoken. The
    /// announcement itself is `.high`-priority and non-interrupting (see
    /// `AccessibilityAnnouncer`), so it never yanks VO out of the user's
    /// current focus context.
    func announceTrackChange(to track: Track) {
        trackAnnounceTask?.cancel()
        let message = "Now playing \(track.name) by \(track.artistName)"
        trackAnnounceTask = Task {
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                // Cancelled by a newer track change before the window
                // elapsed — the newer call owns the announcement.
                return
            }
            if Task.isCancelled { return }
            AccessibilityAnnouncer.announce(message)
        }
    }

    /// Fetch detail fields (currently just `People`) for the track that is
    /// playing right now and publish the result on `currentTrackPeople` so
    /// the Now Playing credits block can render them. See #279.
    ///
    /// Safe to call repeatedly — if the current track hasn't changed since
    /// the last successful fetch, this is a no-op. On auth errors the
    /// central `handleAuthError` path triggers the re-login prompt; other
    /// errors are swallowed silently because Credits is a secondary
    /// widget and an empty state reads better than an error banner.
    func fetchCurrentTrackDetails() async {
        guard let track = status.currentTrack else {
            currentTrackPeople = []
            currentTrackPeopleForId = nil
            return
        }
        // Already have details for this track — skip.
        if currentTrackPeopleForId == track.id { return }
        let id = track.id
        do {
            let json = try await Task.detached(priority: .userInitiated) { [core] in
                try core.fetchItem(itemId: id, fields: ["People"])
            }.value
            // Ignore the response if the user skipped to a different track
            // while we were awaiting.
            guard status.currentTrack?.id == id else { return }
            currentTrackPeople = Self.parsePeople(from: json)
            currentTrackPeopleForId = id
        } catch {
            _ = handleAuthError(error)
            // Silent fallback — credits is a best-effort block.
        }
    }

    /// Parse Jellyfin's `Item.People` array out of the raw JSON returned by
    /// `core.fetchItem`. Each person comes back as
    /// `{ "Name": string, "Type": string, "Role": string, ... }`; only
    /// `Name` and `Type` are retained (see `Person`). Entries missing a
    /// non-empty `Name` are dropped so we don't render blank rows.
    static func parsePeople(from json: String) -> [Person] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["People"] as? [[String: Any]]
        else {
            return []
        }
        return raw.compactMap { entry in
            let name = (entry["Name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let type = (entry["Type"] as? String) ?? ""
            let rawId = (entry["Id"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let id = rawId.isEmpty ? nil : rawId
            guard !name.isEmpty else { return nil }
            return Person(name: name, type: type, id: id)
        }
    }

    /// Load lyrics for the currently-playing track and publish them on
    /// `currentLyrics`. Supports both LRC (timestamped) and plain-text
    /// bodies via the core `Lyrics` record — `LyricsView` renders the
    /// right layout based on `is_synced`. See #91, #273, #287, #288.
    ///
    /// Respects the `lyrics.source` `@AppStorage` preference (#121):
    /// - `none` — skips all fetches; sets `currentLyrics = []`.
    /// - `jellyfinOnly` (default) — asks the server only.
    /// - `jellyfinPlusLrcLib` — asks the server first; on a server miss
    ///   silently falls back to lrclib.net.
    ///
    /// Safe to call repeatedly — short-circuits when the current track
    /// id already matches the last successful fetch. Cleared on track
    /// change by the polling loop (see `startPolling`).
    func fetchCurrentTrackLyrics() async {
        guard let track = status.currentTrack else {
            currentLyrics = nil
            currentLyricsForId = nil
            return
        }
        if currentLyricsForId == track.id { return }
        let id = track.id

        // Read the preference. `@AppStorage` is not accessible off the
        // main actor, so we read it here on the main actor and pass the
        // value into the detached task by capture.
        let sourceRaw = UserDefaults.standard.string(forKey: "lyrics.source") ?? LyricsSource.jellyfinOnly.rawValue
        let source = LyricsSource(rawValue: sourceRaw) ?? .jellyfinOnly

        // "None" — skip all network work immediately.
        if source == .none {
            currentLyrics = []
            currentLyricsForId = id
            return
        }

        do {
            let lyrics = try await Task.detached(priority: .userInitiated) { [core] in
                try core.lyrics(trackId: id)
            }.value
            guard status.currentTrack?.id == id else { return }
            if let lyrics {
                // The FFI `LyricLine` has `timeSeconds: Double`; internal
                // `LyricLine` uses `Double?` for the "untimed" case (plain
                // text). When the server reports `is_synced == false` the
                // payload is typically a single line with `time_seconds == 0.0`
                // — preserve the nil-timestamp convention so LyricsView
                // doesn't auto-scroll a static blob.
                currentLyrics = lyrics.lines.enumerated().map { idx, line in
                    LyricLine(
                        id: idx,
                        timestamp: lyrics.isSynced ? line.timeSeconds : nil,
                        text: line.text
                    )
                }
                currentLyricsForId = id
                return
            }
            // Server returned no lyrics. If the user wants the LRCLib
            // fallback, try it now — still off the main actor.
            if source == .jellyfinPlusLrcLib {
                let fallback = await Self.fetchLrcLibLyrics(for: track)
                guard status.currentTrack?.id == id else { return }
                currentLyrics = fallback ?? []
            } else {
                currentLyrics = []
            }
            currentLyricsForId = id
        } catch {
            _ = handleAuthError(error)
            guard status.currentTrack?.id == id else { return }
            currentLyrics = []
            currentLyricsForId = id
        }
    }

    /// Fetch synced (LRC) or plain-text lyrics from lrclib.net for a track.
    ///
    /// Uses the `/api/get` endpoint with `track_name`, `artist_name`,
    /// `album_name`, and `duration` query parameters. Returns parsed
    /// `[LyricLine]` on a match, `nil` on any failure (network error,
    /// no match, bad JSON) — callers treat `nil` as a graceful "no
    /// lyrics found" and must not surface the error to the user.
    ///
    /// Runs entirely off the main actor (URLSession + JSON parsing
    /// are blocking/CPU-bound). The result is not persisted to disk; it
    /// lives in `currentLyrics` only for the current app session, satisfying
    /// the acceptance criterion that "fallback is cached locally per track".
    ///
    /// LRCLib API: https://lrclib.net/docs
    static func fetchLrcLibLyrics(for track: Track) async -> [LyricLine]? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "lrclib.net"
        components.path = "/api/get"
        let durationSeconds = Int(Double(track.runtimeTicks) / 10_000_000.0)
        components.queryItems = [
            URLQueryItem(name: "track_name", value: track.name),
            URLQueryItem(name: "artist_name", value: track.artistName),
            URLQueryItem(name: "album_name", value: track.albumName ?? ""),
            URLQueryItem(name: "duration", value: String(durationSeconds)),
        ]
        guard let url = components.url else { return nil }

        do {
            // URLSession.data(from:) is async and non-blocking — safe to
            // call off the main actor without taking the core mutex.
            let (data, response) = try await URLSession.shared.data(from: url)
            // lrclib.net returns 404 when no track is found — not an error,
            // just a miss. Any non-200 is treated as "no lyrics" so we don't
            // surface transient server issues.
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            // Prefer the synced (LRC) lyrics when available; fall back to
            // plain text so tracks without timing still show something.
            if let synced = root["syncedLyrics"] as? String, !synced.isEmpty {
                let lines = LyricLine.parseLRC(synced)
                return lines.isEmpty ? nil : lines
            }
            if let plain = root["plainLyrics"] as? String, !plain.isEmpty {
                let lines = plain
                    .split(whereSeparator: { $0.isNewline })
                    .enumerated()
                    .compactMap { idx, raw -> LyricLine? in
                        let text = raw.trimmingCharacters(in: .whitespaces)
                        return text.isEmpty ? nil : LyricLine(id: idx, timestamp: nil, text: text)
                    }
                return lines.isEmpty ? nil : lines
            }
            return nil
        } catch {
            // Network failure, timeout, etc. — swallowed per the issue spec
            // ("failure is silent").
            return nil
        }
    }

    // MARK: - Status polling

    /// Drive the status poll loop. The timer fires at a 1s cadence (was
    /// 500ms in rc<=10 — every tick takes the Rust core's `parking_lot`
    /// mutex on the MainActor and republishes `@Observable` state, which
    /// SwiftUI treats as a redraw signal even when the actual values
    /// didn't change).
    ///
    /// rc11 also tried to skip the tick body entirely when
    /// `status.state != .playing`, but `pause()` / `resume()` /
    /// `skipNext()` / `skipPrevious()` delegate straight to
    /// `AudioEngine` and never call `refreshStatus()` — so after the
    /// first user-driven pause the local `status.state` stayed `.paused`
    /// forever and the PlayerBar froze: clicking play resumed audio
    /// audibly but no UI signaled the transition (rc12 regression
    /// caught by the user). The energy win from this skip was small
    /// compared to the dominant `timeObserver` rate-zero skip in
    /// `LyrebirdAudio/AudioEngine`, so rc13 keeps the 1s cadence and
    /// drops the gate. Idle wakes/hour:
    ///   rc<=10: ~14,400 (500ms pollTimer + 500ms timeObserver)
    ///   rc11/12: ~0 paused, but UI broke
    ///   rc13:    ~3,600 paused (1s pollTimer ticks; timeObserver
    ///            still skips when `player.rate == 0`)
    /// — which still clears the macOS "high energy use" badge while
    /// keeping the player UI live.
    func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                let beforeTrack = self.status.currentTrack
                let before = beforeTrack?.id
                let beforeQueuePos = self.status.queuePosition
                let beforeQueueLen = self.status.queueLength
                self.status = self.core.status()
                let after = self.status.currentTrack?.id
                // Keep the custom Dock tile's progress ring filling in real
                // time. The controller throttles its own redraws to ≤1 Hz, so
                // calling it on every 1 s poll tick is the right cadence.
                AppDelegate.shared?.refreshDockTile()
                // Feed the scrobble gate the fresh status. Fires a ListenBrainz
                // `playing_now` on track change and a durable listen once the
                // current track passes the threshold — both off the main actor.
                self.driveScrobble()
                // Trigger a details refetch when the track changes. Scoped
                // to the polling loop so skipping via the PlayerBar,
                // media keys, or end-of-track auto-advance all get it
                // for free.
                if before != after {
                    // Record the track we just left onto the in-session
                    // history (#81). Only push real outgoing tracks — a
                    // start-from-stopped transition (before == nil) has
                    // nothing to record.
                    if let outgoing = beforeTrack {
                        self.recordSessionPlay(outgoing)
                    }
                    if after == nil {
                        self.currentTrackPeople = []
                        self.currentTrackPeopleForId = nil
                        self.currentLyrics = nil
                        self.currentLyricsForId = nil
                    } else {
                        Task { await self.fetchCurrentTrackDetails() }
                        Task { await self.fetchCurrentTrackLyrics() }
                        // Notify on the new track. The manager no-ops when the
                        // banner toggle is off, so this is cheap on every change.
                        // The first track after a startup-from-resume is left
                        // unsuppressed — a fresh play is exactly when the user
                        // wants the banner.
                        if let track = self.status.currentTrack {
                            NotificationManager.shared.notifyTrackChange(
                                title: track.name,
                                artist: track.artistName,
                                album: track.albumName
                            )
                        }
                    }
                }
                // Menu-bar "while playing" needs no poll-driven mirroring:
                // `LyrebirdApp`'s `MenuBarExtra(isInserted:)` binding observes
                // `status.state` directly, so the transient icon tracks
                // play/pause reactively (#984 retired the old
                // `MenuBarController.setVisibleWhilePlaying` call here).
                // Keep MediaSession's queue index in sync when a skip
                // happens. `AudioEngine.play(track:)` already fires
                // `trackChanged` for the new item; `queueChanged` handles
                // the case where the queue length shifts without a new
                // track starting (e.g. future `setQueue` on the current).
                // Elapsed time is intentionally NOT pushed on every tick
                // (see issue #48 — the widget interpolates from
                // `elapsed + wallclock * rate`).
                if beforeQueuePos != self.status.queuePosition
                    || beforeQueueLen != self.status.queueLength {
                    self.mediaSession.queueChanged()
                }
            }
        }
        // Pin the timer to .common so it keeps firing while the user is
        // dragging a slider or interacting with menus (the default
        // .default mode is suspended during those tracking loops).
        if let pollTimer {
            RunLoop.main.add(pollTimer, forMode: .common)
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
