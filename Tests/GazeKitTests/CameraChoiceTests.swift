import Testing
@testable import GazeKit

private let builtIn = CameraDevice(id: "b", name: "FaceTime HD", isBuiltIn: true)
private let usb = CameraDevice(id: "u", name: "USB", isBuiltIn: false)

@Test func pickPrefersTheChosenCamera() {
    #expect(CameraCapture.pick([builtIn, usb], preferred: "u") == usb)
}

@Test func pickFallsBackToTheBuiltInCamera() {
    #expect(CameraCapture.pick([usb, builtIn], preferred: "unplugged") == builtIn)
    #expect(CameraCapture.pick([usb, builtIn], preferred: nil) == builtIn)
}

@Test func pickWithoutBuiltInTakesTheFirstAndNothingGivesNil() {
    #expect(CameraCapture.pick([usb], preferred: nil) == usb)
    #expect(CameraCapture.pick([], preferred: "u") == nil)
}

@Test func listingCamerasNeedsNoAccess() {
    let list = CameraCapture.devices()          // enumeration never opens a device, so never prompts
    #expect(Set(list.map(\.id)).count == list.count)
}
