# GitHub Actions — secrets checklist

Every secret referenced by `.github/workflows/*.yml`. Fill in each value,
then run the matching `gh secret set` command to add it to the repo.

See `.env.example` for the local-dev counterpart of these values.

---

## E2E testing

Target: [`.github/workflows/e2e.yml`](../.github/workflows/e2e.yml). Runs on every push to `main` / nightly cron against the **live `music.skalthoff.com` test instance** using the read-only `test` account.

**No secret needed.** The test server URL and `test` / `test` credentials are baked into the workflow env block. The account is read-isolated — favorites and played-flags it writes are scoped to the user and don't pollute production data. If the server is unreachable, the workflow fails fast (<20s) at the healthcheck step.

If you run your own Jellyfin behind Cloudflare Access, `core/src/client.rs::cf_access_headers` will auto-attach `CF-Access-Client-Id` and `CF-Access-Client-Secret` to every outbound request when both env vars are set. The shared CI test server doesn't need this any more (it's no longer proxied through Cloudflare), but the helper stays for users who do.

---

## macOS release pipeline

Target: [`.github/workflows/macos-release.yml`](../.github/workflows/macos-release.yml). Only fires on `v*` tag push.

### Apple Developer ID signing

| Secret | What it is | How to get it |
|---|---|---|
| `APPLE_DEVELOPER_ID_CERT_P12` | Base64-encoded `.p12` file of the Developer ID Application certificate (private key included). | Keychain Access → right-click cert → Export → save as `.p12` → `base64 -i DeveloperID.p12 \| pbcopy`. |
| `APPLE_DEVELOPER_ID_CERT_P12_PASSWORD` | Password you set when exporting the `.p12`. | Same export dialog. |
| `APPLE_DEVELOPER_ID_IDENTITY` | The full identity string `codesign` uses. | `security find-identity -v -p codesigning` → copy the line between the quotes, e.g. `Developer ID Application: Your Name (TEAMID)`. |
| `APPLE_TEAM_ID` | 10-character team identifier. | [developer.apple.com/account](https://developer.apple.com/account) → Membership. Also embedded in the identity above. |

```bash
# Cert + password
base64 -i /path/to/DeveloperID.p12 | gh secret set APPLE_DEVELOPER_ID_CERT_P12
gh secret set APPLE_DEVELOPER_ID_CERT_P12_PASSWORD

# Identity + team ID
gh secret set APPLE_DEVELOPER_ID_IDENTITY
gh secret set APPLE_TEAM_ID
```

### Notarization

| Secret | What it is | How to get it |
|---|---|---|
| `APPLE_ID` | Your Apple ID email. | The account you used to enroll in the Developer Program. |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for `notarytool`. | [appleid.apple.com](https://appleid.apple.com) → Sign-In and Security → App-Specific Passwords → generate one labeled `lyrebird-notary`. |
| `APPLE_NOTARY_PROFILE` | Name of the keychain profile `notarize.sh` looks up. | Default: `lyrebird-notary`. Only override if you want a different profile name on CI. |

```bash
gh secret set APPLE_ID
gh secret set APPLE_APP_SPECIFIC_PASSWORD
gh secret set APPLE_NOTARY_PROFILE   # optional; value = "lyrebird-notary" unless you want something else
```

### Sparkle auto-update signing

| Secret | What it is | How to get it |
|---|---|---|
| `SPARKLE_ED25519_PRIVATE` | Private EdDSA key that signs release DMGs for the appcast. | Run `./Sparkle/bin/generate_keys` once (or locate the existing one in your login keychain under `https://sparkle-project.org` → "Sparkle signing key"); export it as a single-line string. |
| `SPARKLE_PUBLIC_ED_KEY` | Corresponding public key. | Paired output from `generate_keys`, or `./Sparkle/bin/generate_keys -p` to print the public half. |

```bash
gh secret set SPARKLE_ED25519_PRIVATE
gh secret set SPARKLE_PUBLIC_ED_KEY
```

---

## Coverage reporting

Target: [`.github/workflows/coverage.yml`](../.github/workflows/coverage.yml).

| Secret | What it is | How to get it |
|---|---|---|
| `CODECOV_TOKEN` | Upload token for codecov.io. | Sign in at [codecov.io](https://app.codecov.io) → add this repo → copy the repository upload token. |

```bash
gh secret set CODECOV_TOKEN
```

---

## Provided automatically by GitHub

No action needed — these are always available to workflows:

- `GITHUB_TOKEN` — used by `security.yml`. Scoped per run, expires after the job.

---

## Quick-fire: set every required secret in one shot

After you have the values in hand, paste into a fresh terminal:

```bash
gh secret set APPLE_DEVELOPER_ID_CERT_P12 < <(base64 -i /path/to/DeveloperID.p12)
gh secret set APPLE_DEVELOPER_ID_CERT_P12_PASSWORD
gh secret set APPLE_DEVELOPER_ID_IDENTITY
gh secret set APPLE_TEAM_ID
gh secret set APPLE_ID
gh secret set APPLE_APP_SPECIFIC_PASSWORD
gh secret set APPLE_NOTARY_PROFILE
gh secret set SPARKLE_ED25519_PRIVATE
gh secret set SPARKLE_PUBLIC_ED_KEY
gh secret set CODECOV_TOKEN
```

Verify afterwards:

```bash
gh secret list
```

---

## What's NOT a secret

Plain workflow env vars — these live in the YAML, not in secrets:

- `CARGO_TERM_COLOR`, `CARGO_INCREMENTAL`, `RUST_BACKTRACE`, `RUSTDOCFLAGS` — Rust build knobs.
- `JELLIFY_E2E_URL`, `JELLIFY_E2E_USER`, `JELLIFY_E2E_PASS` — live `music.skalthoff.com` test-account coordinates baked into `e2e.yml`; not secrets (the `test` account is read-only and isolated).
- `JELLIFY_UNIVERSAL`, `JELLIFY_BUILD_CONFIG`, `JELLIFY_VERSION`, `JELLIFY_BUILD` — release build flags injected by `macos-release.yml`.
- `RELEASE_TAG` — derived from the tag push in the release workflow.
