# Sparkle updates

Sparkle 2 lets a downloaded app find, verify, and install its next version.
The app reads an appcast (an RSS file on your web server), downloads the
newest archive it lists, checks its EdDSA signature against a public key
built into the app, and replaces itself. Only the direct build gets
Sparkle. The App Store updates its own copy.

## 1. Pin Sparkle

Fetch one release into a cache folder and check it against a recorded
checksum, so every machine and CI run embeds the same framework and signs
with the same tools:

```bash
sparkle_version=2.9.6
sparkle_sha256=<sha256 of Sparkle-$sparkle_version.tar.xz>
archive=.cache/sparkle/Sparkle-$sparkle_version.tar.xz
mkdir -p .cache/sparkle
[[ -f $archive ]] || curl --fail -sSL -o $archive \
  "https://github.com/sparkle-project/Sparkle/releases/download/$sparkle_version/Sparkle-$sparkle_version.tar.xz"
shasum -a 256 $archive | grep -q $sparkle_sha256 || { echo "Sparkle checksum mismatch"; exit 1; }
tar -xJf $archive -C .cache/sparkle
```

The folder now holds `Sparkle.framework` and `bin/` (`generate_keys`,
`sign_update`, `generate_appcast`). Add `.cache/` to `.gitignore`.

## 2. Make the signing key once

```bash
.cache/sparkle/bin/generate_keys
```

It stores the private key in the login keychain and prints the public
key. The private key never goes in git. Back it up: an app built with
this public key accepts updates signed only by its private half.

## 3. Build it into the app

- Info.plist: `SUFeedURL` (the appcast URL, HTTPS) and `SUPublicEDKey`
  (the printed public key). Add them in the direct build only.
- Link and embed: compile against `-F .cache/sparkle -framework Sparkle`,
  add the rpath `@executable_path/../Frameworks`, and copy
  `Sparkle.framework` into `Contents/Frameworks` with `ditto` (it keeps
  the symlinks).
- Start the updater once, and add a menu item:

  ```swift
  import Sparkle

  @MainActor final class Updates {
      let controller = SPUStandardUpdaterController(
          startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
  }

  // In the app menu, after About:
  Button("Check for Updates…") { updates.controller.checkForUpdates(nil) }
  ```

Check after the build:

```bash
/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' <App>.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' <App>.app/Contents/Info.plist
test -d <App>.app/Contents/Frameworks/Sparkle.framework
```

Put these three checks in CI too, so a direct build without its updater
cannot ship.

## 4. Sign Sparkle as your own code

Sparkle ships signed by its own team. Notarization needs every nested
item signed with your Developer ID and hardened runtime, innermost first:

```text
Sparkle.framework/Versions/B/XPCServices/Installer.xpc
Sparkle.framework/Versions/B/XPCServices/Downloader.xpc
Sparkle.framework/Versions/B/Autoupdate
Sparkle.framework/Versions/B/Updater.app
Sparkle.framework
```

`scripts/notarize.sh` does this for every nested item. Use
`--preserve-metadata=entitlements` if you sign by hand.

## 5. Publish a version

Notarize and staple first (`SKILL.md`, step 4). Then, in this order:

1. Sign the archive and check the signature:

   ```bash
   sig=$(.cache/sparkle/bin/sign_update -p dist/<App>-<version>.dmg)
   .cache/sparkle/bin/sign_update --verify dist/<App>-<version>.dmg "$sig"
   ```

2. Upload the archive. Fetch it back over HTTPS and compare checksums.
3. Add an `<item>` for this version to the appcast with the archive URL,
   `sparkle:version` (`CFBundleVersion`), `sparkle:shortVersionString`,
   `sparkle:edSignature`, `length`, and `sparkle:minimumSystemVersion`
   (the app's floor). `generate_appcast <folder>` writes the whole file
   from a folder of archives, if you keep them all.
4. Upload the appcast last, then read it back and compare:

   ```bash
   curl --fail -sS https://example.com/appcast.xml | cmp -s - appcast.xml && echo "feed matches"
   ```

The order matters. An appcast that names an archive that is not there yet
is the one failure an installed app cannot recover from: it offers an
update that fails for every user.

## 6. Prove it

Install the previous version, then choose Check for Updates. It offers
the new version, installs it, and relaunches with the new
`CFBundleShortVersionString` in About.

## Gotchas from real apps

- `CFBundleVersion` must grow with every release, or Sparkle sees no update.
- Start a new appcast from the live one, not a local copy that may be old,
  so you never drop a version people are on.
- Rotating the key: ship one release signed with the old key that carries
  the new public key, before you sign with the new key.
