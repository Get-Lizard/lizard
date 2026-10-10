# Releasing Lizard

Releases are built by GitHub Actions (`.github/workflows/release.yml`) on a `v*` tag:
build → sign with **Developer ID** (hardened runtime) → **notarize** with Apple → staple → DMG on GitHub Releases →
update the **Homebrew cask** in the tap repo. Users install with:

```sh
brew install --cask vitoraguila/tap/lizard
```

## One-time setup

### 1. Repositories
- This repo (e.g. `vitoraguila/lizard`).
- A tap repo named **`homebrew-tap`** (`vitoraguila/homebrew-tap`). Homebrew finds `vitoraguila/tap` → `github.com/vitoraguila/homebrew-tap`.
  It can start empty; the workflow creates `Casks/lizard.rb`. To use another name, set the repo variable
  `HOMEBREW_TAP_REPO` (Settings › Secrets and variables › Actions › Variables).

### 2. Secrets (Settings › Secrets and variables › Actions › Secrets)

| Secret | What | How to get it |
|---|---|---|
| `DEVELOPER_ID_CERTIFICATE_P12` | Your **Developer ID Application** certificate + private key, base64 | Keychain Access › My Certificates › *Developer ID Application: Vitor Hugo Aguila Oliveira (6H728M7XQK)* › Export… (.p12, set a password) → `base64 -i DeveloperID.p12 \| pbcopy` |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | The password you set on the .p12 | |
| `APPLE_TEAM_ID` | `6H728M7XQK` | |
| `NOTARY_KEY_P8` | App Store Connect API key, base64 | App Store Connect › Users and Access › Integrations › App Store Connect API › Team Keys › **+** (role *Developer*) → download `AuthKey_XXXX.p8` → `base64 -i AuthKey_XXXX.p8 \| pbcopy` |
| `NOTARY_KEY_ID` | The key's ID (`XXXX`) | same page |
| `NOTARY_ISSUER_ID` | The Issuer ID (a UUID) | top of the same page |
| `HOMEBREW_TAP_TOKEN` | Fine-grained token that can push to the tap | GitHub › Settings › Developer settings › Fine-grained tokens › repository access: `homebrew-tap` › Contents: Read and write |

## Releasing

```sh
git tag v0.2.0 && git push origin v0.2.0
```
(or run the workflow manually with a version). It takes ~15–25 minutes, most of it Apple's notarization.

## Releasing from your Mac

```sh
xcrun notarytool store-credentials lizard --key AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer-id>   # once
VERSION=0.2.0 NOTARY_PROFILE=lizard scripts/release.sh      # → build/Lizard-0.2.0.dmg (signed, notarized, stapled)
VERSION=0.2.0 SKIP_NOTARIZE=1 scripts/release.sh            # signed only, for testing
```

## Notes
- The app must be signed with **Developer ID** and **notarized**, or macOS blocks it for anyone who downloads it
  (Homebrew no longer lets users skip Gatekeeper). The *Apple Development* certificate used for local builds can't be
  used for distribution.
- `scripts/release.sh` re-signs Mach-O files that are copied in as resources (esbuild's binary inside the extension
  runtime); notarization rejects any unsigned or non-hardened binary in the bundle.
- Hardened runtime is on in `project.yml`; entitlements are in `App/Lizard.entitlements` (Apple events only — no JIT
  or library-validation exceptions are needed: MLX uses Metal, Node runs as a separate process).
