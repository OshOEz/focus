import CoreGraphics
import FocusCore
import FocusMac
import Foundation

/// Bench 2, "setups-two-places". Same laptop, a different external monitor on each side of it at home and at
/// the office. Arriving at each place must load that place's calibrations, so the same head turn focuses the
/// right screen, and a click learned at home must still be there after a trip to the office.
@MainActor
func setupsTwoPlaces() -> (passed: Bool, detail: String) {
    let builtIn = DisplayFingerprint(vendor: 1552, model: 41_000, serial: 1, width: 1512, height: 982, originX: 0, originY: 0)
    let dell = DisplayFingerprint(vendor: 4268, model: 16_600, serial: 777, width: 2560, height: 1440, originX: 1512, originY: 0)
    let lg = DisplayFingerprint(vendor: 7789, model: 30_000, serial: 42, width: 2560, height: 1440, originX: -2560, originY: 0)
    func cal(_ yaw: Double) -> DisplayCalibration {
        let pts = [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.1), CGPoint(x: 0.1, y: 0.9),
                   CGPoint(x: 0.9, y: 0.9), CGPoint(x: 0.5, y: 0.5)].map { CalibrationPoint(input: $0, target: $0) }
        return DisplayCalibration(pose: PoseFeature(yaw: yaw, pitch: 0, faceX: 0.5, faceY: 0.5), calibrationPoints: pts)
    }
    func world(_ ds: [DisplayFingerprint]) -> World {
        let displays = ds.map { DisplayInfo(key: $0.key, frame: CGRect(x: $0.originX, y: $0.originY, width: $0.width, height: $0.height)) }
        // One focused window on the laptop screen, so looking at the external screen is a screen switch.
        return World(displays: displays, windows: [WindowInfo(id: 1, frame: displays[0].frame)], focusedWindowID: 1)
    }
    let homeFP = Fingerprint(displays: [builtIn, dell], cameraID: "cam", wifiSSID: "Home")
    let officeFP = Fingerprint(displays: [builtIn, lg], cameraID: "cam", wifiSSID: nil)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("focus-bench-setups-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = SetupStore(directory: dir)
    let home = Setup(id: UUID(), name: "Home", fingerprint: homeFP, calibrations: [builtIn.key: cal(0), dell.key: cal(0.35)])
    let office = Setup(id: UUID(), name: "Office", fingerprint: officeFP, calibrations: [builtIn.key: cal(0), lg.key: cal(-0.35)])
    do { try store.save(home); try store.save(office) } catch { return (false, "cannot write setups: \(error)") }

    let engine = FocusEngine(calibrations: [:], settings: FocusSettings())
    let resolver = SetupResolver(store: store, engine: engine)
    var t = 0.0, worst = 0.0
    var problems: [String] = []

    /// One second of 15 fps samples facing `yaw`; returns the first action.
    func look(_ yaw: Double, _ w: World) -> FocusAction? {
        let start = t
        for _ in 0..<15 {
            t += 1.0 / 15
            let s = GazeSample(time: t, raw: CGPoint(x: 0.5, y: 0.5),
                               pose: PoseFeature(yaw: yaw, pitch: 0, faceX: 0.5, faceY: 0.5), confidence: 1)
            if let a = engine.decide(s, world: w, input: InputActivity()) { worst = max(worst, t - start); return a }
        }
        return nil
    }
    func expect(_ ok: Bool, _ what: String) { if !ok { problems.append(what) } }

    expect(resolver.resolve(homeFP) == nil && resolver.activeID == home.id, "launch at home did not load Home")
    expect(look(0.35, world([builtIn, dell])) == .display(dell.key), "home: turning right did not focus the Dell")
    _ = look(0, world([builtIn, dell]))
    expect(engine.recordClick(at: CGPoint(x: 756, y: 491), time: t, world: world([builtIn, dell])), "home: click not learned")

    expect(resolver.resolve(officeFP) == .switched(office.id, ambiguous: false), "office: no switch to Office")
    expect(look(-0.35, world([builtIn, lg])) == .display(lg.key), "office: turning left did not focus the LG")

    expect(resolver.resolve(homeFP) == .switched(home.id, ambiguous: false), "back home: no switch to Home")
    expect(engine.calibrations[builtIn.key]?.learnedPoints.count == 1, "back home: learned click lost")
    expect(look(0.35, world([builtIn, dell])) == .display(dell.key), "back home: turning right did not focus the Dell")
    expect(worst < 0.5, "switch latency \(Int(worst * 1000)) ms ≥ 500 ms")

    return problems.isEmpty
        ? (true, "home → office → home: right screen each time, learned click kept, worst switch \(Int(worst * 1000)) ms")
        : (false, problems.joined(separator: "; "))
}

/// Bench 2 (engine group), "setups-fingerprint":
/// the fingerprint sees every active screen and passes the camera ID through. It never requests Location
/// (bench code must never prompt) — when the grant isn't already there, reading the Wi-Fi name is
/// impossible without one, so this reports a skip instead of a fail.
@MainActor
func setupsFingerprint() -> BenchResult {
    // `DisplayProvider`, not raw `CGGetActiveDisplayList`: a mirrored display shows another
    // display's pixels (one screen to look at), and `DisplayProvider` already drops mirrors — the
    // same count the fingerprint itself is built from, so the two must agree by construction.
    let dp = DisplayProvider()
    let fp = EnvironmentFingerprinter.current(displays: dp.fingerprints, cameraID: "bench-camera")
    guard Permissions.location == .granted else {
        return .skipped(group: 2, name: "setups-fingerprint", reason: "Location not granted: Wi-Fi name unavailable without a prompt")
    }
    var problems: [String] = []
    if fp.displays.count != dp.displays.count { problems.append("\(fp.displays.count) screens fingerprinted, \(dp.displays.count) non-mirrored") }
    if fp.cameraID != "bench-camera" { problems.append("camera ID not passed through") }
    let detail = problems.isEmpty
        ? "\(dp.displays.count) screen(s); Wi-Fi name \(fp.wifiSSID == nil ? "not on Wi-Fi" : "read")"
        : problems.joined(separator: "; ")
    return BenchResult(group: 2, name: "setups-fingerprint", passed: problems.isEmpty, detail: detail)
}
