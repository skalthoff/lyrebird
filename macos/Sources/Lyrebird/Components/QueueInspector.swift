import AppKit
import SwiftUI
import UniformTypeIdentifiers
@preconcurrency import LyrebirdCore

/// Right-side "Queue Inspector" panel (320pt) that surfaces the currently-
/// playing track, the user-added "Up Next" list, and the auto-queue tail.
///
/// Implements issues #79 (the panel itself), #80 (drag-to-reorder + remove),
/// #282 (Up Next vs Auto Queue separation), #283 (drop-indicator on drag
/// reorder), and #284 (Clear / Save / Shuffle queue actions).
///
/// Layout (top → bottom):
///   1. **Action row** — Clear / Save / Shuffle for the whole queue (#284).
///   2. **Now Playing card** — large thumbnail, title/artist/album, and a
///      read-only scrubber driven by `AppModel.status.positionSeconds`.
///   3. **UP NEXT** — user-added queue; drag-reorder with a 2pt accent
///      drop-indicator between rows (#283), per-row X button on hover,
///      keyboard reorder via Opt+↑/Opt+↓.
///   4. **PLAYING FROM {source}** — auto-queue tail; double-click jumps
///      to that track.
///
/// The panel is mounted by `MainShell` via `appModel.isQueueInspectorOpen`
/// and toggled with Cmd+Opt+Q.
struct QueueInspector: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focusedQueueId: UUID?

    /// Local presentation state for the three queue actions (#284). These
    /// live on the view rather than `AppModel` because the sheet / dialog
    /// are scoped to the inspector and don't need to survive a panel
    /// collapse. Keeping them here also means no stale flags if the user
    /// closes the inspector mid-action — SwiftUI reclaims the struct.
    @State private var showClearConfirm = false
    @State private var showSaveSheet = false
    @State private var saveDraftName = ""

    /// Drag-reorder state for the drop-indicator line (#283). `draggingId`
    /// is the queueId of the row currently being dragged; `dropTargetIndex`
    /// is the insertion slot where it would land on release (0 ≤ i ≤
    /// upNextUserAdded.count). The indicator renders between rows at that
    /// index.
    @State private var draggingId: UUID?
    @State private var dropTargetIndex: Int?

    /// Local `NSEvent` monitor tokens that watch for `.leftMouseUp` and
    /// `.keyDown` (Escape) while a drag is in flight. SwiftUI's `onDrag`
    /// modifier has no cancel callback, so a drag aborted by Escape or
    /// released outside any drop target never reaches
    /// `QueueRowDropDelegate.performDrop` and the row stays dimmed with the
    /// drop indicator stuck on screen. Installed in
    /// `.onChange(of: draggingId)` when a drag starts and removed when the
    /// drag ends (success or cancel), and on `.onDisappear` for safety.
    @State private var dragCancelMonitor: Any?
    @State private var dragEscapeMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    actionRow
                    nowPlayingCard
                    lyricsSnippet
                    upNextSection
                    playingFromSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
        }
        .frame(maxHeight: .infinity)
        .background(Theme.bgAlt)
        // Clear-queue confirmation dialog (#284). Count interpolated into
        // the title so a user with a long queue sees at a glance what's
        // about to disappear — the generic "Clear queue?" hid that.
        .confirmationDialog(
            "Clear \(CountStrings.label(totalQueueCount, .items))?",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) { model.clearQueue() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes everything in Up Next and the rest of the current source. The currently-playing track keeps playing.")
        }
        // Save-queue sheet (#284). Kept local to the inspector — the only
        // caller for `saveQueueAsPlaylist(name:)` lives here.
        .sheet(isPresented: $showSaveSheet, onDismiss: { saveDraftName = "" }) {
            SaveQueueSheet(
                name: $saveDraftName,
                onCancel: { showSaveSheet = false },
                onSave: {
                    let trimmed = saveDraftName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    showSaveSheet = false
                    Task { await model.saveQueueAsPlaylist(name: trimmed) }
                }
            )
            .environment(model)
        }
        // Drag-cancel safety net. `onDrag` has no completion callback, so a
        // drag aborted via Escape or released outside any drop target would
        // otherwise leave `draggingId` and `dropTargetIndex` set indefinitely.
        // While a drag is in flight we install two local monitors:
        //   * `.leftMouseUp` — fires on release whether or not the cursor
        //     was over a valid drop target. Local monitors run before the
        //     responder chain dispatches to `performDrop`, so the cleanup
        //     is deferred onto the next main-queue tick so a successful
        //     drop's commit observes the still-set `draggingId` /
        //     `dropTargetIndex` before they're cleared.
        //   * `.keyDown` filtered on keyCode 53 (Escape) — the NSDragging
        //     session's escape sequence does not surface as a `mouseUp`,
        //     so the leftMouseUp monitor alone misses it.
        // The successful-drop path in `QueueRowDropDelegate.performDrop`
        // clears `draggingId` itself, which re-enters this closure with
        // `newValue == nil` and tears both monitors down.
        .onChange(of: draggingId) { _, newValue in
            if newValue != nil {
                installDragCancelMonitors()
            } else {
                removeDragCancelMonitors()
            }
        }
        .onDisappear {
            removeDragCancelMonitors()
        }
    }

    /// Install the local `NSEvent` monitors that clear stuck drag state on
    /// cancel. Idempotent: a second call while monitors are already active
    /// is a no-op so re-entrant SwiftUI updates can't leak tokens.
    private func installDragCancelMonitors() {
        if dragCancelMonitor == nil {
            dragCancelMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
                DispatchQueue.main.async {
                    draggingId = nil
                    dropTargetIndex = nil
                }
                return event
            }
        }
        if dragEscapeMonitor == nil {
            dragEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 {
                    DispatchQueue.main.async {
                        draggingId = nil
                        dropTargetIndex = nil
                    }
                }
                return event
            }
        }
    }

    /// Tear down the drag-cancel monitors if installed. Called when the drag
    /// ends (success or cancel) and on `.onDisappear` so the monitors never
    /// outlive the view.
    private func removeDragCancelMonitors() {
        if let token = dragCancelMonitor {
            NSEvent.removeMonitor(token)
            dragCancelMonitor = nil
        }
        if let token = dragEscapeMonitor {
            NSEvent.removeMonitor(token)
            dragEscapeMonitor = nil
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Queue")
                    .font(Theme.font(11, weight: .bold))
                    .foregroundStyle(Theme.ink2)
                    .tracking(2)
                    .textCase(.uppercase)
                Spacer()
                // Note: the Cmd+Opt+Q toggle lives on `MainShell` so it works
                // whether the panel is open or closed. The X here is click-only
                // so we don't register two responders for the same shortcut.
                Button(action: { model.isQueueInspectorOpen = false }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.ink2)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Theme.surface))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close queue")
            }
            autoplayToggle
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    /// "Autoplay similar music when queue ends" toggle. When on
    /// (default), playback extends with an Instant Mix once Up Next and the
    /// source tail run dry; when off, playback stops at the end of what the
    /// user queued. Persists across launches via
    /// `AppModel.setAutoplayWhenQueueEnds(_:)`.
    @ViewBuilder
    private var autoplayToggle: some View {
        Toggle(isOn: autoplayBinding) {
            HStack(spacing: 6) {
                Image(systemName: "infinity")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.ink2)
                    .accessibilityHidden(true)
                Text("Autoplay similar music when queue ends")
                    .font(Theme.font(11, weight: .medium))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(Theme.accent)
        .accessibilityLabel("Autoplay similar music when queue ends")
        .accessibilityHint("When off, playback stops at the end of the queue instead of continuing with similar music")
    }

    /// Bridges the `@Observable` model's persisted flag to a SwiftUI
    /// `Binding` so the `Toggle` writes through `setAutoplayWhenQueueEnds`
    /// (which both updates state and persists to UserDefaults). The model
    /// isn't `@Bindable` here, so we route the setter explicitly rather than
    /// `$model.autoplayWhenQueueEnds`, which would bypass persistence.
    private var autoplayBinding: Binding<Bool> {
        Binding(
            get: { model.autoplayWhenQueueEnds },
            set: { model.setAutoplayWhenQueueEnds($0) }
        )
    }

    // MARK: - Action row (BATCH-07b, #284)

    /// Clear / Save / Shuffle buttons. All three disable when there's
    /// nothing to act on — an empty queue can't be cleared, saved, or
    /// shuffled — so the row reads as a stable affordance rather than
    /// three buttons of flickering state.
    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: 8) {
            queueActionButton(
                title: "Clear",
                systemImage: "trash",
                accessibilityHint: "Clears the queue"
            ) {
                showClearConfirm = true
            }
            .disabled(totalQueueCount == 0)

            queueActionButton(
                title: "Save",
                systemImage: "square.and.arrow.down",
                accessibilityHint: "Saves the queue as a playlist"
            ) {
                saveDraftName = defaultPlaylistName()
                showSaveSheet = true
            }
            .disabled(totalQueueCount == 0)

            queueActionButton(
                title: "Shuffle",
                systemImage: "shuffle",
                accessibilityHint: "Shuffles Up Next"
            ) {
                model.shuffleUpNext()
            }
            .disabled(model.upNextUserAdded.count < 2)
        }
    }

    /// Compact pill-style action button shared by the three queue actions.
    /// Matches the Home / Library CTAs so the inspector reads as a first-
    /// class surface rather than a grab-bag of system buttons.
    @ViewBuilder
    private func queueActionButton(
        title: String,
        systemImage: String,
        accessibilityHint: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(Theme.font(11, weight: .semibold))
            }
            .foregroundStyle(Theme.ink2)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6).fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Theme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(accessibilityHint)
    }

    /// Total rows the three queue actions operate on. Used to disable the
    /// action row when the queue is empty. Does not count the
    /// currently-playing track since the actions leave it alone; the Save
    /// action includes it, but Save is also disabled only when *everything*
    /// is empty (covered by this same check).
    private var totalQueueCount: Int {
        model.upNextUserAdded.count + model.upNextAutoQueue.count
    }

    /// Default playlist name for the Save sheet. Prefers the current
    /// source label ("My Playlist + Up Next") and falls back to a
    /// dated placeholder so the user always lands on something typeable.
    private func defaultPlaylistName() -> String {
        if let name = model.currentContext?.name, !name.isEmpty {
            return "\(name) + Up Next"
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Queue \(formatter.string(from: Date()))"
    }

    // MARK: - Now Playing card

    @ViewBuilder
    private var nowPlayingCard: some View {
        if let track = model.status.currentTrack {
            VStack(alignment: .leading, spacing: 12) {
                Artwork(
                    url: model.imageURL(
                        for: track.albumId ?? track.id,
                        tag: track.imageTag,
                        maxWidth: 480
                    ),
                    seed: track.name,
                    size: 288,
                    radius: 10
                )
                .frame(width: 288, height: 288)
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.name)
                        .font(Theme.font(17, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                    Text(track.artistName)
                        .font(Theme.font(12, weight: .medium))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                    if let album = track.albumName, !album.isEmpty {
                        Text(album)
                            .font(Theme.font(11, weight: .medium))
                            .foregroundStyle(Theme.ink3)
                            .lineLimit(1)
                    }
                }
                scrubber
            }
        } else {
            EmptyQueueState()
                .frame(height: 320)
        }
    }

    /// Read-only scrubber. The real seek control lives in the PlayerBar;
    /// here we mirror playback progress so the inspector reads as a live
    /// widget rather than a static list. Driven by
    /// `AppModel.status.positionSeconds` / `durationSeconds`, which are
    /// pushed from the polling loop (#48).
    @ViewBuilder
    private var scrubber: some View {
        VStack(spacing: 4) {
            GeometryReader { geom in
                let total = max(1.0, model.status.durationSeconds)
                let pct = min(1.0, max(0.0, model.status.positionSeconds / total))
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surface2)
                    Capsule().fill(Theme.ink2).frame(width: geom.size.width * CGFloat(pct))
                }
                .frame(height: 3)
            }
            .frame(height: 3)
            HStack {
                Text(format(model.status.positionSeconds))
                    .font(Theme.font(10, weight: .semibold))
                    .foregroundStyle(Theme.ink3)
                    .monospacedDigit()
                Spacer()
                Text(format(model.status.durationSeconds))
                    .font(Theme.font(10, weight: .semibold))
                    .foregroundStyle(Theme.ink3)
                    .monospacedDigit()
            }
            .accessibilityHidden(true)
        }
        // Speak the progress as one spelled-out element rather than two
        // ambiguous "three oh five" timecode labels. See #349.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue(scrubberAccessibilityValue)
    }

    // MARK: - Inline lyrics snippet (#91)

    /// Compact 3-line synced lyrics preview below the Now Playing card.
    /// `InlineLyricsSnippet` renders nothing when the current track has no
    /// timed lyrics, so the section gracefully omits itself — no spacer or
    /// empty box is left behind. Only mounted while a track is playing.
    @ViewBuilder
    private var lyricsSnippet: some View {
        if model.status.currentTrack != nil {
            InlineLyricsSnippet()
        }
    }

    // MARK: - Up Next (user-added)

    @ViewBuilder
    private var upNextSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Up Next")
            if model.upNextUserAdded.isEmpty {
                emptyRow("Nothing queued. Use \u{2318}-click \u{2192} Play Next on a track.")
            } else {
                // A `LazyVStack` + custom `onDrag` / `onDrop` drives the
                // reorder instead of `List.onMove` so we can render a
                // visible 2pt drop-indicator line between rows (#283).
                // `List` doesn't expose its native drop indicator for
                // styling, and the accent tint is a design requirement.
                upNextList
            }
        }
    }

    /// Manual drag-reorder surface. Reads the drop slot from
    /// `dropTargetIndex` and renders the accent line at that boundary.
    /// `List.onMove` semantics are preserved through
    /// `AppModel.moveUpNext(from:to:)` so the model continues to see the
    /// same `IndexSet → Int` contract it had before.
    ///
    /// Rendered as a `LazyVStack` directly in the inspector's outer
    /// `ScrollView` (#79). It used to nest its own `ScrollView` clamped to 8
    /// rows / 352pt, which trapped two-finger scroll inside the Up Next
    /// region for longer queues and hid items 9+ behind a competing inner
    /// scrollbar. Letting the page scroll keeps the whole list reachable, and
    /// `LazyVStack` still defers off-screen row construction.
    @ViewBuilder
    private var upNextList: some View {
        LazyVStack(spacing: 0) {
            dropIndicator(at: 0)
            ForEach(Array(model.upNextUserAdded.enumerated()), id: \.element.id) { index, entry in
                QueueInspectorRow(
                    entry: entry,
                    removable: true,
                    onRemove: { model.removeFromUpNext(id: entry.id) },
                    onMoveUp: { moveEntry(entry, by: -1) },
                    onMoveDown: { moveEntry(entry, by: 1) }
                )
                .focused($focusedQueueId, equals: entry.id)
                .opacity(draggingId == entry.id ? 0.4 : 1.0)
                .onDrag {
                    draggingId = entry.id
                    return NSItemProvider(object: entry.id.uuidString as NSString)
                }
                .onDrop(
                    of: [.text],
                    delegate: QueueRowDropDelegate(
                        targetIndex: index,
                        draggingId: $draggingId,
                        dropTargetIndex: $dropTargetIndex,
                        model: model
                    )
                )

                dropIndicator(at: index + 1)
            }
        }
    }

    /// 2pt accent-tinted line rendered between rows while a drag is in
    /// flight (#283). Shows only at the slot that matches
    /// `dropTargetIndex`, so the user can see exactly where the release
    /// will land. Fades in/out with the drag so the list doesn't flash a
    /// stray bar when nothing is being dragged.
    @ViewBuilder
    private func dropIndicator(at index: Int) -> some View {
        let active = draggingId != nil && dropTargetIndex == index
        Rectangle()
            .fill(Theme.accent)
            .frame(height: active ? 2 : 0)
            .padding(.horizontal, 4)
            .opacity(active ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: active)
            .accessibilityHidden(true)
    }

    // MARK: - Playing From (auto queue)

    @ViewBuilder
    private var playingFromSection: some View {
        if !model.upNextAutoQueue.isEmpty || model.currentContext != nil {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader(playingFromHeaderTitle)
                if model.upNextAutoQueue.isEmpty {
                    emptyRow("Nothing else queued from this source.")
                } else {
                    // `LazyVStack` (not a plain `VStack`) so a large source
                    // context — a full album/playlist tail — doesn't
                    // instantiate every row up front; off-screen rows
                    // materialize as the outer page scrolls. No drag-reorder
                    // here: the auto tail is the source's natural order.
                    LazyVStack(spacing: 0) {
                        ForEach(model.upNextAutoQueue) { entry in
                            QueueInspectorRow(
                                entry: entry,
                                removable: false,
                                onRemove: {},
                                onMoveUp: {},
                                onMoveDown: {}
                            )
                            .onTapGesture(count: 2) { jumpTo(entry: entry) }
                        }
                    }
                }
            }
        }
    }

    /// Section title for the "Playing From" block. Prefers the live
    /// context label when present and falls back to a generic string so
    /// the block still reads clearly on ad-hoc selections.
    private var playingFromHeaderTitle: String {
        if let name = model.currentContext?.name, !name.isEmpty {
            return "Playing From \(name)"
        }
        return "Playing From Queue"
    }

    // MARK: - Actions

    /// Shift `entry` within the user-added list by `delta` rows (clamped).
    /// Wired to Opt+↑ / Opt+↓ on a focused row so reorder is usable from
    /// the keyboard as well as the mouse. See #80.
    private func moveEntry(_ entry: Queue, by delta: Int) {
        guard let idx = model.upNextUserAdded.firstIndex(where: { $0.id == entry.id }) else { return }
        let target = idx + delta
        guard target >= 0, target < model.upNextUserAdded.count else { return }
        // `List.onMove`'s `toOffset` semantics are "insert before this
        // index after the item has been removed", so we bias the offset
        // when moving down to land in the expected slot.
        let offset = delta > 0 ? target + 1 : target
        model.moveUpNext(from: IndexSet(integer: idx), to: offset)
    }

    /// Jump playback to an auto-queue entry. Routes through
    /// `AppModel.jumpToQueueEntry(_:)`, which rebuilds the flat track list
    /// (current → user-added → auto tail), locates this entry, and replays
    /// from its index so the engine actually repositions and auto-advances
    /// from there. See #282.
    private func jumpTo(entry: Queue) {
        model.jumpToQueueEntry(entry)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(Theme.font(10, weight: .bold))
            .foregroundStyle(Theme.ink2)
            .tracking(1.5)
            .textCase(.uppercase)
    }

    @ViewBuilder
    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(Theme.font(11, weight: .medium))
            .foregroundStyle(Theme.ink3)
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func format(_ seconds: Double) -> String {
        DurationFormatter.colon(seconds)
    }

    /// Spelled-out position/duration for VoiceOver — "1 minute 23 seconds of
    /// 4 minutes 10 seconds". Mirrors the PlayerBar scrubber's spoken value so
    /// the read-only inspector progress reads the same way. See #349.
    private var scrubberAccessibilityValue: String {
        let pos = DurationFormatter.spokenAccessibility(model.status.positionSeconds)
        let total = DurationFormatter.spokenAccessibility(model.status.durationSeconds)
        return "\(pos) of \(total)"
    }
}

// MARK: - Row

/// One track row in the Queue Inspector. Shared between the user-added
/// "Up Next" list and the auto-queue tail — the only behavioural knob is
/// `removable`, which toggles the trailing X button on hover. Keyboard
/// reorder (Opt+↑/↓) is plumbed through `onMoveUp` / `onMoveDown`; the
/// callbacks are no-ops for rows that aren't reorderable.
private struct QueueInspectorRow: View {
    @Environment(AppModel.self) private var model
    let entry: Queue
    let removable: Bool
    let onRemove: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Artwork(
                url: model.imageURL(
                    for: entry.track.albumId ?? entry.track.id,
                    tag: entry.track.imageTag,
                    maxWidth: 120
                ),
                seed: entry.track.albumName ?? entry.track.name,
                size: 32,
                radius: 4
            )
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.track.name)
                    .font(Theme.font(12, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text(entry.track.artistName)
                    .font(Theme.font(10, weight: .medium))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)

            if removable, isHovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.ink2)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Theme.surface))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(entry.track.name) from Up Next")
                .transition(.opacity)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? Theme.rowHover : .clear)
        )
        .contentShape(Rectangle())
        // `.focusable` on reorderable rows so the rotor can Tab through Up
        // Next; auto-queue rows are read-only and remain non-focusable.
        // `.combine` collapses artwork + text + remove button into one element
        // so VoiceOver reads "Track by Artist" as a single queue entry.
        // See #588.
        .focusable(removable)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.track.name) by \(entry.track.artistName)")
        // Expose Remove as a VoiceOver / Full Keyboard Access rotor action so
        // it's reachable without hovering — the visible X button is gated on
        // mouse hover, which keyboard and assistive-tech users can't trigger
        // (#588). The `.isButton` trait is deliberately *not* added: the row
        // has no single primary activation (its actions are reorder via
        // Opt+↑/↓ and this Remove action), so advertising a button trait
        // would promise a tap-to-activate that doesn't exist.
        .accessibilityActions {
            if removable {
                Button("Remove") { onRemove() }
            }
        }
        // Opt+↑ / Opt+↓ reorders the focused row. Only match when the
        // Option modifier is held so plain arrow keys fall through to
        // the surrounding list's focus traversal.
        .onKeyPress(phases: .down) { press in
            guard press.modifiers.contains(.option) else { return .ignored }
            switch press.key {
            case .upArrow:
                onMoveUp()
                return .handled
            case .downArrow:
                onMoveDown()
                return .handled
            default:
                return .ignored
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
    }
}

// MARK: - Drop delegate (BATCH-07b, #283)

/// Drop handler for one row in the Up Next list. Updates
/// `dropTargetIndex` as the mouse hovers a row boundary, and commits the
/// reorder through `AppModel.moveUpNext(from:to:)` on release.
///
/// `targetIndex` is the row's own index in the current list. The insertion
/// slot is biased by "top-half vs bottom-half" of the row so the indicator
/// snaps to the nearer edge — that matches how Finder / other AppKit
/// reorderable lists behave on macOS.
private struct QueueRowDropDelegate: DropDelegate {
    let targetIndex: Int
    @Binding var draggingId: UUID?
    @Binding var dropTargetIndex: Int?
    let model: AppModel

    func dropEntered(info: DropInfo) {
        guard draggingId != nil else { return }
        // Snap the indicator to the top edge of this row while the cursor
        // is over it. Dropping with the cursor at the bottom half snaps to
        // the row below on move — handled in `dropUpdated`.
        dropTargetIndex = targetIndex
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard draggingId != nil else { return nil }
        // A midpoint check biases the indicator toward the nearer row
        // boundary. `info.location.y` is in the row's coordinate space on
        // macOS 14+, so we compare against a fixed half-height constant
        // (~22pt for our 44pt row).
        let midline: CGFloat = 22
        let above = info.location.y < midline
        dropTargetIndex = above ? targetIndex : targetIndex + 1
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        // Intentionally left blank — the cursor crossing a row boundary
        // will call `dropEntered` on the next row before we'd clear state
        // here, and clearing on exit causes the indicator to flicker
        // between rows. The final clear happens in `performDrop` or on
        // drag cancel (handled by the view clearing `draggingId` on the
        // `onDrag` closure completion path).
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let sourceId = draggingId,
              let sourceIndex = model.upNextUserAdded.firstIndex(where: { $0.id == sourceId }),
              let insertAt = dropTargetIndex
        else {
            draggingId = nil
            dropTargetIndex = nil
            return false
        }
        defer {
            draggingId = nil
            dropTargetIndex = nil
        }
        // Short-circuit when the user dropped the row right back where it
        // started — otherwise `List.move(fromOffsets:toOffset:)` would
        // still fire and SwiftUI diff a pointless reorder.
        if insertAt == sourceIndex || insertAt == sourceIndex + 1 { return false }
        model.moveUpNext(from: IndexSet(integer: sourceIndex), to: insertAt)
        return true
    }
}

// MARK: - Save sheet (BATCH-07b, #284)

/// Minimal sheet with a name field and Cancel / Save buttons. Kept
/// private to the inspector since it's the only caller — promoting it to
/// a shared component would be premature until a second surface wants the
/// same interaction.
private struct SaveQueueSheet: View {
    @Environment(AppModel.self) private var model
    @Binding var name: String
    let onCancel: () -> Void
    let onSave: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Save queue as playlist")
                    .font(Theme.font(15, weight: .bold))
                    .foregroundStyle(Theme.ink)
                Text("Creates a new playlist with \(CountStrings.label(totalCount, .tracks)).")
                    .font(Theme.font(11, weight: .medium))
                    .foregroundStyle(Theme.ink3)
            }

            TextField("Playlist name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(Theme.font(12, weight: .medium))
                .focused($focused)
                .onSubmit { onSave() }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            // Auto-focus the field so the user can type straight away;
            // auto-select the default so overwriting doesn't need a
            // manual Cmd-A first.
            focused = true
        }
    }

    private var totalCount: Int {
        let currentCount = model.status.currentTrack == nil ? 0 : 1
        return currentCount + model.upNextUserAdded.count + model.upNextAutoQueue.count
    }
}
