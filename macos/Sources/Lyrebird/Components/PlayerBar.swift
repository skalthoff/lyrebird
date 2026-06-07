import SwiftUI
@preconcurrency import LyrebirdCore

struct PlayerBar: View {
    @Environment(AppModel.self) private var model
    // Contrast-adaptive accent for foreground/active-state controls. Lifts
    // `Theme.accent` to the brighter `accentHot` under Increase Contrast so
    // accent-tinted transport icons clear 4.5:1 (#888). Decorative accents
    // (e.g. the play-button fill) keep the base token.
    @Environment(\.accessibleTheme) private var a11yTheme
    // Dynamic Type size drives layout reflow (#338): at the accessibility text
    // sizes the three fixed-width regions (meta / transport / volume) can't
    // share one row without clipping, so we stack them vertically and let the
    // bar grow taller. The decision is factored into the pure
    // `DynamicTypeReflow.decide` helper so the threshold is unit-tested without
    // a live scene; this view only reads the size and branches on the result.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Local scrubber position used while the user is actively dragging the
    /// Slider. We don't bind the Slider straight to `status.positionSeconds`
    /// because the 1Hz polling loop would fight the user's drag — every
    /// status push would yank the thumb back to the server position. When
    /// `isScrubbing` is true we drive the Slider from `scrubPosition`; when
    /// it's false we fall through to the live playback position.
    @State private var scrubPosition: Double = 0
    @State private var isScrubbing: Bool = false

    var body: some View {
        // Reflow decision for the current text size (#338). `hasContextLabel`
        // tracks the "Playing from {source}" affordance so the resting
        // (non-reflowed) min-height still matches the historical 78/96pt chrome
        // and the bar doesn't twitch when the label toggles between tracks.
        let reflow = DynamicTypeReflow.decide(
            dynamicTypeSize: dynamicTypeSize,
            hasContextLabel: model.currentContext != nil
        )
        Group {
            if reflow.stackPlayerBar {
                stackedLayout
            } else {
                horizontalLayout
            }
        }
        .padding(.horizontal, 16)
        // Below the accessibility sizes this is the historical fixed
        // 78/96pt height, but applied as a *minimum* rather than an exact
        // frame so a one-notch glyph overflow can nudge the bar a couple of
        // points taller instead of clipping. At the accessibility sizes the
        // floor jumps so the vertically stacked regions seat without overlap;
        // real content taller than the floor grows the bar downward. See #338.
        .frame(minHeight: reflow.minBarHeight)
        // HUD-style translucent material for the unified transport bar so
        // the chrome matches Music.app's bottom panel and reads as "system
        // chrome" rather than app content. Brand wash on top keeps Lyrebird's
        // palette dominant. See issues #9 / #10 / #28.
        .background(
            VisualEffectView(material: .hudWindow)
                .overlay(Theme.bgAlt.opacity(0.7))
        )
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
        // PlayerBar as a whole comes after the main content in the tab
        // traversal, so the sidebar / content / toolbar all get focus
        // before the persistent chrome at the bottom. See #334.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Playback controls")
    }

    /// The default single-row layout used at the body text sizes (#338). The
    /// three regions ride fixed widths with flexible spacers between them, the
    /// historical chrome. `accessibilitySortPriority` keeps the #334 tab order
    /// (meta → transport → volume) regardless of layout axis.
    @ViewBuilder
    private var horizontalLayout: some View {
        HStack(spacing: 16) {
            leftMeta
                .frame(width: 280, alignment: .leading)
                // Tab order: primary metadata → transport → volume.
                // See #334. Higher priority ships focus here first.
                .accessibilitySortPriority(60)
            Spacer(minLength: 16)
            centerTransport
                .frame(maxWidth: 640)
                .accessibilitySortPriority(50)
            Spacer(minLength: 16)
            rightControls
                .frame(width: 220, alignment: .trailing)
                .accessibilitySortPriority(40)
        }
    }

    /// Accessibility-size layout (#338): the same three regions stacked
    /// vertically so the Dynamic-Type-scaled glyphs each get the full bar
    /// width instead of being squeezed into a 280 / 220pt column where they'd
    /// clip. The regions drop their fixed widths and fill the width; the bar's
    /// `minHeight` (from `DynamicTypeReflow`) grows to seat all three rows.
    /// Sort priorities are preserved so VoiceOver / Tab traversal order is
    /// identical to the horizontal layout — only the visual axis changes.
    @ViewBuilder
    private var stackedLayout: some View {
        VStack(spacing: 10) {
            leftMeta
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilitySortPriority(60)
            centerTransport
                .frame(maxWidth: .infinity)
                .accessibilitySortPriority(50)
            rightControls
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilitySortPriority(40)
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var leftMeta: some View {
        if let track = model.status.currentTrack {
            HStack(spacing: 8) {
                // Tapping the track meta pushes Route.nowPlaying onto navPath,
                // opening the full Now Playing view (Queue / Lyrics / About /
                // Credits tabs). Guard prevents double-push if the view is
                // already on the stack. The button is styled flush so it reads
                // as a regular bar region, not a chrome control.
                Button(action: {
                    if !model.isShowingNowPlaying {
                        model.navPath.append(AppModel.Route.nowPlaying)
                    }
                }) {
                    HStack(spacing: 12) {
                        Artwork(
                            url: model.imageURL(for: track.albumId ?? track.id, tag: track.imageTag, maxWidth: 120),
                            seed: track.name,
                            size: 54,
                            radius: 6
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.name)
                                .font(Theme.font(13, weight: .bold))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                            Text("\(track.artistName) · \(track.albumName ?? "")")
                                .font(Theme.font(11, weight: .medium))
                                .foregroundStyle(Theme.ink2)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Now Playing: \(track.name) by \(track.artistName)")
                .accessibilityHint("Opens Now Playing")

                // Heart button — favorite the currently playing track without
                // navigating away. Mirrors the treatment in NowPlayingView and
                // in Apple Music's persistent transport bar. v1.0 audit #7.
                let isFav = model.isFavorite(track: track)
                iconBtn(
                    isFav ? "heart.fill" : "heart",
                    label: isFav ? "Unfavorite" : "Favorite",
                    tint: isFav ? a11yTheme.accent : Theme.ink2
                ) { model.toggleFavorite(track: track) }
                    .help(isFav ? "Unfavorite" : "Favorite")
            }
        } else {
            Text("player.nothing_playing")
                .font(Theme.font(12, weight: .medium))
                .foregroundStyle(Theme.ink3)
        }
    }

    @ViewBuilder
    private var centerTransport: some View {
        VStack(spacing: 6) {
            HStack(spacing: 20) {
                iconBtn(
                    "shuffle",
                    label: "Shuffle",
                    tint: model.status.shuffle ? a11yTheme.accent : Theme.ink2
                ) {
                    Haptics.levelChange()
                    model.mediaSessionSetShuffle(!model.status.shuffle)
                }
                    .help("Shuffle")
                iconBtn("backward.fill", label: "Previous track", size: 16) {
                    Haptics.transport()
                    model.skipPrevious()
                }
                    .help("Previous · ⌘←")
                Button(action: {
                    Haptics.transport()
                    model.togglePlayPause()
                }) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.bg)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Theme.ink))
                }
                .buttonStyle(.plain)
                // Bind the label to play/pause state rather than the SF
                // Symbol name so VoiceOver reads the action the user is
                // about to take. See #331.
                .accessibilityLabel(Text(isPlaying ? "Pause" : "Play"))
                .help(isPlaying ? "Pause · Space" : "Play · Space")
                iconBtn("forward.fill", label: "Next track", size: 16) {
                    Haptics.transport()
                    model.skipNext()
                }
                    .help("Next · ⌘→")
                iconBtn(
                    model.status.repeatMode == .one ? "repeat.1" : "repeat",
                    label: "Repeat",
                    tint: model.status.repeatMode != .off ? a11yTheme.accent : Theme.ink2
                ) {
                    Haptics.levelChange()
                    let next: RepeatMode = {
                        switch model.status.repeatMode {
                        case .off: return .all
                        case .all: return .one
                        case .one: return .off
                        }
                    }()
                    model.mediaSessionSetRepeatMode(next)
                }
                    .help("Repeat")
            }
            scrubber
        }
    }

    /// The progress row — time labels flanking a real `Slider` (#332).
    /// Replacing the bespoke `Capsule` scrubber with a `Slider` gets us
    /// Voice Control / Switch Control "adjust value" out of the box and
    /// feeds VoiceOver a native percent read-out in addition to the
    /// custom `accessibilityValue` we set below.
    @ViewBuilder
    private var scrubber: some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                Text(format(displayPosition))
                    .font(Theme.font(10, weight: .semibold))
                    .foregroundStyle(Theme.ink3)
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
                    .accessibilityHidden(true)

                Slider(
                    value: Binding(
                        get: {
                            // Clamp `displayPosition` into the Slider's
                            // domain. The polling loop can briefly report
                            // a position past duration across a track
                            // boundary; without clamping SwiftUI logs a
                            // "value out of range" warning.
                            min(max(0, displayPosition), sliderMax)
                        },
                        set: { scrubPosition = $0 }
                    ),
                    in: 0...sliderMax,
                    onEditingChanged: { editing in
                        if editing {
                            // Drag started — freeze the thumb on the user's
                            // position so the polling loop doesn't fight it.
                            scrubPosition = model.status.positionSeconds
                            isScrubbing = true
                        } else {
                            // Drag ended — commit the seek and release the
                            // local position so the next polling tick can
                            // pull the thumb back to the live position. The
                            // alignment tap gives the commit a tactile
                            // "snap" the same way the system volume HUD does.
                            Haptics.scrubCommit()
                            model.seek(toSeconds: scrubPosition)
                            isScrubbing = false
                        }
                    }
                )
                .tint(Theme.ink)
                .disabled(model.status.currentTrack == nil)
                .controlSize(.mini)
                .accessibilityLabel("Playback position")
                .accessibilityValue(accessibilityPositionValue)

                Text(format(model.status.durationSeconds))
                    .font(Theme.font(10, weight: .semibold))
                    .foregroundStyle(Theme.ink3)
                    .monospacedDigit()
                    .frame(width: 36, alignment: .leading)
                    .accessibilityHidden(true)
            }
            playingFromLabel
        }
    }

    /// Small "Playing from {source}" affordance below the scrubber (#82).
    /// Clickable when `AppModel.currentContext` has a navigable id — the
    /// label navigates the main content column to the source playlist /
    /// album / artist. Reads as plain text for ad-hoc sources (radio,
    /// genre, search) where there's no single destination to land on.
    @ViewBuilder
    private var playingFromLabel: some View {
        if let context = model.currentContext, !context.name.isEmpty {
            Group {
                if model.currentContextIsNavigable {
                    Button(action: { model.goToPlayingFromSource() }) {
                        playingFromText(context.name, bold: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Playing from \(context.name)")
                    .accessibilityHint("Opens source")
                } else {
                    playingFromText(context.name, bold: false)
                        .accessibilityLabel("Playing from \(context.name)")
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func playingFromText(_ name: String, bold: Bool) -> some View {
        // Split "Playing from" from the source name so only the name picks
        // up the brighter ink color when the label is clickable — mirrors
        // the link-style treatment used on Album / Artist liner chips.
        HStack(spacing: 4) {
            Text("Playing from")
                .font(Theme.font(10, weight: .medium))
                .foregroundStyle(Theme.ink3)
            Text(name)
                .font(Theme.font(10, weight: bold ? .bold : .medium))
                .foregroundStyle(bold ? Theme.ink2 : Theme.ink3)
                .underline(bold, color: Theme.ink2.opacity(0.6))
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private var rightControls: some View {
        HStack(spacing: 6) {
            Spacer()
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 14))
                .foregroundStyle(Theme.ink2)
                .accessibilityHidden(true)
            Slider(
                value: Binding(
                    get: { Double(model.status.volume) },
                    set: { model.setVolume(Float($0)) }
                ),
                in: 0...1
            )
            .tint(Theme.ink2)
            .frame(width: 100)
            .accessibilityLabel("Volume")
            .accessibilityValue("\(Int((Double(model.status.volume) * 100).rounded())) percent")

            // System AirPlay / output-route picker (#38). Auto-hidden when no
            // alternate routes are within range, matching Apple Music's
            // behaviour: `RouteDetector.shared.multipleRoutesDetected` is true
            // only when at least one AirPlay / Bluetooth destination replies to
            // `AVRouteDetector`'s scan — so on a machine that's never near an
            // AirPlay speaker the button stays out of the way. When visible,
            // tapping presents the OS list of receivers (the same popover
            // Music.app shows). `AVRoutePickerView` drives the routing stack
            // directly; this needs no core FFI.
            if RouteDetector.shared.multipleRoutesDetected {
                AirPlayRoutePicker()
                    .frame(width: 28, height: 28)
                    .accessibilityLabel("AirPlay")
                    .accessibilityHint("Choose an audio output device")
                    .help("AirPlay")
            }
        }
    }

    /// Unified "what to render in the Slider right now" — the live playback
    /// position most of the time, and the frozen `scrubPosition` only while
    /// the user is actively dragging.
    private var displayPosition: Double {
        isScrubbing ? scrubPosition : model.status.positionSeconds
    }

    /// Upper bound for the scrubber's domain. Stays at a positive floor so
    /// the Slider's `in:` range is always non-empty even before duration
    /// has been reported (pre-roll / no track).
    private var sliderMax: Double {
        max(1.0, model.status.durationSeconds)
    }

    /// Human-readable VoiceOver value for the scrubber — "1 minute 23
    /// seconds of 4 minutes 10 seconds". Using spoken words rather than
    /// raw digits matches Apple Music / Podcasts behaviour.
    private var accessibilityPositionValue: String {
        guard model.status.currentTrack != nil else { return "No track loaded" }
        let pos = Self.voiceOverTime(displayPosition)
        let total = Self.voiceOverTime(model.status.durationSeconds)
        return "\(pos) of \(total)"
    }

    private var isPlaying: Bool {
        model.status.state == .playing
    }

    @ViewBuilder
    private func iconBtn(
        _ name: String,
        label: String,
        size: CGFloat = 14,
        tint: Color = Theme.ink2,
        action: @escaping () -> Void = {}
    ) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: size))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }

    private func format(_ seconds: Double) -> String {
        DurationFormatter.colon(seconds)
    }

    /// Convert a duration in seconds to a word-based string for VoiceOver.
    /// "0 seconds", "45 seconds", "1 minute 5 seconds", "2 minutes", etc.
    private static func voiceOverTime(_ seconds: Double) -> String {
        DurationFormatter.spokenAccessibility(seconds)
    }
}
