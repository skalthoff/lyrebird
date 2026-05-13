import ServiceManagement

/// Thin wrapper around `SMAppService.mainApp` that exposes launch-at-login
/// as a simple Bool property. Requires macOS 13+, which matches the app's
/// deployment target. Both `enable()` and `disable()` are fire-and-forget
/// — errors are logged rather than propagated because a failure to register
/// should not block the UI thread or crash the prefs pane.
struct LaunchAtLogin {
    /// Whether Lyrebird is currently registered as a login item.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Register Lyrebird as a login item. No-op if already registered.
    static func enable() {
        guard SMAppService.mainApp.status != .enabled else { return }
        do {
            try SMAppService.mainApp.register()
        } catch {
            Log.app.error("LaunchAtLogin register() failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Unregister Lyrebird as a login item. No-op if not registered.
    static func disable() {
        guard SMAppService.mainApp.status == .enabled else { return }
        do {
            try SMAppService.mainApp.unregister()
        } catch {
            Log.app.error("LaunchAtLogin unregister() failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
