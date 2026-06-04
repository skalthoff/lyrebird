import SwiftUI

/// Pure mapping logic for the Library A–Z fast-scroll rail (#216).
///
/// Extracted out of the SwiftUI layer so the letter → first-row arithmetic
/// can be exercised by unit tests without a scene graph or an `AppModel`,
/// mirroring the `TrackSelectionResolver` pattern in `LibraryView`. The view
/// (`AlphabetScrollRail`) keeps only rendering + the gesture → `scrollTo`
/// glue; everything that decides *which* letter a name buckets under, and
/// *which* row a tapped letter resolves to, lives here.
enum AlphabetScrollIndex {
    /// The rail's letters, top to bottom: a leading `#` bucket for names that
    /// don't start with a Latin letter (digits, symbols, CJK, …) followed by
    /// A–Z. Stable order so the view can render it directly and tests can
    /// assert against it.
    static let letters: [Character] = ["#"] + (UnicodeScalar("A").value...UnicodeScalar("Z").value)
        .compactMap { UnicodeScalar($0).map(Character.init) }

    /// The index-rail bucket a sort-name belongs to.
    ///
    /// Folds diacritics first (so "Édith" → `E`, "Ángel" → `A`) to match the
    /// way `localizedCaseInsensitiveCompare` — the comparator the Library's
    /// alphabetical sorts use — collates accented Latin letters next to their
    /// base form. A leading whitespace run is skipped; any name whose first
    /// significant character isn't A–Z (digits like "2Pac", symbols, or a
    /// non-Latin script) lands in the `#` bucket, again matching the rail's
    /// leading entry.
    static func bucket(for sortName: String) -> Character {
        let folded = sortName.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: nil
        )
        guard let first = folded.first(where: { !$0.isWhitespace }) else {
            return "#"
        }
        let upper = Character(first.uppercased())
        return (upper >= "A" && upper <= "Z") ? upper : "#"
    }

    /// The set of buckets that have at least one item in `sortNames`. Drives
    /// the rail's emphasis: letters present in the data are inked, absent ones
    /// are dimmed.
    static func presentBuckets(in sortNames: [String]) -> Set<Character> {
        Set(sortNames.map(bucket(for:)))
    }

    /// Resolve a tapped/dragged rail `letter` to the index of the first row it
    /// should scroll to, within `sortNames` **in the order they are displayed**
    /// (i.e. the already-sorted array).
    ///
    /// Behaviour matches the platform fast-scroll convention:
    /// - If the letter has rows, return the first such row's index.
    /// - If the letter is empty (e.g. the user drags across "Q" in a library
    ///   with no Q artists), fall forward to the first row of the next
    ///   non-empty bucket at or after it, so a drag always lands somewhere
    ///   sensible rather than dead-ending.
    /// - Returns `nil` only when there is no row at or after the letter (e.g.
    ///   dragging onto "Z" when the last item is an "M"), letting the caller
    ///   no-op instead of scrolling to a bogus index.
    ///
    /// Assumes `sortNames` is already sorted ascending (the contract the
    /// Library upholds — the rail is only shown for the A–Z / Z–A name sorts,
    /// see `AlphabetScrollRail`), so the first matching index is also the
    /// top-most occurrence of the bucket.
    static func firstIndex(for letter: Character, in sortNames: [String]) -> Int? {
        guard let target = letters.firstIndex(of: letter) else { return nil }
        // Walk the rail forward from the tapped letter; the first bucket that
        // actually has a row wins. This gives the "snap to the next present
        // section" behaviour without scanning `sortNames` once per rail letter.
        for railIndex in target..<letters.count {
            let bucket = letters[railIndex]
            if let row = sortNames.firstIndex(where: { Self.bucket(for: $0) == bucket }) {
                return row
            }
        }
        return nil
    }
}

/// Vertical A–Z fast-scroll rail overlaid on the right edge of the Library
/// list (#216). ~20pt wide; renders `#` + A–Z stacked, emphasising letters
/// present in the data and dimming the rest. A tap or a vertical drag reports
/// the letter under the finger to `onSelect`, which the Library turns into a
/// `ScrollViewProxy.scrollTo`.
///
/// The rail is intentionally dumb about *data*: it takes the present-letter
/// set and a callback. All "which row does P map to" logic lives in
/// `AlphabetScrollIndex` so it stays unit-testable. Drag tracking dedupes
/// repeated callbacks for the same letter so a slow drag down the rail fires
/// one `scrollTo` per section crossed rather than one per pixel.
struct AlphabetScrollRail: View {
    /// Buckets that have at least one row — inked; the rest render dimmed.
    let presentBuckets: Set<Character>
    /// Invoked with the rail letter under a tap or the current drag location.
    /// Repeated calls for the same letter during a single drag are suppressed.
    let onSelect: (Character) -> Void

    /// The last letter reported during the in-flight drag, so we only call
    /// `onSelect` when the finger crosses into a new letter's slot.
    @State private var lastReported: Character?

    private let letters = AlphabetScrollIndex.letters
    /// Per-letter slot height. 13pt keeps the full `#`+A–Z column ≈ 350pt,
    /// which fits a MacBook content height without scrolling the rail itself.
    private let slotHeight: CGFloat = 13

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                ForEach(Array(letters.enumerated()), id: \.element) { _, letter in
                    Text(String(letter))
                        .font(Theme.font(9, weight: .bold))
                        .foregroundStyle(
                            presentBuckets.contains(letter) ? Theme.ink2 : Theme.ink3.opacity(0.4)
                        )
                        .frame(maxWidth: .infinity, minHeight: slotHeight, maxHeight: slotHeight)
                        .contentShape(Rectangle())
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        report(at: value.location.y, in: geo.size.height)
                    }
                    .onEnded { _ in lastReported = nil }
            )
        }
        .frame(width: 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Alphabet index")
        .accessibilityHint("Drag to jump to a letter")
    }

    /// Map a vertical position inside the rail to a letter slot and report it
    /// (once) to the callback. The column is centred vertically in the rail's
    /// height, so the live column height — not the full geometry — defines the
    /// hit zones.
    private func report(at y: CGFloat, in totalHeight: CGFloat) {
        let columnHeight = slotHeight * CGFloat(letters.count)
        // The VStack is centre-aligned, so the column's top sits at this inset.
        let top = max((totalHeight - columnHeight) / 2, 0)
        let local = y - top
        guard local >= 0, local < columnHeight else { return }
        let slot = min(max(Int(local / slotHeight), 0), letters.count - 1)
        let letter = letters[slot]
        guard letter != lastReported else { return }
        lastReported = letter
        onSelect(letter)
    }
}
