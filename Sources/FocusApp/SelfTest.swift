import FocusCore
import FocusMac
import Foundation
import GazeKit

/// `Focus --selftest`: proves the bundle is wired (models load, permission API, desktop readers, one engine
/// decision) without a window, the camera or any permission request. Prints one JSON object; exit 0 = healthy.
@MainActor
enum SelfTest {
    static func run() -> Int32 {
        var report: [String: Any] = [:]
        var ok = true
        // GazeTracker() only loads the CoreML models; it never starts the camera (that needs start()).
        do { _ = try GazeTracker(); report["models"] = "ok" }
        catch { report["models"] = "\(error)"; ok = false }
        report["camera"] = "\(Permissions.camera)"
        report["accessibility"] = "\(Permissions.accessibility)"
        report["location"] = "\(Permissions.location)"
        let dp = DisplayProvider()
        let displays = dp.displays
        report["displays"] = displays.map { ["key": $0.key, "frame": [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height]] }
        report["windows"] = WindowProvider().windows().count   // CGWindowList: no Screen Recording prompt for metadata
        // Enumeration never prompts (CameraCapture.devices()'s own guarantee): a real cameraID lets the
        // resolver match a saved setup exactly like a launch would, without opening the camera.
        let resolver = SetupResolver(store: SetupStore(directory: AppPaths.setups),
                                      engine: FocusEngine(calibrations: [:], settings: FocusSettings()))
        if let cameraID = CameraCapture.pick(CameraCapture.devices(), preferred: nil)?.id {
            resolver.resolve(EnvironmentFingerprinter.current(displays: dp.fingerprints, cameraID: cameraID))
        }
        report["setups"] = resolver.setups.count
        if let name = resolver.active?.name { report["activeSetup"] = name }
        if let d = displays.first {
            // Identity calibration of the first display, then a steady gaze at its centre → expect `.display(key)`.
            let pose = PoseFeature(yaw: 0, pitch: 0, faceX: 0.5, faceY: 0.5)
            let grid = [0.12, 0.5, 0.88].flatMap { y in [0.1, 0.5, 0.9].map { x in CGPoint(x: x, y: y) } }
            let targets = grid.map { p in
                (target: p, samples: (0..<5).map { GazeSample(time: Double($0), raw: p, pose: pose, confidence: 1) })
            }
            let cal = CalibrationBuilder.build(targets: targets, minConfidence: 0.5)
            let engine = FocusEngine(calibrations: cal.map { [d.key: $0] } ?? [:], settings: FocusSettings())
            let world = World(displays: displays, windows: [], focusedWindowID: nil)
            var action: FocusAction?
            for i in 0..<30 where action == nil {
                action = engine.decide(GazeSample(time: Double(i) * 0.1, raw: CGPoint(x: 0.5, y: 0.5), pose: pose, confidence: 1),
                                       world: world, input: InputActivity())
            }
            report["decision"] = action.map { "\($0)" } ?? "none"
            if action != .display(d.key) { ok = false }
        } else {
            report["decision"] = "no display"
            ok = false
        }
        report["ok"] = ok
        let data = (try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])) ?? Data("{}".utf8)
        print(String(decoding: data, as: UTF8.self))
        return ok ? 0 : 1
    }
}
