import AppKit
import QuartzCore
import Testing
@testable import FocusMac

@MainActor private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    return condition()
}

@MainActor @Test func lockSuspendsAndUnlockResumes() async {
    let ws = NotificationCenter(), dist = NotificationCenter()
    let m = SystemStateMonitor(workspace: ws, distributed: dist, initiallyLocked: false)
    var changes: [Bool] = []
    m.onChange = { changes.append($0) }
    dist.post(name: .init("com.apple.screenIsLocked"), object: nil)
    #expect(await eventually { m.isSuspended })
    dist.post(name: .init("com.apple.screenIsUnlocked"), object: nil)
    #expect(await eventually { !m.isSuspended })
    #expect(changes == [true, false])
}

@MainActor @Test func overlappingReasonsResumeOnlyWhenAllEnd() async {
    let ws = NotificationCenter(), dist = NotificationCenter()
    let m = SystemStateMonitor(workspace: ws, distributed: dist, initiallyLocked: false)
    var changes: [Bool] = []
    m.onChange = { changes.append($0) }
    dist.post(name: .init("com.apple.screensaver.didstart"), object: nil)
    dist.post(name: .init("com.apple.screenIsLocked"), object: nil)
    #expect(await eventually { m.reasons == [.screensaver, .locked] })
    dist.post(name: .init("com.apple.screensaver.didstop"), object: nil)
    #expect(await eventually { m.reasons == [.locked] })
    #expect(m.isSuspended)
    ws.post(name: NSWorkspace.willSleepNotification, object: nil)
    dist.post(name: .init("com.apple.screenIsUnlocked"), object: nil)
    ws.post(name: NSWorkspace.didWakeNotification, object: nil)
    #expect(await eventually { !m.isSuspended })
    #expect(changes == [true, false])
}

@MainActor @Test func startsSuspendedWhenLaunchedLocked() {
    let m = SystemStateMonitor(workspace: NotificationCenter(), distributed: NotificationCenter(), initiallyLocked: true)
    #expect(m.isSuspended && m.reasons == [.locked])
}

@MainActor @Test func inputActivityIsOnTheHostClock() {
    let a = InputMonitor().activity           // idle counters: no permission, no event contents
    let now = CACurrentMediaTime()
    #expect(a.lastKey <= now && a.lastMouse <= now)
}
