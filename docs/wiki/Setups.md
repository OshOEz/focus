# Setups

How Focus tells your places apart and keeps a separate calibration for each one.

## What a setup is

One calibration set for one place: your desk, the office, a friend's flat. Each setup is a JSON file,
`~/Library/Application Support/Focus/setups/<uuid>.json` (`SetupStore`, `AppPaths.setups`;
`FOCUS_SUPPORT_DIR` overrides the folder for benches). A file that fails to decode is renamed
`<uuid>.json.broken` and skipped; every other setup still loads (`SetupStore.loadAll`).

## How Focus recognises a place

A place is a fingerprint (`Fingerprint`, `Sources/FocusCore/Setup.swift`):

| Part | Source | Notes |
|---|---|---|
| Screens | `DisplayFingerprint`: vendor, model, serial, size, position | Key is `vendor-model-serial`; monitors that report no serial fall back to `vendor-model-@x,y` (position). Two identical monitors that *do* share a non-zero serial still get told apart, by appending position (`DisplayFingerprint.uniqueKeys`). |
| Camera | `AVCaptureDevice.uniqueID` of the camera actually in use (the chosen one if connected, else built-in, else any — `CameraCapture.pick`) | Not the *setting*; if the preferred camera is unplugged, Focus still resolves against whichever one is running. |
| Wi-Fi name | `EnvironmentFingerprinter.wifiSSID()` | Only once Location is allowed (`Permissions.location == .granted`); otherwise `nil`, and Wi-Fi plays no part in matching. |

## When it checks

`SetupController` (`Sources/FocusApp/SetupController.swift`) re-reads the environment and asks
`SetupResolver` to match:

- **Launch**: `AppController.start()` builds the resolver and calls `setups.start()`, which resolves once
  immediately, before the app's first status is computed.
- **Display reconfiguration**: `DisplayProvider.onChange` triggers a re-resolve, but only after 1 s with no
  further change (`environmentMayHaveChanged`'s debounce Task). A screen reconfiguration fires several
  callbacks per change (begin, then one per screen) and positions keep moving for a few hundred ms —
  resolving mid-way would read a half-applied arrangement as a new place.
- **Camera connect/disconnect**: `AVCaptureDevice.wasConnectedNotification`/`wasDisconnectedNotification`,
  observed directly by `SetupController.start()`.
- **Camera changed in Settings**: `AppController.update(_:)` re-resolves whenever `settings.cameraID` changes.
- **Wake**: `SystemStateMonitor.onChange` re-resolves on the way back from sleep/lock/screensaver — Wi-Fi and
  screens often change while the Mac was away. Going *to* sleep instead saves what the engine learned
  (`setups.saveNow()`), not a re-resolve.
- **Wi-Fi name**: polled every 15 s (`SetupController.start()`'s timer) instead of a `CWEventDelegate` — no
  delegate, no queue hop. A Wi-Fi-only move (same screens and camera, different network) is caught within
  15 s; screens and the camera are instant.

## Rules

All in `SetupResolver.apply()`/`SetupMatcher.match` (`Sources/FocusCore/SetupResolver.swift`, `Setup.swift`):

- **One setup matches**: its calibration loads. While the app is already running, a switch also shows a
  "Now using …" notice; the very first match right after launch loads quietly (nothing to announce yet).
- **Several match** (identical screens and camera, ambiguous or unknown Wi-Fi): the one already in use is
  kept if it's still among them (so a flaky Wi-Fi reading never flips the choice), otherwise the first one;
  the menu marks the others "(also fits here)". Picking one while it was merely a candidate teaches it the
  current Wi-Fi name, so the tie breaks by itself next time.
- **None match**: the engine's calibration is emptied (tracking pauses) and "New place detected" is shown —
  once per unmatched place per run, and not at all on the very first run ever (before any setup exists,
  there is nothing to contrast the new place with).
- **A Wi-Fi drop is not a move**: the last known name is kept as long as screens and camera stay the same,
  so losing the network briefly (sleep, roaming) never looks like arriving somewhere else.
- **A manual pick** (Setup ▸, or the switcher notice's "pick another") holds until screens, camera or network
  change — including a Wi-Fi *join* after the pick, which is not itself a move.
- **Picking a setup whose screens and camera already match perfectly**, but whose saved geometry doesn't
  (only resolution, scaling or arrangement moved), adopts the new geometry — so a manual pick under a
  changed layout doesn't get reported as a new place again on every later launch.
- **A new setup carries over** the calibration of any screen that is identical (same fingerprint) to one on
  the previously active setup, when the camera is the same too; unfamiliar screens still need calibrating.
  Recalibrating a screen always replaces its calibration and what was learned for it.
- **What the engine learned from clicks** is written back to the active setup before every switch, and on
  sleep and on quit (`SetupResolver.saveActive`/`SetupController.saveNow`) — never lost by moving on.

## Menu

`SetupController.menuItem()` builds "Setup ▸" (inserted in the status menu right after Recalibrate):

```
Setup: Home                     ▸
    ✓ Home                      ▸   Rename…  ·  Recalibrate…  ·  ──  ·  Delete…
      Office                    ▸   Use This Setup  ·  Rename…  ·  ──  ·  Delete…
      Desk (also fits here)     ▸   …                  ← when the match is ambiguous
    ──
    Calibrate This Place…           ← only when no setup is active and the place was read
    Choose Automatically            ← only while a manual pick is active
```

Renaming refuses a blank name (trimmed first); deleting asks for confirmation and, if the deleted setup was
active, falls back to automatic matching without announcing the place as new again.

## Privacy

Location is used for exactly one value: the current Wi-Fi network name (`CWWiFiClient`). Never your
position, never sent anywhere — like everything else in Focus, matching stays on this Mac. The prompt is
never automatic: only the guide's "Recognise your places" step (`PlacesStep.swift`) can trigger it, from an
explicit button, and Location itself is entirely optional — every rule above still works without it, just
less precisely when two places share the same screens and camera.

## Limits

- Changing resolution, scaling or monitor arrangement reads as a new place until you pick the right setup
  once; after that, Focus recognises the new geometry on its own.
- A Wi-Fi-only move can take up to 15 s to be recognised.
- Identical screens and camera with no Wi-Fi name available (Location off, or both places share a network)
  stay ambiguous until you pick one by hand.
- No export or import, and no per-setup engine settings (dwell, sensitivity, …) — those are global.
- Carrying a calibration over to a new setup assumes you sit the same way relative to the screens it was
  measured for; if you don't, recalibrate that setup instead of relying on the carry-over.

## Code map

- `Sources/FocusCore/SetupResolver.swift`, `Setup.swift`, `SetupStore.swift` — matching, persistence, the
  rules above.
- `Sources/FocusMac/EnvironmentFingerprinter.swift` — reads the live environment (screens, camera, Wi-Fi).
- `Sources/FocusApp/SetupController.swift` — triggers, debouncing, notifications, the Setup ▸ menu, the
  calibration hand-off; `PlacesStep.swift` — the optional onboarding step.
- Tests: `SetupResolverTests`, `SetupTests` (`Tests/FocusCoreTests`).
- Benches: `setups-two-places` (engine group: calibrations follow the place, learned clicks are kept) and
  `setups-fingerprint` (live, read-only; skipped when Location isn't already granted), both in
  `Sources/FocusBench` — see [Benches](Benches.md).
