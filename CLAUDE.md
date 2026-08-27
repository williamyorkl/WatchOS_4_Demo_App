# Project Memory — Hang Tracker (watchOS + iOS)

This file is loaded automatically at the start of every session. It captures
hard-won workflow knowledge so mistakes aren't repeated.

## Project structure

- `FirstWatchApp WatchKit Extension/` — watchOS app (SwiftUI). Target watchOS 9.
- `FirstWatchApp/` — iOS app (SwiftUI `@main`, replaces old UIKit storyboard).
  Target iOS 14 (SwiftUI App lifecycle needs ≥14; Swift Charts/`Canvas` need 16
  so they are NOT used — Path/Shape hand-drawing + `drawingGroup()` instead).
- `Shared/` — pure-`Foundation`/`SwiftUI` code compiled into BOTH the watch
  extension AND the iOS target AND the test target: `TrackerLogic.swift`,
  `MotionStateMachine.swift`, `HangSession.swift`, `HangSessionStore.swift`,
  `HangStats.swift`, `HangGrowth.swift`, `HangConnectivity.swift`, `HangTheme.swift`.
- `FirstWatchAppTests/` — unit tests, hosted by the iOS target, run on iOS
  Simulator. Currently **124+ tests, must stay green**.

## MANDATORY: run real-device/simulator UI after any UI change

**Do NOT ship UI changes based only on `xcodebuild build` success.** A clean
build says nothing about whether the UI looks/works right. After changing any
view, ALWAYS:

1. Build to a fixed derivedData path:
   `xcodebuild build -scheme FirstWatchApp -destination 'platform=iOS Simulator,name=iPhone 15' -derivedDataPath /tmp/hangdd`
2. Install + launch into the booted simulator:
   `xcrun simctl install booted /tmp/hangdd/Build/Products/Debug-iphonesimulator/FirstWatchApp.app`
   `xcrun simctl launch booted williamyorkl.pull-up-your-spine`
3. Drive the UI with **idb** (installed below) — tap, scroll, screenshot — and
   LOOK at the screenshots yourself before declaring done. See "idb workflow".

This closes the loop that was broken for many rounds: code was "building" but
the actual rendered UI had gaps, wrong colours, jumping layout, etc. Only a
real screenshot catches those.

## idb workflow (Facebook IDB — the chosen UI-automation tool)

Installed via `brew tap facebook/fb && brew install idb-companion` + `pip3 install fb-idb`.
Chosen over Maestro (iOS sim silent-hang bug on macOS 15.6, GitHub #2628) and
XCUITest (needs a UI test target I can't reliably add to pbxproj). idb is pure
CLI: tap/swipe/screenshot/record, no test target required.

### One-time per session: start the companion

```bash
UDID=$(xcrun simctl list devices booted -j | python3 -c "import sys,json; d=json.load(sys.stdin); print(next(v[0]['udid'] for v in d['devices'].values() if v))")
idb_companion --udid "$UDID" >/tmp/idb_companion.log 2>&1 &
sleep 4
PORT=$(grep -oE '"grpc_port":[0-9]+' /tmp/idb_companion.log | grep -oE '[0-9]+')
idb connect 127.0.0.1 $PORT
```

### Drive the UI

```bash
idb screenshot --udid $UDID /tmp/shot.png      # capture
idb ui tap --udid $UDID <x> <y>                  # tap (points, origin top-left)
idb ui swipe --udid $UDID <x1> <y1> <x2> <y2>    # swipe/scroll
```

iPhone 15 logical points: 393×852. Tab bar bottom ~y=810; tabs at x≈65/196/327.
Screenshot every step and READ the image — don't assume the tap landed.

### Capturing animations (idb record is unreliable)

`idb record video` blocks and only flushes the mp4 on graceful exit — `kill`
drops the file. Instead, **rapid-screenshot** to capture an animation as a
sequence of stills:
```bash
idb ui tap --udid $UDID <x> <y>
for i in $(seq 1 8); do idb screenshot --udid $UDID /tmp/seq_$i.png; sleep 0.18; done
```
Then read several frames to see how the animation progresses (file-size
changes between frames confirm motion is happening).

### DEBUG launch args (auto-load demo + jump to a tab)

`RootTabView` honours `-loadDemo "<span>"` and `-goGarden` in DEBUG:
```bash
xcrun simctl launch booted williamyorkl.pull-up-your-spine -loadDemo "1 year" -goGarden
```
Spans: "3 weeks" / "1 year" / "2 years". Use this to screenshot any state
without manual tapping.

## Ant Forest reference assets (already integrated)

The open-source Ant Forest repo (https://github.com/happy888888/Ant-Forest) was
mined for real sprites. Already cropped into `Assets.xcassets`:
- `EnergyOrb` — the official water-drop bubble-full sprite (from
  `tileset-bubble.png`, frame x=10 y=346 148×148). Used by `EnergyOrbView`.
- `Ripple` — the official ripple sprite (from `tileset-common.png`). Used for
  the collect ripple rings.

NOTE: Ant Forest's TREE sprites are NOT in the repo — trees are loaded remotely
per-user from `gw.alipayobjects.com` at runtime. The tree is hand-drawn with
Bézier `Path` in `PlantIconView.swift`. For truly fluid growth animation, the
next step is Lottie (needs the user to add `airbnb/lottie-ios` via SPM in Xcode,
which I can't do from text).

## Known pitfalls (don't repeat)

- **iOS 14 ceiling**: `NavigationStack`, `.foregroundStyle`, `.tint`,
  `Button(role:)`, `.buttonStyle(.bordered)`, `Canvas`, `TimelineView`,
  `.overlay(alignment:content:)`, `.symbolEffect` are all iOS 15+/16+/17+. Use
  the iOS 14 equivalents (NavigationView, .foregroundColor, .accentColor, plain
  Buttons + background, Path/Shape, onAppear timer, ZStack). Always grep new
  code for these.
- **Tuple not Hashable** in `ForEach(_, id: \.self)`: use a `struct: Hashable`.
- **pbxproj edits**: validate with `plutil -lint` after every edit. Use the
  `7C82FB###30000001005C0E74` UUID namespace for new Shared/iOS files.
- **`@StateObject` requires the type to conform to `ObservableObject`** — a
  plain class injected via `@StateObject` won't compile.
- **Shared files must be added to 3 Sources phases** (iOS + watch + test) for
  the test target to see them via `@testable import FirstWatchApp`. But the
  test target itself should NOT compile shared logic files directly (it gets
  them through the host) — only test files go in the test Sources phase.
- **`withAnimation { }` closure must return Void`** — wrap `@discardableResult`
  calls in `_ = foo()`.
- **Energy-collector 72h boundary**: `now.timeIntervalSince(date) <= expiry` —
  at exactly 72h floating error can flip it; tests use `expiry - 60s`.
