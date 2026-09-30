import Testing
@testable import FocusCore

@Test func defaultsMatchSpec() {
    let s = FocusSettings()
    #expect(s.screenDwell == 0.3 && s.paneDwell == 0.3)
    #expect(s.typingPause == 3 && s.mousePause == 1.5)
    #expect(s.headTurn == 0.5)
}

@Test func screensWaitOneSecondAndPanesTheTypingPause() {
    let s = FocusSettings()
    var input = InputActivity(lastKey: 10)
    #expect(!input.allowsScreenSwitch(at: 10.9, s))
    #expect(input.allowsScreenSwitch(at: 11, s))
    #expect(!input.allowsSameScreen(at: 12.9, s))
    #expect(input.allowsSameScreen(at: 13, s))
    input.lastMouse = 13
    #expect(!input.allowsScreenSwitch(at: 14.4, s) && !input.allowsSameScreen(at: 14.4, s))
    #expect(input.allowsScreenSwitch(at: 14.5, s) && input.allowsSameScreen(at: 14.5, s))
}

@Test func waitWhileTypingOffIgnoresKeysButNotTheMouse() {
    var s = FocusSettings()
    s.waitWhileTyping = false
    let input = InputActivity(lastKey: 10, lastMouse: 10)
    #expect(!input.allowsSameScreen(at: 11, s))
    #expect(input.allowsSameScreen(at: 11.5, s) && input.allowsScreenSwitch(at: 11.5, s))
}

@Test func dwellFiresOnceAfterDuration() {
    var d = Dwell<String>()
    #expect(d.propose("A", at: 0, duration: 0.3) == nil)
    #expect(d.propose("A", at: 0.2, duration: 0.3) == nil)
    #expect(d.propose("A", at: 0.35, duration: 0.3) == "A")
    #expect(d.propose("A", at: 0.4, duration: 0.3) == nil) // restarted
}

@Test func dwellRestartsOnChangeOrNil() {
    var d = Dwell<String>()
    _ = d.propose("A", at: 0, duration: 0.3)
    #expect(d.propose("B", at: 0.2, duration: 0.3) == nil)
    #expect(d.propose("B", at: 0.4, duration: 0.3) == nil)
    #expect(d.propose(nil, at: 0.45, duration: 0.3) == nil)
    #expect(d.propose("B", at: 0.5, duration: 0.3) == nil)
    #expect(d.propose("B", at: 0.85, duration: 0.3) == "B")
}
