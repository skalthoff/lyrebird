import SwiftUI

/// Compact, synced 3-line lyrics preview for the Queue Inspector (#91).
///
/// Sits below the Now Playing card and shows the previous, current
/// (highlighted), and next lyric line so users who don't want the
/// full-screen takeover still get a glanceable, in-sync read. Tapping it
/// promotes to the full Lyrics tab via `AppModel.openLyrics()`.
///
/// Data + sync contract:
///   * Reads `AppModel.currentLyrics` — the same parsed `[LyricLine]` the
///     full `LyricsView` consumes, populated by `fetchCurrentTrackLyrics()`
///     on every track change (polling loop), so the snippet is live even
///     when the full player has never been opened.
///   * Only renders for *timed* (LRC) lyrics. A 3-line synced window has no
///     meaning for an untimed plain-text blob — there's no "current line"
///     to track — so untimed / empty / nil all collapse to nothing. The
///     Queue Inspector omits the whole section in that case (graceful
///     omission per the issue's acceptance criteria).
///   * A 0.5s ticker recomputes the active line index. Cheap: a backwards
///     scan over a handful of lines + an index compare, mutating state only
///     when the active line actually changes. The cadence is deliberately
///     coarser than the full `LyricsView` (which uses 0.2s) — the inline
///     preview doesn't need sub-second precision and the inspector is a
///     persistent surface, so we keep idle wakes down (gap pattern #2).
struct InlineLyricsSnippet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Index of the active line within `timedLines`, or `nil` before the
    /// first timestamp is reached. Driven by the ticker.
    @State private var activeIndex: Int?

    /// Timed lyric lines only. Drops untimed rows entirely — see the type
    /// doc for why the snippet is synced-only.
    private var timedLines: [LyricLine] {
        (model.currentLyrics ?? []).filter { $0.timestamp != nil }
    }

    /// Whether there's anything to show. The Queue Inspector checks the
    /// same condition to decide whether to mount the section header.
    var hasContent: Bool { !timedLines.isEmpty }

    var body: some View {
        if hasContent {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        let lines = timedLines
        VStack(alignment: .leading, spacing: 6) {
            row(for: relativeLine(offset: -1, in: lines), emphasis: .past)
            row(for: relativeLine(offset: 0, in: lines), emphasis: .current)
            row(for: relativeLine(offset: 1, in: lines), emphasis: .upcoming)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.openLyrics() }
        .help("Open full lyrics")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: lines))
        .accessibilityHint("Opens the full lyrics view")
        .accessibilityAddTraits(.isButton)
        .onAppear { updateActiveLine() }
        // 0.5s cadence (see type doc). Skip the recompute while paused — a
        // paused inspector's position is static, so the active line can't move.
        // onAppear / onChange still re-anchor on visibility or track change so a
        // paused track shows the right line.
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            guard model.status.state == .playing else { return }
            updateActiveLine()
        }
        // Re-anchor when the track changes (currentLyrics swaps wholesale).
        .onChange(of: model.currentLyrics) { _, _ in
            activeIndex = nil
            updateActiveLine()
        }
    }

    private enum Emphasis {
        case past, current, upcoming
    }

    /// Resolve the line at `offset` rows from the active line. Returns `nil`
    /// past either end so the surrounding/upcoming row renders empty (a
    /// reserved blank line) rather than wrapping — that keeps the 3-line box
    /// a stable height and stops the current line from jumping as the song
    /// crosses the first/last lyric.
    private func relativeLine(offset: Int, in lines: [LyricLine]) -> LyricLine? {
        // Before the first timestamp, treat the upcoming first line as the
        // "current" anchor so the preview shows what's about to start rather
        // than an empty box during an intro.
        let anchor = activeIndex ?? 0
        let idx = anchor + offset
        guard idx >= 0, idx < lines.count else { return nil }
        return lines[idx]
    }

    @ViewBuilder
    private func row(for line: LyricLine?, emphasis: Emphasis) -> some View {
        let text = line?.text ?? " "
        let isCurrent = emphasis == .current
        Text(text)
            .font(Theme.font(isCurrent ? 14 : 12, weight: isCurrent ? .bold : .medium))
            .foregroundStyle(color(for: emphasis))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: text)
    }

    private func color(for emphasis: Emphasis) -> Color {
        switch emphasis {
        case .current: return Theme.ink
        case .upcoming: return Theme.ink3
        case .past: return Theme.ink3
        }
    }

    /// Find the index of the line whose timestamp is the most recent one at
    /// or before the current playback position. Walks backwards over the
    /// timestamp-ordered lines; mutates `activeIndex` only on change so most
    /// ticks are no-ops.
    private func updateActiveLine() {
        let newActive = Self.activeLineIndex(in: timedLines, at: model.status.positionSeconds)
        if newActive != activeIndex {
            activeIndex = newActive
        }
    }

    /// Index of the line whose timestamp is the most recent at or before `now`,
    /// or `nil` before the first timestamp. Lines are timestamp-ordered, so the
    /// scan stops at the first cue in the future; lines without a timestamp are
    /// skipped (they render but never auto-highlight).
    static func activeLineIndex(in lines: [LyricLine], at now: Double) -> Int? {
        var newActive: Int? = nil
        for (idx, line) in lines.enumerated() {
            guard let ts = line.timestamp else { continue }
            if ts <= now {
                newActive = idx
            } else {
                break
            }
        }
        return newActive
    }

    private func accessibilityLabel(for lines: [LyricLine]) -> String {
        if let current = relativeLine(offset: 0, in: lines)?.text, !current.isEmpty {
            return "Lyrics, now: \(current)"
        }
        return "Lyrics"
    }
}
