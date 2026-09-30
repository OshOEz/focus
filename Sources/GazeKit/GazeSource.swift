import FocusCore

/// The only seam between the camera and the app. Two implementations: `GazeTracker` (camera)
/// and `ScriptedGazeSource` (focus-bench, replays traces with host-clock times).
public protocol GazeSource: AnyObject, Sendable {
    /// Starts producing samples; restartable after `stop()`. The returned stream finishes on `stop()`.
    func start() async throws -> AsyncStream<GazeSample>
    func stop()
}
