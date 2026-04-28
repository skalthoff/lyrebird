import SwiftUI
@preconcurrency import JellifyCore

struct PlayerBar: View {
    @Environment(AppModel.self) private var model
    @State private var showNowPlaying = false

    /// Local scrubber position used while the user is actively dragging the
    /// Slider. We don't bind the Slider straight to `status.positionSeconds`
    /// because the 1Hz polling loop would fight the user's drag — every
    /// status push would yank the thumb back to the server position. When
    /// `isScrubbing` is true we drive the Slider from `scrubPosition`; when
    /// it's false we fall through to the live playback position.
    @State private var scrubPosition: Double = 0
    @State private var isScrubbing: Bool = false

    var body: some View {
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
        .padding(.horizontal, 16)
        // Bar grows a few points taller when a "Playing from {source}"
        // label is present (#82). Keeping both heights hard-coded preserves
        // the stable bar chrome so the whole app doesn't shift a pixel
        // when the label appears or disappears between tracks.
        .frame(height: model.currentContext == nil ? 78 : 96)
        // HUD-style translucent material for the unified transport bar so
        // the chrome matches Music.app's bottom panel and reads as "system
        // chrome" rather than app content. Brand wash on top keeps Jellify's
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
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingSheet()
                .environment(model)
        }
    }

    @ViewBuilder
    private var leftMeta: some View {
        if let track = model.status.currentTrack {
            // Tapping the track meta opens the Now Playing sheet (#279)
            // which currently surfaces track artwork, title/artist/album,
            // and the Credits block. The button is styled flush so it
            // reads as a regular bar region, not a chrome control.
            Button(action: { showNowPlaying = true }) {
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
            .accessibilityHint("Shows track details")
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
                iconBtn("shuffle", label: "Shuffle")
                    .help("Shuffle")
                iconBtn("backward.fill", label: "Previous track", size: 16) { model.skipPrevious() }
                    .help("Previous · ⌘←")
                Button(action: model.togglePlayPause) {
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
                iconBtn("forward.fill", label: "Next track", size: 16) { model.skipNext() }
                    .help("Next · ⌘→")
                iconBtn("repeat", label: "Repeat")
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
                            // pull the thumb back to the live position.
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
        action: @escaping () -> Void = {}
    ) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: size))
                .foregroundStyle(Theme.ink2)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }

    private func format(_ seconds: Double) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    /// Convert a duration in seconds to a word-based string for VoiceOver.
    /// "0 seconds", "45 seconds", "1 minute 5 seconds", "2 minutes", etc.
    private static func voiceOverTime(_ seconds: Double) -> String {
        let safe = seconds.isFinite ? max(0, seconds) : 0
        let total = Int(safe.rounded())
        let m = total / 60
        let s = total % 60
        switch (m, s) {
        case (0, 0): return "0 seconds"
        case (0, _): return s == 1 ? "1 second" : "\(s) seconds"
        case (_, 0): return m == 1 ? "1 minute" : "\(m) minutes"
        default:
            let mins = m == 1 ? "1 minute" : "\(m) minutes"
            let secs = s == 1 ? "1 second" : "\(s) seconds"
            return "\(mins) \(secs)"
        }
    }
}
