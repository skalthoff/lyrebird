import ServiceManagement

/// Thin wrapper around `SMAppService.mainApp` that exposes launch-at-login
/// as a simple Bool property. Requires macOS 13+, which matches the app's
/// deployment target. Both `enable()` and `disable()` are fire-and-forget
/// — errors are logged rather than propagated because a failure to register
/// should not block the UI thread or crash the prefs pane.
struct LaunchAtLogin {
    /// Whether Jellify is currently registered as a login item.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Register Jellify as a login item. No-op if already registered.
    static func enable() {
        guard SMAppService.mainApp.status != .enabled else { return }
        do {
            try SMAppService.mainApp.register()
        } catch {
            debugPrint("[LaunchAtLogin] register() failed: \(error)")
        }
    }

    /// Unregister Jellify as a login item. No-op if not registered.
    static func disable() {
        guard SMAppService.mainApp.status == .enabled else { return }
        do {
            try SMAppService.mainApp.unregister()
        } catch {
            debugPrint("[LaunchAtLogin] unregister() failed: \(error)")
        }
    }
}
