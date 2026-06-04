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

    /// Live count of matching tracks over the current snapshot. Recomputed
    /// each render; the evaluator is a single linear pass so this is cheap
    /// even for the largest in-memory snapshot.
    private var liveCount: Int {
        SmartPlaylistEvaluator.matchCount(
            draft,
            tracks: model.tracks,
            albums: model.albums
        )
    }

    private var trimmedName: String {
        draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
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
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "gearshape.2.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.primary)
            Text("Smart Playlist")
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
            Text("NAME")
                .font(Theme.font(10, weight: .bold))
                .foregroundStyle(Theme.ink3)
                .tracking(1.5)
            TextField("Smart Playlist Name", text: $draft.name)
                .textFieldStyle(.plain)
                .font(Theme.font(15, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
                .cornerRadius(8)
                .accessibilityLabel("Smart playlist name")
        }
    }

    // MARK: - Match mode

    @ViewBuilder
    private var matchModeRow: some View {
        HStack(spacing: 8) {
            Text("Match")
                .font(Theme.font(13, weight: .medium))
                .foregroundStyle(Theme.ink2)
            Picker("Match mode", selection: $draft.matchMode) {
                ForEach(SmartPlaylistMatchMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 90)
            .accessibilityLabel("Match mode")
            Text("of the following rules:")
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
                    Text("Add Rule")
                }
                .font(Theme.font(13, weight: .semibold))
                .foregroundStyle(Theme.primary)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            .accessibilityLabel("Add rule")
        }
    }

    /// A single editable rule row: field picker, operator picker, value
    /// editor (typed to the field's value kind), and a remove button.
    @ViewBuilder
    private func ruleRow(_ rule: Binding<SmartPlaylistRule>) -> some View {
        HStack(spacing: 8) {
            // Field picker — changing the field repairs the operator/value so
            // an impossible pairing (e.g. Favorite + greater-than) can't form.
            Picker("Field", selection: Binding(
                get: { rule.wrappedValue.field },
                set: { newField in
                    var next = rule.wrappedValue
                    next.field = newField
                    rule.wrappedValue = next.repaired()
                }
            )) {
                ForEach(SmartPlaylistField.allCases, id: \.self) { field in
                    Text(field.displayName).tag(field)
                }
            }
            .labelsHidden()
            .frame(width: 110)
            .accessibilityLabel("Rule field")

            // Operator picker — scoped to operators valid for the field kind.
            Picker("Operator", selection: rule.op) {
                ForEach(SmartPlaylistOperator.applicable(to: rule.wrappedValue.field.valueKind), id: \.self) { op in
                    Text(op.displayName).tag(op)
                }
            }
            .labelsHidden()
            .frame(width: 150)
            .accessibilityLabel("Rule operator")

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
            .accessibilityLabel("Remove rule")
        }
    }

    /// Value editor rendered per the field's value kind: a free-text field
    /// for text, a numeric field for numbers, a boolean menu for favorites,
    /// and a "N days" numeric field for dates.
    @ViewBuilder
    private func valueEditor(_ rule: Binding<SmartPlaylistRule>) -> some View {
        switch rule.wrappedValue.field.valueKind {
        case .text:
            TextField("value", text: rule.value)
                .textFieldStyle(.plain)
                .font(Theme.font(13))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 8)
                .frame(width: 130, height: 30)
                .background(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                .cornerRadius(6)
                .accessibilityLabel("Rule value")
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
                .accessibilityLabel("Rule value")
        case .boolean:
            Picker("value", selection: Binding(
                get: { SmartPlaylistEvaluator.parseBool(rule.wrappedValue.value) ?? true },
                set: { rule.wrappedValue.value = $0 ? "true" : "false" }
            )) {
                Text("yes").tag(true)
                Text("no").tag(false)
            }
            .labelsHidden()
            .frame(width: 80)
            .accessibilityLabel("Rule value")
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
                    .accessibilityLabel("Rule value in days")
                Text("days")
                    .font(Theme.font(12, weight: .medium))
                    .foregroundStyle(Theme.ink3)
            }
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack {
            // Live result count over the loaded snapshot.
            Label(SmartPlaylistDetailView.countSummary(liveCount) + " match", systemImage: "music.note")
                .font(Theme.font(12, weight: .semibold))
                .foregroundStyle(Theme.ink2)
            Spacer()
            Button("Cancel") { onCancel() }
                .buttonStyle(.plain)
                .font(Theme.font(13, weight: .medium))
                .foregroundStyle(Theme.ink2)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(Capsule().fill(Theme.surface))
                .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
                .keyboardShortcut(.cancelAction)

            Button("Save") {
                var finished = draft
                // Never persist a blank name — fall back to a sensible default.
                if trimmedName.isEmpty {
                    finished.name = "Smart Playlist"
                } else {
                    finished.name = trimmedName
                }
                onSave(finished)
            }
            .buttonStyle(.plain)
            .font(Theme.font(13, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(height: 32)
            .background(Capsule().fill(Theme.accent))
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel("Save smart playlist")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }
}
