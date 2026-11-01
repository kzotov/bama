# Widgets that show live app state

A widget runs in its own process, on WidgetKit's schedule, often while
the app is not running. It cannot ask the app for data. The app writes a
snapshot where the widget can read it, and tells WidgetKit when the
snapshot changed in a way people can see. Every part below comes from a
time-tracking widget that shows the running task and today's total.

A widget is an app extension, so it needs an Xcode or XcodeGen target
(see `new-mac-app`, "When to switch to an Xcode project").

## Contents

- Share data through an App Group
- Write a snapshot, not live objects
- Reload only on visible changes
- Let the widget count time itself
- Say when the app is not running
- Timelines and deployment targets
- Check it

## Share data through an App Group

Add the same App Group to both entitlements files, the app's and the
widget's. On macOS the group name starts with the team ID:

```xml
<key>com.apple.security.application-groups</key>
<array>
    <string>TEAMID.com.yourname.tasks.shared</string>
</array>
```

Both sides open the same suite:

```swift
let shared = UserDefaults(suiteName: "TEAMID.com.yourname.tasks.shared")
```

A typo in either file still builds and signs. The widget then reads an
empty suite and shows its placeholder forever. Check both signed bundles:

```bash
codesign -d --entitlements - <App>.app | grep -A2 application-groups
codesign -d --entitlements - <App>.app/Contents/PlugIns/<Widget>.appex | grep -A2 application-groups
```

## Write a snapshot, not live objects

The app writes one dictionary of plain values (strings, numbers, dates as
seconds) under one key. Include a `schema` number and an `updatedAt`
time:

```swift
shared?.set([
    "schema": 3,
    "updatedAt": Date().timeIntervalSince1970,
    "tracking": true,
    "title": task.title,
    "startedAt": task.started.timeIntervalSince1970,
    "todaySeconds": todaySeconds,
], forKey: "widgetSnapshot")
```

The widget decodes it with a default for every field, and treats a
missing or older `schema` as "open the app once": an update can install a
new widget before the app has written the new shape.

## Reload only on visible changes

`WidgetCenter.shared.reloadTimelines(ofKind:)` asks WidgetKit to run the
provider again. WidgetKit gives each widget a reload budget. An app that
reloads on every write (a menu that refreshes every second, a sync that
writes on each item) burns it, and then the widget stops updating at all
for a while.

Compare the new snapshot with the last one on the keys the widget shows,
and reload only when one of them changed:

```swift
let visibleKeys = ["schema", "tracking", "title", "startedAt", "status"]

func write(_ snapshot: [String: Any]) {
    let previous = shared?.dictionary(forKey: "widgetSnapshot")
    shared?.set(snapshot, forKey: "widgetSnapshot")
    let changed = previous == nil || visibleKeys.contains {
        (previous?[$0] as? NSObject) != (snapshot[$0] as? NSObject)
    }
    if changed { WidgetCenter.shared.reloadTimelines(ofKind: "TrackingWidget") }
}
```

Keep this check in a plain function with a unit test: "a new elapsed
second does not reload, a new task does".

## Let the widget count time itself

A running timer must not reload the widget every second. Store the start
time, and let SwiftUI count:

```swift
Text(Date(timeIntervalSince1970: startedAt), style: .timer)
```

The text ticks on its own with no timeline entries and no reloads.

## Say when the app is not running

When the app quits, the last snapshot still says "tracking", and the
widget shows a timer that stopped hours ago. Write a final snapshot in
`applicationWillTerminate`:

```swift
func applicationWillTerminate(_ notification: Notification) {
    var snapshot = shared?.dictionary(forKey: "widgetSnapshot") ?? [:]
    snapshot["tracking"] = false
    snapshot["status"] = "Tasks is not running"
    snapshot["updatedAt"] = Date().timeIntervalSince1970
    write(snapshot)
}
```

A crash skips this. In the widget, also treat a tracking snapshot with an
old `updatedAt` (more than a few minutes, when the app writes at least
that often) as stale, and say so instead of counting.

## Timelines and deployment targets

- Return one entry and a refresh date for totals that change without an
  app write, such as "today" rolling over at midnight:
  `Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60)))`.
  WidgetKit treats the date as a hint and may run later.
- `placeholder(in:)` and `snapshot(for:in:)` with `context.isPreview` show
  sample data in the widget gallery, never the user's data.
- The extension has its own deployment target. It can be newer than the
  app's (14.0 for a widget in a 12.0 app). Guard newer widget APIs with
  `#available(macOSApplicationExtension 14.0, *)`.
- Desktop widgets and buttons or toggles in widgets need macOS 14. They
  run App Intents.
- Declare the `AppIntent` configuration type internal, not `private` or
  `fileprivate`. A file-private type builds, and WidgetKit then cannot
  create it, so the widget shows no settings.

## Check it

1. Install the app, add the widget to the desktop, start the action the
   widget shows. The widget changes within a few seconds.
2. Log each reload from the app (`Logger(subsystem: bundleID, category:
   "widget").debug("reload")`), and leave the app open for a minute with
   its menu open. `log stream --level debug --predicate 'category == "widget"'`
   prints a line per visible change, not one per second.
3. Quit the app. The widget says the app is not running.

Done when the three checks pass, and the reload check has a unit test.
