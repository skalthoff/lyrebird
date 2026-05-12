import SwiftUI

/// Now Playing — "Credits" info block (see #279 / `06-screen-specs.md` issue 80).
///
/// Renders a compact card listing contributor credits for the current track,
/// derived from Jellyfin's `Item.People` field. Rows are grouped by person
/// type (Writer, Producer, Composer, …) and presented as `label → value`
/// with the same visual rhythm as the "About this track" block
/// (`panels.jsx:74`).
///
/// The block is purely presentational: the caller owns fetching and mapping
/// the `People` array into `[Credit]` rows. When `credits` is empty the view
/// renders an unobtrusive placeholder rather than an empty card — callers
/// can decide to hide the block entirely if that reads better.
struct NowPlayingCredits: View {
    let credits: [Credit]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Credits")
                .font(Theme.font(10, weight: .bold))
                .foregroundStyle(Theme.ink3)
                .tracking(1.2)
                .textCase(.uppercase)
                .padding(.bottom, 10)

            if credits.isEmpty {
                Text("No credits available")
                    .font(Theme.font(12, weight: .medium))
                    .foregroundStyle(Theme.ink3)
                    .italic()
                    .padding(.vertical, 6)
            } else {
                ForEach(Array(credits.enumerated()), id: \.offset) { idx, credit in
                    CreditRow(credit: credit, isLast: idx == credits.count - 1)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Credits")
    }
}

/// A single `label → value` row inside the Credits block. The final row
/// drops its underline so the card reads cleanly when the list ends.
private struct CreditRow: View {
    let credit: Credit
    let isLast: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(credit.label)
                .font(Theme.font(12, weight: .medium))
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)

            Spacer(minLength: 12)

            Text(credit.value)
                .font(Theme.font(12, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle()
                    .fill(Theme.border)
                    .frame(height: 1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(credit.label): \(credit.value)")
    }
}

/// A single contributor-credit row. `label` is the human-readable role
/// ("Written by", "Produced by", "Composer", …) and `value` is a
/// comma-separated list of one or more people who filled that role.
struct Credit: Equatable {
    let label: String
    let value: String
}

extension Credit {
    /// Group a flat `[Person]` list (as returned by Jellyfin's `People`
    /// field) into the rows specified by the screen spec: Written by,
    /// Produced by, Composer. Unknown types are dropped. Returns rows in
    /// spec order; rows with no matching people are omitted so the block
    /// stays compact.
    ///
    /// Person `Type` values come straight from Jellyfin (see
    /// `BaseItemPerson.Type` — `Artist`, `AlbumArtist`, `Composer`,
    /// `Writer`, `Producer`, `Arranger`, `Conductor`, `Lyricist`,
    /// `Engineer`, `Mixer`, `Remixer`, `Actor`, `Director`…). For music
    /// tracks we only surface the writing/producing/composing triad.
    static func rows(from people: [Person]) -> [Credit] {
        // Preserve the order each name first appeared in, but deduplicate
        // within a group — some servers list the same person multiple
        // times with different Role strings.
        func unique(_ names: [String]) -> [String] {
            var seen = Set<String>()
            var out: [String] = []
            for n in names {
                let trimmed = n.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
                out.append(trimmed)
            }
            return out
        }

        func names(of type: String) -> [String] {
            unique(people.filter { $0.type.caseInsensitiveCompare(type) == .orderedSame }.map(\.name))
        }

        let mapping: [(label: String, names: [String])] = [
            ("Written by", names(of: "Writer")),
            ("Produced by", names(of: "Producer")),
            ("Composer", names(of: "Composer")),
        ]
        return mapping.compactMap { row in
            guard !row.names.isEmpty else { return nil }
            return Credit(label: row.label, value: row.names.joined(separator: ", "))
        }
    }
}

/// A contributor on a Jellyfin item, flattened from `BaseItemPerson`. The
/// fields kept here are the ones any of the Credits surfaces need — name and
/// type are load-bearing, `id` is optional (not every server populates it,
/// and the Now Playing card doesn't need it) but lets the album liner-note
/// chips navigate to the artist detail screen when present.
struct Person: Equatable {
    let name: String
    /// Jellyfin's `Type` enum as a raw string — kept untyped because new
    /// server versions can introduce new variants and we don't want a
    /// decoding failure to mask the whole Credits block.
    let type: String
    /// Jellyfin's `Id` for this person, when the server returns one. The
    /// id points at a `MusicArtist`-ish item for music credits, so the
    /// album liner-note chips feed it straight into `Route.artist(id)`.
    /// Nil when the field is absent on the raw JSON — callers should render
    /// the chip as non-interactive in that case.
    let id: String?

    init(name: String, type: String, id: String? = nil) {
        self.name = name
        self.type = type
        self.id = id
    }
}

#Preview("Credits — populated") {
    NowPlayingCredits(credits: [
        Credit(label: "Written by", value: "Sarah Saloli, Max Richter"),
        Credit(label: "Produced by", value: "Saloli"),
        Credit(label: "Composer", value: "Sarah Saloli"),
    ])
    .frame(width: 320)
    .padding(24)
    .background(Theme.bgAlt)
    .preferredColorScheme(.dark)
}

#Preview("Credits — empty") {
    NowPlayingCredits(credits: [])
        .frame(width: 320)
        .padding(24)
        .background(Theme.bgAlt)
        .preferredColorScheme(.dark)
}
