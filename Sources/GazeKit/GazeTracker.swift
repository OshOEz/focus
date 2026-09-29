import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import FocusCore

/// Camera → CoreML FaceMesh → head pose → homography eye patch → BlazeGaze, one GazeSample per frame.
/// Mirrors MacGazeControl.runPipeline (CoreML branch) without RBF or smoothing: FocusCore does those.
public final class GazeTracker: @unchecked Sendable {
    public enum Failure: Error { case modelMissing(String) }

    private let camera = CameraCapture()
    private let mesh: CoreMLFaceMeshLandmarker
    private let blaze: BlazeGazeRunner
    private var loop: Task<Void, Never>?

    public init() throws {
        guard let meshURL = Bundle.module.url(forResource: "face_mesh", withExtension: "mlmodelc") else {
            throw Failure.modelMissing("face_mesh.mlmodelc")
        }
        guard let blazeURL = Bundle.module.url(forResource: "blazegaze", withExtension: "mlmodelc") else {
            throw Failure.modelMissing("blazegaze.mlmodelc")
        }
        mesh = try CoreMLFaceMeshLandmarker(modelURL: meshURL)
        blaze = try BlazeGazeRunner(modelURL: blazeURL)
    }

    /// Starts the camera. Single consumer; only the newest sample is buffered.
    public func start() async throws -> AsyncStream<GazeSample> {
        try await camera.start()
        let frames = camera.frames
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { cont in
            let task = Task { [self] in
                for await f in frames {
                    if Task.isCancelled { break }
                    if let s = process(pixelBuffer: f.pixelBuffer, time: f.timestampSeconds) { cont.yield(s) }
                }
                cont.finish()
            }
            loop = task
            cont.onTermination = { [weak self] _ in
                task.cancel()
                self?.camera.stop()
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        camera.stop()
    }

    /// One frame → sample, or nil without a usable face. Not thread-safe; never call while started.
    func process(pixelBuffer pb: CVPixelBuffer, time: Double) -> GazeSample? {
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard let r = mesh.detect(pixelBuffer: pb), r.landmarks.count >= 468,
              let patch = HomographyEyePatchExtractor.extract(pixelBuffer: pb, landmarks: r.landmarks,
                                                               frameWidth: w, frameHeight: h)
        else { return nil }
        let pose = HeadPoseSolver.solve(landmarks: r.landmarks, width: w, height: h)
        let origin = MetricFaceOrigin.compute(landmarks: r.landmarks, width: w, height: h)
        guard let raw = blaze.predict(eyePatch: patch, headVector: pose.flatMap { Self.vector($0.headVector) },
                                      faceOrigin3D: Self.vector(origin))
        else { return nil }
        let xs = r.landmarks.map { $0[0] }, ys = r.landmarks.map { $0[1] }
        let face = PoseFeature(yaw: pose?.yaw ?? .nan, pitch: pose?.pitch ?? .nan,
                               faceX: (xs.min()! + xs.max()!) / 2, faceY: (ys.min()! + ys.max()!) / 2)
        return GazeSample(time: time, raw: raw, pose: face, confidence: r.score)
    }

    private static func vector(_ v: [Float]) -> MLMultiArray? {
        guard v.count == 3, let a = try? MLMultiArray(shape: [1, 3], dataType: .float32) else { return nil }
        for i in 0..<3 { a[i] = NSNumber(value: v[i]) }
        return a
    }
}
