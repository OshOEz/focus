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
the engine's latch. A `false` (unknown window or display, no Accessibility, refused raise, or a pane
before plan 4) is "no effect". The latch stops the engine from re-issuing the same action every frame.

### 9. Known limits

- Windows on other Spaces are invisible: they are not in the on-screen list.
- A full-screen app is its own Space, so its screen shows only that app.
- Some apps refuse the AX raise or ignore `kAXMainAttribute`. For those, `perform` returns `false`, or
  focus does not land and the next `World` shows it.

## Panes (plan 4)

Not implemented yet. `FocusActuator.paneFocuser` is the hook that plan 4 installs: AX focus on the pane,
then the synthetic-click fallback gated by `syntheticClickFallback`. Until then, `.pane` actions return
`false`.
