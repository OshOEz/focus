# Permissions and privacy

What Focus asks macOS for, when, and what it keeps on disk. Short version: two permissions are
required, everything stays on this Mac, and nothing is ever sent anywhere.

## When Focus asks

Only a button in the Setup Guide (`Sources/FocusApp/OnboardingView.swift`) triggers a macOS
permission prompt, and only after the user clicks it. Launch, `--selftest`, `--smoke` and every bench
only *read* statuses (`Permissions.camera`, `.accessibility`, `.location`, all in
`Sources/FocusMac/Permissions.swift`), never request. The guide polls the statuses (the app's 1 Hz tick
plus `didBecomeActive`), so its Permissions page flips to "✓ Allowed" by itself when the user comes
back from System Settings.

The guide opens by itself on first launch (until "Start Using Focus" sets `onboardingCompleted`) and
from the menu bar ("Setup Guide…") at any time.

## Each permission

| Permission | Required | Used for | Asked by |
|---|---|---|---|
| Camera | yes | Head pose and gaze estimation, frame by frame, in memory | "Allow Camera" → `AVCaptureDevice.requestAccess`; if denied, "Open Privacy Settings" |
| Accessibility | yes | Raising and focusing the window or pane you look at, moving the pointer, reading window and pane frames (AX) | "Allow Accessibility" → `AXIsProcessTrustedWithOptions(prompt)` + opens Privacy & Security → Accessibility |
| Notifications | no | "Recalibration suggested" and new-screen notices | the guide's last button, once |
| Location | no | Reading the Wi-Fi name so a Setup can match a place ([Setups](Setups.md)) | the guide's optional "Recognise your places" step (`PlacesStep.swift`), "Allow Wi-Fi Name" |

Accessibility has no "not determined" state: an untrusted app reads as denied, so the guide always
shows the button until the grant lands. Global mouse monitors installed before the grant receive
nothing, so `AppController.refreshPermissions` reinstalls them once it arrives.

## Not needed: Input Monitoring

Focus never reads *which* key you press, so it does not ask for Input Monitoring:

- Typing guards only need *when* the last key went down: `CGEventSource.secondsSinceLastEventType`
  on the HID system state, which reports idle time without any permission.
- Clicks (for learning and the mouse pause) come from an `NSEvent` global monitor for mouse events,
  which is covered by Accessibility. Key events are never monitored.

## What is stored

Everything lives in `~/Library/Application Support/Focus/` (`FOCUS_SUPPORT_DIR` overrides it for
benches):

- `settings.json`: the Settings window's values and a few one-shot flags (`onboardingCompleted`,
  `loginItemDefaultApplied`, `notifiedDisplays`).
- `setups/<uuid>.json`, one per Setup ([Setups](Setups.md)):
  - a fingerprint of the screens (vendor, model, serial or origin), the camera ID, and the Wi-Fi name
    when Location was allowed;
  - per screen, the calibration: median head pose overall and at each dot, the dot positions
    (normalised 0-1 on that screen) with their median gaze input;
  - up to 200 learned click points per screen (`DisplayCalibration.maxLearned`): the normalised
    click position and the gaze input at that moment, with no timestamps and no app or window names;
  - the last 30 click errors, used only to suggest a recalibration.

Recalibrating a screen replaces its calibration and drops what was learned for it.

## What is never stored

- Camera frames: each one is analysed in memory and dropped.
- Key contents: never read in the first place.
- Window titles, app names or screen contents.

## The camera LED

The camera runs only while `AppConditions.wantsCamera` is true (`Sources/FocusCore/AppStatus.swift`):
not paused, not locked or asleep, Camera granted, and either calibrating, or Accessibility granted with
at least one calibrated screen and something to do (not one screen with window focus off). Otherwise
the session is stopped and the green LED is off. A failed camera stays "wanted" so Focus retries every
3 s.

## Network

None. Focus makes no network requests: no analytics, no update checks, no model downloads (the models
ship inside the app).

## Ad-hoc signing ceiling

`scripts/build-app.sh` signs the app with a local self-signed identity (create it once with
`scripts/make-signing-cert.sh`), so Camera and Accessibility grants survive rebuilds. Without it the
signature is ad hoc and changes on every build: macOS then treats a rebuilt Focus as a new app and
silently drops both grants (see Troubleshooting).
