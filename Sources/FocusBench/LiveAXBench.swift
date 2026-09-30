import AppKit
import ApplicationServices
import Carbon
import FocusCore
import FocusMac
import QuartzCore

/// Group 4: FocusMac against the real window server, on `focus-fixture`'s windows only.
/// Input-sensitive checks run before any synthetic event; every synthetic event targets the fixture.
/// Cleanup always runs: fixture terminated, previous app re-activated, pointer put back.
enum LiveAXBench {
    static let group = BenchResult.groupNames[4]!
    static let names = ["display-provider", "window-provider", "own-app-exclusion", "world-build-latency",
                        "focus-window-1", "focus-window-2", "display-restores-last-window", "e2e-scripted-gaze",
                        "cursor-warp", "warp-is-not-mouse-activity", "synthetic-click-ignored",
                        "input-sees-key", "input-sees-click", "hotkey"]

    struct Fixture: Decodable {
        struct Window: Decodable { var id: UInt32; var frame: [Double] }
        var pid: Int32
        var windows: [Window]
        var selfOnScreen: Int
        var selfListed: Int
        func frame(_ i: Int) -> CGRect { let f = windows[i].frame; return CGRect(x: f[0], y: f[1], width: f[2], height: f[3]) }
    }

    @MainActor static func run() async -> [BenchResult] {
        // Captured and restored once, wrapping the whole function: every branch below may call
        // `paneBenches()`, which launches its own fixture(s) independently of `Run`'s single
        // long-lived one, so a capture/restore living only around `Run`'s own launch (as this used
        // to be) never covers what `paneBenches()` does to the frontmost app or the pointer.
        let previous = NSWorkspace.shared.frontmostApplication
        let pointer = CGEvent(source: nil)!.location
        defer {
            if let previous {
                AXUIElementSetAttributeValue(AXUIElementCreateApplication(previous.processIdentifier),
                                             kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                previous.activate()
            }
            CGWarpMouseCursorPosition(pointer)
            CGAssociateMouseAndMouseCursorPosition(1)
        }

        // The pane rows launch their own fixture(s) and never share `Run`'s single
        // long-lived one, so they're appended after every branch below, not just the happy path.
        // `paneBenches()` re-checks accessibility and the screen lock itself (it can run with none
        // of this function's own state, e.g. when `Run` never launches at all).
        if SystemStateMonitor.screenIsLocked() { return names.map { .skip(group, $0, "screen locked") } + paneBenches() }
        if Permissions.accessibility != .granted {
            return names.map { .skip(group, $0, "Accessibility not granted to the process running focus-bench (grant it to the terminal)") } + paneBenches()
        }
        let url = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("focus-fixture")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            return names.map { .check(group, $0, false, rule: "fixture present", reason: "focus-fixture not built") } + paneBenches()
        }

        let proc = Process()
        proc.executableURL = url
        proc.arguments = ["--quit-after", "60"]   // never lingers, even if this process dies
        let pipe = Pipe()
        proc.standardOutput = pipe
        do { try proc.run() } catch {
            return names.map { .check(group, $0, false, rule: "fixture starts", reason: "focus-fixture: \(error)") } + paneBenches()
        }
        // Safety net only: both paths below already terminate `proc` explicitly, before calling
        // `paneBenches()` (see there) — a bare `defer` here would fire too late for that (only at
        // `run()`'s own return, after `paneBenches()` already ran). Idempotent either way.
        defer { proc.terminate(); proc.waitUntilExit() }
        // Closing the pipe (timeout → terminate) ends the read, so a silent fixture can't hang the bench.
        let handle = pipe.fileHandleForReading
        let reader = Task.detached { () -> String? in
            for try await line in handle.bytes.lines { return line }
            return nil
        }
        let timeout = Task {   // cancelled = the line arrived: sleep throws, and the fixture must live on
            guard (try? await Task.sleep(for: .seconds(10))) != nil else { return }
            proc.terminate()
        }
        let line = try? await reader.value
        timeout.cancel()
        guard let line, let fx = try? JSONDecoder().decode(Fixture.self, from: Data(line.utf8)), fx.windows.count == 2 else {
            // Same reasoning as below: whatever's left of this fixture must be gone before
            // `paneBenches()` launches its own — two live fixtures fighting for frontmost/pointer
            // is the flakiness risk, not just the happy path.
            proc.terminate()
            proc.waitUntilExit()
            return names.map { .check(group, $0, false, rule: "fixture JSON within 10 s", reason: "no fixture JSON: \(line ?? "nothing")") } + paneBenches()
        }
        // `Run`'s fixture must be fully gone before `paneBenches()` launches its own: the outer
        // `defer`s only fire when `run()` itself returns, i.e. *after* `paneBenches()` already ran,
        // so without this, two `focus-fixture` processes would be alive and fighting for frontmost
        // and the pointer at once (a real flakiness risk, not hypothetical).
        let runResults = await Run(fx: fx).all()
        proc.terminate()
        proc.waitUntilExit()
        return runResults + paneBenches()
    }

    /// Polls every 50 ms; returns the elapsed seconds when `condition` holds, nil on timeout.
    @MainActor static func poll(_ timeout: Double, _ condition: () -> Bool) async -> Double? {
        let t0 = CACurrentMediaTime()
        while true {
            if condition() { return CACurrentMediaTime() - t0 }
            if CACurrentMediaTime() - t0 > timeout { return nil }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    static func percentile(_ xs: [Double], _ p: Double) -> Double {
        let s = xs.sorted()
        return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
    }

    @MainActor final class Run {
        let fx: Fixture
        let dp = DisplayProvider()
        let wp = WindowProvider()
        let actuator: FocusActuator
        let pp: PaneProvider
        let im = InputMonitor()
        let w1: UInt32, w2: UInt32
        let main: DisplayInfo
        var out: [BenchResult] = []

        init(fx: Fixture) {
            self.fx = fx
            pp = PaneProvider(windows: wp)
            pp.allows = { _ in true }   // the fixture has no bundle id, so it is on no allow-list
            actuator = FocusActuator(windows: wp, panes: pp)
            actuator.moveCursor = true
            w1 = fx.windows[0].id; w2 = fx.windows[1].id
            let c = CGPoint(x: fx.frame(0).midX, y: fx.frame(0).midY)
            main = dp.displays.first { $0.frame.contains(c) } ?? dp.displays[0]
            im.start()
        }

        func world() -> World { World(displays: dp.displays, windows: wp.windows(), focusedWindowID: wp.focusedWindowID()) }
        func add(_ name: String, _ ok: Bool, _ rule: String, _ metrics: [String: Double] = [:], _ reason: String) {
            out.append(.check(group, name, ok, rule: rule, metrics: metrics, reason: reason))
        }
        func focused(_ id: UInt32, within t: Double = 1) async -> Double? { await poll(t) { self.wp.focusedWindowID() == id } }

        func all() async -> [BenchResult] {
            defer { im.stop() }
            providers()
            await ownApp()
            worldLatency()
            await focusWindows()
            await displayRestore()
            await e2e()
            await warps()
            if Permissions.eventPosting != .granted {
                for n in ["synthetic-click-ignored", "input-sees-key", "input-sees-click", "hotkey"] {
                    out.append(.skip(group, n, "event posting not granted to the process running focus-bench"))
                }
            } else {
                await syntheticClick()
                await key()
                await click()
                await hotKey()
            }
            return out
        }

        func providers() {
            let d = dp.displays
            add("display-provider", !d.isEmpty && Set(d.map(\.key)).count == d.count && d.allSatisfy { !$0.frame.isEmpty },
                "≥ 1 display, unique keys, non-empty frames", ["count": Double(d.count)], "\(d.map { "\($0.key) \($0.frame)" })")
        }

        func ownApp() async {
            // WindowProvider from focus-bench (another process) must list both fixture windows at their frames.
            var err = Double.infinity
            _ = await poll(2) {
                let ws = self.wp.windows()
                let errs = (0..<2).map { i -> Double in
                    guard let f = ws.first(where: { $0.id == self.fx.windows[i].id })?.frame else { return .infinity }
                    let e = self.fx.frame(i)
                    return [f.minX - e.minX, f.minY - e.minY, f.width - e.width, f.height - e.height].map(abs).max()!
                }
                err = errs.max()!
                return err <= 2
            }
            add("window-provider", err <= 2, "both fixture ids listed, frames within 2 pt",
                ["max_frame_error_pt": err.isFinite ? err : -1], err.isFinite ? "frame error \(err) pt" : "a fixture window is missing")
            // …and a WindowProvider inside the fixture never lists the fixture's own windows.
            add("own-app-exclusion", fx.selfOnScreen >= 2 && fx.selfListed == 0 && err.isFinite,
                "listed from focus-bench; in-process WindowProvider lists 0 of ≥ 2 own on-screen windows",
                ["self_on_screen": Double(fx.selfOnScreen), "self_listed": Double(fx.selfListed)],
                "fixture sees \(fx.selfOnScreen) own windows on screen, its WindowProvider lists \(fx.selfListed)")
        }

        func worldLatency() {
            // The engine builds a World per camera frame on the main thread: 15 fps = 66 ms per frame.
            var build: [Double] = [], ax: [Double] = []
            for _ in 0..<30 {
                var t = CACurrentMediaTime()
                _ = world()
                build.append((CACurrentMediaTime() - t) * 1000)
                t = CACurrentMediaTime()
                _ = wp.focusedWindowID()
                ax.append((CACurrentMediaTime() - t) * 1000)
            }
            let p95 = percentile(build, 0.95)
            add("world-build-latency", p95 < 33, "p95 < 33 ms (half a 15 fps frame), 30 builds",
                ["world_p50_ms": percentile(build, 0.5), "world_p95_ms": p95,
                 "ax_focused_p50_ms": percentile(ax, 0.5), "ax_focused_p95_ms": percentile(ax, 0.95)], "p95 \(p95) ms")
        }

        func focusWindows() async {
            for (n, id) in [(1, w1), (2, w2)] {
                let t0 = CACurrentMediaTime()
                let ok = actuator.perform(.window(id), world: world())
                let dt = await focused(id).map { _ in CACurrentMediaTime() - t0 } ?? -1
                add("focus-window-\(n)", ok && dt >= 0, "perform true, AX focused window within 1 s",
                    ["latency_ms": dt >= 0 ? dt * 1000 : -1], "perform \(ok), focused \(wp.focusedWindowID().map(String.init) ?? "nil")")
            }
        }

        func displayRestore() async {
            _ = actuator.perform(.window(w2), world: world())
            _ = await focused(w2)
            var w = world()
            w.displays = [DisplayInfo(key: "virtual", frame: main.frame)]
            w.focusedWindowID = nil
            actuator.noteFocusChange(windowID: w1, display: "virtual")
            let t0 = CACurrentMediaTime()
            let ok = actuator.perform(.display("virtual"), world: w)
            let dt = await focused(w1) != nil ? CACurrentMediaTime() - t0 : -1
            add("display-restores-last-window", dt >= 0, "window 1 focused within 1 s", ["latency_ms": dt >= 0 ? dt * 1000 : -1],
                "perform \(ok), focused \(wp.focusedWindowID().map(String.init) ?? "nil")")
        }

        func e2e() async {
            let quiet = await poll(10) {
                let a = self.im.activity, now = CACurrentMediaTime()
                return now - a.lastKey >= 3 && now - a.lastMouse >= 1.5
            }
            guard quiet != nil else { out.append(.skip(group, "e2e-scripted-gaze", "user active")); return }
            let pose = PoseFeature(yaw: 0, pitch: 0, faceX: 0.5, faceY: 0.5)
            let dots = [(0.1, 0.1), (0.9, 0.1), (0.1, 0.9), (0.9, 0.9), (0.5, 0.5)].map {
                CalibrationPoint(input: CGPoint(x: $0.0, y: $0.1), target: CGPoint(x: $0.0, y: $0.1))
            }
            let engine = FocusEngine(calibrations: [main.key: DisplayCalibration(pose: pose, calibrationPoints: dots)],
                                     settings: FocusSettings())
            var latencies: [Double] = []
            var rng = SplitMix64(state: 7)
            for (i, target) in [(1, w2), (0, w1)] {
                let f = fx.frame(i), d = main.frame
                // The trace only means something if the fixture window is really there to be gazed
                // at: skip rather than trace blind if something else is on top of it (same occluder
                // rule the click/key/hotkey guards use).
                guard blockers(above: target, at: CGPoint(x: f.midX, y: f.midY)).isEmpty else {
                    out.append(.skip(group, "e2e-scripted-gaze", "fixture window \(i) not on top (FocusActuator occluder rule): nothing traced"))
                    return
                }
                let raw = CGPoint(x: (f.midX - d.minX) / d.width, y: (f.midY - d.minY) / d.height)
                let trace = (0..<30).map { k in
                    GazeSample(time: Double(k) / 15, raw: raw,
                               pose: PoseFeature(yaw: .random(in: -0.005...0.005, using: &rng), pitch: .random(in: -0.005...0.005, using: &rng),
                                                 faceX: 0.5, faceY: 0.5), confidence: 0.9)
                }
                let source = ScriptedGazeSource(trace)
                let t0 = CACurrentMediaTime()
                var hit: Double?
                do {
                    for await s in try await source.start() {
                        if let a = engine.decide(s, world: world(), input: im.activity) { _ = actuator.perform(a, world: world()) }
                        if wp.focusedWindowID() == target { hit = CACurrentMediaTime() - t0; break }
                    }
                } catch {}
                source.stop()
                latencies.append(hit ?? -1)
            }
            let ok = latencies.allSatisfy { $0 >= 0 && $0 <= 1.5 }
            add("e2e-scripted-gaze", ok, "ScriptedGazeSource → FocusEngine → FocusActuator focuses the looked-at window ≤ 1.5 s, both ways",
                ["latency_w2_ms": latencies[0] >= 0 ? latencies[0] * 1000 : -1, "latency_w1_ms": latencies[1] >= 0 ? latencies[1] * 1000 : -1],
                "status \(engine.status), latencies \(latencies) s")
        }

        /// A World where `main` is split in two virtual displays between the fixture windows, focus on window 2:
        /// `.window(w1)` crosses displays, so the actuator warps the pointer onto window 1.
        func crossingWorld() -> World {
            let split = (fx.frame(0).maxX + fx.frame(1).minX) / 2, d = main.frame
            var w = world()
            w.displays = [DisplayInfo(key: "vL", frame: CGRect(x: d.minX, y: d.minY, width: split - d.minX, height: d.height)),
                          DisplayInfo(key: "vR", frame: CGRect(x: split, y: d.minY, width: d.maxX - split, height: d.height))]
            w.focusedWindowID = w2
            return w
        }

        func warps() async {
            _ = actuator.perform(.window(w1), world: crossingWorld())
            let p = CGEvent(source: nil)!.location, f = fx.frame(0)
            let dist = hypot(max(f.minX - p.x, 0, p.x - f.maxX), max(f.minY - p.y, 0, p.y - f.maxY))
            add("cursor-warp", f.contains(p), "pointer inside window 1", ["distance_pt": dist], "pointer at \(p)")

            // CGWarpMouseCursorPosition posts no event, so the HID idle counters must not move.
            let before = im.activity.lastMouse
            CGWarpMouseCursorPosition(CGPoint(x: fx.frame(1).midX, y: fx.frame(1).midY))
            CGAssociateMouseAndMouseCursorPosition(1)
            _ = actuator.perform(.window(w1), world: crossingWorld())
            try? await Task.sleep(for: .milliseconds(100))
            let delta = im.activity.lastMouse - before
            add("warp-is-not-mouse-activity", abs(delta) <= 0.001, "InputActivity.lastMouse unchanged (±1 ms) across warps",
                ["delta_s": delta.isFinite ? delta : -1], "lastMouse moved by \(delta) s")
        }

        /// Windows above `windowID` that cover `p`, by FocusActuator's own occluder rule (other pids,
        /// alpha > 0, the Dock's real UI only — never its invisible full-display window). Shared by
        /// every guard that needs to know a fixture window is genuinely on top before it posts or traces.
        func blockers(above windowID: UInt32, at p: CGPoint) -> [[String: Any]] {
            let above = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow, .excludeDesktopElements], windowID)
                as? [[String: Any]] ?? []
            return above.filter { w in
                FocusActuator.occluders(in: [w], excludingPID: getpid(), window: windowID,
                                        dockStrips: FocusActuator.dockStrips(), displayFrames: FocusActuator.displayFrames())
                    .contains { $0.contains(p) }
            }
        }

        /// Safety: synthetic input goes to the fixture only. False when another app holds keyboard focus,
        /// or a window of any layer (FocusActuator's occluder rule) covers `p` above the fixture window
        /// there: the check is skipped and nothing is posted.
        func fixtureOnTop(_ name: String, at p: CGPoint) -> Bool {
            let ids: Set = [w1, w2]
            guard wp.focusedWindowID().map(ids.contains) == true,
                  let target = wp.windows().first(where: { $0.frame.contains(p) }), ids.contains(target.id) else {
                out.append(.skip(group, name, "another app's window is focused or on top of the fixture: nothing posted"))
                return false
            }
            let blocking = blockers(above: target.id, at: p)
            if blocking.isEmpty { return true }
            let who = blocking.map { w -> String in
                let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
                return "\(owner)\(owner == "Dock" ? " bar" : "") layer \(w[kCGWindowLayer as String] as? Int ?? -1)"
            }
            out.append(.skip(group, name, "covered above the fixture by \(who.joined(separator: ", ")) (FocusActuator occluder rule): nothing posted"))
            return false
        }

        func post(_ type: CGEventType, at p: CGPoint, source: CGEventSource?, tap: CGEventTapLocation = .cghidEventTap) {
            let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)!
            e.setIntegerValueField(.mouseEventClickState, value: 1)
            e.post(tap: tap)
        }

        func syntheticClick() async {
            // FocusActuator.postMarkedClick, exactly as FocusActuator.focusPane posts it (.privateState
            // source, marker, session tap), into window 2's right text view while the left one has focus:
            // it must reach the text view yet stay invisible to the HID idle counter and InputMonitor's
            // click monitors.
            let name = "synthetic-click-ignored", rule = "pane focused by the click; HID leftMouseDown idle counter not reset; onClick not called"
            _ = actuator.perform(.window(w2), world: world())
            _ = await focused(w2)
            let panes = pp.panes(of: w2)
            guard panes.count == 2 else { add(name, false, rule, [:], "fixture window 2: \(panes.count) panes found, expected 2"); return }
            let left = panes[0].minX < panes[1].minX ? 0 : 1, right = 1 - left
            var w = world()
            w.panes = panes
            _ = actuator.perform(.pane(window: w2, frame: panes[left]), world: w)
            guard await poll(0.5, { self.pp.focusedPaneIndex(of: self.w2, panes: panes) == left }) != nil else {
                add(name, false, rule, [:], "could not focus the left pane first (AX)"); return
            }
            let p = CGPoint(x: panes[right].midX, y: panes[right].midY)
            guard fixtureOnTop(name, at: p) else { return }
            var clicks = 0
            im.onClick = { _, _ in clicks += 1 }
            let hid = { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .leftMouseDown) }
            let before = hid()
            guard FocusActuator.postMarkedClick(at: p) else { add(name, false, rule, [:], "could not build the click event"); return }
            let paneFocused = await poll(0.5, { self.pp.focusedPaneIndex(of: self.w2, panes: panes) == right }) != nil
            try? await Task.sleep(for: .milliseconds(100))   // give the NSEvent monitor time to (wrongly) fire
            let after = hid()
            im.onClick = nil
            add(name, paneFocused && after >= before && clicks == 0, rule,
                ["pane_focused": paneFocused ? 1 : 0, "hid_idle_before_s": before, "hid_idle_after_s": after, "onclick_calls": Double(clicks)],
                "pane focused \(paneFocused), idle \(before) → \(after) s, onClick ×\(clicks)")
        }

        func key() async {
            guard fixtureOnTop("input-sees-key", at: CGPoint(x: fx.frame(0).midX, y: fx.frame(0).midY)) else { return }
            let t0 = CACurrentMediaTime()
            for down in [true, false] { CGEvent(keyboardEventSource: nil, virtualKey: 0x4F, keyDown: down)!.post(tap: .cghidEventTap) }
            let lag = await poll(0.5) { self.im.activity.lastKey >= t0 - 0.001 }
            add("input-sees-key", lag != nil, "lastKey within 0.5 s of an F18 post", ["lag_ms": lag.map { $0 * 1000 } ?? -1],
                "lastKey \(t0 - im.activity.lastKey) s before the post")
        }

        func click() async {
            var got: CGPoint?
            im.onClick = { p, _ in got = p }
            let p = CGPoint(x: fx.frame(0).midX, y: fx.frame(0).midY)
            guard fixtureOnTop("input-sees-click", at: p) else { return }
            let t0 = CACurrentMediaTime()
            post(.leftMouseDown, at: p, source: nil)
            post(.leftMouseUp, at: p, source: nil)
            let lag = await poll(0.5) { got != nil }
            let err = got.map { hypot($0.x - p.x, $0.y - p.y) } ?? -1
            let mouse = im.activity.lastMouse >= t0 - 0.001
            im.onClick = nil
            add("input-sees-click", lag != nil && err <= 2 && mouse, "onClick within 0.5 s at ≤ 2 pt; lastMouse updated",
                ["lag_ms": lag.map { $0 * 1000 } ?? -1, "error_pt": err], "onClick \(got.map { "\($0)" } ?? "never"), lastMouse updated \(mouse)")
        }

        func hotKey() async {
            guard fixtureOnTop("hotkey", at: CGPoint(x: fx.frame(0).midX, y: fx.frame(0).midY)) else { return }
            var fired = false
            guard let hk = HotKey(keyCode: 0x50, modifiers: UInt32(cmdKey | optionKey | controlKey), action: { fired = true }) else {
                add("hotkey", false, "action within 0.5 s", [:], "combination taken"); return
            }
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: nil, virtualKey: 0x50, keyDown: down)!
                // Real F-key presses carry the fn flag; without it Carbon never matches the hot key.
                e.flags = [.maskCommand, .maskAlternate, .maskControl, .maskSecondaryFn]
                e.post(tap: .cghidEventTap)
            }
            let lag = await poll(0.5) { fired }
            withExtendedLifetime(hk) {}
            add("hotkey", lag != nil, "⌃⌥⌘F19 action within 0.5 s", ["lag_ms": lag.map { $0 * 1000 } ?? -1], "fired \(fired)")
        }
    }
}
