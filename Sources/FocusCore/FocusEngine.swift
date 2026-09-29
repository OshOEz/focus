import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Turns gaze samples into focus actions for one setup (spec §5–8).
public final class FocusEngine {
    public var settings: FocusSettings
    public private(set) var calibrations: [String: DisplayCalibration] = [:]
    private var classifier: ScreenClassifier
    private var maps: [String: RBFMap] = [:]
    private var dwell = Dwell<FocusAction>()
    private var recent: [(sample: GazeSample, display: String)] = []

    public init(calibrations: [String: DisplayCalibration], settings: FocusSettings) {
        self.settings = settings
        classifier = ScreenClassifier(centroids: [:], hysteresis: settings.hysteresis, maxDistance: settings.offScreenDistance)
        load(calibrations)
    }

    /// Swap in another setup's calibrations.
    public func load(_ calibrations: [String: DisplayCalibration]) {
        self.calibrations = calibrations
        classifier = ScreenClassifier(centroids: calibrations.mapValues(\.pose),
                                      hysteresis: settings.hysteresis, maxDistance: settings.offScreenDistance)
        maps = calibrations.compactMapValues(\.map)
        dwell.reset()
        recent.removeAll()
    }

    public func decide(_ s: GazeSample, world: World, input: InputActivity) -> FocusAction? {
        let now = s.time
        guard s.confidence >= settings.minConfidence, s.raw.x.isFinite, s.raw.y.isFinite,
              let key = classifier.classify(s.pose),
              let display = world.displays.first(where: { $0.key == key })
        else { dwell.reset(); return nil }

        // Kept even when the guards below block, so a click right after moving the mouse can still teach us.
        recent.append((s, key))
        recent.removeAll { now - $0.sample.time > 1 }

        guard input.isQuiet(at: now, settings) else { dwell.reset(); return nil }

        let focusedDisplay = world.windows.first { $0.id == world.focusedWindowID }.flatMap { w in
            world.displays.first { $0.frame.contains(CGPoint(x: w.frame.midX, y: w.frame.midY)) }?.key
        }
        if key != focusedDisplay {
            return dwell.propose(.display(key), at: now, duration: settings.screenDwell)
        }

        guard settings.windowFocus, let map = maps[key], calibrations[key]?.needsRecalibration == false
        else { dwell.reset(); return nil }
        // The RBF returns raw unchanged far from calibration data, so a point just past a
        // display's edge (common near scrollbars/window borders) must be clamped back into it —
        // otherwise it can resolve to a window on the neighboring screen (issue #6). The upper
        // bound is clamped strictly below 1 (not to it) because CGRect.contains excludes maxX
        // but includes minX, so an exact 1.0 would land on the adjacent display's own frame.
        let local = map.map(s.raw)
        let upperBound = CGFloat(1).nextDown
        let clamped = CGPoint(x: min(max(local.x, 0), upperBound), y: min(max(local.y, 0), upperBound))
        let p = globalPoint(clamped, in: display.frame)

        var candidate: FocusAction?
        if let w = TargetResolver.window(at: p, windows: world.windows, current: world.focusedWindowID,
                                         display: display.frame, settings: settings),
           w != world.focusedWindowID {
            candidate = .window(w)
        } else if settings.paneFocus, let fw = world.focusedWindowID,
                  let i = TargetResolver.pane(at: p, panes: world.panes, display: display.frame, settings: settings),
                  i != world.focusedPane {
            candidate = .pane(window: fw, frame: world.panes[i])
        }
        return dwell.propose(candidate, at: now, duration: settings.paneDwell)
    }

    /// Learns from a click if the gaze was steady on the clicked display just before. Returns true if learned.
    @discardableResult
    public func recordClick(at p: CGPoint, time: Double, world: World) -> Bool {
        let steady = recent.filter { $0.sample.time <= time && time - $0.sample.time <= settings.screenDwell }
        guard steady.count >= 3,
              let display = world.displays.first(where: { $0.frame.contains(p) }),
              steady.allSatisfy({ $0.display == display.key }),
              calibrations[display.key] != nil
        else { return false }
        let input = CGPoint(x: median(steady.map { Double($0.sample.raw.x) }),
                            y: median(steady.map { Double($0.sample.raw.y) }))
        calibrations[display.key]!.learn(CalibrationPoint(input: input, target: localPoint(p, in: display.frame)))
        maps[display.key] = calibrations[display.key]!.map
        return true
    }
}
