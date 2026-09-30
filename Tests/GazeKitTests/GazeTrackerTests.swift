import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Testing
import FocusCore
@testable import GazeKit

private func pixelBuffer(width: Int, height: Int, draw: (CGContext) -> Void) throws -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pb)
    let buffer = try #require(pb)
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let ctx = try #require(CGContext(
        data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
    draw(ctx)
    return buffer
}

private func portrait() throws -> CVPixelBuffer {
    let url = try #require(Bundle.module.url(forResource: "portrait", withExtension: "jpg"))
    let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let img = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
    return try pixelBuffer(width: img.width, height: img.height) {
        $0.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    }
}

@Test func modelsLoadFromBundle() throws {
    _ = try GazeTracker()
}

@Test func frontalFaceGivesFiniteSample() throws {
    let tracker = try GazeTracker()
    let frame = try portrait()
    // The landmarker bootstraps with Vision on the first frames, then tracks.
    var sample: GazeSample?
    for i in 0..<5 where sample == nil {
        let s = tracker.process(pixelBuffer: frame, time: Double(i))
        if s.confidence > 0 { sample = s }
    }
    let s = try #require(sample)
    #expect(s.raw.x.isFinite && s.raw.y.isFinite)
    #expect(s.confidence >= 0.5)
    #expect(abs(s.pose.yaw) < 0.3 && abs(s.pose.pitch) < 0.4)   // frontal portrait, radians
    #expect((0.2...0.8).contains(s.pose.faceX) && (0...1).contains(s.pose.faceY))
}

@Test func blackFrameGivesANoFaceSample() throws {
    let tracker = try GazeTracker()
    let frame = try pixelBuffer(width: 1280, height: 720) {
        $0.setFillColor(gray: 0, alpha: 1); $0.fill(CGRect(x: 0, y: 0, width: 1280, height: 720))
    }
    for i in 0..<3 {
        let s = tracker.process(pixelBuffer: frame, time: Double(i))
        #expect(s.confidence == 0 && s.raw.x.isNaN && s.pose.yaw.isNaN && s.time == Double(i))
    }
}

@Test func stopBeforeStartIsHarmless() throws {
    let source: any GazeSource = try GazeTracker()
    source.stop()
    source.stop()
}

// No camera access in this environment (see the gated test below): these exercise the lifecycle
// lock and the generation counter in `start()`/`stop()` without ever reaching AVCaptureSession.

@Test func concurrentStopCallsDontDeadlock() throws {
    let source: any GazeSource = try GazeTracker()
    DispatchQueue.concurrentPerform(iterations: 8) { _ in source.stop() }
}

/// Doesn't reproduce the start/stop races themselves — camera access isn't authorized here, so
/// `start()` throws inside the lock before any real session (or race window) exists. Just confirms
/// concurrent `start()`/`stop()` calls resolve (each acquires `lock` in turn, one after the other)
/// instead of hanging.
@Test func concurrentStartAndStopDontHang() async throws {
    let tracker = try GazeTracker()
    async let started: Void = {
        await #expect(throws: (any Error).self) { _ = try await tracker.start() }
    }()
    tracker.stop()
    await started
}

/// `stop(ifGeneration:)` is what a stream's `onTermination` calls; it must only act when its
/// generation is still current, and do so atomically (check + stop under the same lock hold).
@Test func staleGenerationStopIsANoOp() throws {
    let tracker = try GazeTracker()
    tracker.stop()                                            // generation 0 → 1
    let current = tracker.debugGeneration
    tracker.stop(ifGeneration: current - 1)                    // stale: must not act
    #expect(tracker.debugGeneration == current)
    tracker.stop(ifGeneration: current)                        // still current: must act
    #expect(tracker.debugGeneration == current + 1)
}

@Test(.enabled(if: AVCaptureDevice.authorizationStatus(for: .video) != .authorized,
               "camera already granted: start() would really open it"))
func startWithoutCameraAccessFailsWithoutPrompting() async throws {
    let tracker = try GazeTracker()
    await #expect(throws: CameraCaptureError.self) { _ = try await tracker.start() }
}
