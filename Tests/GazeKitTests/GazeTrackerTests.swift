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
    for i in 0..<5 { sample = sample ?? tracker.process(pixelBuffer: frame, time: Double(i)) }
    let s = try #require(sample)
    #expect(s.raw.x.isFinite && s.raw.y.isFinite)
    #expect(s.confidence >= 0.5)
    #expect(abs(s.pose.yaw) < 0.3 && abs(s.pose.pitch) < 0.4)   // frontal portrait, radians
    #expect((0.2...0.8).contains(s.pose.faceX) && (0...1).contains(s.pose.faceY))
}

@Test func blackFrameGivesNoSample() throws {
    let tracker = try GazeTracker()
    let frame = try pixelBuffer(width: 1280, height: 720) {
        $0.setFillColor(gray: 0, alpha: 1); $0.fill(CGRect(x: 0, y: 0, width: 1280, height: 720))
    }
    for i in 0..<3 where tracker.process(pixelBuffer: frame, time: Double(i)) != nil {
        Issue.record("black frame produced a sample at iteration \(i)")
    }
}
