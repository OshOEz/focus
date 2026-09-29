import Testing
@testable import FocusCore

@Test func defaultsMatchSpec() {
    let s = FocusSettings()
    #expect(s.screenDwell == 0.3 && s.paneDwell == 0.3)
    #expect(s.typingPause == 3 && s.mousePause == 1.5)
    #expect(s.hysteresis == 0.25)
}

@Test func quietOnlyAfterTypingAndMousePauses() {
    let s = FocusSettings()
    var input = InputActivity()
    #expect(input.isQuiet(at: 0, s))
    input.lastKey = 10
    #expect(!input.isQuiet(at: 12.9, s))
    #expect(input.isQuiet(at: 13, s))
    input.lastMouse = 13
    #expect(!input.isQuiet(at: 14.4, s))
    #expect(input.isQuiet(at: 14.5, s))
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
