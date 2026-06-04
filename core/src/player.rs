//! Queue + playback-state bookkeeping.
//!
//! Actual audio output lives on the platform side (AVFoundation on macOS,
//! MediaPlayer on Windows, GStreamer on Linux). The core only tracks what
//! *should* be playing; the platform reports back via status updates.

use crate::error::{LyrebirdError, Result};
use crate::models::Track;
use parking_lot::Mutex;

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum PlaybackState {
    Idle,
    Loading,
    Playing,
    Paused,
    Stopped,
    Ended,
}

/// Queue-wide repeat mode carried on [`PlayerStatus`] and exposed to the
/// platform remote-control surface (macOS `MPChangeRepeatModeCommand`, MPRIS
/// `LoopStatus`, SMTC `AutoRepeatMode`).
///
/// * `Off` — advance through the queue once, then stop at the end.
/// * `One` — keep replaying the current track; next/previous both no-op.
/// * `All` — wrap around at the ends of the queue so skip-next past the last
///   track jumps to index 0, and skip-previous from index 0 jumps to the end.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default, uniffi::Enum)]
pub enum RepeatMode {
    #[default]
    Off,
    One,
    All,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct PlayerStatus {
    pub state: PlaybackState,
    pub current_track: Option<Track>,
    pub position_seconds: f64,
    pub duration_seconds: f64,
    pub volume: f32,
    pub queue_position: u32,
    pub queue_length: u32,
    /// Whether the queue-shuffle mode is engaged. The core does not actually
    /// reorder the stored queue — it just carries the flag so the platform
    /// layer can reflect it in remote-control surfaces (Control Center,
    /// media keys) and so downstream "Up Next" logic can opt into a shuffled
    /// ordering. See issue #34.
    pub shuffle: bool,
    /// Current [`RepeatMode`] for the queue. Interpreted by the platform
    /// audio engine when deciding what to do at end-of-track and by
    /// [`Player::skip_next`] / [`Player::skip_previous`] when the caller
    /// walks past a queue boundary. See issue #34.
    pub repeat_mode: RepeatMode,
    /// The `PlaySessionId` assigned by Jellyfin's `POST /Items/{id}/PlaybackInfo`
    /// for the current track. Must be echoed on every subsequent
    /// `PlaybackProgressInfo` / `PlaybackStopInfo` report so the server can
    /// correlate the stream with its transcode job. `None` when no session is
    /// active. See issue #569.
    pub play_session_id: Option<String>,
}

pub struct Player {
    shared: Mutex<Shared>,
}

struct Shared {
    state: PlaybackState,
    current: Option<Track>,
    queue: Vec<Track>,
    queue_index: usize,
    volume: f32,
    position_seconds: f64,
    shuffle: bool,
    repeat_mode: RepeatMode,
    play_session_id: Option<String>,
}

impl Shared {
    fn new() -> Self {
        Self {
            state: PlaybackState::Idle,
            current: None,
            queue: Vec::new(),
            queue_index: 0,
            volume: 1.0,
            position_seconds: 0.0,
            shuffle: false,
            repeat_mode: RepeatMode::Off,
            play_session_id: None,
        }
    }

    fn snapshot(&self) -> PlayerStatus {
        let duration_seconds = self
            .current
            .as_ref()
            .map(Track::duration_seconds)
            .unwrap_or(0.0);
        PlayerStatus {
            state: self.state.clone(),
            current_track: self.current.clone(),
            position_seconds: self.position_seconds,
            duration_seconds,
            volume: self.volume,
            queue_position: self.queue_index as u32,
            queue_length: self.queue.len() as u32,
            shuffle: self.shuffle,
            repeat_mode: self.repeat_mode,
            play_session_id: self.play_session_id.clone(),
        }
    }
}

impl Default for Player {
    fn default() -> Self {
        Self::new()
    }
}

impl Player {
    pub fn new() -> Self {
        Self {
            shared: Mutex::new(Shared::new()),
        }
    }

    /// Set the queue and mark `tracks[start_index]` as the current track.
    ///
    /// Returns `Err(LyrebirdError::InvalidIndex)` when `start_index` is
    /// out-of-bounds for the supplied `tracks` slice, so callers learn about
    /// the bad index instead of silently playing the wrong track. An empty
    /// `tracks` vec is also rejected because there is no valid index into it.
    pub fn set_queue(&self, tracks: Vec<Track>, start_index: u32) -> Result<()> {
        let idx = start_index as usize;
        if idx >= tracks.len() {
            return Err(LyrebirdError::InvalidIndex {
                index: idx,
                len: tracks.len(),
            });
        }
        let mut s = self.shared.lock();
        s.current = tracks.get(idx).cloned();
        s.queue = tracks;
        s.queue_index = idx;
        Ok(())
    }

    pub fn current_in_queue(&self) -> Option<Track> {
        let s = self.shared.lock();
        s.queue.get(s.queue_index).cloned()
    }

    /// Advance to the next track in the queue. Returns `Some(track)` on
    /// success and updates `current` so that `status()` immediately reflects
    /// the new track.
    ///
    /// Behaviour at end-of-queue depends on [`RepeatMode`]:
    /// * [`RepeatMode::Off`] — returns `None`, current unchanged.
    /// * [`RepeatMode::All`] — wraps to index 0 and returns the first track.
    /// * [`RepeatMode::One`] — returns the current track without advancing
    ///   the queue index; `current` and `queue_position` are unchanged.
    ///
    /// `RepeatMode::One` short-circuits regardless of queue position, so a
    /// "track ended" callback that invokes `skip_next` keeps replaying the
    /// same entry.
    pub fn skip_next(&self) -> Option<Track> {
        let mut s = self.shared.lock();
        if matches!(s.repeat_mode, RepeatMode::One) {
            return s.queue.get(s.queue_index).cloned();
        }
        if s.queue_index + 1 < s.queue.len() {
            s.queue_index += 1;
            let track = s.queue.get(s.queue_index).cloned();
            s.current = track.clone();
            track
        } else if matches!(s.repeat_mode, RepeatMode::All) && !s.queue.is_empty() {
            s.queue_index = 0;
            let track = s.queue.first().cloned();
            s.current = track.clone();
            track
        } else {
            None
        }
    }

    /// The track [`Player::skip_next`] *would* return, without mutating the
    /// queue index or `current`. Lets the platform audio engine pre-load the
    /// upcoming item for gapless playback while the current track is still
    /// playing.
    ///
    /// Mirrors `skip_next`'s [`RepeatMode`] semantics exactly so the pre-loaded
    /// track is always the one that actually plays next:
    /// * [`RepeatMode::One`] — the current track (it replays in place).
    /// * [`RepeatMode::Off`] — the next sequential track, or `None` at the
    ///   end of the queue.
    /// * [`RepeatMode::All`] — wraps to the first track at the end of the
    ///   queue.
    ///
    /// See issue #931.
    pub fn peek_next(&self) -> Option<Track> {
        let s = self.shared.lock();
        if matches!(s.repeat_mode, RepeatMode::One) {
            return s.queue.get(s.queue_index).cloned();
        }
        if s.queue_index + 1 < s.queue.len() {
            s.queue.get(s.queue_index + 1).cloned()
        } else if matches!(s.repeat_mode, RepeatMode::All) && !s.queue.is_empty() {
            s.queue.first().cloned()
        } else {
            None
        }
    }

    /// Step back to the previous track in the queue. Returns `Some(track)` on
    /// success and updates `current` so that `status()` immediately reflects
    /// the new track.
    ///
    /// Behaviour at start-of-queue depends on [`RepeatMode`]:
    /// * [`RepeatMode::Off`] — returns `None`, current unchanged.
    /// * [`RepeatMode::All`] — wraps to the last track in the queue.
    /// * [`RepeatMode::One`] — returns the current track without advancing
    ///   the queue index; `current` and `queue_position` are unchanged.
    pub fn skip_previous(&self) -> Option<Track> {
        let mut s = self.shared.lock();
        if matches!(s.repeat_mode, RepeatMode::One) {
            return s.queue.get(s.queue_index).cloned();
        }
        if s.queue_index > 0 {
            s.queue_index -= 1;
            let track = s.queue.get(s.queue_index).cloned();
            s.current = track.clone();
            track
        } else if matches!(s.repeat_mode, RepeatMode::All) && !s.queue.is_empty() {
            let last = s.queue.len() - 1;
            s.queue_index = last;
            let track = s.queue.get(last).cloned();
            s.current = track.clone();
            track
        } else {
            None
        }
    }

    /// Insert `tracks` into the queue immediately after the currently-playing
    /// entry without disturbing what's already playing. "Play Next" semantics,
    /// matching Apple Music / Spotify.
    ///
    /// When the queue is **empty** there is no playhead to insert after, so
    /// this behaves like a fresh [`Player::set_queue`]: the queue becomes
    /// `tracks`, `queue_index` resets to 0, and `current` is primed to the
    /// first track. That makes "Play Next" do the obvious thing on a cold
    /// queue instead of silently dropping the tracks.
    ///
    /// A `tracks` of zero length is a genuine no-op.
    ///
    /// Returns the new queue length. Closes #282 for the Play Next flows
    /// (album / playlist / track context menu, Up Next panel drag-drop).
    pub fn insert_next(&self, tracks: Vec<Track>) -> u32 {
        let mut s = self.shared.lock();
        if tracks.is_empty() {
            return s.queue.len() as u32;
        }
        if s.queue.is_empty() {
            // No playhead to insert after — start a fresh queue so the
            // tracks are actually playable (mirrors `set_queue`).
            s.current = tracks.first().cloned();
            s.queue = tracks;
            s.queue_index = 0;
            return s.queue.len() as u32;
        }
        let insert_at = (s.queue_index + 1).min(s.queue.len());
        s.queue.splice(insert_at..insert_at, tracks);
        s.queue.len() as u32
    }

    /// Append `tracks` to the end of the queue. "Add to Queue" semantics.
    /// No-op when `tracks` is empty.
    ///
    /// When the queue was **empty** before the append there is no playhead,
    /// so `queue_index` is set to 0 and `current` is primed to the first
    /// appended track — otherwise the queue would be non-empty with
    /// `current == None`, and `skip_next` could never reach the appended
    /// tracks. When the queue already had entries the playhead is left
    /// untouched.
    ///
    /// Returns the new queue length. Closes #282 for Add-to-Queue flows.
    pub fn append_to_queue(&self, tracks: Vec<Track>) -> u32 {
        let mut s = self.shared.lock();
        if tracks.is_empty() {
            return s.queue.len() as u32;
        }
        let was_empty = s.queue.is_empty();
        s.queue.extend(tracks);
        if was_empty {
            s.queue_index = 0;
            s.current = s.queue.first().cloned();
        }
        s.queue.len() as u32
    }

    /// Replace the queue with an empty vec. Distinct from [`Player::clear`]
    /// (which only wipes the active-playback bookkeeping) so the UI can offer
    /// a "Clear Up Next" action without stopping playback of the current
    /// track. Leaves the currently playing track intact as a single-item
    /// queue so subsequent `skip_next` correctly reports `None` rather than
    /// falling off a zero-length vec.
    pub fn clear_queue(&self) {
        let mut s = self.shared.lock();
        if let Some(current) = s.current.clone() {
            s.queue = vec![current];
            s.queue_index = 0;
        } else {
            s.queue.clear();
            s.queue_index = 0;
        }
    }

    /// Mark `track` as the currently-playing entry and force state to
    /// `Playing`. When `track` is present in the queue, `queue_index` is
    /// advanced to its position so `current` never diverges from
    /// `queue[queue_index]` (which drives `current_in_queue()` and the
    /// skip/peek cursor). When it is not in the queue (e.g. a one-off play of
    /// an item that was never enqueued) the index is left untouched.
    pub fn set_current(&self, track: Track) {
        let mut s = self.shared.lock();
        if let Some(i) = s.queue.iter().position(|t| t.id == track.id) {
            s.queue_index = i;
        }
        s.current = Some(track);
        s.state = PlaybackState::Playing;
    }

    /// Store the `PlaySessionId` from `POST /Items/{id}/PlaybackInfo`.
    /// Must be called at playback start and echoed on every subsequent
    /// `PlaybackProgressInfo` / `PlaybackStopInfo` report. See issue #569.
    pub fn set_play_session_id(&self, id: Option<String>) {
        self.shared.lock().play_session_id = id;
    }

    /// The current session's `PlaySessionId`, or `None` when no playback
    /// session is active.
    pub fn play_session_id(&self) -> Option<String> {
        self.shared.lock().play_session_id.clone()
    }

    pub fn mark_state(&self, state: PlaybackState) {
        self.shared.lock().state = state;
    }

    pub fn mark_position(&self, seconds: f64) {
        self.shared.lock().position_seconds = seconds.max(0.0);
    }

    pub fn set_volume(&self, v: f32) {
        self.shared.lock().volume = v.clamp(0.0, 1.0);
    }

    /// Toggle the queue-wide shuffle flag. The core does not reorder the
    /// stored queue — callers that want a shuffled listening session are
    /// expected to call [`Player::set_queue`] with pre-shuffled tracks and
    /// then toggle this flag so the remote-control surface reflects the
    /// current mode. See issue #34.
    pub fn set_shuffle(&self, on: bool) {
        self.shared.lock().shuffle = on;
    }

    /// Update the queue's [`RepeatMode`]. Does not touch the queue itself;
    /// the platform audio engine consults this when the current track ends
    /// to decide whether to replay, advance, or stop. See issue #34.
    pub fn set_repeat_mode(&self, mode: RepeatMode) {
        self.shared.lock().repeat_mode = mode;
    }

    pub fn clear(&self) {
        let mut s = self.shared.lock();
        s.state = PlaybackState::Stopped;
        s.current = None;
        s.position_seconds = 0.0;
        s.play_session_id = None;
        s.queue.clear();
        s.queue_index = 0;
    }

    pub fn status(&self) -> PlayerStatus {
        self.shared.lock().snapshot()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::Track;

    fn track(id: &str) -> Track {
        Track {
            id: id.to_string(),
            name: id.to_string(),
            album_id: None,
            album_name: None,
            artist_name: "Test Artist".to_string(),
            artist_id: None,
            index_number: None,
            disc_number: None,
            year: None,
            runtime_ticks: 1_800_000_000, // 3 minutes
            is_favorite: false,
            play_count: 0,
            container: None,
            bitrate: None,
            image_tag: None,
            playlist_item_id: None,
            user_data: None,
        }
    }

    #[test]
    fn status_defaults_shuffle_off_and_repeat_off() {
        let player = Player::new();
        let status = player.status();
        assert!(!status.shuffle);
        assert_eq!(status.repeat_mode, RepeatMode::Off);
    }

    #[test]
    fn set_shuffle_toggles_flag_on_status() {
        let player = Player::new();
        player.set_shuffle(true);
        assert!(player.status().shuffle);
        player.set_shuffle(false);
        assert!(!player.status().shuffle);
    }

    #[test]
    fn set_repeat_mode_persists_all_three_variants() {
        let player = Player::new();
        player.set_repeat_mode(RepeatMode::One);
        assert_eq!(player.status().repeat_mode, RepeatMode::One);
        player.set_repeat_mode(RepeatMode::All);
        assert_eq!(player.status().repeat_mode, RepeatMode::All);
        player.set_repeat_mode(RepeatMode::Off);
        assert_eq!(player.status().repeat_mode, RepeatMode::Off);
    }

    #[test]
    fn shuffle_and_repeat_flags_are_preserved_across_queue_changes() {
        // Callers (e.g. the macOS AppModel) set shuffle/repeat once and
        // expect the flags to survive a fresh `set_queue` call — otherwise
        // dropping a new album onto the dock would silently disable the
        // user's chosen repeat mode. Validate that invariant here.
        //
        // NOTE: this asserts only that the *flags* survive, NOT that shuffle
        // reorders playback. See `shuffle_is_a_flag_and_does_not_reorder_the_queue`
        // for the no-reorder contract.
        let player = Player::new();
        player.set_shuffle(true);
        player.set_repeat_mode(RepeatMode::All);
        player.set_queue(vec![track("a"), track("b")], 0).unwrap();
        let status = player.status();
        assert!(status.shuffle);
        assert_eq!(status.repeat_mode, RepeatMode::All);
        assert_eq!(status.queue_length, 2);
    }

    #[test]
    fn shuffle_is_a_flag_and_does_not_reorder_the_queue() {
        // Contract (#34): `set_shuffle` is intentionally a flag only. The
        // core never reorders the stored queue — callers that want a
        // shuffled listening session hand pre-shuffled tracks to
        // `set_queue`. This test pins that contract explicitly so the
        // "shuffle flag survives" test above can't be mistaken for proof
        // that shuffle changes navigation order. If core ever grows real
        // in-core shuffling, this test (and the docs) must change together.
        let player = Player::new();
        player
            .set_queue(vec![track("a"), track("b"), track("c")], 0)
            .unwrap();
        player.set_shuffle(true);
        // Navigation order is unchanged by the flag: skip/peek still walk the
        // queue in its stored order.
        assert_eq!(player.peek_next().unwrap().id, "b");
        assert_eq!(player.skip_next().unwrap().id, "b");
        assert_eq!(player.skip_next().unwrap().id, "c");
        assert!(player.status().shuffle, "flag is still reported as engaged");
    }

    // ---- #591: set_queue OOB start_index ----

    #[test]
    fn set_queue_rejects_out_of_bounds_start_index() {
        use crate::error::LyrebirdError;
        let player = Player::new();
        let result = player.set_queue(vec![track("a"), track("b")], 5);
        match result {
            Err(LyrebirdError::InvalidIndex { index: 5, len: 2 }) => {}
            other => panic!("expected InvalidIndex {{ 5, 2 }}, got {other:?}"),
        }
    }

    #[test]
    fn set_queue_rejects_empty_queue() {
        use crate::error::LyrebirdError;
        let player = Player::new();
        let result = player.set_queue(vec![], 0);
        match result {
            Err(LyrebirdError::InvalidIndex { .. }) => {}
            other => panic!("expected InvalidIndex for empty queue, got {other:?}"),
        }
    }

    #[test]
    fn set_queue_valid_index_sets_current() {
        let player = Player::new();
        player
            .set_queue(vec![track("a"), track("b"), track("c")], 1)
            .unwrap();
        let status = player.status();
        assert_eq!(status.current_track.unwrap().id, "b");
        assert_eq!(status.queue_position, 1);
    }

    // ---- #604: skip_next / skip_previous update current ----

    #[test]
    fn skip_next_updates_current_on_status() {
        let player = Player::new();
        player
            .set_queue(vec![track("a"), track("b"), track("c")], 0)
            .unwrap();

        let next = player.skip_next().expect("should return next track");
        assert_eq!(next.id, "b");

        let status = player.status();
        assert_eq!(
            status.current_track.unwrap().id,
            "b",
            "status().current_track must reflect the track after skip_next"
        );
        assert_eq!(status.queue_position, 1);
    }

    #[test]
    fn skip_previous_updates_current_on_status() {
        let player = Player::new();
        player
            .set_queue(vec![track("a"), track("b"), track("c")], 2)
            .unwrap();

        let prev = player
            .skip_previous()
            .expect("should return previous track");
        assert_eq!(prev.id, "b");

        let status = player.status();
        assert_eq!(
            status.current_track.unwrap().id,
            "b",
            "status().current_track must reflect the track after skip_previous"
        );
        assert_eq!(status.queue_position, 1);
    }

    #[test]
    fn skip_next_at_end_returns_none_and_leaves_current_unchanged() {
        let player = Player::new();
        player.set_queue(vec![track("a"), track("b")], 1).unwrap();

        let result = player.skip_next();
        assert!(result.is_none(), "skip_next at end should return None");
        assert_eq!(player.status().current_track.unwrap().id, "b");
    }

    #[test]
    fn skip_previous_at_start_returns_none_and_leaves_current_unchanged() {
        let player = Player::new();
        player.set_queue(vec![track("a"), track("b")], 0).unwrap();

        let result = player.skip_previous();
        assert!(
            result.is_none(),
            "skip_previous at start should return None"
        );
        assert_eq!(player.status().current_track.unwrap().id, "a");
    }

    // ---- #282: insert_next / append_to_queue / clear_queue ----

    #[test]
    fn insert_next_puts_tracks_right_after_current() {
        let player = Player::new();
        player
            .set_queue(vec![track("a"), track("b"), track("c")], 0)
            .unwrap();

        let new_len = player.insert_next(vec![track("x"), track("y")]);

        assert_eq!(new_len, 5, "queue length after insert_next");
        // Current stays on "a"; skip_next should now land on "x", then "y",
        // then the original "b".
        assert_eq!(player.status().current_track.unwrap().id, "a");
        assert_eq!(player.skip_next().unwrap().id, "x");
        assert_eq!(player.skip_next().unwrap().id, "y");
        assert_eq!(player.skip_next().unwrap().id, "b");
    }

    #[test]
    fn insert_next_at_end_appends_after_current_and_allows_skip_next() {
        let player = Player::new();
        player.set_queue(vec![track("a")], 0).unwrap();
        let new_len = player.insert_next(vec![track("x")]);
        assert_eq!(new_len, 2);
        assert_eq!(player.skip_next().unwrap().id, "x");
    }

    #[test]
    fn insert_next_on_empty_queue_starts_fresh_queue() {
        // With no playhead to insert after, insert_next behaves like a fresh
        // set_queue: the tracks become the queue and the first is primed as
        // current, so "Play Next" on a cold queue actually plays.
        let player = Player::new();
        let new_len = player.insert_next(vec![track("x"), track("y")]);
        assert_eq!(new_len, 2);
        let status = player.status();
        assert_eq!(status.current_track.unwrap().id, "x");
        assert_eq!(status.queue_position, 0);
        // The whole inserted set is reachable.
        assert_eq!(player.skip_next().unwrap().id, "y");
    }

    #[test]
    fn insert_next_with_empty_tracks_is_noop() {
        let player = Player::new();
        player.set_queue(vec![track("a"), track("b")], 0).unwrap();
        let new_len = player.insert_next(vec![]);
        assert_eq!(new_len, 2);
        assert_eq!(player.skip_next().unwrap().id, "b");
    }

    #[test]
    fn append_to_queue_adds_at_end_without_disturbing_current() {
        let player = Player::new();
        player.set_queue(vec![track("a"), track("b")], 0).unwrap();

        let new_len = player.append_to_queue(vec![track("x"), track("y")]);

        assert_eq!(new_len, 4);
        assert_eq!(player.status().current_track.unwrap().id, "a");
        assert_eq!(player.skip_next().unwrap().id, "b");
        assert_eq!(player.skip_next().unwrap().id, "x");
        assert_eq!(player.skip_next().unwrap().id, "y");
    }

    #[test]
    fn append_to_queue_on_empty_queue_primes_current() {
        let player = Player::new();
        let new_len = player.append_to_queue(vec![track("x"), track("y")]);
        // Appending onto an empty queue primes the playhead so the queue is
        // actually playable (otherwise current would be None with a
        // non-empty queue and skip_next could never reach the tracks).
        assert_eq!(new_len, 2);
        let status = player.status();
        assert_eq!(status.current_track.unwrap().id, "x");
        assert_eq!(status.queue_position, 0);
        assert_eq!(player.skip_next().unwrap().id, "y");
    }

    #[test]
    fn append_to_queue_with_empty_tracks_is_noop() {
        let player = Player::new();
        player.set_queue(vec![track("a")], 0).unwrap();
        let new_len = player.append_to_queue(vec![]);
        assert_eq!(new_len, 1);
    }

    #[test]
    fn clear_queue_keeps_current_track_as_single_entry() {
        let player = Player::new();
        player
            .set_queue(vec![track("a"), track("b"), track("c")], 1)
            .unwrap();
        player.clear_queue();

        let status = player.status();
        assert_eq!(status.current_track.unwrap().id, "b");
        assert_eq!(status.queue_length, 1);
        assert_eq!(status.queue_position, 0);
        // skip_next should now return None — nothing left after "b".
        assert!(player.skip_next().is_none());
    }

    #[test]
    fn clear_queue_on_empty_player_stays_empty() {
        let player = Player::new();
        player.clear_queue();
        assert_eq!(player.status().queue_length, 0);
        assert!(player.status().current_track.is_none());
    }

    #[test]
    fn skip_next_wraps_when_repeat_all() {
        let player = Player::new();
        player.set_queue(vec![track("a"), track("b")], 0).unwrap();
        player.set_repeat_mode(RepeatMode::All);
        assert_eq!(player.skip_next().unwrap().id, "b");
        let wrapped = player.skip_next();
        assert!(
            wrapped.is_some(),
            "RepeatMode::All must wrap at end of queue"
        );
        assert_eq!(wrapped.unwrap().id, "a");
        let status = player.status();
        assert_eq!(status.queue_position, 0);
        assert_eq!(status.current_track.unwrap().id, "a");
    }

    #[test]
    fn skip_next_wraps_to_self_on_single_track_queue_with_repeat_all() {
        let player = Player::new();
        player.set_queue(vec![track("a")], 0).unwrap();
        player.set_repeat_mode(RepeatMode::All);
        let wrapped = player.skip_next();
        assert!(
            wrapped.is_some(),
            "RepeatMode::All on a single-track queue must wrap to itself"
        );
        assert_eq!(wrapped.unwrap().id, "a");
        let status = player.status();
        assert_eq!(status.queue_position, 0);
        assert_eq!(status.current_track.unwrap().id, "a");
    }

    #[test]
    fn skip_next_replays_when_repeat_one() {
        let player = Player::new();
        player.set_queue(vec![track("a"), track("b")], 0).unwrap();
        player.set_repeat_mode(RepeatMode::One);
        let result = player.skip_next();
        assert!(
            result.is_some(),
            "RepeatMode::One must replay current track"
        );
        assert_eq!(result.unwrap().id, "a");
        let status = player.status();
        assert_eq!(status.queue_position, 0, "queue_position must not advance");
        assert_eq!(status.current_track.unwrap().id, "a");
    }

    #[test]
    fn skip_next_returns_none_when_repeat_off_and_at_end() {
        let player = Player::new();
        player.set_queue(vec![track("a"), track("b")], 1).unwrap();
        player.set_repeat_mode(RepeatMode::Off);
        let result = player.skip_next();
        assert!(
            result.is_none(),
            "RepeatMode::Off at end-of-queue must return None"
        );
        assert_eq!(player.status().current_track.unwrap().id, "b");
        assert_eq!(player.status().queue_position, 1);
    }

    #[test]
    fn skip_previous_wraps_when_repeat_all() {
        let player = Player::new();
        player
            .set_queue(vec![track("a"), track("b"), track("c")], 0)
            .unwrap();
        player.set_repeat_mode(RepeatMode::All);
        let wrapped = player.skip_previous();
        assert!(
            wrapped.is_some(),
            "RepeatMode::All must wrap at start of queue"
        );
        assert_eq!(wrapped.unwrap().id, "c");
        let status = player.status();
        assert_eq!(status.queue_position, 2);
        assert_eq!(status.current_track.unwrap().id, "c");
    }

    #[test]
    fn skip_previous_replays_when_repeat_one() {
        let player = Player::new();
        player.set_queue(vec![track("a"), track("b")], 1).unwrap();
        player.set_repeat_mode(RepeatMode::One);
        let result = player.skip_previous();
        assert!(
            result.is_some(),
            "RepeatMode::One must replay current track on skip_previous"
        );
        assert_eq!(result.unwrap().id, "b");
        let status = player.status();
        assert_eq!(status.queue_position, 1, "queue_position must not move");
        assert_eq!(status.current_track.unwrap().id, "b");
    }

    #[test]
    fn skip_previous_returns_none_when_repeat_off_and_at_start() {
        let player = Player::new();
        player.set_queue(vec![track("a"), track("b")], 0).unwrap();
        player.set_repeat_mode(RepeatMode::Off);
        let result = player.skip_previous();
        assert!(
            result.is_none(),
            "RepeatMode::Off at start-of-queue must return None"
        );
        assert_eq!(player.status().current_track.unwrap().id, "a");
        assert_eq!(player.status().queue_position, 0);
    }

    // ---- #931: peek_next mirrors skip_next without mutating the queue ----

    #[test]
    fn peek_next_returns_upcoming_track_without_advancing() {
        let player = Player::new();
        player
            .set_queue(vec![track("a"), track("b"), track("c")], 0)
            .unwrap();

        let peeked = player.peek_next().expect("should peek the next track");
        assert_eq!(peeked.id, "b");
        // The peek is read-only: current and queue_position are untouched, so a
        // subsequent skip_next still lands on the same track.
        assert_eq!(player.status().current_track.unwrap().id, "a");
        assert_eq!(player.status().queue_position, 0);
        assert_eq!(player.skip_next().unwrap().id, "b");
    }

    #[test]
    fn peek_next_is_idempotent_and_does_not_advance() {
        let player = Player::new();
        player
            .set_queue(vec![track("a"), track("b"), track("c")], 0)
            .unwrap();
        // Idempotent: peeking twice yields the same track and never advances.
        assert_eq!(player.peek_next().unwrap().id, "b");
        assert_eq!(player.peek_next().unwrap().id, "b");
        assert_eq!(player.status().queue_position, 0);
    }

    #[test]
    fn peek_next_predicts_skip_next_across_queue_including_wrap() {
        // The peek/skip consistency contract: peek_next must predict exactly
        // what the next skip_next yields. Walk the whole queue, and include
        // the RepeatMode::All wrap boundary where divergence is most likely.
        let player = Player::new();
        player
            .set_queue(vec![track("a"), track("b"), track("c")], 0)
            .unwrap();
        player.set_repeat_mode(RepeatMode::All);

        // Walk one full lap plus the wrap, asserting peek == the subsequent
        // skip at every step.
        for _ in 0..4 {
            let peeked = player.peek_next().unwrap().id;
            let skipped = player.skip_next().unwrap().id;
            assert_eq!(
                peeked, skipped,
                "peek_next must predict the next skip_next exactly"
            );
        }
        // After a→b→c→(wrap)a→b we should be sitting on "b".
        assert_eq!(player.status().current_track.unwrap().id, "b");
    }

    #[test]
    fn peek_next_returns_none_at_end_when_repeat_off() {
        let player = Player::new();
        player.set_queue(vec![track("a"), track("b")], 1).unwrap();
        player.set_repeat_mode(RepeatMode::Off);
        assert!(
            player.peek_next().is_none(),
            "RepeatMode::Off at end-of-queue has nothing to pre-load"
        );
    }

    #[test]
    fn peek_next_wraps_to_first_when_repeat_all() {
        let player = Player::new();
        player.set_queue(vec![track("a"), track("b")], 1).unwrap();
        player.set_repeat_mode(RepeatMode::All);
        let peeked = player.peek_next();
        assert_eq!(
            peeked.unwrap().id,
            "a",
            "RepeatMode::All must pre-load the wrap-around track"
        );
        // Still read-only.
        assert_eq!(player.status().queue_position, 1);
    }

    #[test]
    fn peek_next_returns_current_when_repeat_one() {
        let player = Player::new();
        player.set_queue(vec![track("a"), track("b")], 0).unwrap();
        player.set_repeat_mode(RepeatMode::One);
        let peeked = player.peek_next();
        assert_eq!(
            peeked.unwrap().id,
            "a",
            "RepeatMode::One replays in place, so the upcoming track is current"
        );
    }

    #[test]
    fn peek_next_on_empty_queue_is_none() {
        let player = Player::new();
        assert!(player.peek_next().is_none());
    }

    // ---- Coverage for previously-untested Player methods + PlayerStatus
    //      fields (set_volume / mark_position clamps, mark_state, set_current,
    //      clear, current_in_queue, play_session_id, and the snapshot
    //      duration/position/volume/state plumbing). ----

    #[test]
    fn set_volume_clamps_to_unit_range() {
        let player = Player::new();
        player.set_volume(2.0);
        assert_eq!(
            player.status().volume,
            1.0,
            "above-range volume clamps to 1.0"
        );
        player.set_volume(-1.0);
        assert_eq!(
            player.status().volume,
            0.0,
            "below-range volume clamps to 0.0"
        );
        player.set_volume(0.5);
        assert_eq!(
            player.status().volume,
            0.5,
            "in-range volume passes through"
        );
    }

    #[test]
    fn mark_position_clamps_negative_to_zero() {
        let player = Player::new();
        player.mark_position(-5.0);
        assert_eq!(player.status().position_seconds, 0.0);
        player.mark_position(42.5);
        assert_eq!(player.status().position_seconds, 42.5);
    }

    #[test]
    fn mark_state_sets_state_on_status() {
        let player = Player::new();
        player.mark_state(PlaybackState::Paused);
        assert_eq!(player.status().state, PlaybackState::Paused);
        player.mark_state(PlaybackState::Loading);
        assert_eq!(player.status().state, PlaybackState::Loading);
    }

    #[test]
    fn set_current_sets_track_and_forces_playing_state() {
        let player = Player::new();
        player.set_current(track("z"));
        let status = player.status();
        assert_eq!(status.current_track.unwrap().id, "z");
        assert_eq!(status.state, PlaybackState::Playing);
    }

    #[test]
    fn set_current_advances_queue_index_when_track_in_queue() {
        // Regression: set_current used to leave queue_index stale, letting
        // current diverge from queue[queue_index] / current_in_queue().
        let player = Player::new();
        player
            .set_queue(vec![track("a"), track("b"), track("c")], 0)
            .unwrap();
        player.set_current(track("c"));
        assert_eq!(player.status().queue_position, 2);
        assert_eq!(player.current_in_queue().unwrap().id, "c");
        // And skip_next from there honours the realigned cursor.
        assert!(player.skip_next().is_none(), "c is the last entry");
    }

    #[test]
    fn set_current_leaves_index_untouched_for_track_not_in_queue() {
        let player = Player::new();
        player.set_queue(vec![track("a"), track("b")], 1).unwrap();
        player.set_current(track("offqueue"));
        // The cursor stays where it was; only `current` changes.
        assert_eq!(player.status().queue_position, 1);
        assert_eq!(player.status().current_track.unwrap().id, "offqueue");
        assert_eq!(player.current_in_queue().unwrap().id, "b");
    }

    #[test]
    fn current_in_queue_returns_indexed_track() {
        let player = Player::new();
        player
            .set_queue(vec![track("a"), track("b"), track("c")], 2)
            .unwrap();
        assert_eq!(player.current_in_queue().unwrap().id, "c");
    }

    #[test]
    fn play_session_id_round_trips() {
        let player = Player::new();
        assert!(player.play_session_id().is_none());
        player.set_play_session_id(Some("sess-123".to_string()));
        assert_eq!(player.play_session_id().as_deref(), Some("sess-123"));
        assert_eq!(player.status().play_session_id.as_deref(), Some("sess-123"));
        player.set_play_session_id(None);
        assert!(player.play_session_id().is_none());
    }

    #[test]
    fn clear_resets_all_playback_bookkeeping() {
        let player = Player::new();
        player.set_queue(vec![track("a"), track("b")], 1).unwrap();
        player.set_play_session_id(Some("sess".to_string()));
        player.mark_position(30.0);
        player.mark_state(PlaybackState::Playing);

        player.clear();

        let status = player.status();
        assert_eq!(status.state, PlaybackState::Stopped);
        assert!(status.current_track.is_none());
        assert_eq!(status.position_seconds, 0.0);
        assert!(status.play_session_id.is_none());
        assert_eq!(status.queue_length, 0);
        assert_eq!(status.queue_position, 0);
    }

    #[test]
    fn status_duration_reflects_current_track_and_zero_when_empty() {
        let player = Player::new();
        // No current track => duration defaults to 0.0.
        assert_eq!(player.status().duration_seconds, 0.0);
        // `track()` is 1_800_000_000 ticks = 180s.
        player.set_queue(vec![track("a")], 0).unwrap();
        assert!((player.status().duration_seconds - 180.0).abs() < 0.001);
    }

    #[test]
    fn status_reports_position_volume_and_state_fields() {
        let player = Player::new();
        player.set_queue(vec![track("a")], 0).unwrap();
        player.mark_position(12.0);
        player.set_volume(0.25);
        player.mark_state(PlaybackState::Paused);
        let status = player.status();
        assert_eq!(status.position_seconds, 12.0);
        assert_eq!(status.volume, 0.25);
        assert_eq!(status.state, PlaybackState::Paused);
    }
}
