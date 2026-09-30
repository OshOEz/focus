import CoreGraphics
import Foundation
import QuartzCore
import FocusCore
import GazeKit

// focus-gaze probe [secondes]  — affiche le regard brut et la pose ~2 fois par seconde
// focus-gaze screens           — calibre la pose de tête par écran puis affiche en direct l'écran regardé
// focus-gaze cameras           — liste les caméras disponibles (jamais de prompt)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func f(_ x: Double, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", x) }
func deg(_ radians: Double) -> String { f(radians * 180 / .pi, 1) + "°" }

@MainActor
func run() async {
    let args = Array(CommandLine.arguments.dropFirst())
    let mode = args.first ?? "probe"
    guard mode == "probe" || mode == "screens" || mode == "cameras" else {
        fail("usage: focus-gaze probe [secondes] | screens | cameras")
    }

    if mode == "cameras" {
        for d in CameraCapture.devices() {
            print("\(d.id)  \(d.name)" + (d.isBuiltIn ? "  (intégrée)" : ""))
        }
        return
    }

    let tracker: GazeTracker
    do { tracker = try GazeTracker() } catch { fail("Modèles introuvables : \(error)") }
    guard await CameraCapture.requestAccess() else { fail("Caméra refusée : Réglages Système > Confidentialité > Caméra pour ton terminal.") }
    let stream: AsyncStream<GazeSample>
    do { stream = try await tracker.start() } catch {
        fail("Caméra indisponible : \(error). Vérifie Réglages Système > Confidentialité > Caméra pour ton terminal.")
    }
    var samples = stream.makeAsyncIterator()

    if mode == "probe" {
        let seconds = args.count > 1 ? Double(args[1]) ?? 10 : 10
        let end = CACurrentMediaTime() + seconds
        var count = 0
        var lastPrint = 0.0
        while CACurrentMediaTime() < end, let s = await samples.next() {
            count += 1
            let now = CACurrentMediaTime()
            guard now - lastPrint >= 0.5 else { continue }
            lastPrint = now
            if s.confidence == 0 { print("no face"); continue }
            print("raw=(\(f(s.raw.x)), \(f(s.raw.y))) yaw=\(deg(s.pose.yaw)) pitch=\(deg(s.pose.pitch)) "
                + "face=(\(f(s.pose.faceX)), \(f(s.pose.faceY))) conf=\(f(s.confidence)) lag=\(f((now - s.time) * 1000, 0))ms")
        }
        print("\(f(Double(count) / seconds, 1)) échantillons/s")
    } else {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        let displays = ids.prefix(Int(n)).map { id -> (key: String, bounds: CGRect) in
            let b = CGDisplayBounds(id)
            let fp = DisplayFingerprint(vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id),
                                        serial: CGDisplaySerialNumber(id), width: Int(b.width), height: Int(b.height),
                                        originX: Int(b.minX), originY: Int(b.minY))
            return (fp.key, b)
        }

        var centroids: [String: PoseFeature] = [:]
        var names: [String: String] = [:]
        for (i, d) in displays.enumerated() {
            print("Écran \(i + 1)/\(displays.count) (\(Int(d.bounds.width))×\(Int(d.bounds.height)) en x=\(Int(d.bounds.minX))) : "
                + "regarde son centre puis appuie sur Entrée.")
            _ = readLine()
            let start = CACurrentMediaTime()
            var poses: [PoseFeature] = []
            while CACurrentMediaTime() - start < 2, let s = await samples.next() {
                // Samples captured while the user was reading the prompt are stale.
                if s.time >= start, s.confidence >= 0.5 { poses.append(s.pose) }
            }
            guard poses.count >= 10, let c = PoseFeature.median(of: poses) else {
                fail("Pas assez d'images avec un visage pour l'écran \(i + 1) (\(poses.count)). Mets-toi face à la caméra et recommence.")
            }
            // ponytail: identical monitors sharing a non-zero serial collide on key (plan 3 fixes the key).
            centroids[d.key] = c
            names[d.key] = "écran \(i + 1)"
            print("  ok : yaw \(deg(c.yaw)), pitch \(deg(c.pitch)) (\(poses.count) images)")
        }

        var classifier = ScreenClassifier(centroids: centroids, maxDistance: 0.35)
        print("Suivi en direct, Ctrl-C pour quitter.")
        var shown: String?? = .none
        while let s = await samples.next() {
            let key = s.confidence >= 0.5 ? classifier.classify(s.pose) : nil
            if shown != .some(key) {
                shown = .some(key)
                print("→ \(key.flatMap { names[$0] } ?? "hors écran")")
            }
        }
    }
    tracker.stop()
}
await run()
