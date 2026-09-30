import CoreGraphics
import Foundation
import FocusCore

/// Seeded RNG (SplitMix64): benches must be reproducible run to run.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Box–Muller normal sample.
    mutating func gaussian(_ sigma: Double) -> Double {
        let u = Double.random(in: .ulpOfOne..<1, using: &self), v = Double.random(in: 0..<1, using: &self)
        return sigma * (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
}

/// A synthetic desk: the head sits `distance` points in front of the centre of the displays'
/// bounding box. The head covers `headShare` of the gaze angle, the eyes the rest (~60-70 % for
/// large gaze shifts, Freedman 2008) — why screen choice is a head-pose problem.
/// Noise defaults: pose 0.01 rad (≈0.6°, focus-gaze probe at rest), raw gaze 0.03 (BlazeGaze units).
struct Desk {
    var displays: [DisplayInfo]
    var distance = 1800.0
    var headShare = 0.65
    var poseNoise = 0.01
    var gazeNoise = 0.03

    var head: CGPoint {
        let u = displays.map(\.frame).reduce(displays[0].frame) { $0.union($1) }
        return CGPoint(x: u.midX, y: u.midY)
    }

    func pose(lookingAt p: CGPoint) -> PoseFeature {
        PoseFeature(yaw: headShare * atan2(p.x - head.x, distance), pitch: headShare * atan2(head.y - p.y, distance),
                    faceX: 0.5, faceY: 0.4)
    }

    func display(at p: CGPoint) -> DisplayInfo? { displays.first { $0.frame.contains(p) } }

    /// One sample looking at `p` (global): noisy pose, raw gaze = local point + `bias` + noise.
    func sample(at t: Double, lookingAt p: CGPoint, bias: CGPoint = .zero, rng: inout SplitMix64) -> GazeSample {
        var pose = pose(lookingAt: p)
        pose.yaw += rng.gaussian(poseNoise); pose.pitch += rng.gaussian(poseNoise)
        let d = display(at: p) ?? displays[0]
        let local = CGPoint(x: (p.x - d.frame.minX) / d.frame.width + bias.x + rng.gaussian(gazeNoise),
                            y: (p.y - d.frame.minY) / d.frame.height + bias.y + rng.gaussian(gazeNoise))
        return GazeSample(time: t, raw: local, pose: pose, confidence: 0.9)
    }

    /// Calibrates every display with the real CalibrationLayout + CalibrationBuilder
    /// (10 samples per dot, same noise as use).
    func calibrate(rng: inout SplitMix64) -> [String: DisplayCalibration] {
        var out: [String: DisplayCalibration] = [:]
        let layout = CalibrationLayout.targets(for: displays)
        for d in displays {   // display order, not dictionary order: the RNG draws must not depend on hash seeding
            let dots = layout[d.key]!
            let targets = dots.map { dot -> (target: CGPoint, samples: [GazeSample]) in
                let g = CGPoint(x: d.frame.minX + dot.x * d.frame.width, y: d.frame.minY + dot.y * d.frame.height)
                return (dot, (0..<10).map { sample(at: Double($0) / 15, lookingAt: g, rng: &rng) })
            }
            out[d.key] = CalibrationBuilder.build(targets: targets, minConfidence: 0.5)
        }
        return out
    }

    static let single = Desk(displays: [DisplayInfo(key: "A", frame: CGRect(x: 0, y: 0, width: 1512, height: 982))])
    static let sideBySide = Desk(displays: [DisplayInfo(key: "L", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
                                            DisplayInfo(key: "R", frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080))])
    static let stacked = Desk(displays: [DisplayInfo(key: "T", frame: CGRect(x: 0, y: -1080, width: 1920, height: 1080)),
                                         DisplayInfo(key: "B", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))])
    static let laptopBelow = Desk(displays: [DisplayInfo(key: "A", frame: CGRect(x: 0, y: 0, width: 2560, height: 1440)),
                                             DisplayInfo(key: "B", frame: CGRect(x: 2560, y: 0, width: 2560, height: 1440)),
                                             DisplayInfo(key: "M", frame: CGRect(x: 1792, y: 1440, width: 1536, height: 960))])
}

/// Drives a real FocusEngine at 15 fps on a synthetic clock and applies its actions the way a
/// working actuator would, so scenarios measure decisions, not AX.
struct Sim {
    let desk: Desk
    let engine: FocusEngine
    var world: World
    var input = InputActivity()
    var t = 0.0
    var actions: [(time: Double, action: FocusAction)] = []
    var statuses: [EngineStatus] = []
    var rng: SplitMix64
    static let dt = 1.0 / 15

    /// Default world: one 1200×800 window centred on each display, the first one focused.
    init(_ desk: Desk, windows: [WindowInfo]? = nil, settings: FocusSettings = FocusSettings()) {
        self.desk = desk
        var r = SplitMix64(state: 42)
        engine = FocusEngine(calibrations: desk.calibrate(rng: &r), settings: settings)
        rng = r
        let ws = windows ?? desk.displays.enumerated().map { i, d in
            WindowInfo(id: UInt32(i + 1), frame: CGRect(x: d.frame.midX - 600, y: d.frame.midY - 400, width: 1200, height: 800))
        }
        world = World(displays: desk.displays, windows: ws, focusedWindowID: ws.first?.id)
    }

    mutating func look(at p: CGPoint, for seconds: Double, bias: CGPoint = .zero) {
        feed(seconds) { sim in sim.desk.sample(at: sim.t, lookingAt: p, bias: bias, rng: &sim.rng) }
    }

    /// Linear head/eye movement from `a` to `b`.
    mutating func turn(from a: CGPoint, to b: CGPoint, over seconds: Double) {
        let start = t
        feed(seconds) { sim in
            let k = min((sim.t - start) / seconds, 1)
            return sim.desk.sample(at: sim.t, lookingAt: CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k), rng: &sim.rng)
        }
    }

    mutating func pose(_ p: PoseFeature, for seconds: Double) {
        feed(seconds) { GazeSample(time: $0.t, raw: CGPoint(x: 0.5, y: 0.5), pose: p, confidence: 0.9) }
    }

    mutating func noFace(for seconds: Double) { feed(seconds) { .noFace(at: $0.t) } }

    private mutating func feed(_ seconds: Double, _ make: (inout Sim) -> GazeSample) {
        let end = t + seconds
        while t < end - 1e-9 {
            let s = make(&self)
            if let a = engine.decide(s, world: world, input: input) { actions.append((t, a)); apply(a) }
            statuses.append(engine.status)
            t += Self.dt
        }
    }

    /// What a working actuator does: focus the window (or the last/topmost window of the display).
    mutating func apply(_ a: FocusAction) {
        switch a {
        case .window(let id): world.focusedWindowID = id
        case .display(let key):
            if let d = world.displays.first(where: { $0.key == key }),
               let id = TargetResolver.windowToRestore(on: d.frame, windows: world.windows, last: nil) {
                world.focusedWindowID = id
            }
        case .pane: break
        }
    }

    func centre(_ key: String) -> CGPoint { let f = desk.displays.first { $0.key == key }!.frame; return CGPoint(x: f.midX, y: f.midY) }
    func displayOf(_ a: FocusAction) -> String? {
        switch a {
        case .display(let k): return k
        case .window(let id), .pane(let id, _):
            guard let f = world.windows.first(where: { $0.id == id })?.frame else { return nil }
            return desk.display(at: CGPoint(x: f.midX, y: f.midY))?.key
        }
    }
}
