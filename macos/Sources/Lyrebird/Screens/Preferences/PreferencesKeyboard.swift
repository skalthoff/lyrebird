import AppKit
import SwiftUI

/// Keyboard-shortcuts editor pane (#120 / #265).
///
/// A grouped table of every customizable shortcut. Each row shows the action
/// name, its current chord rendered as a key-cap chip, and a Record button. The
/// recorder flips to a "Press keys…" state that captures the next chord via a
/// local `NSEvent` monitor; clashes with another action are detected and warned
/// inline (in `Theme.danger`) and refused. Per-row "Reset" restores the catalog
/// default; a pane-level "Reset All" clears every override.
///
/// Read vs. write model: the catalog (`AppShortcuts.all`) supplies the rows and
/// their defaults; the live binding flows through `AppModel`'s override map
/// (`AppModel+Shortcuts`), which `LyrebirdCommands` also resolves so a remap
/// re-binds the actual menu key-equivalent. Persistence + conflict detection
/// live in the model; this view is the editing surface.
///
/// Spec: `research/03-ux-patterns.md` (Issue 120) and `06-screen-specs.md`
/// (Issue 265).
struct PreferencesKeyboard: View {
	@Environment(AppModel.self) private var model

	/// The action id currently in "Press keys…" capture mode, or `nil`.
	@State private var recordingId: String?
	/// Transient inline warning for the last refused (conflicting) capture,
	/// keyed by action id so it renders under the right row.
	@State private var conflictWarning: ConflictWarning?
	/// Confirmation gate for the destructive "Reset All".
	@State private var confirmResetAll = false

	/// Action ids the editor deliberately does not offer for remapping. Bare
	/// Space (Play/Pause) is bound by an app-wide `NSEvent` monitor
	/// (`PlayPauseSpaceMonitor`) rather than a menu key-equivalent — it must
	/// stay ⎵ so it can fall through to focused text fields — so it can't be
	/// re-bound through the override map. It still appears in the help window's
	/// catalog; it's just not editable here.
	static let nonEditableActionIds: Set<String> = ["playback.play_pause"]

	/// Rows grouped by section, in catalog order, mirroring the help window so
	/// the editor reads like the menus (minus the non-editable actions above).
	private var sections: [(section: AppShortcuts.Section, rows: [AppShortcuts.Shortcut])] {
		AppShortcuts.Section.allCases.compactMap { section in
			let rows = AppShortcuts.all.filter {
				$0.section == section && !Self.nonEditableActionIds.contains($0.id)
			}
			return rows.isEmpty ? nil : (section, rows)
		}
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 24) {
			header

			ForEach(sections, id: \.section.id) { entry in
				section(entry.section, rows: entry.rows)
			}

			Spacer(minLength: 0)
		}
		// Capture mode lives in a single window-scoped monitor; tearing it down
		// when no row is recording keeps the app from intercepting every keypress
		// in the Preferences window.
		.background(
			ShortcutCaptureMonitor(isRecording: recordingId != nil) { event in
				handleCapture(event)
			}
		)
		.onDisappear { recordingId = nil }
	}

	// MARK: - Header

	private var header: some View {
		HStack(alignment: .firstTextBaseline) {
			VStack(alignment: .leading, spacing: 6) {
				Text("Keyboard")
					.font(Theme.font(28, weight: .black, italic: true))
					.foregroundStyle(Theme.ink)
				Text("Customize the keyboard shortcuts for menu and playback actions.")
					.font(Theme.font(13, weight: .medium))
					.foregroundStyle(Theme.ink3)
			}

			Spacer()

			Button(role: .destructive) {
				confirmResetAll = true
			} label: {
				Text("Reset All…")
					.font(Theme.font(12, weight: .semibold))
			}
			.buttonStyle(.bordered)
			.disabled(!model.shortcutOverrides.isEmpty ? false : true)
			.accessibilityLabel("Reset all keyboard shortcuts to defaults")
			.confirmationDialog(
				"Reset all keyboard shortcuts to their defaults?",
				isPresented: $confirmResetAll,
				titleVisibility: .visible
			) {
				Button("Reset All", role: .destructive) {
					model.resetAllShortcuts()
					conflictWarning = nil
					recordingId = nil
				}
				Button("Cancel", role: .cancel) {}
			} message: {
				Text("This restores every shortcut to its original chord. This can't be undone.")
			}
		}
	}

	// MARK: - Sections

	private func section(_ section: AppShortcuts.Section, rows: [AppShortcuts.Shortcut]) -> some View {
		VStack(alignment: .leading, spacing: 10) {
			Text(section.titleKey)
				.font(Theme.font(11, weight: .bold))
				.textCase(.uppercase)
				.tracking(1.2)
				.foregroundStyle(Theme.ink3)

			VStack(spacing: 0) {
				ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
					shortcutRow(row)
					if index < rows.count - 1 {
						Divider().overlay(Theme.border.opacity(0.6))
					}
				}
			}
			.background(
				RoundedRectangle(cornerRadius: 10)
					.fill(Theme.surface)
					.overlay(
						RoundedRectangle(cornerRadius: 10)
							.stroke(Theme.border, lineWidth: 1)
					)
			)
		}
	}

	// MARK: - Row

	@ViewBuilder
	private func shortcutRow(_ row: AppShortcuts.Shortcut) -> some View {
		let isRecording = recordingId == row.id
		let chord = model.resolvedChord(for: row.id)
		let customized = model.isShortcutCustomized(row.id)
		let warning = conflictWarning?.actionId == row.id ? conflictWarning : nil

		VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 12) {
				Text(row.nameKey)
					.font(Theme.font(13, weight: .semibold))
					.foregroundStyle(Theme.ink)
				if customized {
					Text("Customized")
						.font(Theme.font(9, weight: .bold))
						.textCase(.uppercase)
						.tracking(0.5)
						.foregroundStyle(Theme.accent)
						.padding(.horizontal, 6)
						.padding(.vertical, 2)
						.background(
							Capsule().fill(Theme.accent.opacity(0.14))
						)
						.accessibilityHidden(true)
				}

				Spacer(minLength: 16)

				chordChip(chord: chord, isRecording: isRecording, hasWarning: warning != nil)

				recordButton(for: row, isRecording: isRecording)

				resetButton(for: row, customized: customized)
			}

			if let warning {
				Label(warning.message, systemImage: "exclamationmark.triangle.fill")
					.font(Theme.font(11, weight: .medium))
					.foregroundStyle(Theme.danger)
					.transition(.opacity)
			}
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 10)
		.contentShape(Rectangle())
		.accessibilityElement(children: .combine)
		.accessibilityLabel(Text(row.localizedName))
		.accessibilityValue(Text(isRecording ? "Recording. Press a shortcut." : (chord?.glyphs ?? "Unassigned")))
	}

	/// The current-chord chip. Renders "Press keys…" while recording, an
	/// `Unassigned` placeholder if somehow unset, and a danger-bordered cap when
	/// the last capture conflicted.
	@ViewBuilder
	private func chordChip(chord: KeyChord?, isRecording: Bool, hasWarning: Bool) -> some View {
		if isRecording {
			Text("Press keys…")
				.font(Theme.font(12, weight: .semibold))
				.foregroundStyle(Theme.accent)
				.padding(.horizontal, 10)
				.padding(.vertical, 4)
				.background(
					RoundedRectangle(cornerRadius: 6, style: .continuous)
						.fill(Theme.accent.opacity(0.12))
						.overlay(
							RoundedRectangle(cornerRadius: 6, style: .continuous)
								.strokeBorder(Theme.accent, lineWidth: 1)
						)
				)
				.frame(minWidth: 88)
		} else {
			Text(chord?.glyphs ?? "—")
				.font(.system(size: 13, weight: .medium, design: .rounded))
				.monospacedDigit()
				.foregroundStyle(chord == nil ? Theme.ink3 : Theme.ink)
				.padding(.horizontal, 10)
				.padding(.vertical, 4)
				.background(
					RoundedRectangle(cornerRadius: 6, style: .continuous)
						.fill(Theme.surface2)
						.overlay(
							RoundedRectangle(cornerRadius: 6, style: .continuous)
								.strokeBorder(hasWarning ? Theme.danger : Theme.borderStrong, lineWidth: 1)
						)
				)
				.frame(minWidth: 88)
				.accessibilityHidden(true)
		}
	}

	private func recordButton(for row: AppShortcuts.Shortcut, isRecording: Bool) -> some View {
		Button {
			if isRecording {
				recordingId = nil
			} else {
				conflictWarning = nil
				recordingId = row.id
			}
		} label: {
			Text(isRecording ? "Cancel" : "Record")
				.font(Theme.font(12, weight: .semibold))
				.frame(minWidth: 56)
		}
		.buttonStyle(.bordered)
		.tint(isRecording ? Theme.danger : Theme.accent)
		.accessibilityLabel(isRecording
			? Text("Cancel recording shortcut for \(row.localizedName)")
			: Text("Record shortcut for \(row.localizedName)"))
	}

	@ViewBuilder
	private func resetButton(for row: AppShortcuts.Shortcut, customized: Bool) -> some View {
		Button {
			model.resetShortcut(for: row.id)
			if conflictWarning?.actionId == row.id { conflictWarning = nil }
			if recordingId == row.id { recordingId = nil }
		} label: {
			Image(systemName: "arrow.uturn.backward")
				.font(.system(size: 12, weight: .semibold))
		}
		.buttonStyle(.borderless)
		.foregroundStyle(customized ? Theme.ink2 : Theme.ink3.opacity(0.4))
		.disabled(!customized)
		.help("Reset to default")
		.accessibilityLabel(Text("Reset \(row.localizedName) to default"))
	}

	// MARK: - Capture handling

	/// Apply a captured key-down to the recording row. `Esc` cancels; a valid
	/// chord either commits (and exits capture) or is refused with an inline
	/// conflict warning that keeps the row in capture mode for a retry.
	private func handleCapture(_ event: NSEvent) {
		guard let id = recordingId else { return }

		// Escape cancels capture without changing the binding.
		if event.keyCode == 53 {
			recordingId = nil
			return
		}

		guard let chord = KeyChord.from(event: event) else {
			// A bare/unsupported key — keep waiting for a real chord.
			return
		}

		let conflicts = model.setShortcut(chord, for: id)
		if conflicts.isEmpty {
			recordingId = nil
			conflictWarning = nil
		} else {
			conflictWarning = ConflictWarning(
				actionId: id,
				chord: chord,
				conflictingIds: conflicts
			)
		}
	}

	/// A refused capture: the chord clashed with one or more other actions.
	private struct ConflictWarning: Equatable {
		let actionId: String
		let chord: KeyChord
		let conflictingIds: [String]

		/// Human-facing message naming the chord and the first action it
		/// collides with (most clashes are 1:1).
		var message: String {
			let names = conflictingIds
				.compactMap { id in AppShortcuts.all.first { $0.id == id }?.localizedName }
			let other = names.first ?? "another action"
			return "\(chord.glyphs) is already used by \(other). Pick a different shortcut."
		}
	}
}

/// An invisible NSView that installs a window-local key-down monitor while
/// `isRecording` is true and tears it down otherwise.
///
/// A `local` monitor (vs. `addLocalMonitorForEvents` global) sees key-downs
/// routed to *this* app's key window and can swallow them (returning `nil`) so
/// the captured chord doesn't also trigger whatever it's normally bound to. The
/// monitor's lifetime is tied to the recording flag, so outside capture the
/// Preferences window behaves completely normally.
private struct ShortcutCaptureMonitor: NSViewRepresentable {
	let isRecording: Bool
	let onKeyDown: (NSEvent) -> Void

	func makeNSView(context: Context) -> NSView {
		let view = NSView(frame: .zero)
		return view
	}

	func updateNSView(_ nsView: NSView, context: Context) {
		context.coordinator.onKeyDown = onKeyDown
		context.coordinator.setRecording(isRecording)
	}

	func makeCoordinator() -> Coordinator { Coordinator() }

	static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
		coordinator.setRecording(false)
	}

	final class Coordinator {
		var onKeyDown: (NSEvent) -> Void = { _ in }
		private var monitor: Any?

		func setRecording(_ recording: Bool) {
			if recording {
				guard monitor == nil else { return }
				monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
					self?.onKeyDown(event)
					// Swallow the event so the captured chord doesn't also fire
					// its (or some other) action while recording.
					return nil
				}
			} else {
				if let monitor {
					NSEvent.removeMonitor(monitor)
					self.monitor = nil
				}
			}
		}

		deinit { setRecording(false) }
	}
}
