import SwiftUI

/// Top-level Preferences window. Presented via the `Settings { ... }` scene in
/// `LyrebirdApp` so macOS handles the ⌘, shortcut and standard window behavior
/// automatically.
///
/// Matches the native macOS System Settings two-pane layout: left sidebar
/// lists sections, the right pane shows the currently selected one. Section
/// order and naming come from the spec in `research/03-ux-patterns.md` — the
/// shipping p0 set is **General / Server / Playback / Audio / Library /
/// Appearance / Downloads / About**. Advanced, Keyboard, and Lyrics source
/// live in follow-up work and intentionally aren't listed here yet.
///
/// Issues closed here: #114 (top-level org), #115 (Server section), #116
/// (Playback gap-fill), #117 (Audio quality section), #121 (Lyrics source).
/// The Server pane incorporates the Account workflow previously split under
/// its own sidebar entry (still available as `PreferencesAccount` for any
/// other caller that wants the minimal account view).
struct PreferencesView: View {
    enum Pane: String, CaseIterable, Hashable, Identifiable {
        case general, server, playback, audio, equalizer, library, appearance, keyboard, notifications, scrobbling, lyrics, downloads, privacy, advanced, experiments, about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "General"
            case .server: return "Server"
            case .playback: return "Playback"
            case .audio: return "Audio"
            case .equalizer: return "Equalizer"
            case .library: return "Library"
            case .appearance: return "Appearance"
            case .keyboard: return "Keyboard"
            case .notifications: return "Notifications"
            case .scrobbling: return "Scrobbling"
            case .lyrics: return "Lyrics"
            case .downloads: return "Downloads"
            case .privacy: return "Privacy"
            case .advanced: return "Advanced"
            case .experiments: return "Experiments"
            case .about: return "About"
            }
        }

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .server: return "server.rack"
            case .playback: return "play.circle"
            case .audio: return "speaker.wave.2"
            case .equalizer: return "slider.vertical.3"
            case .library: return "music.note.list"
            case .appearance: return "paintpalette"
            case .keyboard: return "keyboard"
            case .notifications: return "bell"
            case .scrobbling: return "dot.radiowaves.up.forward"
            case .lyrics: return "text.alignleft"
            case .downloads: return "arrow.down.circle"
            case .privacy: return "lock.shield"
            case .advanced: return "wrench.and.screwdriver"
            case .experiments: return "flask"
            case .about: return "info.circle"
            }
        }
    }

    @State private var selection: Pane = .general
    // Observed so the sidebar re-renders when debug_panel_enabled changes.
    @State private var flags = FeatureFlags.shared

    var body: some View {
        HStack(spacing: 0) {
            PreferencesNav(selection: $selection, flags: flags)
                .frame(width: 180)

            Divider()
                .background(Theme.border)

            ScrollView {
                pane(for: selection)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bg)
        }
        .frame(width: 780, height: 560)
    }

    @ViewBuilder
    private func pane(for selection: Pane) -> some View {
        switch selection {
        case .general: PreferencesGeneral()
        case .server: PreferencesServer()
        case .playback: PreferencesPlayback()
        case .audio: PreferencesAudio()
        case .equalizer: PreferencesEqualizer()
        case .library: PreferencesLibrary()
        case .appearance: AppearancePane()
        case .keyboard: PreferencesKeyboard()
        case .notifications: PreferencesNotifications()
        case .scrobbling: PreferencesScrobbling()
        case .lyrics: PreferencesLyrics()
        case .downloads: PreferencesDownloads()
        case .privacy: PreferencesPrivacy()
        case .advanced: PreferencesAdvanced()
        case .experiments: PreferencesExperiments()
        case .about: PreferencesAbout()
        }
    }
}

// MARK: - Left navigation

private struct PreferencesNav: View {
    @Binding var selection: PreferencesView.Pane
    /// Observed so the sidebar re-renders when `debug_panel_enabled` changes
    /// without requiring the entire `PreferencesView` to rebuild.
    let flags: FeatureFlags

    /// The set of panes shown in the sidebar. The `experiments` entry is
    /// omitted unless `debug_panel_enabled` is true in `flags.json`.
    private var visiblePanes: [PreferencesView.Pane] {
        PreferencesView.Pane.allCases.filter { pane in
            if pane == .experiments { return flags.debugPanelEnabled }
            return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header

            ForEach(visiblePanes) { pane in
                navRow(pane)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .frame(maxHeight: .infinity)
        .background(Theme.bgAlt)
    }

    private var header: some View {
        Text("Preferences".uppercased())
            .font(Theme.font(10, weight: .bold))
            .foregroundStyle(Theme.ink3)
            .tracking(1.5)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
    }

    @ViewBuilder
    private func navRow(_ pane: PreferencesView.Pane) -> some View {
        let active = selection == pane
        Button { selection = pane } label: {
            HStack(spacing: 10) {
                Image(systemName: pane.icon)
                    .foregroundStyle(active ? Theme.accent : Theme.ink2)
                    .frame(width: 18)
                Text(pane.title)
                    .font(Theme.font(13, weight: active ? .bold : .semibold))
                    .foregroundStyle(active ? Theme.ink : Theme.ink2)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(active ? Theme.surface2 : .clear)
            )
            .overlay(alignment: .leading) {
                if active {
                    Rectangle()
                        .fill(Theme.accent)
                        .frame(width: 3)
                        .clipShape(RoundedRectangle(cornerRadius: 1))
                        .padding(.vertical, 6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pane.title)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }
}

#Preview {
    PreferencesView()
}
