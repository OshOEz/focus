import AppKit
import ApplicationServices
import FocusCore
import FocusMac
import QuartzCore

/// Buffers a process's stdout lines as they arrive off the main thread (a `Pipe`'s
/// `readabilityHandler` runs on a background queue), so a bench row can look for one — the fixture's
/// `pane-focused <i>` / `pane-clicked <i>` protocol lines — without a dedicated async reader per check.
private final class LineLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var carry = ""

    func feed(_ data: Data) {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
        lock.lock(); defer { lock.unlock() }
        carry += text
        let parts = carry.components(separatedBy: "\n")
        lines.append(contentsOf: parts.dropLast())
        carry = parts.last ?? ""
    }

    func since(_ n: Int) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return n < lines.count ? Array(lines[n...]) : []
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return lines.count }
}

/// One `focus-fixture` launch, kept alive for a group of P4.x rows that need the same flags
/// (`--refuse-ax-focus` or `--late-ax`). Reads the startup JSON (window ids/frames — same shape as
/// `LiveAXBench.Fixture`) then keeps buffering stdout until `terminate()`.
@MainActor private final class PaneFixture {
    let fx: LiveAXBench.Fixture
    private let proc: Process
    private let pipe: Pipe
    private let log: LineLog

    var lineCount: Int { log.count }

    /// nil when focus-fixture isn't built or never printed its startup JSON within 5 s.
    init?(args: [String]) {
        let url = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("focus-fixture")
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        let proc = Process()
        proc.executableURL = url
        proc.arguments = args + ["--quit-after", "30"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        let log = LineLog()
        pipe.fileHandleForReading.readabilityHandler = { h in log.feed(h.availableData) }
        guard (try? proc.run()) != nil else { return nil }
        self.proc = proc
        self.pipe = pipe
        self.log = log
        let end = CACurrentMediaTime() + 5
        var json: String?
        repeat {
            json = log.since(0).first
            if json != nil { break }
            usleep(20_000)
        } while CACurrentMediaTime() < end
        guard let json, let fx = try? JSONDecoder().decode(LiveAXBench.Fixture.self, from: Data(json.utf8)) else {
            proc.terminate(); proc.waitUntilExit()
            return nil
        }
        self.fx = fx
    }

    /// True once a line with `prefix` appears among lines seen after `since`, waiting up to `timeout`.
    func waitFor(_ prefix: String, since: Int, timeout: Double) -> Bool {
        let end = CACurrentMediaTime() + timeout
        repeat {
            if log.since(since).contains(where: { $0.hasPrefix(prefix) }) { return true }
            usleep(20_000)
        } while CACurrentMediaTime() < end
        return log.since(since).contains(where: { $0.hasPrefix(prefix) })
    }

    /// True if no line with `prefix` appears within `wait` (checked to the end, not short-circuited).
    func neverSees(_ prefix: String, since: Int, wait: Double) -> Bool {
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        return !log.since(since).contains(where: { $0.hasPrefix(prefix) })
    }

    func terminate() {
        pipe.fileHandleForReading.readabilityHandler = nil
        proc.terminate()
        proc.waitUntilExit()
    }
}

/// FocusMac wiring around one `PaneFixture`: providers, actuator, and the fixed window id of the
/// split window (always `focus-fixture`'s second window).
@MainActor private final class PaneSession {
    let fixture: PaneFixture
    let wp = WindowProvider()
    let pp: PaneProvider
    let actuator: FocusActuator
    let dp = DisplayProvider()
    let startPointer: CGPoint
    var splitID: UInt32 { fixture.fx.windows[1].id }

    init?(args: [String]) {
        guard let f = PaneFixture(args: args) else { return nil }
        fixture = f
        pp = PaneProvider(windows: wp)
        pp.allows = { _ in true }   // the fixture has no bundle id; production keeps PaneApps
        actuator = FocusActuator(windows: wp, panes: pp)
        startPointer = CGEvent(source: nil)!.location
        NSRunningApplication(processIdentifier: f.fx.pid)?.activate()
        Thread.sleep(forTimeInterval: 0.2)   // let the window server settle activation before AX calls
    }

    func world(panes: [CGRect] = [], focusedPane: Int? = nil) -> World {
        World(displays: dp.displays, windows: wp.windows(), focusedWindowID: wp.focusedWindowID(),
              panes: panes, focusedPane: focusedPane)
    }

    /// Puts the pointer back where it was when the session started (P4.5 moves it on purpose).
    func restorePointer() {
        CGWarpMouseCursorPosition(startPointer)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    func terminate() { fixture.terminate() }
}

/// Whatever's covering `p` above `windowID` by `FocusActuator`'s own occluder rule (same one
/// `focusPane` reads right before posting a click), or nil when nothing is. A real desktop's own
/// clutter — a notification banner, a stray popup — can transiently sit over a pane's centre with
/// nothing wrong in the product; P4.4/P4.5 skip in that case instead of failing, exactly the class
/// of flakiness `LiveAXBench.fixtureOnTop` already guards its own click rows against.
@MainActor private func coveringWindow(above windowID: UInt32, at p: CGPoint) -> String? {
    let raw = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow, .excludeDesktopElements], windowID) as? [[String: Any]] ?? []
    let occluded = FocusActuator.occluders(in: raw, excludingPID: getpid(), window: windowID,
                                           dockStrips: FocusActuator.dockStrips(), displayFrames: FocusActuator.displayFrames())
        .contains { $0.contains(p) }
    guard occluded else { return nil }
    let owner = raw.first { w in
        guard let b = w[kCGWindowBounds as String] as? NSDictionary, let f = CGRect(dictionaryRepresentation: b) else { return false }
        return f.contains(p)
    }
    let name = owner.flatMap { $0[kCGWindowOwnerName as String] as? String } ?? "another window"
    let layer = owner.flatMap { $0[kCGWindowLayer as String] as? Int }
    return layer.map { "\(name) layer \($0)" } ?? name
}

/// Group 4's pane rows: AX-first pane focus, the click fallback behind
/// `syntheticClickFallback`, its safety guards (disabled setting, covered pane), and the Electron-style
/// late AX tree (`PaneProvider`'s empty-tree retry). Each row group launches its own `focus-fixture`
/// with its pane flags: `--refuse-ax-focus` forces the click path, `--late-ax` exercises the
/// retry. Never clicks to set up a starting state — only to make the state the row is checking.
@MainActor func paneBenches() -> [BenchResult] {
    let group = BenchResult.groupNames[4]!
    let allNames = ["P4.1 panes found", "P4.2 walk time", "P4.3 AX path", "P4.4 click path",
                    "P4.5 click moves pointer", "P4.6 click disabled", "P4.7 covered pane", "P4.8 late tree"]
    // `paneBenches()` launches its own fixture(s) independently of `LiveAXBench.run()`'s own
    // preconditions, so it re-checks both instead of trusting a caller to have already gated it.
    guard !SystemStateMonitor.screenIsLocked() else { return allNames.map { .skip(group, $0, "screen locked") } }
    guard Permissions.accessibility == .granted else {
        return allNames.map { .skip(group, $0, "Accessibility not granted") }
    }

    var out: [BenchResult] = []

    // P4.1-P4.3: default fixture, AX path only.
    let axNames = ["P4.1 panes found", "P4.2 walk time", "P4.3 AX path"]
    if let session = PaneSession(args: []) {
        out += panesFoundAndWalkTime(session, group)
        out += axPath(session, group)
        session.terminate()
    } else {
        out += axNames.map { .check(group, $0, false, rule: "fixture starts and prints its window JSON", reason: "focus-fixture did not start") }
    }

    // P4.4-P4.7: the click fallback, needs event posting.
    let clickNames = ["P4.4 click path", "P4.5 click moves pointer", "P4.6 click disabled", "P4.7 covered pane"]
    if Permissions.eventPosting != .granted {
        out += clickNames.map { .skip(group, $0, "event posting not granted") }
    } else if let session = PaneSession(args: ["--refuse-ax-focus"]) {
        out += clickPath(session, group)
        out += clickMovesPointer(session, group)
        out += clickDisabled(session, group)
        out += coveredPane(session, group)
        session.terminate()
    } else {
        out += clickNames.map { .check(group, $0, false, rule: "fixture starts", reason: "focus-fixture did not start") }
    }

    // P4.8: the late AX tree.
    if let session = PaneSession(args: ["--late-ax"]) {
        out += lateTree(session, group)
        session.terminate()
    } else {
        out.append(.check(group, "P4.8 late tree", false, rule: "fixture starts", reason: "focus-fixture did not start"))
    }

    return out
}

@MainActor private func panesFoundAndWalkTime(_ s: PaneSession, _ group: String) -> [BenchResult] {
    let panes = s.pp.panes(of: s.splitID)
    let ordered = panes.count == 2 && panes[0].minX < panes[1].minX
    let disjoint = panes.count == 2 && panes[0].intersection(panes[1]).isNull
    // No size check here: `PaneFinder.panes` already enforces the ≥ 200×150 floor (`PaneProvider`'s
    // `minSize`), so anything it returns already satisfies it — the rule text still states the floor.
    let r1 = BenchResult.check(group, "P4.1 panes found", panes.count == 2 && ordered && disjoint,
                               rule: "2 disjoint panes, left before right, each ≥ 200×150",
                               metrics: ["count": Double(panes.count)], reason: "\(panes)")

    s.pp.invalidate()
    var t = CACurrentMediaTime()
    let first = s.pp.panes(of: s.splitID)
    let firstMs = (CACurrentMediaTime() - t) * 1000
    t = CACurrentMediaTime()
    let second = s.pp.panes(of: s.splitID)
    let secondMs = (CACurrentMediaTime() - t) * 1000
    let r2 = BenchResult.check(group, "P4.2 walk time", first.count == 2 && second.count == 2 && firstMs < 50 && secondMs < 1,
                               rule: "first walk < 50 ms; cached (second) walk < 1 ms",
                               metrics: ["first_ms": firstMs, "second_ms": secondMs],
                               reason: "first \(String(format: "%.2f", firstMs)) ms, cached \(String(format: "%.3f", secondMs)) ms")
    return [r1, r2]
}

/// AX-first focus of each pane in turn (never a click: that would exercise the fallback, not this path).
@MainActor private func axPath(_ s: PaneSession, _ group: String) -> [BenchResult] {
    let panes = s.pp.panes(of: s.splitID)
    guard panes.count == 2 else {
        return [.check(group, "P4.3 AX path", false, rule: "2 panes found", reason: "panes(of:) returned \(panes.count)")]
    }
    var ok = true
    var detail: [String] = []
    for i in [0, 1] {
        let since = s.fixture.lineCount
        let performed = s.actuator.perform(.pane(window: s.splitID, frame: panes[i]), world: s.world(panes: panes))
        let focusedLine = s.fixture.waitFor("pane-focused \(i)", since: since, timeout: 0.5)
        let idx = s.pp.focusedPaneIndex(of: s.splitID, panes: panes)
        let noClick = s.fixture.neverSees("pane-clicked", since: since, wait: 0)
        let good = performed && focusedLine && idx == i && noClick
        ok = ok && good
        detail.append("pane \(i): perform \(performed), focused-line \(focusedLine), index \(idx.map(String.init) ?? "nil"), clicked \(!noClick)")
    }
    return [.check(group, "P4.3 AX path", ok,
                   rule: "perform true; pane-focused <i> within 0.5 s; focusedPaneIndex == i; no pane-clicked",
                   reason: detail.joined(separator: "; "))]
}

@MainActor private func clickPath(_ s: PaneSession, _ group: String) -> [BenchResult] {
    let panes = s.pp.panes(of: s.splitID)
    guard panes.count == 2 else {
        return [.check(group, "P4.4 click path", false, rule: "2 panes found", reason: "panes(of:) returned \(panes.count)")]
    }
    if let blocker = coveringWindow(above: s.splitID, at: CGPoint(x: panes[1].midX, y: panes[1].midY)) {
        return [.skip(group, "P4.4 click path", "covered by \(blocker) (real desktop clutter, not the fixture): nothing posted")]
    }
    s.actuator.syntheticClickFallback = true
    s.actuator.moveCursor = false
    let im = InputMonitor()
    im.start()
    var clicks = 0
    im.onClick = { _, _ in clicks += 1 }
    defer { im.stop() }

    let pointerBefore = CGEvent(source: nil)!.location
    let since = s.fixture.lineCount
    let mouseBefore = im.activity.lastMouse
    let performed = s.actuator.perform(.pane(window: s.splitID, frame: panes[1]), world: s.world(panes: panes))
    let clickedLine = s.fixture.waitFor("pane-clicked 1", since: since, timeout: 0.5)
    let focusedLine = s.fixture.waitFor("pane-focused 1", since: since, timeout: 0.5)
    let pointerAfter = CGEvent(source: nil)!.location
    let pointerDelta = hypot(pointerAfter.x - pointerBefore.x, pointerAfter.y - pointerBefore.y)
    Thread.sleep(forTimeInterval: 0.3)
    let mouseDelta = abs(im.activity.lastMouse - mouseBefore)
    let ok = performed && clickedLine && focusedLine && pointerDelta <= 1 && clicks == 0 && mouseDelta <= 0.001
    return [.check(group, "P4.4 click path", ok,
                   rule: "perform true; pane-clicked 1 & pane-focused 1 within 0.5 s; pointer restored ≤ 1 pt; onClick 0; lastMouse unchanged",
                   metrics: ["onclick_calls": Double(clicks), "pointer_delta_pt": pointerDelta, "mouse_delta_s": mouseDelta],
                   reason: "perform \(performed), clicked-line \(clickedLine), focused-line \(focusedLine), pointer Δ\(pointerDelta) pt, onClick ×\(clicks)")]
}

@MainActor private func clickMovesPointer(_ s: PaneSession, _ group: String) -> [BenchResult] {
    let panes = s.pp.panes(of: s.splitID)
    guard panes.count == 2 else {
        return [.check(group, "P4.5 click moves pointer", false, rule: "2 panes found", reason: "panes(of:) returned \(panes.count)")]
    }
    if let blocker = coveringWindow(above: s.splitID, at: CGPoint(x: panes[0].midX, y: panes[0].midY)) {
        return [.skip(group, "P4.5 click moves pointer", "covered by \(blocker) (real desktop clutter, not the fixture): nothing posted")]
    }
    s.actuator.syntheticClickFallback = true
    s.actuator.moveCursor = true
    let performed = s.actuator.perform(.pane(window: s.splitID, frame: panes[0]), world: s.world(panes: panes))
    let p = CGEvent(source: nil)!.location
    let inside = panes[0].contains(p)
    s.restorePointer()
    return [.check(group, "P4.5 click moves pointer", performed && inside,
                   rule: "perform true; pointer inside panes[0] right after",
                   reason: "perform \(performed), pointer \(p) \(inside ? "inside" : "outside") \(panes[0])")]
}

@MainActor private func clickDisabled(_ s: PaneSession, _ group: String) -> [BenchResult] {
    let panes = s.pp.panes(of: s.splitID)
    guard panes.count == 2 else {
        return [.check(group, "P4.6 click disabled", false, rule: "2 panes found", reason: "panes(of:) returned \(panes.count)")]
    }
    // Target whichever pane isn't already focused: an AX focus request on an already-focused pane
    // trivially succeeds (nothing to change) before `focusPane` ever reaches the disabled setting,
    // which would pass this row without exercising it.
    let target = s.pp.focusedPaneIndex(of: s.splitID, panes: panes) == 1 ? 0 : 1
    s.actuator.syntheticClickFallback = false
    s.actuator.moveCursor = false
    let since = s.fixture.lineCount
    let performed = s.actuator.perform(.pane(window: s.splitID, frame: panes[target]), world: s.world(panes: panes))
    let noClick = s.fixture.neverSees("pane-clicked", since: since, wait: 0.3)
    return [.check(group, "P4.6 click disabled", !performed && noClick,
                   rule: "perform false; no pane-clicked within 0.3 s",
                   reason: "perform \(performed), no pane-clicked \(noClick), target pane \(target)")]
}

@MainActor private func coveredPane(_ s: PaneSession, _ group: String) -> [BenchResult] {
    let panes = s.pp.panes(of: s.splitID)
    guard panes.count == 2, let otherID = s.fixture.fx.windows.first?.id, let el = s.wp.element(for: otherID) else {
        return [.check(group, "P4.7 covered pane", false, rule: "2 panes found; other fixture window resolvable", reason: "setup failed")]
    }
    s.actuator.syntheticClickFallback = true
    s.actuator.moveCursor = false
    // If panes[1] is already focused (a prior row), an AX focus request on it trivially succeeds
    // before `focusPane` ever reaches the click fallback the cover is meant to block — move focus
    // away first with a plain click, so this row exercises the occluder guard, not a no-op. That
    // setup click is itself an unguarded post: pane 0's centre can be covered by the
    // exact same real-desktop clutter P4.4/P4.5 already check for — often the very thing P4.5 just
    // found covered, since a covered P4.5 leaves pane 1 still focused — so it needs the same guard,
    // skipping instead of posting a click into whatever's there.
    if s.pp.focusedPaneIndex(of: s.splitID, panes: panes) == 1 {
        if let blocker = coveringWindow(above: s.splitID, at: CGPoint(x: panes[0].midX, y: panes[0].midY)) {
            return [.skip(group, "P4.7 covered pane", "covered by \(blocker) (real desktop clutter, not the fixture): setup click not posted")]
        }
        _ = FocusActuator.postMarkedClick(at: CGPoint(x: panes[0].midX, y: panes[0].midY))
        s.restorePointer()   // same as P4.5: a click posted at a point moves the real pointer there
        Thread.sleep(forTimeInterval: 0.15)
    }
    let target = CGPoint(x: panes[1].midX, y: panes[1].midY)
    let otherSize = s.fixture.fx.frame(0)
    // Same top-left global CG space `WindowProvider`/`World` already use for frames — no flip needed.
    var origin = CGPoint(x: target.x - otherSize.width / 2, y: target.y - otherSize.height / 2)
    if let axValue = AXValueCreate(.cgPoint, &origin) {
        AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, axValue)
    }
    AXUIElementPerformAction(el, kAXRaiseAction as CFString)
    Thread.sleep(forTimeInterval: 0.15)   // window server settle
    let since = s.fixture.lineCount
    let performed = s.actuator.perform(.pane(window: s.splitID, frame: panes[1]), world: s.world(panes: panes))
    let noClick = s.fixture.neverSees("pane-clicked", since: since, wait: 0.3)
    return [.check(group, "P4.7 covered pane", !performed && noClick,
                   rule: "perform false; no pane-clicked within 0.3 s",
                   reason: "perform \(performed), no pane-clicked \(noClick)")]
}

@MainActor private func lateTree(_ s: PaneSession, _ group: String) -> [BenchResult] {
    // Timing coupling: `first` only proves the empty-tree case if it lands inside the fixture's own
    // late-AX window (`fixtureLaunchTime` + 1.5 s in FocusFixture/main.swift) — i.e. before this
    // session's own launch-plus-settle overhead (PaneFixture's JSON wait + PaneSession's activation
    // sleep) eats past 1.5 s. Comfortably true in practice (well under 1 s here), but the two aren't
    // otherwise linked.
    let first = s.pp.panes(of: s.splitID)
    Thread.sleep(forTimeInterval: 1.2)
    let second = s.pp.panes(of: s.splitID)
    let ok = first.isEmpty && second.count == 2
    return [.check(group, "P4.8 late tree", ok,
                   rule: "empty right after launch; 2 panes after 1.2 s (the empty-tree 1 s retry)",
                   metrics: ["first_count": Double(first.count), "second_count": Double(second.count)],
                   reason: "first \(first.count) panes, after 1.2 s \(second.count) panes")]
}
