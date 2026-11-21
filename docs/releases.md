# Signed releases

Purrthrough uses `com.firefungames.purrthrough`, Developer ID signing, the hardened
runtime, Apple notarization and Sparkle 2.8.1 updates from GitHub Releases. It runs
on macOS 15+ on Apple Silicon and Intel.

The release tooling is adapted from CatGuard and keeps its credential handling.

## Prepare without publishing

Requirements: full Xcode, XcodeGen, Python 3, OpenSSL with Ed25519 support, gopass
and access to the Apple credentials on a trusted publisher Mac. Extract the official
[Sparkle 2.8.1](https://github.com/sparkle-project/Sparkle/releases/tag/2.8.1)
distribution outside the repository and verify `Sparkle-2.8.1.tar.xz` against SHA256
`5cddb7695674ef7704268f38eccaee80e3accbf19e61c1689efff5b6116d85be`. The script
independently pins the `sign_update` binary hash.

1. Bump `CFBundleShortVersionString` and the integer `CFBundleVersion` in
   `Config/Purrthrough-Info.plist`. The build number must increase with every release.
2. Run `xcodegen generate` and `swift test`, build the app unsigned as CI does, and
   commit everything, including the generated project and `Package.resolved`.
3. Run `python3 -B scripts/release.py --team <TEAM_ID> --sparkle-tools <dir>
   --output <new dir outside the repo>`. Use `--test` on a clean review branch and
   `--dry-run` for credential-free checks. A real release refuses a dirty tree, a
   non-main branch or a commit that differs from `origin/main`. Test-mode output
   records `test_only: true` and must never be published.

The Apple certificate, private key and notarization key come from the gopass entries
named by the script's defaults. Private keys stay in memory or inside a disposable,
owner-only AES-256 image that is removed afterwards. Temporary files live under
`/Volumes/Kingston/bottemp/workspaces` and are moved to that volume's Trash.

## What the script checks

- Universal (arm64 + x86_64) binaries, with Sparkle's unused XPC services removed.
- Sparkle's Autoupdate, Updater.app and framework are signed first with **no
  entitlements**; the app is signed last with exactly one entitlement,
  `com.apple.security.device.audio-input`. The hardened runtime blocks every audio
  input without it, including Line In. Any other entitlement fails the release.
- Developer ID publisher identity, secure timestamp and hardened runtime on every
  component; no cdhash in the designated requirement, so microphone permission
  survives updates.
- Separate notarization and stapling for the app and the DMG, plus Gatekeeper and
  stapler checks on the exact unpacked update ZIP.

Outputs: stapled `Purrthrough.app`, `Purrthrough-<version>.dmg`,
`Purrthrough-<version>.zip`, `appcast.xml`, the detached `appcast.xml.ed25519`,
notarization receipts and `verification.json`. Nothing is uploaded or installed.

## Update key

The Sparkle Ed25519 private key is the gopass entry
`purrthrough/release/sparkle-eddsa-private-key`; its public half is `SUPublicEDKey` in
the Info.plist. `scripts/sparkle_key.py` created it once and never replaces an
existing key. Back up the encrypted gopass store: losing this key strands every
installed copy on its current version.

## Publish

After review, publish a GitHub release `v<version>` from the exact reviewed main
commit with the DMG, ZIP, `appcast.xml` and `appcast.xml.ed25519` attached. Installed
copies read `https://github.com/oana-ffg/purrthrough/releases/latest/download/appcast.xml`.
Never replace assets of a published version.

## How updates behave

With **Update Automatically** on, Sparkle checks once a day, downloads in the
background, installs immediately and relaunches Purrthrough. Playback pauses for a
second or two and resumes on its own. With it off, nothing is checked until the user
chooses **Check for Updates…**.
