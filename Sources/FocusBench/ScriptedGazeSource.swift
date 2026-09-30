import FocusCore
import Foundation
import GazeKit
import QuartzCore

/// Replays a gaze trace in real time with host-clock timestamps, standing in for the camera
/// (the second implementation of GazeSource).
final class ScriptedGazeSource: GazeSource, @unchecked Sendable {
    private let samples: [GazeSample]
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var output: AsyncStream<GazeSample>.Continuation?

    init(_ samples: [GazeSample]) { self.samples = samples }

    func start() async throws -> AsyncStream<GazeSample> {
        stop()
        let (stream, cont) = AsyncStream.makeStream(of: GazeSample.self, bufferingPolicy: .bufferingNewest(1))
        let samples = samples, t0 = CACurrentMediaTime()
        let task = Task.detached {
            for var s in samples {
                let wait = t0 + s.time - CACurrentMediaTime()
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                if Task.isCancelled { break }
                s.time = CACurrentMediaTime()
                cont.yield(s)
            }
            cont.finish()
        }
        lock.withLock { self.task = task; output = cont }
        return stream
    }

    func stop() {
        let (task, cont) = lock.withLock { () -> (Task<Void, Never>?, AsyncStream<GazeSample>.Continuation?) in
            defer { self.task = nil; output = nil }
            return (self.task, output)
        }
        task?.cancel()
        cont?.finish()
    }
}
