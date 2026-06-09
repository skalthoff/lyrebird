import SwiftUI

/// "Customize Home" modal (#56) — add/remove (show/hide) and reorder the Home
/// shelves, Marvis-style.
///
/// The layout is persisted client-side as two `@AppStorage` CSV strings (the
/// chosen order + the hidden set), and `HomeView` renders its stack by sorting
/// the `HomeSection` catalog through `HomeSectionLayout`. This sheet is the
/// editor over those two strings: a drag-reorderable list with a per-row
/// show/hide toggle, plus a "Reset to defaults" affordance.
///
/// Presentation mirrors `InstantMixSheet` — a fixed-size `VStack` mounted via
/// `.sheet` on `HomeView`, driven by a parent `isPresented` binding. All the
/// ordering / visibility math lives in `HomeSectionLayout` (unit-tested), so
/// this view is a thin editor shell around the two stored strings.
struct CustomizeHomeSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// The same two keys `HomeView` reads, so an edit here repaints Home live.
    @AppStorage(HomeLayoutDefaults.sectionOrderKey) private var orderRaw = ""
    @AppStorage(HomeLayoutDefaults.sectionHiddenKey) private var hiddenRaw = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Theme.border)
            sectionList
            footer
        }
        .frame(width: 460, height: 560)
        .background(Theme.bg)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Customize Home")
                    .font(Theme.font(16, weight: .bold))
                    .foregroundStyle(Theme.ink)
                Text("Drag to reorder. Toggle a section to show or hide it.")
                    .font(Theme.font(11, weight: .medium))
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink2)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Theme.surface))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    // MARK: - Section list

    /// The reconciled, ordered catalog the editor shows. Reconciling against
    /// the live catalog on every render means a shelf added in a future build
    /// shows up here automatically (appended at the bottom).
    private var orderedSections: [HomeSection] {
        HomeSectionLayout.order(stored: orderRaw)
    }

    private var hiddenSet: Set<HomeSection> {
        HomeSectionLayout.hidden(stored: hiddenRaw)
    }

    private var sectionList: some View {
        // A `List` (rather than ScrollView+VStack) unlocks SwiftUI's native
        // `.onMove` drag-reorder — the same pattern the sidebar's playlist
        // reorder uses (#317). Styled down to match the sheet chrome.
        List {
            ForEach(orderedSections) { section in
                row(for: section)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
            }
            .onMove(perform: move)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    /// One section row: glyph + title, a "Hidden" caption when off, and a
    /// trailing toggle that flips the section's visibility. The whole catalog
    /// is reorderable (including hidden rows) so a user can park a shelf at the
    /// bottom whether or not it's currently shown.
    private func row(for section: HomeSection) -> some View {
        let isHidden = hiddenSet.contains(section)
        return HStack(spacing: 12) {
            Image(systemName: section.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isHidden ? Theme.ink3 : Theme.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(section.title)
                    .font(Theme.font(13, weight: .semibold))
                    .foregroundStyle(isHidden ? Theme.ink3 : Theme.ink)
                    .lineLimit(1)
                if isHidden {
                    Text("Hidden")
                        .font(Theme.font(10, weight: .medium))
                        .foregroundStyle(Theme.ink3)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: visibilityBinding(for: section))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .controlSize(.small)
                .accessibilityLabel(section.title)
                .accessibilityValue(isHidden ? "Hidden" : "Shown")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.surface.opacity(0.6))
        )
        .contentShape(Rectangle())
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button(role: .destructive, action: resetToDefaults) {
                Text("Reset to Defaults")
                    .font(Theme.font(12, weight: .semibold))
                    .foregroundStyle(canReset ? Theme.accentHot : Theme.ink3)
            }
            .buttonStyle(.plain)
            .disabled(!canReset)
            .help("Restore the original section order and show every section")
            .accessibilityLabel("Reset Home sections to defaults")

            Spacer()

            Button(action: { dismiss() }) {
                Text("Done")
                    .font(Theme.font(13, weight: .semibold))
                    .frame(width: 96, height: 32)
                    .foregroundStyle(Theme.bg)
                    .background(Theme.ink)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel("Done")
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 18)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    /// Reset is only meaningful when the layout actually diverges from the
    /// shipped default — both stores empty means "defaults" already.
    private var canReset: Bool {
        !orderRaw.isEmpty || !hiddenRaw.isEmpty
    }

    // MARK: - Mutations

    /// Per-section visibility binding. Reading folds the hidden set; writing
    /// toggles it and re-encodes in stable catalog order. `isOn == true` means
    /// "shown", so the stored hidden flag is the inverse.
    private func visibilityBinding(for section: HomeSection) -> Binding<Bool> {
        Binding(
            get: { !hiddenSet.contains(section) },
            set: { shown in
                var hidden = hiddenSet
                if shown {
                    hidden.remove(section)
                } else {
                    hidden.insert(section)
                }
                hiddenRaw = HomeSectionLayout.encodeHidden(hidden)
            }
        )
    }

    /// Fold a `.onMove` into the persisted order. `orderedSections` is the
    /// already-reconciled list the user sees, so the offsets line up; we
    /// re-encode the whole arrangement. Pure list math — see `HomeSectionLayout`.
    private func move(from source: IndexSet, to destination: Int) {
        let next = HomeSectionLayout.applyingMove(
            displayed: orderedSections,
            source: source,
            destination: destination
        )
        orderRaw = HomeSectionLayout.encode(next)
    }

    /// Clear both stores so order falls back to the catalog's declaration order
    /// and every section is shown — the documented "reset to defaults".
    private func resetToDefaults() {
        orderRaw = ""
        hiddenRaw = ""
    }
}
