# Jellify macOS Distribution

End-to-end pipeline for producing a signed, notarized, stapled `Jellify-<version>.dmg`
that passes Gatekeeper and launches cleanly on a fresh Mac.

---

## First-release operator checklist

The rest of this doc is reference material. If you're setting things up
for the first time, work through this list top to bottom — every step is
mandatory for a tag push to produce a signed, notarized DMG.

- [ ] **Apple Developer Program enrolled** (below → "Apple Developer
      Program enrollment"). Individual enrollment is $99/yr; can take
      ~24h to approve.
- [ ] **Developer ID Application certificate** in your Mac's login
      keychain (same section). Verify with
      `security find-identity -v -p codesigning | grep "Developer ID Application"`.
- [ ] **Team ID recorded** (10 chars, from the Membership page).
- [ ] **`.p12` exported** (cert + private key together) and
      `base64 -i cert.p12 | pbcopy`'d for the `APPLE_DEVELOPER_ID_CERT_P12`
      secret.
- [ ] **App-specific password** created at <https://appleid.apple.com>
      → Sign-In and Security → App-Specific Passwords. Label it
      "Jellify notarization".
- [ ] **Sparkle keypair generated** (below → "Sparkle key generation").
      Store both halves in your password manager before closing the
      terminal.
- [ ] **All 9 GitHub secrets set** under Settings → Secrets and
      variables → Actions (below → "Required GitHub Actions secrets").
      The workflow fails fast on the first missing one.
- [ ] **`gh-pages` branch bootstrapped** (below → "First-ever gh-pages
      bootstrap"). Skipping this makes the appcast publish step blow up
      on the first tag.
- [ ] **Local dry run done** (optional but strongly recommended — below
      → "Running the first release manually"). Confirms your secrets
      are shaped right before committing to a tag.
- [ ] **First tag pushed**:
      ```bash
      git tag -s v0.1.0 -m "Jellify 0.1.0"
      git push origin v0.1.0
      ```
      `.github/workflows/macos-release.yml` picks it up, builds for
      ~20 min on macos-14, uploads the DMG to the release, and
      regenerates the appcast on `gh-pages`.

If a step fails, the "Troubleshooting" section at the bottom covers the
usual suspects.

---

## **MANUAL PREREQUISITE — Apple Developer Program enrollment (issue #175)**

**This step is a multi-day, non-engineering task. The engineering pipeline
below cannot be exercised end-to-end until it is done. Start it first.**

1. Enroll at <https://developer.apple.com/programs/>. Individual
   enrollment is $99/year; organizational enrollment can take 1–4 weeks.
2. In the developer portal (**Certificates, IDs & Profiles →
   Certificates**) request a **Developer ID Application** certificate.
   - This is the cert used to sign `.app` bundles and `.dmg` files for
     distribution *outside* the Mac App Store.
   - **Do not** request **Developer ID Installer** — we ship a DMG, not
     a `.pkg`.
   - **Do not** request **Apple Distribution** / **Mac App Distribution**
     — those are MAS-only.
3. On a secure Mac, generate a CSR via **Keychain Access → Certificate
   Assistant → Request a Certificate from a Certificate Authority**.
   Upload the `.certSigningRequest`, download the resulting `.cer`,
   double-click it to import into your login keychain.
4. Export the resulting identity as a `.p12` from **Keychain Access → My
   Certificates**. Select both the certificate *and* its private key
   (if the key is missing from the selection, the Export menu item is
   greyed out). Set a long random password. Store the `.p12` + password
   in 1Password under `jellify-desktop / Apple Developer ID`.
5. From the portal's **Membership** page, record the **Team ID**. Save
   it in the same 1Password entry.
6. (Related to issue #176) In **Identifiers → + → App IDs → macOS App**,
   register the bundle identifier `org.jellify.desktop` exactly. A
   mismatch between the cert's recognized identifiers and the bundle ID
   is a common notarization surprise.

Once the certificate is in your login keychain the engineering pipeline
below will just work.

---

## Environment variables

All scripts read their secrets from the environment. Nothing touches
disk outside of the keychain-stored credentials and local build outputs.

| Variable        | Used by                            | Example                                                      |
| --------------- | ---------------------------------- | ------------------------------------------------------------ |
| `VERSION`       | `make-bundle.sh`, `make-dmg.sh`    | `0.1.0` (semver, matches a git tag)                          |
| `BUILD`         | `make-bundle.sh`                   | `1234` (monotonic build number, typically CI run number)     |
| `DEVELOPER_ID`  | `sign.sh`, `make-dmg.sh`           | `Developer ID Application: Jane Doe (TEAMID123)`             |
| `NOTARY_PROFILE`| `notarize.sh`                      | `jellify-notary` (keychain profile name)                     |

If `VERSION` / `BUILD` are unset, the scripts fall back to
`git describe --tags --abbrev=0` and `git rev-list --count HEAD` so local
dev builds still produce a sensibly-named bundle.

### One-time notary profile bootstrap

Store notary credentials in the keychain so the scripts never see raw
secrets:

```sh
xcrun notarytool store-credentials jellify-notary \
    --apple-id       "$APPLE_ID" \
    --team-id        "$APPLE_TEAM_ID" \
    --password       "$APPLE_NOTARY_APP_PASSWORD"
```

- `APPLE_ID` — the Apple ID associated with your developer account.
- `APPLE_TEAM_ID` — the 10-character team ID from the portal.
- `APPLE_NOTARY_APP_PASSWORD` — an **app-specific password** created at
  <https://appleid.apple.com> → Sign-In and Security → App-Specific
  Passwords. (Your real Apple ID password will not work.)

This only needs to run once per machine. The profile is stored in the
login keychain under the name `jellify-notary`.

### Tooling install

```sh
brew install create-dmg jq shellcheck
rustup target add aarch64-apple-darwin
```

`shellcheck` is dev-only. `jq` is required by `notarize.sh`. Xcode
command line tools must be present (`xcode-select --install`).

---

## Files

| Path                                         | Purpose                                                        |
| -------------------------------------------- | -------------------------------------------------------------- |
| `macos/Resources/Info.plist`                 | Info.plist template with `$VERSION`/`$BUILD` placeholders      |
| `macos/Resources/Jellify.entitlements`       | Hardened-runtime entitlements applied at signing time          |
| `macos/Scripts/build-core.sh`                | Builds the Rust core as an `arm64` xcframework                  |
| `macos/Scripts/make-bundle.sh`               | Assembles `Jellify.app` and injects Info.plist version fields  |
| `macos/Scripts/sign.sh`                      | Codesigns the bundle inside-out with the hardened runtime      |
| `macos/Scripts/make-dmg.sh`                  | Produces `Jellify-<version>.dmg` via `create-dmg`              |
| `macos/Scripts/notarize.sh`                  | Submits to Apple's notary, waits, staples the ticket           |

---

## The release flow — run locally

Each script is idempotent and cleans up after itself on failure, so a
partial run can be retried from any step.

```sh
# 1. Build the Rust core as an arm64 xcframework.
./macos/Scripts/build-core.sh --release

# 2. Compile Swift for arm64 (Apple Silicon only).
cd macos
swift build -c release
cd ..

# 3. Assemble Jellify.app. Picks up $VERSION / $BUILD (or git fallback).
VERSION=0.1.0 BUILD=1 ./macos/Scripts/make-bundle.sh --release

# 4. Code-sign inside-out with the hardened runtime.
DEVELOPER_ID="Developer ID Application: Your Name (TEAMID123)" \
    ./macos/Scripts/sign.sh macos/build/Jellify.app

# 5. Produce the DMG (signed with the same identity).
DEVELOPER_ID="Developer ID Application: Your Name (TEAMID123)" \
    VERSION=0.1.0 \
    ./macos/Scripts/make-dmg.sh

# 6. Submit for notarization and staple the ticket on success.
./macos/Scripts/notarize.sh macos/build/Jellify-0.1.0.dmg
```

After step 6, the DMG is shippable. `spctl --assess --type open
--context context:primary-signature -v macos/build/Jellify-0.1.0.dmg`
should report `accepted`.

---

## Bundle layout (after step 4)

```
Jellify.app/
├── Contents/
│   ├── Info.plist           (rendered from Resources/Info.plist)
│   ├── MacOS/
│   │   └── Jellify          (arm64 Mach-O, signed + hardened runtime)
│   ├── Resources/
│   │   ├── AppIcon.icns     (optional — soft-dependency on icon pipeline)
│   │   └── Jellify_Jellify.bundle/   (SPM-processed fonts bundle)
│   └── _CodeSignature/
```

No `Frameworks/` directory yet. Sparkle ships in BATCH-19 (see
ROADMAP) and will live at `Contents/Frameworks/Sparkle.framework`.
`sign.sh` already handles it correctly when present.

---

## What each script does in detail

### `build-core.sh`

Builds `libjellify_core.a` for `aarch64-apple-darwin` (in release mode;
LTO is pinned in `Cargo.toml`). The UniFFI Swift binding is regenerated
from the `.dylib`, and both the headers and the static lib go into
`macos/Jellify.xcframework`, which the SPM `binaryTarget` consumes.

Apple Silicon only — Intel was dropped from M4 distribution (#660 wontfix).

### `make-bundle.sh`

Assembles `macos/build/Jellify.app` from the `swift build` output.
Copies `macos/Resources/Info.plist` into `Contents/Info.plist`, then
uses `plutil -replace` to inject `$VERSION` and `$BUILD`. Runs
`plutil -lint` on the result — a drift in the template that breaks
Core Foundation parsing fails the script loudly.

### `sign.sh`

Signs inside-out in a deterministic order: frameworks → XPC services
→ loose dylibs → auxiliary helpers → main bundle. Every sign call
uses `--options runtime --timestamp`. Entitlements are applied to
bundle-level binaries (frameworks, the app itself); inner helpers
inherit from the enclosing app.

**Never passes `--deep`.** `--deep` is deprecated, papers over real
signing bugs, and is correlated with notary rejections.

Verifies with `codesign --verify --strict` and previews the Gatekeeper
verdict with `spctl`. The Gatekeeper preview will report "rejected,
source=Unnotarized Developer ID" until `notarize.sh` runs — that's
expected.

### `make-dmg.sh`

Wraps `create-dmg`. Stages the `.app` in a scratch directory so
create-dmg doesn't sweep in any sibling junk in `build/`. Signs the
DMG with `--codesign`. **Does not** pass `--notarize` — notarization
happens via the dedicated `notarize.sh` so a rejected submission is
retriable without rebuilding the DMG.

### `notarize.sh`

`xcrun notarytool submit --wait --output-format json`, parses the
verdict with `jq`, and either staples (success) or dumps the
detail log (failure). Preserves logs in a temp dir on failure for
post-mortem; cleans up on success.

---

## First Launch

### What users see on first run

After downloading `Jellify-<version>.dmg` from GitHub Releases and dragging
`Jellify.app` to `/Applications`, macOS assigns the app the quarantine flag
(`com.apple.quarantine`). On double-click macOS Gatekeeper checks that
attribute before allowing the app to run.

**On a correctly signed and notarized build**, Gatekeeper resolves the ticket
stapled into the bundle and presents a one-time confirmation dialog — not an
error:

> *"Jellify is an app downloaded from the Internet. Are you sure you want to
> open it?"*

Click **Open**. The quarantine flag is cleared and the app launches normally.
On every subsequent launch Gatekeeper lets it through silently.

### macOS 14 (Sonoma) and earlier

The confirmation dialog has an **Open** button directly in the sheet.
Clicking it is all that is required.

### macOS 15 (Sequoia) and later

Apple tightened the first-launch flow in Sequoia. The initial double-click
dismisses with "Apple cannot verify the developer of Jellify" and no
**Open** button is shown. To proceed:

1. Open **System Settings → Privacy & Security**.
2. Scroll to the **Security** section. A notice appears:
   *"Jellify was blocked from use because it is not from an identified
   developer."*
3. Click **Open Anyway** next to the notice.
4. A final confirmation sheet asks "Are you sure you want to open it?" —
   click **Open**.

After this one-time approval the app launches without prompts on all
subsequent runs.

### Why this happens

Apple's Gatekeeper quarantines every file downloaded from the Internet.
For Developer ID–signed and notarized apps (like Jellify), the stapled
notarization ticket allows Gatekeeper to approve the app without a network
call, but the one-time confirmation is still required by design. This is
expected behavior and is **not** a sign of a broken or malicious build.

### What a broken build looks like

If users see **"Jellify cannot be opened because the developer cannot be
verified"** (the "unidentified developer" dialog, with only **Move to Trash**
and **Cancel** options), the code-signing or notarization chain is broken.
Treat this as a release-blocker. Do not ship the DMG until it is resolved —
see the Troubleshooting section and re-run `sign.sh` + `notarize.sh`.

The `xattr -d com.apple.quarantine Jellify.app` terminal command removes the
quarantine attribute and bypasses Gatekeeper entirely. Do **not** advertise
this to end users; it is a developer diagnostic tool, not a user-facing
workaround, and it carries real security implications.

---

## Troubleshooting

### `security find-identity` shows no `Developer ID Application`

The certificate isn't installed in the active keychain. Double-click the
`.cer` or import the `.p12` into **login.keychain**. Run
`security list-keychains` to check which keychain is searched by default.

### `codesign` says "no identity found"

The name passed in `$DEVELOPER_ID` must exactly match the common name of
a cert in the keychain. Copy-paste from:

```sh
security find-identity -v -p codesigning
```

### `notarytool` rejects with "The signature of the binary is invalid"

Almost always one of:
1. You built on an old Xcode SDK (pre-15). The notary requires
   `LC_BUILD_VERSION` loads on every Mach-O — older SDKs emit
   `LC_VERSION_MIN_MACOSX` instead. Xcode 15+ fixes this.
2. Something inside `Contents/Frameworks/` was signed *after* the
   outer app. Rerun `sign.sh`; it orders passes correctly.
3. You passed `--deep` somewhere. Don't.

### `notarytool` rejects with "The binary uses an SDK older than 10.9"

A very old Rust toolchain or a pre-compiled binary dependency. Update
Rust (`rustup update`) and rebuild from clean (`cargo clean`).

### `notarytool` rejects with "The executable does not have the
hardened runtime enabled"

`sign.sh` was not run, or was run with a different tool that didn't set
`--options runtime`. Re-run `sign.sh` on the bundle.

### `stapler staple` says "Could not find the ticket"

Apple's CDN is eventually-consistent. `notarytool submit --wait`
returning "Accepted" does not guarantee the ticket is globally visible
yet. Wait 30 seconds and retry `stapler staple`.

### DMG mounts fine but Gatekeeper says "damaged and can't be opened"

The DMG was downloaded via a browser and the quarantine attribute was
applied after signing. This is expected for unnotarized builds. Once
notarized + stapled, Gatekeeper will accept the download without a
network lookup.

### `create-dmg` hangs / times out

`create-dmg` uses AppleScript to arrange window geometry, which fails
silently under SSH sessions without a logged-in GUI. Run from a local
terminal session.

### Entitlements rejected: "Unsupported entitlement"

Check that `Jellify.entitlements` does not contain MAS-only keys like
`com.apple.application-identifier` or sandbox keys. We are Developer
ID, not MAS.

---

---

## CI, release workflow, and auto-update


How we get a Jellify build from a tag in git to a signed, notarized,
auto-updating `.app` on someone's Mac.

## Pipeline at a glance

```
  git tag v0.2.0  ── push ──►  .github/workflows/macos-release.yml
       │
       ├─ build universal xcframework (arm64 + x86_64)
       ├─ swift build -c release
       ├─ make-iconset.sh            → Resources/Jellify.icns
       ├─ make-bundle.sh             → build/Jellify.app
       ├─ sign.sh                    → codesign + hardened runtime
       ├─ make-dmg.sh                → build/Jellify-<ver>.dmg
       ├─ notarize.sh                → Apple notary + stapled ticket
       ├─ gh release create          → DMG attached to v0.2.0
       ├─ generate-appcast.sh        → docs/appcast.xml
       └─ push to gh-pages           → https://skalthoff.github.io/jellify-desktop/appcast.xml
```

Sparkle on the client side polls the appcast URL, pulls the new DMG,
verifies the Ed25519 signature on the enclosed feed entry, and swaps
itself in place.

## Required GitHub Actions secrets

Set each of these under **Settings → Secrets and variables → Actions**.
All values must be populated before the first tag push — the workflow
fails fast if any are missing.

| Secret | What | How to produce |
|---|---|---|
| `APPLE_DEVELOPER_ID_CERT_P12` | Base64-encoded `.p12` export of the Developer ID Application certificate (and its private key). | Export from Keychain Access → right-click the identity → Export. Pick `.p12`. Then `base64 -i cert.p12 \| pbcopy`. |
| `APPLE_DEVELOPER_ID_CERT_P12_PASSWORD` | Password you typed during the `.p12` export. | Free-form; pick something long, store in a password manager. |
| `APPLE_DEVELOPER_ID_IDENTITY` | Common-name of the identity codesign looks up (e.g. `Developer ID Application: Soren Althoff (XXXXXXXXXX)`). | `security find-identity -v -p codesigning` on a machine with the cert installed. Copy the `"..."` string. |
| `APPLE_TEAM_ID` | 10-character team identifier. | Apple Developer → Membership → Team ID. |
| `APPLE_ID` | Apple ID email used for notarization. | Usually the account that owns the developer program. |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password generated for notarization. | appleid.apple.com → Sign-In and Security → App-Specific Passwords. Label it "Jellify notarization". |
| `APPLE_NOTARY_PROFILE` | Profile name used by `xcrun notarytool store-credentials` if notarize.sh relies on a stored profile rather than raw credentials. | Pick any slug; `notarize.sh` regenerates the profile from the three secrets above on each run. |
| `SPARKLE_PUBLIC_ED_KEY` | Base64 Ed25519 **public** key. Substituted into Info.plist at build time. | `generate_keys` (see below) prints both halves. |
| `SPARKLE_ED25519_PRIVATE` | Base64 Ed25519 **private** key. Never leaves the runner; only used by `generate-appcast.sh`. | Same generator. |

### Sparkle key generation (one-time, on a trusted Mac)

Sparkle ships a `generate_keys` helper inside its distribution. Run it
once, store the outputs in a password manager, and never commit the
private half anywhere.

```bash
# 1. Fetch the Sparkle tarball for the version pinned in
#    macos/Scripts/generate-appcast.sh (SPARKLE_VERSION).
SPARKLE_VERSION=2.6.4
curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz" \
  | tar -xJ
cd "Sparkle-${SPARKLE_VERSION}"

# 2. Generate the keypair. This creates an item in your login keychain
#    AND prints the two base64 blobs. Copy them straight out of the
#    terminal into your password manager.
./bin/generate_keys

# Expected output looks like:
#   A key has been generated and saved in your keychain. Add the
#   following to the Info.plist of each app using this key:
#
#       <key>SUPublicEDKey</key>
#       <string>AAAAA...base64...=</string>
#
#   ED private key (base64, save this in a secure place):
#       /BBBBB...base64...==

# 3. Paste the public half into the SPARKLE_PUBLIC_ED_KEY secret.
# 4. Paste the private half into SPARKLE_ED25519_PRIVATE.
# 5. Lock the keychain item (or delete it once the secrets are stored).
```

Rotating these keys is a breaking change for every already-installed
Jellify — older copies won't trust feeds signed by the new key. If a
rotation is ever required, bump the feed URL to a new path (e.g.
`appcast-v2.xml`) and ship one last update against the old key that
points existing installs at the new URL.

## Icon source

`Scripts/make-iconset.sh` looks for the icon source in this order:

1. `design/icons/jellify-app.svg` — the canonical path once the final
   app icon is designed.
2. `design/project/assets/teal-icon.svg` — placeholder currently in the
   repo.

Drop a finished SVG at path 1 and the script picks it up with no
further changes. `sips` handles the rasterization, with `qlmanage` as
an emergency fallback when `sips` can't resolve a gradient.

## Running the first release manually

Before trusting the workflow on a live tag, do one dry run locally on a
signed, notarization-enabled Mac to confirm the secrets are shaped
right.

```bash
# 0. On a clean branch (so DMG leftovers don't pollute main).
git switch -c dry-run-release

# 1. Build the xcframework (release).
./macos/Scripts/build-core.sh --release

# 2. Build the Swift app.
(cd macos && swift build -c release)

# 3. Generate the .icns (sips renders, iconutil compiles).
./macos/Scripts/make-iconset.sh

# 4. Bundle .app. Populate SPARKLE_PUBLIC_ED_KEY so the real public key
#    lands in Info.plist — otherwise Sparkle silently refuses to
#    initialize on launch.
export SPARKLE_PUBLIC_ED_KEY='AAAAA...your public key...='
export JELLIFY_VERSION=0.0.0-dev
export JELLIFY_BUILD=$(date -u +%Y%m%d%H%M)
./macos/Scripts/make-bundle.sh

# 5. (Optional) Sign + notarize locally — same scripts the workflow
#    calls. Skip if you only want to verify the build step.
./macos/Scripts/sign.sh
./macos/Scripts/make-dmg.sh
./macos/Scripts/notarize.sh

# 6. Regenerate the appcast against a fake release layout. For this you
#    need the private Ed25519 key on disk; keep it out of shell history.
read -rs -p "SPARKLE_ED25519_PRIVATE: " SPARKLE_ED25519_PRIVATE; export SPARKLE_ED25519_PRIVATE
./macos/Scripts/generate-appcast.sh

# 7. Spot-check docs/appcast.xml — confirm the <enclosure url="..."/> is
#    pointed at the expected github.com/.../releases/download path and
#    that <sparkle:edSignature> is present on every item.
```

If everything looks right, push a tag:

```bash
git switch main
git tag -s v0.2.0 -m "Jellify 0.2.0"
git push origin v0.2.0
```

The workflow takes ~20 minutes on `macos-14`. Watch the
[Actions](https://github.com/skalthoff/jellify-desktop/actions) tab
for progress.

## Hosting the appcast

GitHub Pages serves `gh-pages:/appcast.xml` at
`https://skalthoff.github.io/jellify-desktop/appcast.xml`. That URL is
baked into every release's Info.plist as `SUFeedURL`, so it must remain
stable. If GitHub Pages ever moves (custom domain, etc.) the `SUFeedURL`
value in `macos/Resources/Info.plist` has to change in lockstep with a
release that redirects older installs.

### First-ever gh-pages bootstrap

The workflow pushes to `gh-pages` on every release, but the branch has
to exist first. Bootstrap once:

```bash
git switch --orphan gh-pages
git commit --allow-empty -m "init gh-pages"
git push -u origin gh-pages
git switch main
```

Then enable Pages in the repo settings: **Settings → Pages → Source:
Deploy from a branch → Branch: gh-pages / (root)**.

## Troubleshooting

- **Sparkle in the built app logs `no such file SUFeedURL`** — the
  Info.plist template in `macos/Resources/Info.plist` wasn't copied
  into the .app by `make-bundle.sh`. Check the bundle step finished
  before `sign.sh` started.
- **`generate_appcast` warns "no private key"** — the
  `SPARKLE_ED25519_PRIVATE` secret is empty or not exported. Confirm
  with `echo -n "$SPARKLE_ED25519_PRIVATE" | wc -c` — expect ~88
  characters (base64-encoded 64-byte private key).
- **Notarization fails with "invalid signing identity"** — the
  Developer ID certificate in the runner's keychain is expired or
  unreachable. Re-export the `.p12` and update `APPLE_DEVELOPER_ID_CERT_P12`.
- **Users report "app can't be opened because Apple cannot check it"** —
  DMG wasn't notarized or the staple wasn't applied. Re-run
  `notarize.sh` locally on the DMG and re-upload to the GitHub release.

## Reference

- Sparkle 2 docs: <https://sparkle-project.org/documentation/>
- Apple notary service: <https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution>
- Issues this doc addresses: #183, #184, #185, #186, #188, #189, #190.

