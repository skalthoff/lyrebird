import XCTest

@testable import Lyrebird

/// Coverage for the LetsMove first-launch "move to Applications" decision
/// (`MoveToApplications`, #193).
///
/// The choice of whether to surface the prompt is path-based and pure, so it's
/// exercised through `shouldPrompt(_:)` and the two path classifiers without
/// realizing an `NSAlert` or moving any files — a headless test run can do
/// neither. The persisted "don't ask again" flag is verified against an
/// isolated `UserDefaults` suite so the real app's preferences are never
/// touched (the same isolation pattern `FeatureTourSeenStore` tests use).
final class MoveToApplicationsTests: XCTestCase {

    // A release-build environment running from a writable location outside
    // /Applications with no prior suppression — the one case that prompts.
    private func promptable() -> MoveToApplications.Environment {
        MoveToApplications.Environment(
            bundlePath: "/Users/jane/Downloads/Lyrebird.app",
            isInsideApplications: false,
            isTranslocatedOrEphemeral: false,
            isDebugBuild: false,
            userSuppressed: false
        )
    }

    // MARK: - shouldPrompt

    func testPromptsFromDownloadsInReleaseBuild() {
        XCTAssertTrue(
            MoveToApplications.shouldPrompt(promptable()),
            "a release build running from ~/Downloads should offer to move itself"
        )
    }

    func testNoPromptWhenAlreadyInstalled() {
        var env = promptable()
        env.bundlePath = "/Applications/Lyrebird.app"
        env.isInsideApplications = true
        XCTAssertFalse(
            MoveToApplications.shouldPrompt(env),
            "an app already in /Applications must never prompt"
        )
    }

    func testNoPromptForTranslocatedOrEphemeralPath() {
        var env = promptable()
        env.isTranslocatedOrEphemeral = true
        XCTAssertFalse(
            MoveToApplications.shouldPrompt(env),
            "a translocated / DMG-mounted copy must not try to move itself"
        )
    }

    func testNoPromptInDebugBuild() {
        var env = promptable()
        env.isDebugBuild = true
        XCTAssertFalse(
            MoveToApplications.shouldPrompt(env),
            "DEBUG builds (swift run / Xcode) must never nag the developer"
        )
    }

    func testNoPromptWhenUserSuppressed() {
        var env = promptable()
        env.userSuppressed = true
        XCTAssertFalse(
            MoveToApplications.shouldPrompt(env),
            "the 'don't ask again' choice must suppress the prompt on later launches"
        )
    }

    func testDebugSuppressionWinsEvenWhenOtherwisePromptable() {
        // DEBUG short-circuits ahead of every other input: even an otherwise
        // perfectly promptable environment stays silent under DEBUG.
        var env = promptable()
        env.isDebugBuild = true
        env.userSuppressed = false
        env.isInsideApplications = false
        env.isTranslocatedOrEphemeral = false
        XCTAssertFalse(MoveToApplications.shouldPrompt(env))
    }

    // MARK: - isInsideApplications

    func testInsideApplicationsExactRoot() {
        XCTAssertTrue(MoveToApplications.isInsideApplications(path: "/Applications/Lyrebird.app"))
    }

    func testInsideApplicationsNestedSubfolder() {
        XCTAssertTrue(
            MoveToApplications.isInsideApplications(path: "/Applications/Utilities/Lyrebird.app"),
            "an app inside an /Applications subfolder still counts as installed"
        )
    }

    func testUserApplicationsIsNotSystemApplications() {
        XCTAssertFalse(
            MoveToApplications.isInsideApplications(path: "/Users/jane/Applications/Lyrebird.app"),
            "~/Applications is a different domain and should still be migrated"
        )
    }

    func testSimilarlyNamedSiblingIsNotApplications() {
        // A component-boundary match: /ApplicationsArchive must not be treated
        // as /Applications just because it shares the prefix.
        XCTAssertFalse(
            MoveToApplications.isInsideApplications(path: "/ApplicationsArchive/Lyrebird.app"),
            "prefix match must respect the path-component boundary"
        )
    }

    func testDownloadsIsNotApplications() {
        XCTAssertFalse(
            MoveToApplications.isInsideApplications(path: "/Users/jane/Downloads/Lyrebird.app")
        )
    }

    // MARK: - isTranslocatedOrEphemeral

    func testTranslocatedMountIsEphemeral() {
        let path = "/private/var/folders/ab/cd/X/AppTranslocation/EF-12/d/Lyrebird.app"
        XCTAssertTrue(
            MoveToApplications.isTranslocatedOrEphemeral(path: path),
            "a Gatekeeper App Translocation mount must be treated as ephemeral"
        )
    }

    func testMountedDMGVolumeIsEphemeral() {
        // A /Volumes/ path whose volume flags can't be resolved (this one
        // doesn't exist) falls back to the conservative "treat as ephemeral"
        // branch, so a DMG-shaped path still suppresses the prompt. The actual
        // disk-image discrimination is exercised purely in `isEphemeralVolume`.
        XCTAssertTrue(
            MoveToApplications.isTranslocatedOrEphemeral(path: "/Volumes/Lyrebird 2.0/Lyrebird.app"),
            "an app opened from a mounted DMG (/Volumes) must not move out of it"
        )
    }

    func testRealDownloadsPathIsNotEphemeral() {
        XCTAssertFalse(
            MoveToApplications.isTranslocatedOrEphemeral(path: "/Users/jane/Downloads/Lyrebird.app"),
            "a normal writable download location is a valid move source"
        )
    }

    func testInstalledPathIsNotEphemeral() {
        XCTAssertFalse(
            MoveToApplications.isTranslocatedOrEphemeral(path: "/Applications/Lyrebird.app")
        )
    }

    // MARK: - isTranslocated (pure)

    func testIsTranslocatedMatchesAppTranslocationMarker() {
        let path = "/private/var/folders/ab/cd/X/AppTranslocation/EF-12/d/Lyrebird.app"
        XCTAssertTrue(MoveToApplications.isTranslocated(path: path))
    }

    func testIsTranslocatedIsFalseForOrdinaryPaths() {
        XCTAssertFalse(MoveToApplications.isTranslocated(path: "/Applications/Lyrebird.app"))
        XCTAssertFalse(
            MoveToApplications.isTranslocated(path: "/Volumes/External SSD/Applications/Lyrebird.app")
        )
    }

    // MARK: - isEphemeralVolume (pure, injected flags)

    func testMountedDiskImageIsEphemeral() {
        // A DMG is read-only, not internal, and not a physically removable or
        // ejectable device — the disk-image fingerprint.
        let flags = MoveToApplications.VolumeFlags(
            isReadOnly: true,
            isInternal: false,
            isRemovable: false,
            isEjectable: false
        )
        XCTAssertTrue(
            MoveToApplications.isEphemeralVolume(path: "/Volumes/Lyrebird 2.0/Lyrebird.app", flags: flags),
            "a read-only synthesized mount under /Volumes is a DMG and must not be a move source"
        )
    }

    func testPersistentSecondaryDiskIsNotEphemeral() {
        // A writable secondary disk mounted at /Volumes/<Disk>/Applications is a
        // supported, persistent install location — it must still prompt.
        let flags = MoveToApplications.VolumeFlags(
            isReadOnly: false,
            isInternal: false,
            isRemovable: false,
            isEjectable: false
        )
        XCTAssertFalse(
            MoveToApplications.isEphemeralVolume(
                path: "/Volumes/Macintosh SSD/Applications/Lyrebird.app",
                flags: flags
            ),
            "a writable secondary volume is a permanent install location, not a DMG"
        )
    }

    func testWriteProtectedRemovableMediaIsNotTreatedAsDiskImage() {
        // A read-only USB stick reports removable/ejectable; it's real media,
        // not a DMG shadow copy, so it isn't classified as ephemeral here.
        let flags = MoveToApplications.VolumeFlags(
            isReadOnly: true,
            isInternal: false,
            isRemovable: true,
            isEjectable: true
        )
        XCTAssertFalse(
            MoveToApplications.isEphemeralVolume(
                path: "/Volumes/THUMBDRIVE/Lyrebird.app",
                flags: flags
            ),
            "read-only removable media is a physical device, not a mounted disk image"
        )
    }

    func testNonVolumesPathIsNeverEphemeralVolume() {
        // The volume branch only applies under /Volumes/; a Downloads path is
        // never reclassified by volume flags.
        let dmgLikeFlags = MoveToApplications.VolumeFlags(
            isReadOnly: true,
            isInternal: false,
            isRemovable: false,
            isEjectable: false
        )
        XCTAssertFalse(
            MoveToApplications.isEphemeralVolume(
                path: "/Users/jane/Downloads/Lyrebird.app",
                flags: dmgLikeFlags
            )
        )
    }

    // MARK: - shellQuoted (relaunch trampoline safety)

    func testShellQuotedWrapsPlainPath() {
        XCTAssertEqual(
            MoveToApplications.shellQuoted("/Applications/Lyrebird.app"),
            "'/Applications/Lyrebird.app'"
        )
    }

    func testShellQuotedPreservesSpaces() {
        // Spaces survive intact inside the single quotes — no word-splitting.
        XCTAssertEqual(
            MoveToApplications.shellQuoted("/Volumes/External SSD/Lyrebird.app"),
            "'/Volumes/External SSD/Lyrebird.app'"
        )
    }

    func testShellQuotedEscapesEmbeddedSingleQuote() {
        // An embedded apostrophe (e.g. a volume named "Jane's Disk") is closed,
        // escaped, and reopened so the shell can't break out of the quoting.
        XCTAssertEqual(
            MoveToApplications.shellQuoted("/Volumes/Jane's Disk/Lyrebird.app"),
            "'/Volumes/Jane'\\''s Disk/Lyrebird.app'"
        )
    }

    func testShellQuotedNeutralizesMetacharacters() {
        // Shell metacharacters are inert inside single quotes; the round-trip
        // value is the literal path bracketed by quotes.
        let path = "/tmp/a b;rm -rf $HOME/Lyrebird.app"
        XCTAssertEqual(
            MoveToApplications.shellQuoted(path),
            "'" + path + "'"
        )
    }

    // MARK: - Suppress flag persistence

    func testSuppressKeyIsStable() {
        // On-disk contract: renaming this key re-arms the prompt for every
        // existing user, so it's pinned here exactly as shipped.
        XCTAssertEqual(
            MoveToApplications.suppressKey,
            "install.suppressMoveToApplicationsPrompt"
        )
    }

    func testCurrentEnvironmentReadsSuppressFlagFromDefaults() {
        let suiteName = "MoveToApplicationsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("could not create isolated UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Unset → not suppressed.
        let before = MoveToApplications.currentEnvironment(defaults: defaults)
        XCTAssertFalse(before.userSuppressed, "an unset flag reads as not-suppressed")

        // Set → suppressed, and the snapshot picks it up.
        defaults.set(true, forKey: MoveToApplications.suppressKey)
        let after = MoveToApplications.currentEnvironment(defaults: defaults)
        XCTAssertTrue(after.userSuppressed, "currentEnvironment must reflect the persisted flag")
    }

    func testCurrentEnvironmentIsDebugUnderTestBuild() {
        // The unit-test bundle is compiled in the DEBUG configuration, so the
        // captured environment reports a debug build — which also means a live
        // promptIfNeeded() call from a test run can never pop an alert.
        let env = MoveToApplications.currentEnvironment()
        XCTAssertTrue(env.isDebugBuild, "test builds are DEBUG; the prompt is inert under test")
        XCTAssertFalse(
            MoveToApplications.shouldPrompt(env),
            "a DEBUG environment never prompts regardless of path"
        )
    }
}
