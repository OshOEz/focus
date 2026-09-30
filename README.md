# Focus

**Keyboard focus lands where you look.** Focus lives in the menu bar and runs quietly on macOS. Through your
Mac's camera it works out which display, window or split pane has your attention, and hands that one the
keyboard before your first key press. The click you used to make first is gone.

## The problem

With two or three displays, your eyes move faster than your keyboard focus. You look at the terminal on the
left, start typing, and the text goes into the chat window on the right, because that is where you last
clicked. Every switch costs a click, and every forgotten click costs a mistyped command.

## How it works

1. **Watch.** A frame comes in from the camera, gets turned into head direction, eye position and a gaze
   point, and is gone — nothing about that computation ever touches disk or leaves the machine.
2. **Decide.** A short calibration taught Focus where each display sits from your chair. Once you have been
   facing another display, window or pane for about 300 ms, Focus takes it as intent.
3. **Focus.** Landing on that display, Focus raises whichever window your gaze map is confident you're
   reading; without that confidence yet, it falls back to whichever window you had open there most recently,
   so the keyboard is never left on nothing mid-switch. The pointer follows. Inside one display, the same
   two-step pick decides between windows and split panes.

## Features

- **Every display, any layout** — a laptop's built-in screen mixed in with external monitors, two screens
  stacked above each other, or several side by side: Focus doesn't assume a shape, because each display gets
  its own independent head-pose calibration. The pointer follows the focus across, so a window you open next
  lands where you're already looking.
- **Windows and split panes** — on every display, even when you only have one. Split panes work in these
  terminals and editors: iTerm2, Terminal, Ghostty, Warp, kitty, WezTerm, Hyper, VS Code (and Insiders), Cursor,
  Windsurf, VSCodium, Zed, Sublime Text, Xcode, JetBrains IDEs, Android Studio and Xirp. Every other app,
  browsers and chat included, is focused one whole window at a time.
- **Calm by design** — while you type, turning to another display still switches, after roughly one
  second, but reading a neighbouring window or pane waits 3 s (adjustable, 1–10 s). Any touch of the mouse
  or trackpad — move, click, scroll — blocks every switch for the next 1.5 s, so a drag or a long scroll
  never gets undercut by a stray look. A look that ends before the delay does nothing, and so does a
  head pose that points at no display at all, like reading your phone.
- **Tunable edge** — "Head turn needed" (30–70 %, default 50 %) sets where, along each pair of displays'
  calibrated ranges, the switch fires: lower switches on a small turn, higher needs a firmer one.
  Coming home to the display you just left needs a little more turn than leaving it did, a small built-in stickiness so a stare that lands right on a shared bezel can't bounce the keyboard back and forth.
- **Gets more accurate the longer you use it** — every click made while your gaze holds steady on one spot
  doubles as a free calibration point, up to 200 per display. A run of clicks landing away from where Focus
  predicted triggers a one-time notification to recalibrate that display; collecting new points at all can be
  switched off in Settings.
- **Setups** — Focus keeps one calibration per place you work: your desk, the office, a café. It tells places
  apart by their displays and camera (and, if you allow Location, the Wi-Fi name) and switches to the right
  calibration on its own. In a place it has never seen, it pauses and offers to calibrate.
- **In control** — pause and resume with ⇧⌘G (rebindable), an optional red gaze dot to check accuracy, a live
  readout of head yaw and pitch in Settings, launch at login, camera picker.

## Privacy

- Each camera frame is processed in memory, then discarded. Focus records nothing and writes no image to disk.
- Focus reads *when* you last pressed a key, never *which* key.
- Focus makes no network connections of any kind: nothing to sign into, nothing measured, nothing phoned
  home.
- The Wi-Fi name is read only if you allow Location in the optional onboarding step. Focus never asks for
  your position.
- Settings and calibrations stay in `~/Library/Application Support/Focus`.
- The camera runs at 1280×720, 15 frames a second at most, and stops while Focus is paused, the screen is
  locked or the Mac sleeps.

## Requirements

- A Mac with Apple silicon, running macOS 15 or later.
- A camera pointed at your face — the one built into the Mac works, and so does an external one.
- Permissions: Camera and Accessibility. Location is optional (for Wi-Fi names).
- To build: Xcode (Swift 6).

## Install

```bash
git clone <this repo> focus && cd focus
scripts/build-app.sh            # builds build/Focus.app
mv build/Focus.app /Applications/
open /Applications/Focus.app    # the welcome guide walks you through permissions and calibration
```

The app is signed ad hoc for local use. After a rebuild, macOS may ask for Camera and Accessibility again.

Calibration is per display and takes roughly 20 seconds: a dot moves through 9 fixed points, plus a few extra
right on any edge one display shares with another — that seam is where two screens are hardest to tell
apart, so it gets the closest look.

## FAQ

**How much of this is eye tracking?** Screen choice runs on head direction alone — yaw and pitch, which an
ordinary webcam tracks reliably in normal lighting. Only the finer step, picking a window or pane on the
display you're already facing, brings in your actual gaze point, because two windows side by side sit too
close together for head angle alone to tell apart.

**I have a single display. Is it useful?** Yes. There is nothing to switch between, so Focus works inside that
display: whichever window or pane you are reading receives your typing.

**Why does it need Accessibility?** macOS only lets an app raise another app's window, give a pane the
keyboard and move the pointer through Accessibility.

**Does Focus click anything?** Settings has one fallback toggle for it, and off is always a safe choice. It
exists because a handful of terminals and editors have no Accessibility call for focusing one split pane
directly; only in those specific apps, Focus posts a single click at the pane's centre instead (which, in an
editor, also happens to move the text cursor there, same as a real click would). Everywhere else, every
focus change is a plain Accessibility request — no click at all.

**Why did it pause?** It is somewhere it has no calibration for (new displays, another camera, another
arrangement), or the camera can't see your face. The menu bar status tells you which.

**It picked the wrong setup.** Choose the right one from the Setup menu. Focus keeps your choice until the
displays, camera or network change, and remembers the Wi-Fi name so it can tell look-alike places apart next
time.

## Honest limits

- Moving a monitor or the camera means recalibrating. Setups help across places, not within one.
- Sitting somewhere else at the same desk, or leaning far in or out, can call for a recalibration.
- Changing a display's resolution counts as a new place until you pick its setup once.
- Pane focus works in the listed apps only. No tmux panes.
- It needs to see your face: in a dark room or with the camera covered, the status reads "Waiting to see your face…".
- Not notarised, not on the App Store; built and signed locally.
- One user per Mac. macOS only.

## Credits and licences

- Gaze pipeline vendored from [MacGaze](https://github.com/AACTools/MacGaze) (MIT).
- BlazeGaze model from [WebEyeTrack](https://github.com/RedForestAI/WebEyeTrack) (MIT). Its weights were
  trained on MPIIFaceGaze, which is licensed CC BY-NC-SA 4.0 (non-commercial), so Focus is fine for internal
  use only; check before any commercial use.
- FaceMesh model from the [PINTO model zoo](https://github.com/PINTO0309/PINTO_model_zoo) (Apache-2.0),
  derived from Google MediaPipe; canonical face model and test image from MediaPipe (Apache-2.0).
- References read, not copied: [gazectl](https://github.com/jnsahaj/gazectl),
  [AeroSpace](https://github.com/nikitabobko/AeroSpace), [Rectangle](https://github.com/rxhanson/Rectangle).

Focus is released under the [MIT License](LICENSE). Full third-party licence texts: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Documentation:
[docs/wiki/Home.md](docs/wiki/Home.md).
