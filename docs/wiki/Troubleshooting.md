# Troubleshooting

## Status line → cause → fix

The first line of the menu bar eye's menu is `AppStatus.title` (`Sources/FocusCore/AppStatus.swift`). The
first matching row wins, top to bottom.

| Status line | Cause | Fix |
|---|---|---|
| Paused | You paused Focus (menu or pause shortcut). | "Resume Focus" or the shortcut. |
| Paused while the Mac is locked or asleep | Screen locked, asleep, screensaver, or another user's session. The camera is off. | Unlock; tracking resumes by itself. |
| Waiting for camera access | Camera permission not granted. | Setup Guide → permissions step, or Privacy & Security → Camera. |
| Can't reach the camera | The camera failed to start or its stream ended (unplugged, used by another app). Focus retries every 3 s. | Plug it back, close the app holding it, or pick another camera in Settings. |
| Calibrating… | A calibration is running. | Finish it (Space) or cancel (Esc). |
| Waiting for Accessibility access | Accessibility permission not granted: Focus can't move the keyboard focus. | Setup Guide → permissions step, or Privacy & Security → Accessibility. |
| No screen calibrated yet | No connected display has a calibration. | Menu → Recalibrate → All Screens…. |
| One screen: switch on window and pane following in Settings | One display and window focus off: nothing to do, so the camera stays off. | Settings → "Follow my eyes between windows and panes". |
| Waiting to see your face… | No usable face in the last second. | Face the camera, check the lighting, uncover the lens. |
| \<screen\> may need a new calibration | Your clicks keep landing on another screen than the one Focus predicted (drift). | Menu → Recalibrate → that screen. |
| Active · on \<screen\> / Active · looking away | Working normally. | — |

## Permissions lost after rebuilding

A locally built Focus.app is signed ad hoc, so each rebuild is a new app to macOS and the old grants no longer
match. Either remove Focus from Privacy & Security → Camera and → Accessibility and add it back, or reset them:

```sh
tccutil reset Camera fr.osho.focus
tccutil reset Accessibility fr.osho.focus
```

Then open the Setup Guide (menu → "Setup Guide…") and grant both again.

## Notifications don't appear

Focus asks for notification permission once, from the Setup Guide's last button, never at launch. If
notifications are not allowed (or were never asked), nothing is lost: each notice shows up in the menu as a
"⚠︎ …" item right under the status line, and the eye gets a warning badge until you click it (which starts
the matching calibration) or it stops applying. To get real notifications, allow Focus in System Settings →
Notifications.

## "That shortcut is taken by another app."

Another app registered the same combination system-wide. The old shortcut stays in place; record a different
one (it needs ⌘, ⌥ or ⌃).

## The login item needs approval

"Approve Focus in System Settings → General → Login Items." means macOS registered Focus but waits for you
to allow it there. Focus never re-enables a login item you switched off in System Settings.

## Calibration errors

- **No face in view**: the camera didn't see a usable face during a dot. Light your face, uncover the camera,
  then Space redoes that screen.
- **The camera couldn't tell these screens apart**: two screens gave nearly the same head pose, usually
  because only the eyes moved. Turn your head towards each screen and press Space to start over.

## Focus lands on the wrong screen

Recalibrate from your usual seat (menu → Recalibrate → All Screens…). If it still flips near the border,
raise Settings → "Turn needed to switch" so a screen takes over only after a clearer head turn.

## Self-test

```sh
build/Focus.app/Contents/MacOS/Focus --selftest
```

Prints one JSON object and exits 0 when healthy. It opens no window, no camera and asks for no permission.

| Key | Meaning |
|---|---|
| `models` | `ok`, or the error loading the CoreML models (run `scripts/fetch-models.sh`, rebuild). |
| `camera`, `accessibility`, `location` | Permission status as read (never requested). |
| `displays` | Each display's key and CG frame `[x, y, w, h]`. |
| `windows` | How many windows the window list returned. |
| `decision` | The engine's answer to a steady gaze on the first display; must be that display. |
| `ok` | `true` when models load and the decision is right. |

## Where the files live

`~/Library/Application Support/Focus/`:

- `settings.json`: every setting.
- `setups/*.json`: calibrations and what Focus learned from your clicks.

A `settings.json.broken` (or `setups/<id>.json.broken`) means that file couldn't be read. Focus set it aside,
started with defaults, and kept the file for inspection; delete it once you no longer need it.

## Permissions vanish after a rebuild

`scripts/build-app.sh` signs ad-hoc when no local identity exists, and macOS ties Camera and
Accessibility to that signature, so every rebuild loses them. Run `scripts/make-signing-cert.sh`
once (self-signed, login keychain, this Mac only), then `tccutil reset Camera fr.osho.focus` and
`tccutil reset Accessibility fr.osho.focus`, rebuild and grant once more; later rebuilds keep them.
