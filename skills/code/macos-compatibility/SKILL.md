---
name: macos-compatibility
description: Run a Mac app on macOS versions older than the one you build on, from macOS 12 to 15. Use when the brief names a minimum macOS below 26, when an API needs `@available` or `#available`, or when an app crashes or refuses to open on an older Mac.
---

# macOS compatibility

BAMA's template targets macOS 26. Many people still run 12 to 15, and a
menu bar utility or a work tool often has to reach them. Supporting an
older macOS is three jobs: pick the floor, guard every newer API, and
prove the built binary keeps the promise.

## 1. Pick the floor

The floor is the oldest macOS the app runs on. Pick it from the brief,
then from the newest API the app cannot do without:

| Floor | What you lose below it |
| --- | --- |
| 26 | Liquid Glass (`glassEffect`, `.buttonStyle(.glass)`) |
| 15 | `SCRecordingOutput`, Vision `RecognizeTextRequest`, `WindowDragGesture`, `.windowStyle(.plain)` |
| 14 | SwiftData, `@Observable`, `SettingsLink`, `.inspector`, `onKeyPress`, `SCScreenshotManager`, interactive and desktop widgets |
| 13 | `NavigationSplitView`, `MenuBarExtra`, `Window` scene, `SMAppService`, Swift Charts, App Intents |
| 12 | Nothing: it is the oldest macOS an Apple silicon Mac runs in a VM, so the oldest you can test |

The template uses SwiftData and `@Observable`, so 14 is its lowest floor
without a rewrite. For 12 or 13, use `ObservableObject` with
`@Published`, store data in files or Core Data, and use `NavigationView`.

Write the floor in two places, and keep them equal:

```swift
// Package.swift
platforms: [.macOS(.v14)],
```

```xml
<!-- Info.plist.in -->
<key>LSMinimumSystemVersion</key><string>14.0</string>
```

In an Xcode or XcodeGen project the first one is
`MACOSX_DEPLOYMENT_TARGET`. An app extension (a widget) has its own
deployment target and Info.plist, and may need a higher floor than the
app.

The floor is set when `swift build` succeeds with no "is only available
in macOS" errors.

## 2. Guard every newer API

The compiler flags each call that is newer than the floor. Fix each one
with a check and a fallback that still works:

```swift
// One call
if #available(macOS 15, *) {
    window.toolbarBackgroundVisibility = .hidden
}

// A whole type or function
@available(macOS 14, *)
struct InspectorPane: View { ... }
```

In SwiftUI, wrap a modifier so the view body stays one expression:

```swift
extension View {
    @ViewBuilder func glassIfAvailable() -> some View {
        if #available(macOS 26, *) {
            glassEffect()
        } else {
            background(.regularMaterial, in: .capsule)
        }
    }
}
```

The fallback is a real feature, not an empty branch. Launch at login is a
good example: `SMAppService.mainApp.register()` on 13 and later, and
`SMLoginItemSetEnabled` with a helper app on 12. In an app extension, the
check is `#available(macOSApplicationExtension 14.0, *)`.

Frameworks newer than the floor are weak linked by the compiler, so an
unguarded call crashes with "symbol not found" only on the old Mac. That
is why the compiler errors matter: do not silence them with a higher
`@available` on the caller unless the caller is also guarded.

This step is done when the app builds with no availability errors and no
`@available` covers more than it needs.

## 3. Prove the binary keeps the promise

A dependency, a prebuilt framework, or a wrong build setting can link a
binary for a newer macOS than `LSMinimumSystemVersion` says. macOS then
refuses to open the app on the older systems, with a "You can't use this
version" alert. Read the linked version of every slice:

```bash
app=~/Applications/<AppName>.app
bin="$app/Contents/MacOS/<AppName>"
/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist"
for arch in $(lipo -archs "$bin"); do
  xcrun vtool -show-build -arch "$arch" "$bin" | awk -v a=$arch '$1 == "minos" { print a, $2 }'
done
```

Each `minos` must be at or below `LSMinimumSystemVersion`. An arm64 slice
never goes below 11.0, the first macOS for Apple silicon. Check the
frameworks and extensions inside the bundle the same way. A framework runs
inside its app, so it gets the app's floor. An extension gets its own.

Then run the app on the floor itself. On Apple silicon, a macOS VM (UTM,
or Apple's Virtualization framework) runs macOS 12 and later. Open every
page and the Settings window there once before a release.

## Gotchas from real apps

- `Package.swift` says 14, Info.plist says 13. The build succeeds, the App
  Store and Finder offer the app on 13, and macOS 13 refuses to open it.
  Step 3 catches this.
- A Swift `@objc` shim lets Objective-C code reach a Swift-only API such
  as `WidgetCenter`. Mark it `@available` too, or call it behind a check.
- The SDK you build with sets new defaults even on old systems. Look at
  the app on the floor, not only on your Mac.
- Intel Macs stopped at macOS 26. An older floor is when a universal
  build (arm64 and x86_64) matters most.

Done when the floor is written in both places, the app builds with no
availability errors, every slice's `minos` is at or below the floor, and
the app opened on the floor in a VM or on a real Mac.
