import AppKit
import SwiftUI
@preconcurrency import LyrebirdCore

/// Detached, borderless **Mini Player** — a compact always-available transport
/// surface modeled on Apple Music's `MiniPlayer`, Spotify's now-playing widget,
/// and Silicio's progressive-disclosure card.
///
/// The view ships its own chrome rather than relying on a system title bar:
/// the host `NSWindow` is reconfigured (borderless, vibrancy, rounded corners,
/// draggable-by-background, optional always-on-top) through
/// `MiniPlayerWindowConfigurator`, an invisible `NSViewRepresentable` mounted
/// at the root. SwiftUI's `Scene` / `WindowGroup` can't express any of those
/// `NSWindow` knobs, so we bridge through AppKit exactly once, here.
///
/// ## Progressive disclosure
///
/// At rest the surface is a minimal card: artwork, title/artist, and a thin
/// non-interactive progress line. On pointer hover a controls **overlay**
/// fades in showing the full transport (prev / play-pause / next), volume,
/// scrub bar, a favorite heart, and an expand-to-full-window button — mirroring
/// Silicio's pattern. The overlay auto-hides after a 2-second pointer-idle
/// timeout even while the cursor still rests inside the window (any pointer
/// movement re-arms it), and hides immediately when the pointer leaves. The
/// crossfade is suppressed when **Reduce Motion** is enabled.
///
/// All playback state + actions route through the same `AppModel` entry points
/// the `PlayerBar` uses (`togglePlayPause`, `skipNext`, `skipPrevious`,
/// `setVolume`, `seek(toSeconds:)`, `toggleFavorite(track:)`, `status.*`), so
/// the mini player and the full transport bar can never disagree — there is one
/// writer.
struct MiniPlayerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Contrast-adaptive accent for the favorite heart. Lifts to `accentHot`
    // under Increase Contrast so the accent-tinted glyph clears 4.5:1 (#888).
    @Environment(\.accessibleTheme) private var a11yTheme

    /// Whether the controls overlay is currently revealed. Driven by hover plus
    /// the 2-second idle timeout below — `true` while the pointer is moving over
    /// the window, flips back to `false` after `Self.idleTimeout` of stillness
    /// or immediately on pointer exit.
    @State private var showControls = false

    /// Tracks raw pointer presence so the idle-timeout task knows whether the
    /// pointer is still inside the window when it fires.
    @State private var isHovering = false

    /// Debounce task that hides the overlay after the idle timeout. Cancelled
    /// and rescheduled on every pointer move so a moving cursor keeps the
    /// overlay alive; allowed to fire when the cursor goes still.
    @State private var idleHideTask: Task<Void, Never>?

    /// Local scrubber position used only while the user is actively dragging,
    /// so the 1Hz status poll doesn't yank the thumb back mid-drag. Same
    /// freeze pattern as `PlayerBar.scrubPosition`.
    @State private var scrubPosition: Double = 0
    @State private var isScrubbing = false

    /// Seconds of pointer stillness before the controls overlay fades back out.
    /// Short enough that the card returns to its minimal resting state quickly
    /// once the user stops interacting, long enough that a brief pause while
    /// aiming for a control doesn't snatch the transport away mid-reach.
    private static let idleTimeout: Duration = .seconds(2)

    var body: some View {
        ZStack {
            // Vibrancy background fills the whole borderless window. The
            // brand wash on top keeps Lyrebird's palette dominant the same
            // way the PlayerBar layers `Theme.bgAlt` over `.hudWindow`.
            VisualEffectView(material: .hudWindow)
                .overlay(Theme.bgAlt.opacity(0.6))

            content
                .padding(12)
        }
        // Rounded corners on the SwiftUI surface; the host window's own
        // `cornerRadius` + transparent background (set in the configurator)
        // makes the rounding read through to the desktop behind it.
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
        .frame(minWidth: 280, idealWidth: 320, maxWidth: 480, minHeight: 120, idealHeight: 120)
        // `onContinuousHover` gives us pointer-move events so we can re-arm the
        // idle timer on movement (plain `onHover` only fires on enter/exit).
        .onContinuousHover { phase in
            switch phase {
            case .active:
                if !isHovering { isHovering = true }
                reveal()
            case .ended:
                isHovering = false
                idleHideTask?.cancel()
                idleHideTask = nil
                setControls(false)
            }
        }
        .onDisappear {
            idleHideTask?.cancel()
            idleHideTask = nil
        }
        // Configure the host NSWindow exactly once. Mounted as a background
        // so it adds no visual element of its own.
        .background(MiniPlayerWindowConfigurator(alwaysOnTop: model.miniPlayerAlwaysOnTop))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("mini_player.accessibility.label"))
    }

    @ViewBuilder
    private var content: some View {
        if let track = model.status.currentTrack {
            HStack(spacing: 12) {
                artwork(for: track)
                VStack(alignment: .leading, spacing: 4) {
                    header(track: track)
                    Spacer(minLength: 0)
                    // Resting state: a thin, non-interactive progress line so
                    // the minimal card still communicates playback position.
                    // It crossfades out as the interactive controls fade in.
                    if !showControls {
                        restingProgress
                            .transition(.opacity)
                    }
                    // Hover overlay: the full controls cluster.
                    if showControls {
                        controlsOverlay(track: track)
                            .transition(.opacity)
                    }
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: showControls)
        } else {
            idle
        }
    }

    // MARK: - Reveal / idle-timeout plumbing

    /// Show the overlay and (re)arm the 2-second idle-hide timer. Called on
    /// every pointer-move while inside the window.
    private func reveal() {
        setControls(true)
        rearmIdleHide()
    }

    /// Cancel any pending idle-hide task and schedule a fresh one. Split out of
    /// `reveal()` so the scrub-release path can re-arm the timer without also
    /// re-showing controls that are already visible.
    private func rearmIdleHide() {
        idleHideTask?.cancel()
        idleHideTask = Task { @MainActor in
            try? await Task.sleep(for: Self.idleTimeout)
            guard !Task.isCancelled else { return }
            // Only auto-hide if the pointer is still inside but idle, and the
            // user isn't mid-scrub (hiding the scrubber out from under a drag
            // would be hostile).
            guard isHovering, !isScrubbing else { return }
            setControls(false)
        }
    }

    private func setControls(_ visible: Bool) {
        guard showControls != visible else { return }
        showControls = visible
    }

    // MARK: - Artwork (drag region)

    /// Square album art on the leading edge. The album-art region doubles as a
    /// drag target, so it hosts a `MiniPlayerDragHandle` overlay that performs
    /// `NSWindow.performDrag` — the rest of the window is also draggable via the
    /// configurator's `isMovableByWindowBackground`, but the artwork is the
    /// guaranteed-draggable target even where controls sit.
    @ViewBuilder
    private func artwork(for track: Track) -> some View {
        Artwork(
            url: model.imageURL(for: track.albumId ?? track.id, tag: track.imageTag, maxWidth: 192),
            seed: track.name,
            size: 96,
            radius: 8
        )
        .overlay(MiniPlayerDragHandle())
        .accessibilityLabel(Text("mini_player.accessibility.drag_artwork"))
    }

    // MARK: - Header (title + artist + settings menu)

    @ViewBuilder
    private func header(track: Track) -> some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(track.name)
                    .font(Theme.font(13, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(track.artistName)
                    .font(Theme.font(11, weight: .medium))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            // Favorite heart + settings menu only join the header while the
            // overlay is up so the resting card stays a clean two-line widget.
            if showControls {
                favoriteButton(track: track)
                    .transition(.opacity)
                settingsMenu
                    .transition(.opacity)
            }
        }
    }

    /// Heart toggle for the now-playing track. Reads the snapshot-aware
    /// `isFavorite(track:)` so it shows the correct state on first paint, and
    /// routes through `toggleFavorite(track:)` — the single favorite writer the
    /// rest of the app uses (optimistic cache update + server echo + rollback
    /// live inside `AppModel`).
    @ViewBuilder
    private func favoriteButton(track: Track) -> some View {
        let isFav = model.isFavorite(track: track)
        Button {
            model.toggleFavorite(track: track)
        } label: {
            Image(systemName: isFav ? "heart.fill" : "heart")
                .font(.system(size: 12))
                .foregroundStyle(isFav ? a11yTheme.accent : Theme.ink3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(isFav ? "mini_player.unfavorite" : "mini_player.favorite"))
        .accessibilityAddTraits(isFav ? [.isSelected] : [])
    }

    /// Gear menu with the always-on-top toggle and a return-to-full-window
    /// entry. Apple Music's MiniPlayer exposes "Always on Top" here; we mirror
    /// that and add the explicit return action so the contract is reachable
    /// even on a trackpad without hover.
    @ViewBuilder
    private var settingsMenu: some View {
        Menu {
            Toggle(isOn: Binding(
                get: { model.miniPlayerAlwaysOnTop },
                set: { model.setMiniPlayerAlwaysOnTop($0) }
            )) {
                Text("mini_player.menu.always_on_top")
            }
            Divider()
            Button {
                model.returnToFullWindow()
            } label: {
                Text("mini_player.menu.return_to_full")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink3)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text("mini_player.menu.label"))
    }

    // MARK: - Resting progress (minimal card)

    /// Thin, non-interactive position line shown when the overlay is hidden.
    /// `Theme.ink` fill over a faint track, capsule-shaped to read as a slim
    /// progress bar rather than a control.
    @ViewBuilder
    private var restingProgress: some View {
        GeometryReader { geo in
            let fraction = min(max(0, model.status.positionSeconds / sliderMax), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.ink.opacity(0.15))
                Capsule()
                    .fill(Theme.ink.opacity(0.7))
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 3)
        .padding(.bottom, 4)
        .accessibilityHidden(true)
    }

    // MARK: - Controls overlay (hover-revealed)

    @ViewBuilder
    private func controlsOverlay(track _: Track) -> some View {
        VStack(spacing: 4) {
            transportRow
            scrubber
        }
    }

    // MARK: - Transport row (prev / play-pause / next / volume / expand)

    @ViewBuilder
    private var transportRow: some View {
        HStack(spacing: 14) {
            iconBtn("backward.fill", label: "mini_player.previous", size: 13) {
                Haptics.transport()
                model.skipPrevious()
            }
            Button(action: {
                Haptics.transport()
                model.togglePlayPause()
            }) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.bg)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Theme.ink))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(isPlaying ? "mini_player.pause" : "mini_player.play"))
            iconBtn("forward.fill", label: "mini_player.next", size: 13) {
                Haptics.transport()
                model.skipNext()
            }
            Spacer(minLength: 0)
            volumePopover
            // Expand-to-full-window button, complementing the always-reachable
            // menu item.
            iconBtn("arrow.up.left.and.arrow.down.right", label: "mini_player.expand", size: 12) {
                model.returnToFullWindow()
            }
        }
    }

    /// Volume control collapsed into a popover so the transport row stays
    /// compact in a 320pt-wide window. Tapping the speaker reveals a vertical
    /// slider bound to the same `setVolume` writer the PlayerBar uses.
    @ViewBuilder
    private var volumePopover: some View {
        MiniVolumePopover(
            volume: model.status.volume,
            onChange: { model.setVolume($0) }
        )
    }

    // MARK: - Scrubber (hover-revealed)

    @ViewBuilder
    private var scrubber: some View {
        Slider(
            value: Binding(
                get: { min(max(0, displayPosition), sliderMax) },
                set: { scrubPosition = $0 }
            ),
            in: 0...sliderMax,
            onEditingChanged: { editing in
                if editing {
                    scrubPosition = model.status.positionSeconds
                    isScrubbing = true
                } else {
                    Haptics.scrubCommit()
                    model.seek(toSeconds: scrubPosition)
                    isScrubbing = false
                    // The idle-hide task that fired during the drag bailed out
                    // on the `!isScrubbing` guard, so nothing is scheduled to
                    // dismiss the overlay anymore. If the pointer is still
                    // inside but the user has stopped moving it (released the
                    // scrub thumb in place, no fresh `onContinuousHover`), the
                    // overlay would otherwise stay up forever. Re-arm the timer
                    // here so a still cursor after a scrub still auto-hides.
                    if isHovering {
                        rearmIdleHide()
                    }
                }
            }
        )
        .tint(Theme.ink)
        .controlSize(.mini)
        .disabled(model.status.currentTrack == nil)
        .accessibilityLabel(Text("mini_player.scrubber"))
    }

    // MARK: - Idle (nothing playing)

    @ViewBuilder
    private var idle: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note")
                .font(.system(size: 24))
                .foregroundStyle(Theme.ink3)
            Text("player.nothing_playing")
                .font(Theme.font(12, weight: .medium))
                .foregroundStyle(Theme.ink3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Even with nothing playing the whole surface drags so the user can
        // reposition the empty widget.
        .overlay(MiniPlayerDragHandle())
    }

    // MARK: - Derived

    private var isPlaying: Bool { model.status.state == .playing }

    private var displayPosition: Double {
        isScrubbing ? scrubPosition : model.status.positionSeconds
    }

    /// Positive floor so the Slider domain is never empty before duration is
    /// reported. Same guard as `PlayerBar.sliderMax`.
    private var sliderMax: Double {
        max(1.0, model.status.durationSeconds)
    }

    @ViewBuilder
    private func iconBtn(
        _ name: String,
        label: LocalizedStringKey,
        size: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: size))
                .foregroundStyle(Theme.ink2)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}

// MARK: - Volume popover

/// A speaker button that reveals a vertical volume slider in a popover. Kept a
/// separate `View` (rather than inline state in `MiniPlayerView`) so the
/// `isPresented` state doesn't trigger a rebuild of the whole mini player on
/// every open/close.
private struct MiniVolumePopover: View {
    let volume: Float
    let onChange: (Float) -> Void

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: speakerSymbol)
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink2)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("mini_player.volume"))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink3)
                Slider(
                    value: Binding(
                        get: { Double(volume) },
                        set: { onChange(Float($0)) }
                    ),
                    in: 0...1
                )
                // A vertical slider reads as a volume fader; rotating a
                // horizontal `Slider` is the standard SwiftUI idiom on macOS.
                .frame(width: 120)
                .rotationEffect(.degrees(-90))
                .frame(width: 28, height: 120)
                .tint(Theme.ink2)
                .accessibilityLabel(Text("mini_player.volume"))
                .accessibilityValue("\(Int((Double(volume) * 100).rounded())) percent")
                Image(systemName: "speaker.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.ink3)
            }
            .padding(12)
            .frame(width: 56)
        }
    }

    private var speakerSymbol: String {
        switch volume {
        case ..<0.001: return "speaker.slash.fill"
        case ..<0.34: return "speaker.fill"
        case ..<0.67: return "speaker.wave.1.fill"
        default: return "speaker.wave.2.fill"
        }
    }
}

// MARK: - Window configuration bridge

/// Invisible `NSViewRepresentable` that reaches up to the hosting `NSWindow`
/// and applies the mini-player chrome: chromeless (no title bar, no traffic
/// lights), transparent background so the SwiftUI rounded surface shows the
/// desktop through its corners, draggable from anywhere, and an optional
/// always-on-top floating level. SwiftUI's scene modifiers can't express these
/// `NSWindow` properties, so the bridge does it on `makeNSView` (and re-applies
/// the level whenever `alwaysOnTop` changes).
///
/// We intentionally keep the window's `.titled` style mask (the scene's
/// `.windowStyle(.hiddenTitleBar)` already hides the bar) rather than forcing
/// `.borderless`: a SwiftUI-managed window flipped to `.borderless` after
/// creation loses key/main eligibility, which makes the transport controls
/// un-clickable. Hiding the three standard buttons + the transparent
/// titlebar gets the borderless *look* while the window stays focusable.
///
/// The window-level toggle is the only piece that updates after first mount;
/// the transparent / chromeless setup is one-shot because reapplying it on
/// every SwiftUI update would fight the user's live resize.
private struct MiniPlayerWindowConfigurator: NSViewRepresentable {
    let alwaysOnTop: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // Defer to the next runloop tick: the view isn't in a window yet
        // during `makeNSView`, so `view.window` is nil until SwiftUI attaches
        // it. Reading it on the next tick gives us the real host window.
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            Self.applyChrome(to: window)
            Self.applyLevel(to: window, alwaysOnTop: alwaysOnTop)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        Self.applyLevel(to: window, alwaysOnTop: alwaysOnTop)
    }

    /// One-shot chromeless / transparent setup. Keeps the window focusable
    /// (see type doc for why we don't force `.borderless`).
    private static func applyChrome(to window: NSWindow) {
        // Full-size content + transparent, hidden titlebar so the SwiftUI
        // surface owns the entire window, flowing under where the title strip
        // would have been.
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        // Hide the three standard window buttons to complete the borderless
        // look while the window keeps its `.titled` key/main eligibility.
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        // Transparent window so the SwiftUI `RoundedRectangle` clip shows the
        // desktop through the corners instead of square opaque corners.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true

        // Float along into full-screen spaces as an auxiliary window so the
        // mini player stays reachable over a full-screen app.
        window.collectionBehavior.insert(.fullScreenAuxiliary)
    }

    /// Apply (or clear) the always-on-top floating level.
    private static func applyLevel(to window: NSWindow, alwaysOnTop: Bool) {
        window.level = alwaysOnTop ? .floating : .normal
    }
}

// MARK: - Drag handle

/// Transparent overlay whose mouse-down forwards to `NSWindow.performDrag`, so
/// the album-art region (and the idle placeholder) drags the borderless window
/// even though there's no title bar. `isMovableByWindowBackground` already
/// makes empty areas draggable; this guarantees the artwork is a drag target
/// regardless of what sits on top of it.
private struct MiniPlayerDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DraggingView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DraggingView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
