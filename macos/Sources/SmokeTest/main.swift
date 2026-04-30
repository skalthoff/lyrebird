import Foundation
import AppKit
import AVFoundation
@preconcurrency import JellifyCore
import JellifyAudio

// Headless E2E smoke test against a live Jellyfin server.
//
// What it covers:
//   1. login + library list (sanity check the network surface)
//   2. play first track of first album
//   3. observe the .playing state + position advancing (catches stuck queues)
//   4. pause → assert state flips to .paused and position freezes
//   5. resume → assert state flips back to .playing and position advances
//   6. skipNext → assert currentTrack id changes (catches the rc12-class bug
//      where `pause()` / `resume()` / `skipNext()` mutate AudioEngine but the
//      AppModel UI snapshot stayed stale)
//   7. stop + clean exit
//
// Each transition asserts on `core.status()`. Non-zero exit codes encode
// which step regressed so CI logs read at a glance:
//
//   1   wiring / login / list
//   10  failed to enter .playing
//   11  position never advanced
//   12  pause didn't transition
//   13  pause didn't freeze position
//   14  resume didn't transition
//   15  resume didn't advance position
//   16  skipNext didn't change currentTrack
//
// Driven by `JELLYFIN_URL` / `JELLYFIN_USER` / `JELLYFIN_PASS`. The
// `e2e.yml` workflow points all three at a Docker Jellyfin and gates
// merges on this test.

@main
@MainActor
struct SmokeTest {
    static func main() async {
        // AVPlayer needs an active NSApplication to dispatch events properly.
        _ = NSApplication.shared

        let urlStr = ProcessInfo.processInfo.environment["JELLYFIN_URL"] ?? ""
        let user = ProcessInfo.processInfo.environment["JELLYFIN_USER"] ?? ""
        let pass = ProcessInfo.processInfo.environment["JELLYFIN_PASS"] ?? ""
        guard !urlStr.isEmpty else {
            fputs("set JELLYFIN_URL=...\n", stderr)
            exit(2)
        }

        let tmpDir = NSTemporaryDirectory() + "jellify-smoke-\(UUID().uuidString)"
        let core: JellifyCore
        do {
            core = try JellifyCore(
                config: CoreConfig(dataDir: tmpDir, deviceName: "Jellify SmokeTest")
            )
        } catch {
            fputs("core init: \(error)\n", stderr); exit(1)
        }

        do {
            let server = try core.probeServer(url: urlStr)
            print("connected to \(server.name) v\(server.version ?? "?")")
        } catch { fputs("probe: \(error)\n", stderr); exit(1) }

        let session: Session
        do {
            session = try core.login(url: urlStr, username: user, password: pass)
            print("logged in as \(session.user.name)")
        } catch { fputs("login: \(error)\n", stderr); exit(1) }

        let albums: [Album]
        do {
            // `listAlbums` now returns a paginated envelope — the smoke
            // test doesn't need the total, just the first few items.
            albums = try core.listAlbums(offset: 0, limit: 5).items
        } catch { fputs("list albums: \(error)\n", stderr); exit(1) }
        guard let album = albums.first else {
            fputs("no albums on server\n", stderr); exit(1)
        }
        print("first album: \(album.name) — \(album.artistName)")

        let tracks: [Track]
        do {
            tracks = try core.albumTracks(albumId: album.id)
        } catch { fputs("album tracks: \(error)\n", stderr); exit(1) }
        guard let first = tracks.first else {
            fputs("album has no tracks\n", stderr); exit(1)
        }
        print("playing: \(first.name) (\(Int(first.durationSeconds))s)")

        let engine = AudioEngine(core: core)
        engine.onTrackEnded = { print("track ended") }

        // ─── Step 1: play ────────────────────────────────────────────────
        do {
            _ = try core.setQueue(tracks: tracks, startIndex: 0)
            try engine.play(track: first)
        } catch {
            fputs("play: \(error)\n", stderr); exit(1)
        }

        // Allow up to 5s for the AVPlayer to actually start. On CI runners
        // the audio session bringup is occasionally slow; without the wait
        // the .playing assertion races and produces a flaky failure.
        guard await waitFor(state: .playing, on: core, timeout: 5.0) else {
            fputs("FAIL[10]: never entered .playing within 5s\n", stderr); exit(10)
        }
        print("[play] state=.playing reached")

        // Position must advance — catches "queue stuck on track 0 / paused
        // immediately after play" regressions.
        let posBeforeWait = core.status().positionSeconds
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let posAfterWait = core.status().positionSeconds
        guard posAfterWait > posBeforeWait + 0.5 else {
            fputs("FAIL[11]: position didn't advance: \(posBeforeWait) → \(posAfterWait)\n", stderr)
            exit(11)
        }
        print("[play] position advanced \(String(format: "%.2fs", posBeforeWait)) → \(String(format: "%.2fs", posAfterWait))")

        // ─── Step 2: pause ───────────────────────────────────────────────
        engine.pause()
        guard await waitFor(state: .paused, on: core, timeout: 2.0) else {
            fputs("FAIL[12]: pause didn't transition to .paused within 2s\n", stderr); exit(12)
        }
        let posAtPause = core.status().positionSeconds
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let posAfterPauseWait = core.status().positionSeconds
        guard abs(posAfterPauseWait - posAtPause) < 0.2 else {
            fputs("FAIL[13]: position drifted while paused: \(posAtPause) → \(posAfterPauseWait)\n", stderr)
            exit(13)
        }
        print("[pause] state=.paused, position frozen at \(String(format: "%.2fs", posAtPause))")

        // ─── Step 3: resume ──────────────────────────────────────────────
        engine.resume()
        guard await waitFor(state: .playing, on: core, timeout: 2.0) else {
            fputs("FAIL[14]: resume didn't transition to .playing within 2s\n", stderr); exit(14)
        }
        let posAtResume = core.status().positionSeconds
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let posAfterResume = core.status().positionSeconds
        guard posAfterResume > posAtResume + 0.5 else {
            fputs("FAIL[15]: resume didn't advance position: \(posAtResume) → \(posAfterResume)\n", stderr)
            exit(15)
        }
        print("[resume] position advanced \(String(format: "%.2fs", posAtResume)) → \(String(format: "%.2fs", posAfterResume))")

        // ─── Step 4: skipNext (if the album has a second track) ──────────
        if tracks.count >= 2 {
            let beforeId = core.status().currentTrack?.id
            if let next = core.skipNext() {
                try? engine.play(track: next)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let afterId = core.status().currentTrack?.id
                guard afterId != nil, afterId != beforeId else {
                    fputs("FAIL[16]: skipNext didn't change currentTrack: \(beforeId ?? "nil") → \(afterId ?? "nil")\n", stderr)
                    exit(16)
                }
                print("[skipNext] track changed \(beforeId ?? "nil") → \(afterId ?? "nil")")
            } else {
                print("[skipNext] core returned nil (queue exhausted) — skipping assertion")
            }
        } else {
            print("[skipNext] album has 1 track — skipping multi-track assertion")
        }

        // ─── Step 5: stop ────────────────────────────────────────────────
        engine.stop()
        print("[stop] done — all transport assertions passed")
        exit(0)
    }

    /// Poll `core.status().state` at 100ms intervals up to `timeout` seconds,
    /// returning `true` once `expected` is reached. Returns `false` on
    /// timeout. Callers print the failing assertion themselves so the exit
    /// code identifies which step regressed.
    private static func waitFor(
        state expected: PlaybackState,
        on core: JellifyCore,
        timeout: TimeInterval
    ) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if core.status().state == expected {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }
}

extension Track {
    var durationSeconds: Double { Double(runtimeTicks) / 10_000_000.0 }
}
