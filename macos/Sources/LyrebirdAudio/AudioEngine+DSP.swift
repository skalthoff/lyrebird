import AVFoundation
import Foundation
import os
@preconcurrency import LyrebirdCore

private let dspLog = Logger(subsystem: "org.lyrebird.desktop", category: "dsp")

/// AVAudioEngine DSP routing for `AudioEngine` (#39).
///
/// When `dspPipelineEnabled` is on, every public transport method branches
/// here instead of the AVQueuePlayer path. The split is deliberately at the
/// top of each method so that with the flag **off** (the default) the
/// existing path is byte-for-byte untouched — `dspPipeline` is never even
/// constructed.
///
/// Reporting parity: this path drives the exact same server contract as the
/// AVQueuePlayer path — `PlaybackInfo` resolution, `reportPlaybackStarted` /
/// `reportPlaybackProgress` / `reportPlaybackStopped`, `markTrackStarted`,
/// `markState` / `markPosition` (1 Hz, playing only), the 5s heartbeat, and
/// `MediaSession` transport notifications.
///
/// Known #39 gaps on this path (cleanly degraded, listed in the PR):
/// gapless preload is a no-op (tracks advance with a rebuild, like
/// `gaplessEnabled == false`), ReplayGain normalization is not applied,
/// stall recovery is skip-on-error rather than bounded in-place retries, and
/// Ogg containers (which AudioToolbox cannot parse) skip to the next track.
extension AudioEngine {
    /// Build (or reuse) the pipeline. Only ever called from DSP-routed
    /// methods, which are themselves gated on `dspPipelineEnabled` — so the
    /// AVQueuePlayer path never constructs one.
    func dspEnsurePipeline() -> EngineDSPPipeline {
        if let pipeline = dspPipeline { return pipeline }
        let pipeline = EngineDSPPipeline()
        pipeline.onTrackFinished = { [weak self] in
            guard let self else { return }
            // Same contract as `AVPlayerItemDidPlayToEndTime`: mark ended,
            // let the owner advance its queue (AppModel.handleTrackEnded).
            self.core.markState(state: .ended)
            self.onTrackEnded?()
        }
        pipeline.onPositionTick = { [weak self] seconds in
            guard let self, seconds.isFinite, seconds >= 0 else { return }
            self.core.markPosition(seconds: seconds)
        }
        pipeline.onStreamError = { [weak self] message in
            guard let self else { return }
            // Diagnostic detail goes to the log only — stream URLs carry the
            // api_key token, and transient NSURLError descriptions can embed
            // them. The user-facing copy matches the AVPlayer path's
            // transient-skip behaviour.
            dspLog.error("DSP track failed, skipping: \(message, privacy: .public)")
            self.delegate?.audioEngineDidEncounterTransientError("Playback failed — skipping")
            self.core.markState(state: .ended)
            self.onTrackEnded?()
        }
        pipeline.setOutputDevice(uid: outputDeviceUID)
        // Re-apply the persisted EQ curve (#40) — the pipeline constructs
        // flat/bypassed, so a rebuild (or the first DSP-routed play of the
        // session) must restore the user's settings before audio renders.
        pipeline.applyEqualizer(equalizer)
        dspPipeline = pipeline
        return pipeline
    }

    /// DSP-path `play(track:)`. Mirrors the AVQueuePlayer path's resolution
    /// + reporting sequence exactly; only the audio transport differs.
    func dspPlay(track: Track) async throws {
        let pipeline = dspEnsurePipeline()

        // Resolve local copy vs stream — identical decision tree to the
        // AVQueuePlayer path (#819 offline gate included).
        let url: URL
        let authHeader: String?
        let mediaSourceId: String?
        let playSessionId: String?
        if let localURL = await resolveLocalAssetURL(for: track.id) {
            url = localURL
            authHeader = nil
            mediaSourceId = nil
            playSessionId = nil
            core.setPlaySessionId(playSessionId: nil)
        } else {
            let (resolvedSource, resolvedSession) = await resolvePlaybackSource(for: track.id)
            mediaSourceId = resolvedSource
            playSessionId = resolvedSession
            let urlString = try core.streamUrl(
                trackId: track.id,
                mediaSourceId: mediaSourceId,
                playSessionId: playSessionId,
                maxStreamingBitrate: maxStreamingBitrate
            )
            guard let streamURL = URL(string: urlString) else {
                throw AudioEngineError.invalidURL(urlString)
            }
            url = streamURL
            core.setPlaySessionId(playSessionId: playSessionId)
            authHeader = try core.authHeader()
        }

        // Capture the outgoing track's position before the pipeline reloads,
        // so the matching Stopped report carries where it actually stopped —
        // the same capture-before-swap dance as the AVQueuePlayer path.
        let previousPositionTicks = dspPositionTicks()

        let durationHint: Double? = track.runtimeTicks > 0
            ? Double(track.runtimeTicks) / 10_000_000.0
            : nil
        pipeline.load(
            url: url,
            authHeader: authHeader,
            containerHint: track.container,
            durationHint: durationHint
        )

        // Close out the previous server session before opening the new one
        // (Jellyfin keys sessions by PlaySessionId and leaks a transcode job
        // otherwise).
        reportStopped(positionTicks: previousPositionTicks)

        let core = self.core
        Task.detached { core.markTrackStarted(track: track) }
        core.markState(state: .playing)
        pipeline.play()
        mediaSession?.trackChanged(track)

        reportStarted(
            trackId: track.id,
            mediaSourceId: mediaSourceId,
            playSessionId: playSessionId,
            playMethod: nil
        )
        core.startHeartbeat(intervalSecs: 5, playSessionId: playSessionId)
    }

    func dspPause() {
        dspPipeline?.pause()
        core.markState(state: .paused)
        mediaSession?.rateChanged(isPlaying: false)
        reportProgressSnapshot(isPaused: true)
    }

    func dspResume() {
        dspPipeline?.resume()
        core.markState(state: .playing)
        mediaSession?.rateChanged(isPlaying: true)
        reportProgressSnapshot(isPaused: false)
    }

    func dspStop() {
        // Emit Stopped before tearing the pipeline down so the report still
        // reflects the last playback position — same order as the
        // AVQueuePlayer path.
        reportStopped()
        core.stopHeartbeat()
        dspPipeline?.stop()
        core.stop()
        mediaSession?.trackChanged(nil)
    }

    func dspSeek(toSeconds seconds: Double) {
        guard let pipeline = dspPipeline else { return }
        pipeline.seek(toSeconds: seconds)
        // The pipeline's position reflects the target synchronously, so the
        // widget + server snapshot can publish immediately (the streamer
        // corrects the base frame asynchronously only for estimated VBR
        // landings / range-less servers).
        mediaSession?.seeked(to: seconds)
        reportProgressSnapshot(isPaused: pipeline.state != .playing)
    }

    func dspSetVolume(_ v: Float) {
        dspEnsurePipeline().setVolume(max(0, min(1, v)))
        core.setVolume(volume: v)
    }

    /// Position in Jellyfin ticks for the reporting helpers. Mirrors
    /// `positionTicks()`'s clamping for the AVPlayer path.
    func dspPositionTicks() -> Int64 {
        guard let pipeline = dspPipeline else { return 0 }
        let seconds = pipeline.positionSeconds
        guard seconds.isFinite, seconds >= 0 else { return 0 }
        return Int64(seconds * 10_000_000)
    }
}
