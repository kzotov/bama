---
name: release
description: Ship a Mac app outside the App Store, from Developer ID signing and hardened runtime to notarization, stapling, a DMG, Gatekeeper checks, and a Sparkle update feed. Use when the user wants to share the app with other people, make a download, publish a version, or add automatic updates.
---

# Release

The template signs for your own Mac. Anyone else gets "Apple could not
verify this app is free of malware" until the app is signed with
Developer ID, notarized by Apple, and stapled. This skill turns an
installed build into a DMG that opens cleanly on a Mac that has never
seen it, then keeps installed copies up to date.

## Before the first release

These are one-time steps the user does. Check each, and ask the user for
the ones that are missing:

1. A paid Apple Developer membership, and a "Developer ID Application"
   certificate (Xcode > Settings > Accounts > Manage Certificates > +).
   Check: `security find-identity -v -p codesigning | grep "Developer ID Application"`.
2. A notary profile in the keychain. The user runs this once, with an
   app-specific password from account.apple.com:

   ```bash
   xcrun notarytool store-credentials notary --apple-id <email> --team-id <TEAMID>
   ```

   Check: `xcrun notarytool history --keychain-profile notary` prints a table.
3. A version in `Info.plist.in`: `CFBundleShortVersionString` is what
   people see (1.2.0), and `CFBundleVersion` must grow with every release.
   Sparkle and the App Store compare `CFBundleVersion`.

## Steps

1. Build the release, universal unless the brief says Apple silicon only,
   and check every binary (`build-and-verify` skill):

   ```bash
   ./build.sh --universal
   ```

2. Sign with Developer ID and check it, with no upload yet:

   ```bash
   SIGN_ONLY=1 "${CLAUDE_SKILL_DIR}/scripts/notarize.sh" ~/Applications/<AppName>.app
   # signed: hardened runtime, Developer ID
   ```

   The script signs nested code first (frameworks, XPC services, app
   extensions, helper tools), deepest first, each with hardened runtime and
   a secure timestamp, keeping its entitlements. Notarization rejects a
   bundle with any inner item signed by another team or without hardened
   runtime.

3. Run the app once from that path. Hardened runtime blocks things that
   worked before: loading unsigned plug-ins, JIT, Apple Events to other
   apps, the microphone and camera. Each needs an entitlement in the
   app's `.entitlements` file (`com.apple.security.automation.apple-events`,
   `com.apple.security.device.audio-input`, and so on) and a usage string
   in Info.plist.

4. Notarize, staple, and build the DMG:

   ```bash
   "${CLAUDE_SKILL_DIR}/scripts/notarize.sh" ~/Applications/<AppName>.app dist
   # released dist/<AppName>-<version>.dmg
   ```

   It notarizes and staples the app, checks it with
   `spctl --assess --type execute`, then puts it in a DMG next to an
   Applications link, signs, notarizes, and staples the DMG, and checks it
   with `spctl --assess --type open --context context:primary-signature`.
   Stapling puts the ticket in the file, so Gatekeeper accepts it offline.

   On "Invalid", read Apple's log:
   `xcrun notarytool log <submission-id> --keychain-profile notary`. It
   names each file and the reason.

5. Prove it on a clean Mac. Download the DMG through a browser (that sets
   the quarantine flag), or set it by hand, then open it:

   ```bash
   xattr -w com.apple.quarantine "0081;$(printf %x $(date +%s));Safari;" dist/<AppName>-<version>.dmg
   open dist/<AppName>-<version>.dmg
   ```

   The app opens with the usual "downloaded from the Internet" prompt and
   no malware warning.

6. For automatic updates, follow [sparkle.md](sparkle.md).

## Two builds, two entitlement files

An app sold in the Mac App Store and also offered as a download needs two
builds. The App Store build is sandboxed, has no Sparkle (the store
updates it), and is signed for the store. The direct build has Sparkle and
Developer ID. Keep one entitlements file for each (`<App>-AppStore.entitlements`,
`<App>-Direct.entitlements`) and pick it in the build script, so a store
build can never ship an updater.

## Gotchas from real apps

- `codesign --deep` is for checking, not signing: it signs nested code
  with the outer entitlements. Sign each item on its own, as the script does.
- A widget or other extension needs its own entitlements file, including
  the App Group, when it is re-signed.
- An ad hoc signature changes with every build, so keychain items and
  privacy grants (Accessibility, Screen Recording) ask again. A stable
  certificate keeps them.
- Notarization takes from one minute to an hour. `--wait` blocks until it
  is done. Run the script in the background.

Done when `notarize.sh` printed `released`, both `spctl` checks said
`accepted`, and the quarantined DMG opened the app with no malware
warning.
