#!/bin/zsh
# Checks every Mach-O file in an app bundle: the architectures it contains,
# and the macOS version it was linked for, against what the bundle promises.
#
# Usage: check-binary.sh <App.app> [archs]
#   check-binary.sh ~/Applications/Tasks.app                 # any architectures
#   check-binary.sh build/Tasks.app "arm64 x86_64"           # must be universal
#
# Each file is held to the LSMinimumSystemVersion of the nearest app, app
# extension, or XPC service that contains it: an extension runs in its own
# process and can ask for a newer macOS than its app, while a framework loads
# into its host and must run wherever the host runs. A file linked for a newer
# macOS than that is an error: macOS refuses to load it on the older systems
# the bundle claims to support. arm64 slices start at macOS 11, the first
# version for Apple silicon. Swift's back-deployment dylibs (libswift_*.dylib)
# load only on the systems that need them and are skipped.
# Prints PASS or FAIL per file, exits 1 on any FAIL.
set -euo pipefail
app=${1:?usage: check-binary.sh <App.app> [archs]}
app=${app%/}
required=(${=2:-})
[[ -f "$app/Contents/Info.plist" ]] || { echo "FAIL no Info.plist in $app"; exit 1; }

# 1 when version $1 is newer than version $2 (12.0 vs 12, 15.4 vs 15.10).
newer() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    na = split(a, x, "."); nb = split(b, y, "."); n = na > nb ? na : nb
    for (i = 1; i <= n; i++) { if (x[i] + 0 > y[i] + 0) exit 0; if (x[i] + 0 < y[i] + 0) exit 1 }
    exit 1 }'
}

# The LSMinimumSystemVersion of the closest bundle around a file.
minimum_for() {
  local dir=${1:h}
  while [[ "$dir" == "$app"* ]]; do
    if [[ "$dir" == *.app || "$dir" == *.appex || "$dir" == *.xpc ]]; then
      local plist="$dir/Contents/Info.plist"
      if [[ -f "$plist" ]]; then
        local value=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist" 2>/dev/null || true)
        [[ -n "$value" ]] && { echo "$value"; return }
      fi
    fi
    dir=${dir:h}
  done
  /usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist"
}

failed=0
checked=0
while IFS= read -r -d '' file; do
  [[ -L "$file" || ${file:t} == libswift_*.dylib ]] && continue
  file -b "$file" | grep -q 'Mach-O' || continue
  checked=$((checked + 1))
  short=${file#$app/}
  promise=$(minimum_for "$file")
  archs=(${=$(lipo -archs "$file" 2>/dev/null)})
  for want in $required; do
    if (( ! ${archs[(Ie)$want]} )); then
      echo "FAIL $short has no $want slice (has: ${archs[*]})"
      failed=1
    fi
  done
  for arch in $archs; do
    floor=$promise
    [[ $arch == arm64* ]] && newer 11.0 "$promise" && floor=11.0
    linked=$(xcrun vtool -show-build -arch "$arch" "$file" 2>/dev/null | awk '$1 == "minos" { print $2; exit }')
    if [[ -z "$linked" ]]; then
      # Old binaries carry LC_VERSION_MIN_MACOSX instead of LC_BUILD_VERSION.
      linked=$(otool -arch "$arch" -l "$file" 2>/dev/null | awk '/LC_VERSION_MIN_MACOSX/ { f = 1 } f && $1 == "version" { print $2; exit }')
    fi
    if [[ -z "$linked" ]]; then
      echo "FAIL $short ($arch) has no deployment target"
      failed=1
    elif newer "$linked" "$floor"; then
      echo "FAIL $short ($arch) needs macOS $linked, the bundle promises $floor"
      failed=1
    else
      echo "PASS $short ($arch) macOS $linked, promise $floor"
    fi
  done
done < <(find "$app/Contents" -type f -print0)

(( checked > 0 )) || { echo "FAIL no Mach-O files in $app"; exit 1; }
exit $failed
