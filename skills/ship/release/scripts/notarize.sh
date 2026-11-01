#!/bin/zsh
# Signs an app with Developer ID, notarizes and staples it, then wraps it in
# a signed, notarized, and stapled DMG. Each step is checked before the next.
#
# Usage: notarize.sh <App.app> [out-folder]
#   notarize.sh ~/Applications/Tasks.app dist
#   SIGN_ONLY=1 notarize.sh ~/Applications/Tasks.app   # sign and verify, no upload
#
# Needs: a "Developer ID Application" certificate in the keychain (set
# SIGN_IDENTITY when there is more than one), and a notary profile saved once
# with `xcrun notarytool store-credentials <profile>` (NOTARY_PROFILE,
# default "notary").
set -euo pipefail
app=${1:?usage: notarize.sh <App.app> [out-folder]}
app=${app%/}
out=${2:-dist}
profile=${NOTARY_PROFILE:-notary}
plist="$app/Contents/Info.plist"
name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$plist")
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")

identity=${SIGN_IDENTITY:-}
if [[ -z "$identity" ]]; then
  ids=("${(@f)$(security find-identity -v -p codesigning | sed -En 's/.*"(Developer ID Application:.*)"$/\1/p')}")
  ids=(${ids:#})
  (( ${#ids} == 1 )) || { echo "found ${#ids} Developer ID Application identities: set SIGN_IDENTITY"; exit 1; }
  identity=$ids[1]
fi

echo "== sign with $identity"
# Nested code first, deepest path first: notarization rejects a bundle whose
# inner code carries another team's signature or no hardened runtime. Keep
# each item's entitlements, such as a widget's App Group.
sign() { codesign --force --options runtime --timestamp --preserve-metadata=entitlements --sign "$identity" "$1" }
items=()
while IFS= read -r -d '' item; do
  if [[ -d "$item" ]]; then
    items+=("$item")
  elif file -b "$item" | grep -q 'Mach-O'; then
    [[ "${item:h}" == "$app/Contents/MacOS" ]] || items+=("$item")
  fi
done < <(find "$app/Contents" \( -type d \( -name '*.framework' -o -name '*.xpc' -o -name '*.appex' -o -name '*.app' \) \) -print0 -o \( -type f -perm +111 \) -print0 -o \( -type f -name '*.dylib' \) -print0)
# Deepest first: sort by the number of slashes, most first.
for item in "${(@f)$(for i in $items; do print -r -- "${#${i//[^\/]/}} $i"; done | sort -rn | cut -d' ' -f2-)}"; do
  [[ -n "$item" ]] && sign "$item"
done
sign "$app"

codesign --verify --deep --strict "$app"
details=$(codesign -dvv "$app" 2>&1)
grep -q 'flags=.*runtime' <<< "$details" || { echo "no hardened runtime on $app"; exit 1; }
grep -q "Authority=Developer ID Application" <<< "$details" || { echo "not signed with Developer ID"; exit 1; }
echo "signed: hardened runtime, Developer ID"
[[ -n "${SIGN_ONLY:-}" ]] && exit 0

mkdir -p "$out"
zip="$out/$name-$version-$build-notarize.zip"
dmg="$out/$name-$version.dmg"

echo "== notarize the app"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait --output-format json | tee "$out/notary-app.json"
grep -q '"status" *: *"Accepted"' "$out/notary-app.json" || { echo "notarization failed: xcrun notarytool log <id> --keychain-profile $profile"; exit 1; }
rm -f "$zip"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"

echo "== build, sign, and notarize the DMG"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/${app:t}"
ln -s /Applications "$stage/Applications"
rm -f "$dmg"
hdiutil create -quiet -volname "$name $version" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg"
codesign --sign "$identity" --timestamp "$dmg"
xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait --output-format json | tee "$out/notary-dmg.json"
grep -q '"status" *: *"Accepted"' "$out/notary-dmg.json" || { echo "DMG notarization failed"; exit 1; }
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"

shasum -a 256 "$dmg"
echo "released $dmg"
