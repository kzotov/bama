#!/bin/zsh
# Builds __APP_NAME__ and installs it to ~/Applications/__APP_NAME__.app.
# Build products live in ~/Library/Developer/__APP_NAME__, outside the repo
# (and outside Dropbox or iCloud, which would try to sync them).
#
# Usage: ./build.sh            release build, install
#        ./build.sh --debug    debug build, install
#        ./build.sh --open     install, then quit the running copy and open the new one
#        ./build.sh --universal  one binary for Apple silicon and Intel (release builds)
set -euo pipefail
here=${0:A:h}
name="__APP_NAME__"
scratch="$HOME/Library/Developer/$name/build"
config=release
[[ " $* " == *" --debug "* ]] && config=debug
arch_flags=()
archs=""
if [[ " $* " == *" --universal "* ]]; then
  arch_flags=(--arch arm64 --arch x86_64)
  archs="arm64 x86_64"
fi

# Sign with your Apple Development certificate when you have one (Xcode >
# Settings > Accounts). Otherwise sign ad hoc, which is fine for your own Mac.
identity="${SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 -o '"Apple Development: [^"]*"' | tr -d '"' || true)
fi
[[ -n "$identity" ]] || identity=-

build=(swift build -c $config --package-path "$here" --scratch-path "$scratch" $arch_flags)
$build 2>&1 | grep -E "error|warning|Build complete" | grep -v "^\[" || true
# The output folder depends on the architectures and the SwiftPM version. Ask.
bin="$($build --show-bin-path)/$name"
[[ -x "$bin" ]] || { echo "build failed"; exit 1; }
# swift build can report success while an edited file failed to compile. Catch that.
stale=$(find "$here/Sources" -name '*.swift' -newer "$bin" | head -1)
if [[ -n "$stale" ]]; then
  echo "build failed: binary is older than $stale"
  $build 2>&1 | grep -E "error" | head -20
  exit 1
fi

app="$HOME/Applications/$name.app"
mkdir -p "$HOME/Applications"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/$name"
sed -e "s/__BUILD__/$(date +%Y%m%d%H%M)/" "$here/Info.plist.in" > "$app/Contents/Info.plist"
# The icon: Icon/AppIcon.icon -> Resources/Assets.car + AppIcon.icns, rebuilt when it changed.
if [[ -d "$here/Icon/AppIcon.icon" ]]; then
  car="$here/Resources/Assets.car"
  if [[ ! -f "$car" || -n "$(find "$here/Icon/AppIcon.icon" -newer "$car" | head -1)" ]]; then
    "$here/tools/make_icon.sh"
  fi
  cp -X "$car" "$here/Resources/AppIcon.icns" "$app/Contents/Resources/"
fi
xattr -cr "$app"
codesign --force --sign "$identity" "$app" 2>&1 | grep -v "replacing existing signature" || true
# Every binary must run on the macOS that Info.plist promises, with every
# architecture asked for.
if ! check=$("$here/tools/check-binary.sh" "$app" "$archs"); then
  print -r -- "$check" | grep -v '^PASS'
  echo "build failed: binary check"
  exit 1
fi
echo "installed $app (signed: ${identity}${archs:+, $archs})"

if [[ " $* " == *" --open "* ]]; then
  osascript -e "quit app \"$name\"" 2>/dev/null || true
  sleep 0.5
  open "$app"
fi
