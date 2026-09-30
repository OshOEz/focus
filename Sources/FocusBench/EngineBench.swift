import CoreGraphics
import Foundation
import FocusCore

/// Group 2: the real FocusEngine on synthetic desks (Desk.swift), default settings, smoother on,
/// every scenario on a fresh `Sim` (seed 42). Rules and their sources: docs/wiki/Benches.md.
@MainActor
enum EngineBench {
    static let group = BenchResult.groupNames[2]!

    /// The scenario table. Adding a scenario = one row; a row may return several results.
    static let scenarios: [(name: String, run: @MainActor () -> [BenchResult])] = [
        ("switch-latency", { desks.map { switchLatency($0.0, $0.1) } }),
        // A close head makes each screen span more than 2 × offScreenMargin: its outer part must not read as "away".
        ("switch-latency-close", { [900.0, 700].map { distance in
            var d = Desk.laptopBelow
            d.distance = distance
            return switchLatency("laptop-below@\(Int(distance))pt", d)
        } }),
        ("bezel", { desks.map { bezel($0.0, $0.1) } }),
        // Closer heads widen the facing-edge gap; 1000-1700 pt is where the old floor's cliff sat.
        ("bezel-close", { [("side-by-side", Desk.sideBySide, 1300.0), ("side-by-side", .sideBySide, 1000),
                           ("laptop-below", .laptopBelow, 1500), ("laptop-below", .laptopBelow, 1300),
                           ("laptop-below", .laptopBelow, 1000)].map { name, desk, distance in
            var d = desk
            d.distance = distance
            return bezel("\(name)@\(Int(distance))pt", d)
        } }),
        ("quick-look", { [quickLook()] }),
        ("typing", { [typingScreen(), typingPane(wait: true), typingPane(wait: false)] }),
        ("mouse", { [mouse()] }),
        ("off-screen", { [offScreen()] }),
        ("off-screen-away", { awayRows() }),
        ("on-screen", { (desks + [("single", Desk.single)]).flatMap { onScreen($0.0, $0.1) } }),
        ("on-screen-lean", { (desks + [("single", Desk.single)]).map { onScreenLean($0.0, $0.1) } }),
        ("no-face", { [noFace()] }),
        ("latch", { [latch()] }),
        ("window-accuracy", { [windowAccuracy()] }),
        ("learning", { [learning()] }),
        ("recalibration-trigger", { [recalibrationTrigger()] }),
        ("setups-two-places", { let r = setupsTwoPlaces(); return [BenchResult(group: 2, name: "setups-two-places", passed: r.passed, detail: r.detail)] }),
        ("setups-fingerprint", { [setupsFingerprint()] }),
    ]

    static func run() -> [BenchResult] { scenarios.flatMap { $0.run() } }

    static let desks = [("side-by-side", Desk.sideBySide), ("stacked", Desk.stacked), ("laptop-below", Desk.laptopBelow)]

    // MARK: - Helpers

    static func ms(_ s: Double) -> Double { (s * 1000).rounded() }

    /// Nearest-rank percentile of a non-empty array.
    static func percentile(_ xs: [Double], _ p: Double) -> Double {
        let s = xs.sorted()
        return s[max(Int((p * Double(s.count)).rounded(.up)) - 1, 0)]
    }

    /// Left and right halves of the single display, the left one focused.
    static func halves() -> [WindowInfo] {
        let f = Desk.single.displays[0].frame
        return [WindowInfo(id: 1, frame: CGRect(x: 0, y: 0, width: f.width / 2, height: f.height)),
                WindowInfo(id: 2, frame: CGRect(x: f.width / 2, y: 0, width: f.width / 2, height: f.height))]
    }

    /// Every ordered pair of distinct displays.
    static func pairs(_ desk: Desk) -> [(DisplayInfo, DisplayInfo)] {
        desk.displays.flatMap { a in desk.displays.filter { $0.key != a.key }.map { (a, $0) } }
    }

    static func midpoint(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }

    // MARK: - Scenarios

    /// Success criterion: a deliberate head turn switches screens within 500 ms (p95).
    static func switchLatency(_ name: String, _ desk: Desk) -> BenchResult {
        var latencies: [Double] = [], missed: [String] = []
        for (a, b) in pairs(desk) {
            var sim = Sim(desk)
            sim.look(at: sim.centre(a.key), for: 1.5)
            let turnStart = sim.t
            sim.turn(from: sim.centre(a.key), to: sim.centre(b.key), over: 0.25)
            let turnEnd = sim.t
            sim.look(at: sim.centre(b.key), for: 1.5)
            if let hit = sim.actions.first(where: { $0.time >= turnStart && sim.displayOf($0.action) == b.key }) {
                latencies.append(max(hit.time - turnEnd, 0))   // switched mid-turn counts as 0
            } else {
                missed.append("\(a.key)→\(b.key)")
            }
        }
        let p95 = latencies.isEmpty ? -1 : ms(percentile(latencies, 0.95))
        return .check(group, "switch-latency/\(name)", missed.isEmpty && p95 < 500, rule: "every pair switched, p95 < 500 ms",
                      metrics: ["pairs": Double(latencies.count + missed.count),
                                "p50_ms": latencies.isEmpty ? -1 : ms(percentile(latencies, 0.5)),
                                "p95_ms": p95, "max_ms": latencies.isEmpty ? -1 : ms(latencies.max()!)],
                      reason: missed.isEmpty ? "p95 \(p95) ms" : "no switch: \(missed.joined(separator: ", "))")
    }

    /// Staring at the bezel between two screens must not ping-pong focus (hysteresis + return band).
    static func bezel(_ name: String, _ desk: Desk) -> BenchResult {
        var worst = 0, worstPair = ""
        for (a, b) in pairs(desk) {
            // Inflated frames of neighbours overlap in a thin strip along the shared edge; a corner-only touch is ~2×2.
            let strip = a.frame.insetBy(dx: -1, dy: -1).intersection(b.frame.insetBy(dx: -1, dy: -1))
            guard !strip.isNull, max(strip.width, strip.height) > 4 else { continue }
            var sim = Sim(desk)
            sim.look(at: sim.centre(a.key), for: 1)
            let before = sim.actions.count
            sim.look(at: midpoint(strip), for: 10)
            let switches = sim.actions.count - before
            if switches > worst { worst = switches; worstPair = "\(a.key)→\(b.key)" }
        }
        return .check(group, "bezel/\(name)", worst <= 1, rule: "≤ 1 switch on the shared edge",
                      metrics: ["max_switches": Double(worst)], reason: "\(worst) switches on \(worstPair)")
    }

    /// A 200 ms look at the other screen is shorter than the 300 ms dwell: no action.
    static func quickLook() -> BenchResult {
        var sim = Sim(.sideBySide)
        sim.look(at: sim.centre("L"), for: 1)
        sim.look(at: sim.centre("R"), for: 0.2)
        sim.look(at: sim.centre("L"), for: 1)
        return .check(group, "quick-look", sim.actions.isEmpty, rule: "0 actions",
                      metrics: ["actions": Double(sim.actions.count)], reason: "\(sim.actions.map(\.action))")
    }

    /// While typing, another screen still takes focus after ~1 s (screenTypingPause).
    static func typingScreen() -> BenchResult {
        var sim = Sim(.sideBySide)
        sim.look(at: sim.centre("L"), for: 1)
        let key = sim.t
        sim.input.lastKey = key
        sim.look(at: sim.centre("R"), for: 3)
        let after = sim.actions.filter { $0.time >= key }.map { $0.time - key }
        let first = after.first ?? -1
        return .check(group, "typing/screen", first >= 1.0 && first <= 1.6, rule: "no action before 1.0 s; first ≤ 1.6 s",
                      metrics: ["first_ms": first < 0 ? -1 : ms(first)], reason: first < 0 ? "no action" : "first at \(ms(first)) ms")
    }

    /// Same-screen windows wait the full typingPause (3 s) — or not at all when the guard is off.
    static func typingPane(wait: Bool) -> BenchResult {
        var settings = FocusSettings()
        settings.waitWhileTyping = wait
        var sim = Sim(.single, windows: halves(), settings: settings)
        sim.look(at: midpoint(halves()[0].frame), for: 1)
        let key = sim.t
        sim.input.lastKey = key
        sim.look(at: midpoint(halves()[1].frame), for: 5)
        let after = sim.actions.filter { $0.time >= key }
        let first = after.first.map { $0.time - key } ?? -1
        let right = after.first?.action == .window(2)
        let ok = wait ? right && first >= 3.0 && first <= 3.6 : right && first <= 0.6
        return .check(group, wait ? "typing/pane" : "typing/off", ok,
                      rule: wait ? "no action before 3.0 s; first .window(right) ≤ 3.6 s" : "first .window(right) ≤ 0.6 s",
                      metrics: ["first_ms": first < 0 ? -1 : ms(first)],
                      reason: after.first.map { "first \($0.action) at \(ms(first)) ms" } ?? "no action")
    }

    /// The mouse always wins: while it moves, gaze never moves focus.
    static func mouse() -> BenchResult {
        var sim = Sim(.sideBySide)
        sim.look(at: sim.centre("L"), for: 1)
        for _ in 0..<75 {
            sim.input.lastMouse = sim.t
            sim.look(at: sim.centre("R"), for: Sim.dt)
        }
        return .check(group, "mouse", sim.actions.isEmpty, rule: "0 actions",
                      metrics: ["actions": Double(sim.actions.count)], reason: "\(sim.actions.map(\.action))")
    }

    /// Looking down at a phone on the desk is "looking away", not a screen.
    static func offScreen() -> BenchResult {
        var sim = Sim(.sideBySide)
        sim.look(at: sim.centre("L"), for: 1)
        let from = sim.statuses.count
        sim.pose(PoseFeature(yaw: 0, pitch: -0.7, faceX: 0.5, faceY: 0.4), for: 3)
        let away = sim.statuses[from...].filter { $0 == .lookingAway }.count
        let share = Double(away) / Double(sim.statuses.count - from)
        sim.look(at: sim.centre("L"), for: 1)
        return .check(group, "off-screen", sim.actions.isEmpty && share >= 0.9, rule: "0 actions, away_share ≥ 0.9",
                      metrics: ["actions": Double(sim.actions.count), "away_share": share],
                      reason: "\(sim.actions.count) actions, away_share \(share)")
    }

    /// Looking 20° (gaze) past the outer edge of the arrangement is "away": eye 45 cm above the desk,
    /// laptop 60 cm away (its bottom edge 37° down), phone 30 cm away (56° down) → 19°. 40° ≈ the lap.
    /// Head pose = headShare × gaze angle, capped at 85° gaze.
    static func awayRows() -> [BenchResult] {
        let deg = Double.pi / 180
        var out: [BenchResult] = []
        for distance in [1800.0, 1300, 900] {
            func row(_ name: String, _ base: Desk, from key: String, yaw: (Double, Double, Double) -> Double,
                     pitch: (Double, Double, Double) -> Double) {
                var desk = base
                desk.distance = distance
                let u = desk.displays.map(\.frame).reduce(desk.displays[0].frame) { $0.union($1) }, h = desk.head
                let edges = (left: atan2(u.minX - h.x, distance), right: atan2(u.maxX - h.x, distance),
                             top: atan2(h.y - u.minY, distance), bottom: atan2(h.y - u.maxY, distance))
                let cap = 85 * deg
                let gazeYaw = min(max(yaw(edges.left, edges.right, 0), -cap), cap)
                let gazePitch = min(max(pitch(edges.top, edges.bottom, 0), -cap), cap)
                out.append(offScreen("\(name)@\(Int(distance))pt", desk, from: key,
                                     PoseFeature(yaw: desk.headShare * gazeYaw, pitch: desk.headShare * gazePitch, faceX: 0.5, faceY: 0.4)))
            }
            row("laptop-below-phone", .laptopBelow, from: "M", yaw: { _, _, z in z }, pitch: { _, b, _ in b - 20 * deg })
            row("laptop-below-lap", .laptopBelow, from: "M", yaw: { _, _, z in z }, pitch: { _, b, _ in b - 40 * deg })
            row("side-by-side-left", .sideBySide, from: "L", yaw: { l, _, _ in l - 20 * deg }, pitch: { _, _, z in z })
            row("side-by-side-right", .sideBySide, from: "R", yaw: { _, r, _ in r + 20 * deg }, pitch: { _, _, z in z })
            row("stacked-above", .stacked, from: "T", yaw: { _, _, z in z }, pitch: { t, _, _ in t + 20 * deg })
        }
        return out
    }

    /// The whole of every screen, edges and corners included, at head distances 700-2400 pt: never
    /// away (`on-screen/*`) and facing that very screen (`screen-choice/*`). Each point is reached
    /// from its own screen's centre, so the bezel band keeps the screen you came from.
    static func onScreen(_ name: String, _ desk: Desk) -> [BenchResult] {
        var away: [String] = [], wrong: [String] = [], points = 0
        for distance in [700.0, 900, 1300, 1800, 2400] {
            var d = desk
            d.distance = distance
            var sim = Sim(d)
            for display in d.displays {
                for i in 0...10 { for j in 0...10 {
                    let f = display.frame
                    let p = CGPoint(x: f.minX + (0.01 + 0.098 * Double(i)) * f.width, y: f.minY + (0.01 + 0.098 * Double(j)) * f.height)
                    sim.look(at: sim.centre(display.key), for: 0.4)
                    sim.look(at: p, for: 0.4)
                    points += 1
                    let at = "\(display.key)(\(i),\(j))@\(Int(distance))"
                    if sim.statuses.last == .lookingAway { away.append(at) }
                    else if sim.statuses.last != .facing(display.key) { wrong.append("\(at)→\(sim.statuses.last.map { "\($0)" } ?? "-")") }
                }}
            }
        }
        return [.check(group, "on-screen/\(name)", away.isEmpty, rule: "no point of any screen away at 700-2400 pt",
                       metrics: ["points": Double(points), "away": Double(away.count)],
                       reason: "away at \(away.prefix(5).joined(separator: ", "))"),
                // Known limit (Decision-engine.md, "Screen boundary"): laptop-below's three-screen junction corners.
                name == "laptop-below"
                    ? .check(group, "screen-choice/\(name)", Double(wrong.count) <= 0.03 * Double(points),
                             rule: "≤ 3 % of points on the wrong display at 700-2400 pt (known limit, see Decision-engine.md, Screen boundary)",
                             metrics: ["points": Double(points), "wrong": Double(wrong.count)],
                             reason: "wrong at \(wrong.prefix(5).joined(separator: ", "))")
                    : .check(group, "screen-choice/\(name)", wrong.isEmpty, rule: "every point faces its own screen at 700-2400 pt",
                             metrics: ["points": Double(points), "wrong": Double(wrong.count)],
                             reason: "wrong at \(wrong.prefix(5).joined(separator: ", "))")]
    }

    /// Leaning (face shifted in the image by ±0.1/±0.2 in x, ±0.1 in y) while looking at a screen's
    /// centre or 5 % inside its edges never reads as away, at 900 and 1800 pt.
    static func onScreenLean(_ name: String, _ desk: Desk) -> BenchResult {
        let leans = [CGVector(dx: 0.1, dy: 0), CGVector(dx: -0.1, dy: 0), CGVector(dx: 0.2, dy: 0), CGVector(dx: -0.2, dy: 0),
                     CGVector(dx: 0, dy: 0.1), CGVector(dx: 0, dy: -0.1)]
        let spots: [(Double, Double)] = [(0.5, 0.5), (0.05, 0.5), (0.95, 0.5), (0.5, 0.05), (0.5, 0.95)]
        var misses: [String] = [], cases = 0
        for distance in [900.0, 1800] {
            var d = desk
            d.distance = distance
            var sim = Sim(d)
            for display in d.displays {
                let f = display.frame
                for (x, y) in spots { for lean in leans {
                    let p = CGPoint(x: f.minX + x * f.width, y: f.minY + y * f.height)
                    sim.look(at: p, for: 0.4)
                    let from = sim.statuses.count
                    sim.look(at: p, for: 0.6, lean: lean)
                    cases += 1
                    if sim.statuses[from...].contains(.lookingAway) {
                        misses.append("\(display.key)(\(x),\(y)) lean(\(lean.dx),\(lean.dy))@\(Int(distance))")
                    }
                }}
            }
        }
        return .check(group, "on-screen-lean/\(name)", misses.isEmpty, rule: "never away while leaning",
                      metrics: ["cases": Double(cases), "away": Double(misses.count)],
                      reason: "away at \(misses.prefix(5).joined(separator: ", "))")
    }

    /// `from`'s centre 1 s, the away pose 3 s, `from` 1 s.
    static func offScreen(_ name: String, _ desk: Desk, from key: String, _ away: PoseFeature) -> BenchResult {
        var sim = Sim(desk)
        sim.look(at: sim.centre(key), for: 1)   // may switch to `from` first: only what follows counts
        let from = sim.statuses.count, start = sim.t
        sim.pose(away, for: 3)
        let share = Double(sim.statuses[from...].filter { $0 == .lookingAway }.count) / Double(sim.statuses.count - from)
        sim.look(at: sim.centre(key), for: 1)
        let actions = sim.actions.filter { $0.time >= start }.count
        return .check(group, "off-screen/\(name)", actions == 0 && share >= 0.9, rule: "0 actions, away_share ≥ 0.9",
                      metrics: ["actions": Double(actions), "away_share": share],
                      reason: "\(actions) actions, away_share \(share)")
    }

    /// Losing the face resets the dwell: the switch restarts its 300 ms once the face is back.
    static func noFace() -> BenchResult {
        var sim = Sim(.sideBySide)
        sim.look(at: sim.centre("L"), for: 1)
        sim.look(at: sim.centre("R"), for: 0.2)
        let lost = sim.t
        sim.noFace(for: 1)
        let back = sim.t
        sim.look(at: sim.centre("R"), for: 1)
        let during = sim.actions.filter { $0.time >= lost && $0.time < back }.count
        let first = sim.actions.first { $0.time >= back }.map { $0.time - back } ?? -1
        return .check(group, "no-face", during == 0 && first >= 0.3, rule: "no action without a face; first ≥ 300 ms after it returns",
                      metrics: ["first_after_return_ms": first < 0 ? -1 : ms(first)],
                      reason: "\(during) actions without a face; first after return \(first < 0 ? "none" : "\(ms(first)) ms")")
    }

    /// A screen without windows: the actuator can't change focus, so the engine must not repeat itself.
    static func latch() -> BenchResult {
        let l = Desk.sideBySide.displays[0].frame
        var sim = Sim(.sideBySide, windows: [WindowInfo(id: 1, frame: CGRect(x: l.midX - 600, y: l.midY - 400, width: 1200, height: 800))])
        sim.look(at: sim.centre("L"), for: 1)
        sim.look(at: sim.centre("R"), for: 3)
        let ok = sim.actions.count == 1 && sim.actions.first?.action == .display("R")
        return .check(group, "latch", ok, rule: "exactly 1 action (.display(R))",
                      metrics: ["actions": Double(sim.actions.count)], reason: "\(sim.actions.map(\.action))")
    }

    /// Same-screen window choice from calibrated gaze, away from the split (live target 0.80).
    static func windowAccuracy() -> BenchResult {
        let ws = halves(), width = Desk.single.displays[0].frame.width
        var sim = Sim(.single, windows: ws)
        var pick = SplitMix64(state: 7)
        var hits = 0
        for _ in 0..<100 {
            let w = ws[Int.random(in: 0..<2, using: &pick)]
            let gap = 0.1 * width   // ≥ 10 % of the display width from the split
            let xs: ClosedRange<Double> = w.id == 1 ? w.frame.minX...(w.frame.maxX - gap) : (w.frame.minX + gap)...(w.frame.maxX - 1)
            let p = CGPoint(x: Double.random(in: xs, using: &pick), y: Double.random(in: Double(w.frame.minY)...Double(w.frame.maxY - 1), using: &pick))
            sim.look(at: p, for: 1)
            if sim.world.focusedWindowID == w.id { hits += 1 }
        }
        let accuracy = Double(hits) / 100
        return .check(group, "window-accuracy", accuracy >= 0.9, rule: "accuracy ≥ 0.90",
                      metrics: ["accuracy": accuracy], reason: "accuracy \(accuracy)")
    }

    /// Clicks teach the map: 60 clicks under a constant gaze bias must halve the mapping error.
    static func learning() -> BenchResult {
        let bias = CGPoint(x: 0.06, y: -0.04)
        let f = Desk.single.displays[0].frame
        var sim = Sim(.single, windows: [WindowInfo(id: 1, frame: f)])
        let probes = (0..<6).flatMap { i in (0..<5).map { j in CGPoint(x: 0.1 + 0.16 * Double(i), y: 0.1 + 0.2 * Double(j)) } }
        func error() -> Double {
            let map = sim.engine.calibrations["A"]!.map!
            return probes.map { p -> Double in
                let q = map.map(CGPoint(x: p.x + bias.x, y: p.y + bias.y))
                return hypot(q.x - p.x, q.y - p.y)
            }.reduce(0, +) / Double(probes.count)
        }
        let before = error()
        var pick = SplitMix64(state: 7)
        var learned = 0
        for _ in 0..<60 {
            let p = CGPoint(x: f.minX + Double.random(in: 0.05...0.95, using: &pick) * f.width,
                            y: f.minY + Double.random(in: 0.05...0.95, using: &pick) * f.height)
            sim.look(at: p, for: 0.4, bias: bias)
            if sim.engine.recordClick(at: p, time: sim.t, world: sim.world) { learned += 1 }
        }
        let after = error()
        return .check(group, "learning", after <= 0.5 * before, rule: "error_after ≤ 0.5 × error_before",
                      metrics: ["error_before": before, "error_after": after, "learned": Double(learned)],
                      reason: "error \(before) → \(after), \(learned) clicks learned")
    }

    /// A big drift must raise "needs recalibration" within 15 clicks; a good calibration never does.
    static func recalibrationTrigger() -> BenchResult {
        func clicks(bias: CGPoint, max: Int) -> Int? {
            let f = Desk.single.displays[0].frame
            var sim = Sim(.single, windows: [WindowInfo(id: 1, frame: f)])
            var pick = SplitMix64(state: 7)
            for n in 1...max {
                let p = CGPoint(x: f.minX + Double.random(in: 0.05...0.95, using: &pick) * f.width,
                                y: f.minY + Double.random(in: 0.05...0.95, using: &pick) * f.height)
                sim.look(at: p, for: 0.4, bias: bias)
                sim.engine.recordClick(at: p, time: sim.t, world: sim.world)
                if sim.engine.calibrations["A"]!.needsRecalibration { return n }
            }
            return nil
        }
        let flagged = clicks(bias: CGPoint(x: 0.3, y: 0.3), max: 60)
        let control = clicks(bias: .zero, max: 60)
        return .check(group, "recalibration-trigger", (flagged ?? .max) <= 15 && control == nil,
                      rule: "flagged within ≤ 15 clicks; control never flagged",
                      metrics: ["clicks_to_flag": Double(flagged ?? -1), "control_flagged": control == nil ? 0 : 1],
                      reason: "flagged after \(flagged.map(String.init) ?? "never"); control \(control.map { "flagged after \($0)" } ?? "clean")")
    }
}

