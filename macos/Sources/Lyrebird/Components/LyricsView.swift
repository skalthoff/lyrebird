import SwiftUI

/// A single line of lyrics, optionally anchored to a playback timestamp.
///
/// LRC files encode time as `[mm:ss.ff]lyric text` — we store the timestamp
/// as seconds so the highlight tick can compare straight against
/// `PlayerStatus.positionSeconds`. Untimed lyrics (plain text, or the
/// metadata header of an LRC file that hasn't been parsed out) surface with
/// a `nil` timestamp and render as static rows that don't participate in
/// the auto-scroll.
///
/// See #287 (LRC parser) and #288 (auto-scroll).
struct LyricLine: Equatable, Identifiable {
    /// Stable-within-a-track id so SwiftUI lists don't thrash when the set
    /// of lines is swapped wholesale between tracks. We use the line index
    /// because LRC files occasionally repeat the same text at multiple
    /// timestamps (choruses) — the text alone isn't unique.
    let id: Int
    /// Playback position at which this line becomes active, in seconds.
    /// `nil` for lines without an LRC timestamp — those render but never
    /// auto-highlight or auto-scroll.
    let timestamp: Double?
    /// The lyric text, stripped of any timestamp tags.
    let text: String
}

extension LyricLine {
    /// Parse an LRC blob into lines. Each input line may carry one or more
    /// `[mm:ss.ff]` tags — when multiple tags appear on the same text, we
    /// emit one `LyricLine` per tag (common for repeated choruses). Lines
    /// with no tags surface with `timestamp = nil` so the view can still
    /// render them, but they won't participate in auto-scroll.
    ///
    /// This is intentionally permissive: `[mm:ss]`, `[mm:ss.f]`,
    /// `[mm:ss.ff]`, and `[mm:ss.fff]` are all accepted. Metadata tags like
    /// `[ar: Artist]` / `[ti: Title]` — which technically look like
    /// timestamps but aren't — are rejected by requiring two numeric
    /// components separated by `:`. Blank lines are dropped. Output order
    /// follows ascending timestamp (nil-timestamped lines preserve their
    /// relative order at the end).
    ///
    /// See #287.
    static func parseLRC(_ raw: String) -> [LyricLine] {
        var timed: [(Double, String)] = []
        var untimed: [String] = []

        for line in raw.split(whereSeparator: { $0.isNewline }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let (stamps, rest) = extractTimestamps(from: trimmed)
            if stamps.isEmpty {
                // Plain text — could be lyrics without timing, or an
                // orphan LRC metadata tag we rejected. Keep the original
                // (trimmed) text so the line still reads naturally.
                if !trimmed.isEmpty { untimed.append(trimmed) }
            } else {
                let text = rest.trimmingCharacters(in: .whitespaces)
                // An LRC line can have only tags and no text (rare, but
                // some tools emit these as structural anchors). Skip —
                // an empty highlight row reads like a bug, not lyrics.
                guard !text.isEmpty else { continue }
                for stamp in stamps {
                    timed.append((stamp, text))
                }
            }
        }

        // If we never parsed a single timestamp, treat the entire blob as
        // plain text — caller can render it as a static column.
        if timed.isEmpty {
            return untimed.enumerated().map { idx, text in
                LyricLine(id: idx, timestamp: nil, text: text)
            }
        }

        timed.sort { $0.0 < $1.0 }
        var out = timed.enumerated().map { idx, pair in
            LyricLine(id: idx, timestamp: pair.0, text: pair.1)
        }
        // Append any stray untimed lines after the timed block. In
        // practice untimed lines in a timed file are rare (usually the
        // header after we've already stripped tags); they follow the
        // timed run so auto-scroll doesn't jump past them on the last
        // chorus.
        let base = out.count
        for (offset, text) in untimed.enumerated() {
            out.append(LyricLine(id: base + offset, timestamp: nil, text: text))
        }
        return out
    }

    /// Strip one or more leading `[mm:ss.ff]` tags from `line` and return
    /// the parsed timestamps (in seconds) plus the text that follows.
    /// Tags after the first character of actual lyric text are left
    /// in-place — LRC spec has them only at the start of a line.
    private static func extractTimestamps(from line: String) -> ([Double], String) {
        var stamps: [Double] = []
        var cursor = line.startIndex
        while cursor < line.endIndex, line[cursor] == "[" {
            guard let close = line[cursor...].firstIndex(of: "]") else { break }
            let inner = line[line.index(after: cursor)..<close]
            if let seconds = parseTimestamp(String(inner)) {
                stamps.append(seconds)
                cursor = line.index(after: close)
            } else {
                // Not a timestamp — bail without consuming. The `[ar:]`
                // case lands here. Treat the whole line as plain text.
                return ([], line)
            }
        }
        return (stamps, String(line[cursor...]))
    }

    /// Parse the contents of a single `[...]` tag as `mm:ss` /
    /// `mm:ss.f` / `mm:ss.ff` / `mm:ss.fff`. Returns `nil` on any other
    /// shape (metadata tags, malformed numbers, etc.).
    private static func parseTimestamp(_ s: String) -> Double? {
        let parts = s.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let minutes = Int(parts[0])
        else { return nil }

        let secondsRaw = parts[1]
        let secondsParts = secondsRaw.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let seconds = Int(secondsParts[0]) else { return nil }

        var fractional: Double = 0
        if secondsParts.count == 2 {
            let frac = secondsParts[1]
            guard let num = Int(frac) else { return nil }
            // `[mm:ss.f]` → tenths, `[mm:ss.ff]` → hundredths, etc.
            let divisor = pow(10.0, Double(frac.count))
            fractional = Double(num) / divisor
        }

        return Double(minutes * 60 + seconds) + fractional
    }
}

/// Lyrics viewer used inside `NowPlayingView` and as a potential full-screen
/// surface (#91). Takes the lyric lines + a live `progress` hook — the
/// view owns its own ticker so callers don't have to wire one up. When
/// `lines` is empty, renders an "No lyrics available" empty state rather
/// than a blank panel.
///
/// Auto-scroll (#288) uses `ScrollViewReader.scrollTo(.center)` with a
/// 300ms easeInOut animation. Reduce Motion disables the animation — the
/// highlight still follows the track, just without the smooth scroll.
struct LyricsView: View {
    @Environment(AppModel.self) private var model

    /// Parsed lyric lines, ordered by timestamp. Untimed lines (timestamp
    /// = nil) are allowed and render as static rows.
    let lines: [LyricLine]
    /// Closure returning the current playback position in seconds. Called
    /// every 200ms while the view is on-screen. Wrapped in a closure
    /// rather than taken as a plain Double so the view reads the freshest
    /// value on every tick without the caller having to push updates.
    let progress: () -> Double

    /// When true, falls back to a completely static (no ticker, no
    /// highlight) layout. Used as the "No lyrics" placeholder would
    /// otherwise still spin a timer for no reason.
    private var isEmpty: Bool { lines.isEmpty }
    /// When true, the lyrics blob had no LRC timestamps at all — we
    /// render it as a plain text column without a highlight or ticker.
    private var isStatic: Bool {
        !lines.isEmpty && lines.allSatisfy { $0.timestamp == nil }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Current active line id. Driven by the ticker; the view re-renders
    /// on each change to move the highlight + trigger the scroll.
    @State private var activeId: Int?
    /// Cached `Date` used to drive the ticker's Combine timer publisher.
    /// The actual polling cadence is 200ms per the issue, tight enough
    /// to feel live but loose enough not to pummel the main thread.
    @State private var tick: Date = .now

    var body: some View {
        Group {
            if isEmpty {
                emptyState
            } else if isStatic {
                staticText
            } else {
                scrollingLyrics
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    // MARK: - Empty state

    @ViewBuilder
    private var emptyState: some View {
        ContentUnavailableView(
            "No Lyrics",
            systemImage: "music.note.list",
            description: Text("This track doesn't have lyrics available.")
        )
        .foregroundStyle(Theme.ink3)
    }

    // MARK: - Static (untimed) text

    @ViewBuilder
    private var staticText: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(lines) { line in
                    Text(line.text)
                        .font(Theme.font(15, weight: .medium))
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
        }
        .accessibilityLabel("Lyrics")
    }

    // MARK: - Auto-scrolling lyrics

    @ViewBuilder
    private var scrollingLyrics: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(lines) { line in
                        LyricRow(line: line, isActive: line.id == activeId)
                            .id(line.id)
                            .modifier(TapToSeekModifier(timestamp: line.timestamp) { ts in
                                model.seek(toSeconds: ts)
                            })
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                // Top/bottom padding lets the active line sit near the
                // middle of the viewport even when the song is near the
                // first or last line.
                .padding(.vertical, 120)
            }
            .onAppear {
                updateActiveLine()
            }
            // 200ms cadence per #288. Cheap: a timestamp lookup + an id
            // compare, and we only mutate `activeId` when it changes, so
            // most ticks are no-ops.
            .onReceive(Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()) { _ in
                tick = .now
                updateActiveLine()
            }
            .onChange(of: activeId) { _, newValue in
                guard let newValue else { return }
                if reduceMotion {
                    proxy.scrollTo(newValue, anchor: .center)
                } else {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
        .accessibilityLabel("Lyrics")
    }

    /// Find the line whose timestamp is the most recent one at or before
    /// the current playback position. Runs every tick; no-op on stable
    /// state because we only assign `activeId` when it changes.
    private func updateActiveLine() {
        let now = progress()
        // Walk backwards — lyric lines in timestamp order, so the last
        // one with timestamp <= now is active. O(n) on a handful of
        // lines, which is fine for the 200ms cadence.
        var newActive: Int? = nil
        for line in lines {
            guard let ts = line.timestamp else { continue }
            if ts <= now {
                newActive = line.id
            } else {
                break
            }
        }
        if newActive != activeId {
            activeId = newActive
        }
    }
}

/// One rendered lyric row. Active rows bloom in size + brightness; past
/// rows dim so the eye is pulled to the current line.
private struct LyricRow: View {
    let line: LyricLine
    let isActive: Bool

    var body: some View {
        Text(line.text)
            .font(Theme.font(isActive ? 22 : 18, weight: isActive ? .bold : .medium))
            .foregroundStyle(isActive ? Theme.ink : Theme.ink3)
            .fixedSize(horizontal: false, vertical: true)
            .animation(.easeInOut(duration: 0.2), value: isActive)
            .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// Wires a click handler onto a lyric row when — and only when — the line
/// has an LRC timestamp. Untimed rows fall through unchanged so they
/// don't surface a misleading pointer cursor or accessibility action.
private struct TapToSeekModifier: ViewModifier {
    let timestamp: Double?
    let onSeek: (Double) -> Void

    func body(content: Content) -> some View {
        if let ts = timestamp {
            content
                .contentShape(Rectangle())
                .onTapGesture { onSeek(ts) }
                .help("Tap to jump to this line")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { onSeek(ts) }
        } else {
            content
        }
    }
}

#Preview("Lyrics — timed") {
    let sample = """
    [00:00.00]Line one at the top
    [00:04.50]Line two after a pause
    [00:09.20]Line three with feeling
    [00:14.00]Line four pulls it together
    [00:18.80]Line five — final chorus
    """
    return LyricsView(
        lines: LyricLine.parseLRC(sample),
        progress: { 9.5 }
    )
    .frame(width: 420, height: 480)
    .background(Theme.bg)
    .preferredColorScheme(.dark)
}

#Preview("Lyrics — empty") {
    LyricsView(lines: [], progress: { 0 })
        .frame(width: 420, height: 480)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
}

#Preview("Lyrics — static text") {
    let lines = [
        "A first line of static lyrics",
        "A second line without timing",
        "A third — useful for LRC-less tracks",
    ].enumerated().map { idx, text in
        LyricLine(id: idx, timestamp: nil, text: text)
    }
    return LyricsView(lines: lines, progress: { 0 })
        .frame(width: 420, height: 480)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
}
