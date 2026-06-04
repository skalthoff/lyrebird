import AppKit

/// First-launch "move to Applications" helper — the LetsMove flow (#193).
///
/// When a user opens Lyrebird straight from the DMG (or from `~/Downloads`),
/// the app runs from a read-only / temporary location: Sparkle self-updates
/// can't write back into a mounted disk image, Gatekeeper App Translocation
/// hides the real path, and the icon never settles into the Dock. The clean
/// fix is the well-trodden LetsMove pattern: on the very first launch, if we
/// detect we're running from outside `/Applications`, offer to move ourselves
/// there and relaunch.
///
/// This type owns three concerns, deliberately split so the *decision* is
/// pure and unit-testable without a window server:
///
/// - `Environment` — a value snapshot of everything the decision depends on
///   (the bundle path, whether it's already installed, whether the path looks
///   translocated/quarantined, the build configuration, and the persisted
///   "don't ask again" flag). Captured from the live process in
///   `promptIfNeeded()`, or hand-built in tests.
/// - `shouldPrompt(_:)` — the pure rule. Given an `Environment`, returns
///   whether to surface the prompt. No side effects, no AppKit, no globals.
/// - `promptIfNeeded()` / `move(...)` — the runtime side: snapshot the
///   environment, run `shouldPrompt`, and on a yes show a native `NSAlert`
///   and perform the move + relaunch. These are the only parts that touch
///   `NSWorkspace`, the Dock, or `UserDefaults`.
///
/// Called once from `AppDelegate.applicationDidFinishLaunching`. Skipped
/// entirely in `DEBUG` so a `swift run` / Xcode debug session from
/// `.build/` or `DerivedData` never nags the developer.
enum MoveToApplications {
    /// Stable on-disk key for the "don't ask again" choice. Namespaced under
    /// `install.` alongside the other feature-scoped preference keys. Renaming
    /// it re-arms the prompt for every existing user, so it's pinned by tests.
    static let suppressKey = "install.suppressMoveToApplicationsPrompt"

    /// The canonical install root. A bundle whose path is anchored here (the
    /// user's `~/Applications` is intentionally *not* treated as installed —
    /// see `isInsideApplications`) needs no move.
    static let applicationsRoot = "/Applications"

    // MARK: - Decision inputs

    /// Immutable snapshot of everything `shouldPrompt(_:)` reasons about.
    /// Built from the live `Bundle` / `UserDefaults` in `promptIfNeeded()`;
    /// constructed directly in tests so the path-based rule can be exercised
    /// headlessly.
    struct Environment {
        /// Absolute filesystem path of the running `.app` bundle.
        var bundlePath: String

        /// Whether the bundle already lives under `/Applications`.
        var isInsideApplications: Bool

        /// Whether the bundle path looks like a Gatekeeper App Translocation
        /// mount, a still-mounted disk image, or a quarantined download.
        /// Moving is futile (translocated) or premature (the real copy hasn't
        /// landed yet) in these cases, so the prompt is suppressed — the user
        /// will get a clean shot once they drag the app out of the DMG.
        var isTranslocatedOrEphemeral: Bool

        /// True for `DEBUG` builds. The prompt never shows for developers
        /// running out of `.build/` or DerivedData.
        var isDebugBuild: Bool

        /// The persisted "don't ask again" choice.
        var userSuppressed: Bool
    }

    /// Pure first-launch decision: should we offer to move the app into
    /// `/Applications`?
    ///
    /// Returns `false` (no prompt) when any of the following hold, in order of
    /// precedence:
    /// - it's a `DEBUG` build,
    /// - the user previously chose "don't ask again",
    /// - the app is already installed under `/Applications`,
    /// - the path is translocated / on a mounted DMG / quarantined.
    ///
    /// Only a release build, running from a real on-disk location outside
    /// `/Applications`, with no prior suppression, yields `true`.
    ///
    /// Factored out of the AppKit flow so the path-based logic is verifiable
    /// without realizing an `NSAlert` (which a headless test run can't do).
    static func shouldPrompt(_ env: Environment) -> Bool {
        if env.isDebugBuild { return false }
        if env.userSuppressed { return false }
        if env.isInsideApplications { return false }
        if env.isTranslocatedOrEphemeral { return false }
        return true
    }

    // MARK: - Path classification (pure)

    /// Whether `path` is anchored under `/Applications`. A strict prefix match
    /// on the path *component* boundary so a sibling like
    /// `/ApplicationsArchive/Lyrebird.app` is not mistaken for an install, and
    /// the user-domain `~/Applications` (which Sparkle/Gatekeeper treat
    /// differently and which we still want to migrate to the system root)
    /// returns `false`.
    static func isInsideApplications(path: String) -> Bool {
        let root = applicationsRoot
        return path == root || path.hasPrefix(root + "/")
    }

    /// Flags describing the volume a bundle lives on, used to tell a mounted
    /// disk image apart from a persistent secondary disk. Injected in tests so
    /// the volume-based branch of `isTranslocatedOrEphemeral` is exercisable
    /// without a real mount; resolved from `URLResourceValues` in production.
    struct VolumeFlags {
        var isReadOnly: Bool
        var isInternal: Bool
        var isRemovable: Bool
        var isEjectable: Bool
    }

    /// Whether `path` is a Gatekeeper App Translocation mount. Gatekeeper runs
    /// quarantined apps from a randomized, read-only mount under
    /// `/private/var/folders/.../AppTranslocation/`; a move from there is
    /// pointless because the bytes are a shadow copy. Pure and path-based —
    /// the marker is always present in the path itself.
    static func isTranslocated(path: String) -> Bool {
        path.contains("/AppTranslocation/")
    }

    /// Whether a bundle on a `/Volumes/`-mounted volume with the given flags is
    /// running from an ephemeral disk image (a mounted DMG) rather than a
    /// persistent secondary disk.
    ///
    /// A mounted DMG presents as read-only (you can't write back into the
    /// image) and, being a synthesized device, is not an internal volume. A
    /// persistent external SSD or a secondary internal partition mounted at
    /// `/Volumes/<Disk>` is writable (or, if read-only, is a real removable
    /// disk the user can eject and re-mount) — those are supported install
    /// locations and must *not* suppress the prompt.
    ///
    /// The discriminator is "read-only **and** not a real removable device":
    /// a DMG is read-only and neither ejectable nor removable in the
    /// physical-media sense, whereas a write-protected USB stick reports
    /// `isRemovable`/`isEjectable` and is left alone here (we don't try to move
    /// *onto* read-only removable media, but we also don't misclassify it as a
    /// DMG shadow copy).
    static func isEphemeralVolume(path: String, flags: VolumeFlags) -> Bool {
        guard path.hasPrefix("/Volumes/") else { return false }
        // A disk image is read-only and not backed by internal storage, and is
        // not a physically removable/ejectable device.
        return flags.isReadOnly && !flags.isInternal && !flags.isRemovable && !flags.isEjectable
    }

    /// Heuristic for "this path is a translocation mount or a still-mounted
    /// disk image we shouldn't try to relocate yet".
    ///
    /// - **App Translocation** — handled by `isTranslocated(path:)`.
    /// - **Mounted DMG** — a path under `/Volumes/` whose volume reports
    ///   disk-image flags (`isEphemeralVolume`). We don't move *out* of a DMG
    ///   (the source is read-only and the user expects to drag it themselves),
    ///   so we hold the prompt until they've copied it somewhere writable. A
    ///   persistent secondary disk mounted at `/Volumes/<Disk>/Applications`
    ///   is a supported, writable install location and is *not* treated as
    ///   ephemeral.
    ///
    /// Volume flags are read from `URLResourceValues`; if they can't be
    /// resolved we conservatively treat a `/Volumes/` path as ephemeral (the
    /// same fail-safe as before — better to skip the prompt than to copy out
    /// of something that turns out to be read-only).
    static func isTranslocatedOrEphemeral(path: String) -> Bool {
        if isTranslocated(path: path) { return true }
        guard path.hasPrefix("/Volumes/") else { return false }
        guard let flags = volumeFlags(forPath: path) else { return true }
        return isEphemeralVolume(path: path, flags: flags)
    }

    /// Resolve the live volume flags for `path` via `URLResourceValues`.
    /// Returns `nil` when the values can't be read (a missing path or a
    /// filesystem that doesn't vend them), leaving the fail-safe to the caller.
    private static func volumeFlags(forPath path: String) -> VolumeFlags? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [
            .volumeIsReadOnlyKey,
            .volumeIsInternalKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
        ]) else { return nil }
        guard
            let readOnly = values.volumeIsReadOnly,
            let isInternal = values.volumeIsInternal,
            let removable = values.volumeIsRemovable,
            let ejectable = values.volumeIsEjectable
        else { return nil }
        return VolumeFlags(
            isReadOnly: readOnly,
            isInternal: isInternal,
            isRemovable: removable,
            isEjectable: ejectable
        )
    }

    // MARK: - Runtime entry point

    /// Snapshot the live process environment and, if the rule says so, present
    /// the native move-to-Applications prompt. Safe to call unconditionally
    /// from `applicationDidFinishLaunching`; it self-gates via `shouldPrompt`.
    @MainActor
    static func promptIfNeeded(
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard
    ) {
        let env = currentEnvironment(bundle: bundle, defaults: defaults)
        guard shouldPrompt(env) else { return }
        presentPrompt(bundlePath: env.bundlePath, defaults: defaults)
    }

    /// Build an `Environment` from the running process. `isDebugBuild` is
    /// resolved here (not in the pure rule) so the decision stays a value
    /// function the tests can drive across both configurations.
    static func currentEnvironment(
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard
    ) -> Environment {
        let path = bundle.bundlePath
        #if DEBUG
        let debug = true
        #else
        let debug = false
        #endif
        return Environment(
            bundlePath: path,
            isInsideApplications: isInsideApplications(path: path),
            isTranslocatedOrEphemeral: isTranslocatedOrEphemeral(path: path),
            isDebugBuild: debug,
            userSuppressed: defaults.bool(forKey: suppressKey)
        )
    }

    // MARK: - AppKit prompt + move

    /// Show the modal `NSAlert`. "Move to Applications Folder" performs the
    /// move + relaunch; "Do Not Move" dismisses for this launch; the
    /// "Don't ask again" checkbox persists the suppression flag regardless of
    /// which button is chosen.
    @MainActor
    private static func presentPrompt(bundlePath: String, defaults: UserDefaults) {
        let alert = NSAlert()
        alert.messageText = "Move Lyrebird to your Applications folder?"
        alert.informativeText = """
        Lyrebird works best from the Applications folder — it keeps automatic \
        updates working and prevents macOS from running it from a temporary \
        location. You can move it now and Lyrebird will reopen from there.
        """
        alert.alertStyle = .informational
        let moveButton = alert.addButton(withTitle: "Move to Applications Folder")
        moveButton.keyEquivalent = "\r"
        alert.addButton(withTitle: "Do Not Move")

        let suppress = NSButton(checkboxWithTitle: "Don't ask again", target: nil, action: nil)
        suppress.state = .off
        alert.accessoryView = suppress

        let response = alert.runModal()

        if suppress.state == .on {
            defaults.set(true, forKey: suppressKey)
        }

        guard response == .alertFirstButtonReturn else { return }

        move(fromBundlePath: bundlePath)
    }

    /// Move the running bundle into `/Applications` and relaunch from the new
    /// location, then terminate the current (old-location) instance.
    ///
    /// Uses `FileManager` for the copy and a detached `/bin/sh` trampoline plus
    /// `open` for the relaunch. On any failure the move is abandoned and the app
    /// keeps running from its current location — a failed move must never strand
    /// the user without a running app. Errors surface in Console under the `app`
    /// category and, where the user is left with a non-obvious state, via an
    /// `NSAlert`.
    @MainActor
    private static func move(fromBundlePath bundlePath: String) {
        let fileManager = FileManager.default
        let sourceURL = URL(fileURLWithPath: bundlePath)
        let appName = sourceURL.lastPathComponent
        let destURL = URL(fileURLWithPath: applicationsRoot).appendingPathComponent(appName)

        // A copy may already sit at the destination. Only clear it after
        // confirming it's safe to do so — a different app/version there must
        // not be silently destroyed, and a *running* different instance must
        // not be clobbered at all.
        if fileManager.fileExists(atPath: destURL.path) {
            switch resolveExistingDestination(source: sourceURL, destination: destURL) {
            case .sameApp:
                // Same bundle identifier — replacing our own prior install is
                // expected. Recycle (Trash) rather than hard-remove so a botched
                // copy below is recoverable, and so removing a copy that might be
                // open elsewhere can't leave a half-deleted bundle.
                guard recycle(destURL) else {
                    presentMoveFailure(
                        "Lyrebird couldn’t replace the existing copy in your "
                            + "Applications folder. Move “\(appName)” to the Trash "
                            + "manually and try again."
                    )
                    return
                }
            case .differentRunning:
                // A different app with the same name is live at the destination.
                // Tearing it down underneath itself corrupts that app, so refuse.
                presentMoveFailure(
                    "A different app named “\(appName)” is already open from your "
                        + "Applications folder. Quit it first, or move it aside, "
                        + "then try moving Lyrebird again."
                )
                return
            case .differentIdle:
                // A different (not-running) app/version is at the destination.
                // Confirm before replacing it, and recycle rather than destroy.
                guard confirmOverwriteDifferentApp(named: appName) else { return }
                guard recycle(destURL) else {
                    presentMoveFailure(
                        "Lyrebird couldn’t move the existing “\(appName)” to the "
                            + "Trash. Move it aside manually and try again."
                    )
                    return
                }
            }
        }

        do {
            try fileManager.copyItem(at: sourceURL, to: destURL)
        } catch {
            Log.app.error(
                "MoveToApplications copy failed: \(error.localizedDescription, privacy: .public)"
            )
            presentMoveFailure(
                "Lyrebird couldn’t copy itself to your Applications folder "
                    + "(\(error.localizedDescription)). It will keep running from "
                    + "its current location."
            )
            return
        }

        // Relaunch via a detached trampoline that waits for *this* process to
        // exit before opening the installed copy and deleting the source. This
        // guarantees only one instance is ever live: we terminate immediately
        // below, and the new instance is opened only after we're gone — so the
        // two never overlap holding the core mutex / writing persisted state.
        guard spawnRelaunchTrampoline(source: sourceURL, destination: destURL) else {
            // Couldn't even start the trampoline. Roll the copy back so the user
            // isn't left with a silent duplicate, and keep running where we are.
            try? fileManager.removeItem(at: destURL)
            presentMoveFailure(
                "Lyrebird couldn’t relaunch from your Applications folder, so the "
                    + "move was undone. It will keep running from its current "
                    + "location."
            )
            return
        }

        // Hand off: quit now so the trampoline's `open` brings up the installed
        // copy as the sole live instance.
        NSApp.terminate(nil)
    }

    /// Classification of whatever already occupies the move destination.
    private enum ExistingDestination {
        /// Same bundle identifier as the source — our own earlier install.
        case sameApp
        /// A different bundle that is currently running.
        case differentRunning
        /// A different bundle that is not running.
        case differentIdle
    }

    /// Compare the app already at `destination` against the `source` we're about
    /// to install. Identity is the bundle identifier (a version bump keeps the
    /// same id, so an upgrade reads as `sameApp`); a missing/unreadable id at
    /// either side is treated as "different" so we err toward asking rather than
    /// destroying.
    @MainActor
    private static func resolveExistingDestination(
        source: URL,
        destination: URL
    ) -> ExistingDestination {
        let sourceID = Bundle(url: source)?.bundleIdentifier
        let destID = Bundle(url: destination)?.bundleIdentifier
        let sameIdentity = sourceID != nil && sourceID == destID
        if sameIdentity {
            return .sameApp
        }
        // Different (or unknowable) identity: is that app live right now?
        let running = NSWorkspace.shared.runningApplications.contains { app in
            app.bundleURL?.standardizedFileURL == destination.standardizedFileURL
        }
        return running ? .differentRunning : .differentIdle
    }

    /// Move `url` to the Trash, returning whether it succeeded. Recoverable by
    /// design — the user can restore from the Trash if the subsequent copy
    /// fails.
    ///
    /// Uses the synchronous `FileManager.trashItem(at:resultingItemURL:)`
    /// rather than the async `NSWorkspace.recycle(_:completionHandler:)`. This
    /// is reached from `move(...)`, a synchronous `@MainActor` function invoked
    /// after `alert.runModal()` returns — i.e. while the main run loop is
    /// blocked. `NSWorkspace.recycle` delivers its completion handler on the
    /// main thread, so blocking the main thread on a semaphore until that
    /// handler fires deadlocks permanently (the handler can never run). The
    /// `FileManager` variant returns on the calling thread and never hangs,
    /// matching the original synchronous removal's non-blocking behaviour while
    /// keeping the to-Trash recoverability.
    @MainActor
    private static func recycle(_ url: URL) -> Bool {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return true
        } catch {
            Log.app.error(
                "MoveToApplications recycle failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    /// Ask the user before replacing a *different* app of the same name already
    /// installed in `/Applications`. Returns `true` if they confirm the replace.
    @MainActor
    private static func confirmOverwriteDifferentApp(named appName: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Replace the existing “\(appName)”?"
        alert.informativeText = """
        A different version of “\(appName)” is already in your Applications \
        folder. Moving Lyrebird there will move the existing copy to the Trash. \
        You can restore it from the Trash if you change your mind.
        """
        alert.alertStyle = .warning
        let replace = alert.addButton(withTitle: "Move to Trash and Replace")
        replace.keyEquivalent = "\r"
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Surface a move failure to the user. The move flow is rare and one-shot,
    /// so a silent log line isn't enough — the user needs to know whether they
    /// still have a working app and where it is.
    @MainActor
    private static func presentMoveFailure(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t move Lyrebird"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Spawn a detached `/bin/sh` that waits for this process (`getpid()`) to
    /// exit, then deletes the source bundle and opens the installed copy.
    /// Returns whether the helper was launched. Running the relaunch from a
    /// process that outlives us is what lets us terminate *first*, so only one
    /// app instance is ever live.
    @MainActor
    private static func spawnRelaunchTrampoline(source: URL, destination: URL) -> Bool {
        let pid = ProcessInfo.processInfo.processIdentifier
        // Poll until our PID is gone, then clean up the source and relaunch.
        // `kill -0` probes liveness without signalling; `rm -rf` clears the
        // now-stale source copy; `open` brings up the installed bundle.
        let script = """
        while /bin/kill -0 \(pid) >/dev/null 2>&1; do
            /bin/sleep 0.1
        done
        /bin/rm -rf \(shellQuoted(source.path))
        /usr/bin/open \(shellQuoted(destination.path))
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        do {
            try process.run()
            return true
        } catch {
            Log.app.error(
                "MoveToApplications trampoline launch failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    /// Single-quote a path for safe interpolation into the `/bin/sh` trampoline,
    /// escaping any embedded single quotes. Paths under `/Applications` and
    /// `/Volumes` can contain spaces and other shell metacharacters.
    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
