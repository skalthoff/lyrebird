import SwiftUI
@preconcurrency import LyrebirdCore

/// iTunes / Marvis-style rule builder for a `SmartPlaylist` (#77 / #238).
///
/// Presented as a sheet. The user edits the name, the "Match all / any of
/// the following rules" mode, and an ordered list of `field op value` rows
/// (each with add / remove affordances). A live "N songs match" readout at
/// the bottom evaluates the draft against the current library snapshot on
/// every keystroke so the user gets immediate feedback.
///
/// The builder is intentionally self-contained: it edits a local copy of
/// the playlist and only hands the result back through `onSave` when the
/// user commits, so a cancelled edit leaves the stored playlist untouched.
/// The live count is the only thing that reaches into `AppModel` (for the
/// snapshot to evaluate against).
struct SmartPlaylistBuilderView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Local working copy. Edits mutate this; nothing persists until `onSave`.
    @State private var draft: SmartPlaylist

    /// Live count of matching tracks over the current snapshot, recomputed
    /// off the main thread and debounced (see `recomputeLiveCount`). `nil`
    /// until the first evaluation completes so the footer can show a neutral
    /// placeholder rather than a misleading "0 match" before the sweep runs.
    /// The in-flight sweep is owned by `.task(id: draft)`, which cancels and
    /// restarts it on every edit, so no manual task handle is needed.
    @State private var liveCount: Int?

    /// Called with the finished playlist when the user taps Save. The caller
    /// owns persistence (`SmartPlaylistStore.save`).
    private let onSave: (SmartPlaylist) -> Void
    /// Called when the user dismisses without saving.
    private let onCancel: () -> Void

    init(
        playlist: SmartPlaylist,
        onSave: @escaping (SmartPlaylist) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: playlist)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var trimmedName: String {
        draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Recompute the live match count without blocking the main thread.
    ///
    /// The old code read `matchCount` from a computed property in `body`, so
    /// every keystroke in the name field or any rule editor re-ran the whole
    /// O(albums + tracks) sweep synchronously on the MainActor (CLAUDE.md gap
    /// pattern #2). Instead we debounce (~250 ms) and run the evaluation in a
    /// detached task, building the album→genre index once and passing it to
    /// the `genresByAlbumId:` evaluator overload, then marshal just the `Int`
    /// back to `@State` on the main actor. The task is keyed to `draft` via
    /// `.task(id:)` so SwiftUI cancels the prior sweep on each edit.
    private func recomputeLiveCount() async {
        // Debounce: if the draft changes again within the window, `.task(id:)`
        // cancels this task before the sleep returns and starts a fresh one.
        do {
            try await Task.sleep(nanoseconds: 250_000_000)
        } catch {
            return // cancelled — a newer edit superseded this one
        }
        let snapshotTracks = model.tracks
        let snapshotAlbums = model.albums
        let playlist = draft
        let count = await Task.detached(priority: .userInitiated) {
            SmartPlaylistEvaluator.matchCount(
                playlist,
                tracks: snapshotTracks,
                genresByAlbumId: SmartPlaylistEvaluator.albumGenreIndex(snapshotAlbums)
            )
        }.value
        if Task.isCancelled { return }
        liveCount = count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Theme.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    nameField
                    matchModeRow
                    rulesSection
                }
                .padding(24)
            }
            Divider().background(Theme.border)
            footer
        }
        .frame(width: 560, height: 520)
        .background(Theme.bg)
        // Recompute the live count off-main whenever the draft changes;
        // `.task(id:)` cancels the prior (debounced) sweep on each edit.
        .task(id: draft) {
            await recomputeLiveCount()
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "gearshape.2.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.primary)
            Text("smart_playlist.builder.title")
                .font(Theme.font(16, weight: .bold))
                .foregroundStyle(Theme.ink)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: - Name

    @ViewBuilder
    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("smart_playlist.builder.name_label")
                .font(Theme.font(10, weight: .bold))
                .foregroundStyle(Theme.ink3)
                .tracking(1.5)
            TextField(String(localized: "smart_playlist.builder.name_placeholder"), text: $draft.name)
                .textFieldStyle(.plain)
                .font(Theme.font(15, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
                .cornerRadius(8)
                .accessibilityLabel(Text("smart_playlist.builder.a11y.name"))
        }
    }

    // MARK: - Match mode

    @ViewBuilder
    private var matchModeRow: some View {
        HStack(spacing: 8) {
            Text("smart_playlist.builder.match_prefix")
                .font(Theme.font(13, weight: .medium))
                .foregroundStyle(Theme.ink2)
            Picker(String(localized: "smart_playlist.builder.a11y.match_mode"), selection: $draft.matchMode) {
                ForEach(SmartPlaylistMatchMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 90)
            .accessibilityLabel(Text("smart_playlist.builder.a11y.match_mode"))
            Text("smart_playlist.builder.match_suffix")
                .font(Theme.font(13, weight: .medium))
                .foregroundStyle(Theme.ink2)
            Spacer()
        }
    }

    // MARK: - Rules

    @ViewBuilder
    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach($draft.rules) { $rule in
                ruleRow($rule)
            }
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                    draft.rules.append(.defaultRule())
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                    Text("smart_playlist.builder.add_rule")
                }
                .font(Theme.font(13, weight: .semibold))
                .foregroundStyle(Theme.primary)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            .accessibilityLabel(Text("smart_playlist.builder.a11y.add_rule"))
        }
    }

    /// A single editable rule row: field picker, operator picker, value
    /// editor (typed to the field's value kind), and a remove button.
    @ViewBuilder
    private func ruleRow(_ rule: Binding<SmartPlaylistRule>) -> some View {
        HStack(spacing: 8) {
            // Field picker — changing the field normalizes the operator *and*
            // the value for the new field's kind so an impossible pairing
            // (e.g. Favorite + greater-than) or a stale value (e.g. a text
            // value left behind on a boolean field) can't form.
            Picker(String(localized: "smart_playlist.builder.a11y.field"), selection: Binding(
                get: { rule.wrappedValue.field },
                set: { newField in
                    rule.wrappedValue = rule.wrappedValue.changingField(to: newField)
                }
            )) {
                ForEach(SmartPlaylistField.allCases, id: \.self) { field in
                    Text(field.displayName).tag(field)
                }
            }
            .labelsHidden()
            .frame(width: 110)
            .accessibilityLabel(Text("smart_playlist.builder.a11y.field"))

            // Operator picker — scoped to operators valid for the field kind.
            Picker(String(localized: "smart_playlist.builder.a11y.operator"), selection: rule.op) {
                ForEach(SmartPlaylistOperator.applicable(to: rule.wrappedValue.field.valueKind), id: \.self) { op in
                    Text(op.displayName).tag(op)
                }
            }
            .labelsHidden()
            .frame(width: 150)
            .accessibilityLabel(Text("smart_playlist.builder.a11y.operator"))

            valueEditor(rule)

            Spacer(minLength: 0)

            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                    draft.rules.removeAll { $0.id == rule.wrappedValue.id }
                }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.ink3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("smart_playlist.builder.a11y.remove_rule"))
        }
    }

    /// Value editor rendered per the field's value kind: a free-text field
    /// for text, a numeric field for numbers, a boolean menu for favorites,
    /// and a "N days" numeric field for dates.
    @ViewBuilder
    private func valueEditor(_ rule: Binding<SmartPlaylistRule>) -> some View {
        switch rule.wrappedValue.field.valueKind {
        case .text:
            TextField(String(localized: "smart_playlist.builder.value_placeholder"), text: rule.value)
                .textFieldStyle(.plain)
                .font(Theme.font(13))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 8)
                .frame(width: 130, height: 30)
                .background(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                .cornerRadius(6)
                .accessibilityLabel(Text("smart_playlist.builder.a11y.value"))
        case .number:
            TextField("0", text: rule.value)
                .textFieldStyle(.plain)
                .font(Theme.font(13))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.trailing)
                .padding(.horizontal, 8)
                .frame(width: 80, height: 30)
                .background(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                .cornerRadius(6)
                .accessibilityLabel(Text("smart_playlist.builder.a11y.value"))
        case .boolean:
            // The picker's `get` defaults an unparseable stored value to
            // `true`; normalize that back into the binding on appear so the
            // displayed state and the stored/evaluated state agree (otherwise
            // a stale non-boolean value would show "yes" but evaluate to
            // no-match). The `changingField` repair already seeds a valid
            // default on a field switch; this also covers hand-edited files.
            Picker(String(localized: "smart_playlist.builder.a11y.value"), selection: Binding(
                get: { SmartPlaylistEvaluator.parseBool(rule.wrappedValue.value) ?? true },
                set: { rule.wrappedValue.value = $0 ? "true" : "false" }
            )) {
                Text("smart_playlist.builder.bool_yes").tag(true)
                Text("smart_playlist.builder.bool_no").tag(false)
            }
            .labelsHidden()
            .frame(width: 80)
            .accessibilityLabel(Text("smart_playlist.builder.a11y.value"))
            .onAppear {
                if SmartPlaylistEvaluator.parseBool(rule.wrappedValue.value) == nil {
                    rule.wrappedValue.value = "true"
                }
            }
        case .date:
            HStack(spacing: 4) {
                TextField("30", text: rule.value)
                    .textFieldStyle(.plain)
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.trailing)
                    .padding(.horizontal, 8)
                    .frame(width: 56, height: 30)
                    .background(Theme.surface)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                    .cornerRadius(6)
                    .accessibilityLabel(Text("smart_playlist.builder.a11y.value_days"))
                Text("smart_playlist.builder.days_suffix")
                    .font(Theme.font(12, weight: .medium))
                    .foregroundStyle(Theme.ink3)
            }
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack {
            // Live result count over the loaded snapshot. A single localized,
            // plural-aware format string carries the count (no English-glued
            // " match" suffix, which both broke localization and read wrong in
            // the singular). `nil` while the first off-main sweep is in flight.
            Label {
                if let liveCount {
                    Text("smart_playlist.builder.match_count \(liveCount)")
                } else {
                    Text("smart_playlist.builder.counting")
                }
            } icon: {
                Image(systemName: "music.note")
            }
            .font(Theme.font(12, weight: .semibold))
            .foregroundStyle(Theme.ink2)
            Spacer()
            Button { onCancel() } label: {
                Text("smart_playlist.builder.cancel")
            }
                .buttonStyle(.plain)
                .font(Theme.font(13, weight: .medium))
                .foregroundStyle(Theme.ink2)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(Capsule().fill(Theme.surface))
                .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
                .keyboardShortcut(.cancelAction)

            Button {
                var finished = draft
                // Never persist a blank name — fall back to a sensible default.
                if trimmedName.isEmpty {
                    finished.name = String(localized: "smart_playlist.builder.default_name")
                } else {
                    finished.name = trimmedName
                }
                onSave(finished)
            } label: {
                Text("smart_playlist.builder.save")
            }
            .buttonStyle(.plain)
            .font(Theme.font(13, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(height: 32)
            .background(Capsule().fill(Theme.accent))
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel(Text("smart_playlist.builder.a11y.save"))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }
}
