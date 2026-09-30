# Focusing windows and panes

How FocusMac turns the engine's `FocusAction` into real focus. Code: `Sources/FocusMac/WindowProvider.swift`
and `Sources/FocusMac/FocusActuator.swift`. The decision of *what* to focus lives in FocusCore
(see [Decision engine](Decision-engine.md)); this page is only about *how*.

## Windows

### 1. Listing windows

`WindowProvider.windows()` reads `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements])`,
front to back, and keeps a window only if:

- its layer is 0: normal app windows. Menus, the Dock, overlays and status items sit on other layers;
- its owner is not Focus itself: our gaze dot and calibration windows must never become targets;
- it is visible (alpha > 0) and has a non-empty frame.

"On screen" means the current Space: windows on other Spaces are not listed at all.

Only ids, owner pids and bounds are read. Those need no permission. Window titles would need Screen
Recording, and the engine never uses them, so they are never read and that permission is never asked for.

Each call also refreshes the id → pid map and drops cached AX elements of windows that went away.

### 2. Bridging AX and window ids

CGWindowList and the engine use `CGWindowID`. Focusing needs an `AXUIElement`. The only way to go from one
to the other is the private `_AXUIElementGetWindow`. It has been stable since macOS 10.x and AeroSpace,
yabai and AltTab all rely on it. `element(for:)` walks the owner app's `kAXWindowsAttribute`, matches
each window by id and caches the hit. `focusedWindowID()` asks the system-wide element for the focused
app, then that app's focused window. It does not use `NSWorkspace.frontmostApplication`, which only
updates while a run loop pumps notifications.

AX calls need Accessibility. Without it they just fail: the provider returns `nil`, the actuator returns
`false`, and nothing ever prompts.

### 3. AX timeout: 0.25 s

A hung app blocks every AX call to it for the default 6 s. `WindowProvider.init` sets 0.25 s on the
system-wide element, which makes it the global timeout for every AX element the process creates. One
stuck app then costs a quarter second, not a frozen focus loop.

### 4. The focus sequence

For a target window, `FocusActuator` does this, in AeroSpace/Rectangle order:

1. `kAXFrontmostAttribute = true` on the app;
2. `kAXMainAttribute = true` on the window;
3. `kAXRaiseAction` on the window. Its result is the return value;
4. `kAXFocusedAttribute = true` on the window;
5. `NSRunningApplication.activate()` as a backstop.

AX comes first because, since macOS 14, `activate` called from a background agent is "cooperative"
and the system may ignore it. For trusted AX clients, the frontmost attribute is honoured. Windows are
never clicked.

### 5. What a screen switch focuses

On `.display(key)`, `TargetResolver.windowToRestore` picks the window, in this order:

1. the window being gazed at, when the engine already resolved one (that arrives as `.window`, not `.display`);
2. the last window focused on that screen, if it is still there;
3. the topmost window on that screen that is big enough (default 200×150);
4. none: the screen is empty. Only the pointer moves there (if "move pointer" is on), and `perform` returns `false`.

### 6. Per-display history

`lastWindow[displayKey]` is updated:

- at the start of every `perform`, from `world.focusedWindowID`. A window the user focused by hand is
  then the one restored when they come back to that screen;
- after every successful focus.

A window's screen is the display that contains the window's centre.

### 7. Cursor warp

`moveCursor` comes from `AppSettings.moveCursor` (not `FocusSettings`, see reconciliation R1). When it
is on, the pointer moves to the centre of the focused window, but only when focus changes screen. On
`.display`, that is always. On `.window`, it happens only if the target is on a different screen than
the currently focused window. On an empty screen, the pointer goes to the screen's centre. The point is
that Spaces, Mission Control and new windows open where the user is looking.

`CGWarpMouseCursorPosition` moves the pointer without posting a mouse event, so the engine's
"mouse in use" guard does not see it as user input (checked by bench 4). The warp is followed right
away by `CGAssociateMouseAndMouseCursorPosition(1)`. Without it, macOS freezes the pointer for about
0.25 s after a warp.

### 8. Return value and the latch

`perform` returns `true` when the target app accepted the raise (AX `.success`). That does not prove
focus landed. The next `World` snapshot shows whether it did, and that snapshot is also what releases
the engine's latch. A `false` (unknown window or display, no Accessibility, refused raise, or an
unverified/unsafe pane focus) is "no effect". The latch stops the engine from re-issuing the same
action every frame.

### 9. Known limits

- Windows on other Spaces are invisible: they are not in the on-screen list.
- A full-screen app is its own Space, so its screen shows only that app.
- Some apps refuse the AX raise or ignore `kAXMainAttribute`. For those, `perform` returns `false`, or
  focus does not land and the next `World` shows it.

## Split panes

Code: `Sources/FocusCore/PaneFinder.swift`, `PaneClick.swift`; `Sources/FocusMac/PaneProvider.swift`,
`FocusActuator.swift` (the `.pane` branch); wiring in `Sources/FocusApp/AppController.swift`.

Occluders (R11): every window above the target, any layer, other processes, alpha > 0. **R11 note — the
Dock.** The Dock owns an always-on, click-through window spanning the whole display at layer 20 with
alpha 1; counted as is, it covers every point and no pane click is ever posted (bench 4, 2026-09-30).
So that one window (recognised by bounds equal to a display frame **and** layer 20; Launchpad and
Mission Control, which also have the size of a display, sit at a different layer and stay occluders,
audit #27) is dropped and replaced, when it is above the target, by the Dock's real strip per screen:
the side of `NSScreen.frame` that `visibleFrame` gives up (bottom, left or right; the top gap is
the menu bar), flipped to global CG coordinates (`FocusActuator.dockStrip`). Auto-hide = no strip. The
strip spans the whole side, not the bar's exact length: it errs on "blocked".

The click must not look like the user. It comes from a `.privateState` source, carries the marker
`0x464F4355` (InputMonitor's click monitors drop it, R10), and is posted at **`.cgSessionEventTap`**.
Not the HID tap: an event posted at `.cghidEventTap` enters the `.hidSystemState` idle counters
whatever its source state, so the click would reset the mouse-quiet window InputMonitor reads
(bench 4, 2026-09-30: `leftMouseDown` idle 97.9 s → 0.16 s at the HID tap; at the session tap the click
is delivered and the counter keeps running).

### 1. Which apps

Split-pane focus is allow-listed: 16 terminals and editors —
iTerm2, Terminal, Ghostty, Warp, kitty, WezTerm, Hyper, VS Code, VS Code Insiders, Cursor, Windsurf,
VSCodium, Zed, Sublime Text, Xcode, Android Studio — plus every `com.jetbrains.*` IDE, plus Xirp
(`com.spotify.xirp`, a Focus addition; its panes were spiked to accept AX focus). The list lives in
`PaneApps`. Everything else — browsers, chat apps, document editors — gets whole-window focus only:
their "panes" are DOM regions or custom-drawn splits with no stable Accessibility container to find or

### 2. How panes are found

`PaneProvider` walks the window's AX tree with `PaneFinder`: a pane is the *deepest* focusable node
whose visible rect is at least 200×150 pt, where visible means clipped to every ancestor's frame (a
text view can be taller than its scroll area). If the window contains an `AXWebArea` (Electron/web
apps), only panes inside it count — the surrounding native chrome is ignored. The walk prunes any
subtree whose clipped rect already falls under 200×150 and stops after 3000 AX round trips, so one
pathological tree costs a bounded amount, not a frozen focus loop.

Results are cached per window: 2 s while panes were found, 1 s when the tree came back empty, because
Electron/Chromium apps only build their AX tree after `AXManualAccessibility` is set (`PaneProvider`
sets it once per pid) and it can take about a second to appear (spike: `docs/spikes/ax-panes.md`). A
resize or move invalidates the cache for that window at once. Every AX call is bounded by the
process-wide 0.25 s messaging timeout, so one hung app costs a quarter second, not a stall.

To see what a new app's tree looks like, run `swift run ax-dump` against it before adding it to
`PaneApps`.

### 3. How a pane gets focus

`FocusActuator` sets `kAXFocusedAttribute` on the pane's element, then verifies: it reads
`AXFocusedUIElement` and walks up to 40 parents looking for that pane, because some terminals accept
`AXFocused` without actually moving keyboard focus. If that fails, it falls back to a synthetic click
at the pane centre, and only when **all** hold: AX focus failed verification, the "click to focus
panes" setting (`syntheticClickFallback`) is on, the app is allow-listed, `CGPreflightPostEventAccess()`
is already granted (never requested), and `PaneClick.point` finds a safe point — the centre is farther
than `paneBoundaryMargin` from every other pane, the target window is topmost there among on-screen
windows, and nothing above it (any window layer, read right before posting) covers that point. The
click also moves the text cursor in editors, since it is a real click, not just a focus request.

If "move pointer" is off, the pointer is warped back to where it was, but only after the click's own
result is read — warping earlier could be undone by the click itself. Every synthetic event carries
`InputMonitor.syntheticMarker` in `.eventSourceUserData`, so `InputMonitor` never treats our own click
as user input (no mouse pause, nothing learned from it).

### 4. Settings

`FocusSettings.paneDwell` — pane delay, default 300 ms, range 200-1500 ms.
`FocusSettings.syntheticClickFallback` — the click fallback toggle, default on (shared with the
window-focus click setting, see reconciliation R2). Both reach `FocusActuator`/`FocusEngine` through
`AppController.update(_:)`; the Settings-window rows are plan 3b Task 8.

### 5. Known limits

- No tmux (or similar terminal-multiplexer) panes: those are drawn by the terminal itself, not exposed
  as Accessibility elements.
- A divider dragged to create or resize a pane can take up to 2 s to show up (the cache TTL above).
- The click fallback moves the text cursor in editors — there is no way to focus without doing that.
- Verifying AX focus or a click can block the MainActor up to about 250 ms per pane switch (two
  bounded polls); rare and user-paced, but see the `waitUntil` doc comment in `FocusActuator` if gaze
  frames start dropping around pane switches.

Benches: [group 4 live AX](Benches.md#group-4-live-ax-liveaxbenchswift-focus-fixture) checks all of this against a fixture app.
