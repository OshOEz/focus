import Foundation
import Testing
@testable import FocusCore

private let builtIn = DisplayFingerprint(vendor: 1552, model: 41_000, serial: 1, width: 1512, height: 982, originX: 0, originY: 0)
private let dell = DisplayFingerprint(vendor: 4268, model: 16_600, serial: 777, width: 2560, height: 1440, originX: 1512, originY: 0)
private let lg = DisplayFingerprint(vendor: 7789, model: 30_000, serial: 42, width: 2560, height: 1440, originX: -2560, originY: 0)
private let yaws = [builtIn.key: 0.0, dell.key: 0.35, lg.key: -0.35]

private func place(_ d: [DisplayFingerprint], ssid: String? = nil, camera: String = "cam") -> Fingerprint {
    Fingerprint(displays: d, cameraID: camera, wifiSSID: ssid)
}

/// Identity calibration: raw gaze already equals the local point.
private func cal(yaw: Double) -> DisplayCalibration {
    let pts = [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.1), CGPoint(x: 0.1, y: 0.9),
               CGPoint(x: 0.9, y: 0.9), CGPoint(x: 0.5, y: 0.5)].map { CalibrationPoint(input: $0, target: $0) }
    return DisplayCalibration(pose: PoseFeature(yaw: yaw, pitch: 0, faceX: 0.5, faceY: 0.5), calibrationPoints: pts)
}

private func setup(_ name: String, _ fp: Fingerprint) -> Setup {
    Setup(id: UUID(), name: name, fingerprint: fp,
          calibrations: Dictionary(uniqueKeysWithValues: fp.displays.map { ($0.key, cal(yaw: yaws[$0.key] ?? 0)) }))
}

private let home = setup("Home", place([builtIn, dell]))
private let office = setup("Office", place([builtIn, lg]))
private let unknown = place([builtIn], camera: "usb-cam")

@Suite @MainActor struct SetupResolverTests {
    private func make(_ setups: [Setup]) -> (SetupResolver, FocusEngine, SetupStore) {
        let store = SetupStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        for s in setups { try! store.save(s) }
        let engine = FocusEngine(calibrations: [:], settings: FocusSettings())
        return (SetupResolver(store: store, engine: engine), engine, store)
    }

    @Test func launchLoadsTheMatchingSetupQuietly() {
        let (r, e, store) = make([home, office])
        defer { try? FileManager.default.removeItem(at: store.directory) }
        #expect(r.resolve(home.fingerprint) == nil)
        #expect(r.activeID == home.id)
        #expect(e.calibrations == home.calibrations)
    }

    @Test func arrivingElsewhereSwitchesAndSaysSo() {
        let (r, e, store) = make([home, office])
        defer { try? FileManager.default.removeItem(at: store.directory) }
        r.resolve(home.fingerprint)
        #expect(r.resolve(office.fingerprint) == .switched(office.id, ambiguous: false))
        #expect(e.calibrations == office.calibrations)
        #expect(r.resolve(office.fingerprint) == nil)   // idempotent: a callback storm changes nothing
    }

    @Test func unknownPlaceEmptiesTheEngineAndIsAnnouncedOnce() {
        let (r, e, store) = make([home])
        defer { try? FileManager.default.removeItem(at: store.directory) }
        r.resolve(home.fingerprint)
        #expect(r.resolve(unknown) == .newPlace)
        #expect(r.activeID == nil)
        #expect(e.calibrations.isEmpty)
        r.resolve(home.fingerprint)
        #expect(r.resolve(unknown) == nil)
    }

    @Test func firstRunWithoutSetupsAnnouncesNothing() {
        let (r, _, store) = make([])
        defer { try? FileManager.default.removeItem(at: store.directory) }
        #expect(r.resolve(unknown) == nil)
        #expect(r.current == unknown)
    }

    /// #32: a calibration reached with no active setup (skipped guide, an unmatched place, or the active
    /// setup just deleted) must not lose its results. `AppController.startCalibration` now delegates that
    /// case to `SetupController.calibrateThisPlace`, which is exactly `createSetup` + `storeCalibrations` —
    /// this proves that pair creates a setup, activates it, and actually keeps what's stored in it.
    @Test func calibratingWithNoActiveSetupCreatesOne() throws {
        let (r, e, store) = make([])
        defer { try? FileManager.default.removeItem(at: store.directory) }
        #expect(r.resolve(unknown) == nil)   // first run: read the place, nothing to match yet
        #expect(r.activeID == nil)
        let s = try #require(try r.createSetup(named: "Home"))
        #expect(r.activeID == s.id)
        try r.storeCalibrations([builtIn.key: cal(yaw: 0)], into: s.id)
        #expect(e.calibrations[builtIn.key] != nil)
        #expect(store.loadAll().first { $0.id == s.id }?.calibrations[builtIn.key] != nil)
    }

    @Test func emptyReadingsAreIgnored() {
        let (r, _, store) = make([home])
        defer { try? FileManager.default.removeItem(at: store.directory) }
        r.resolve(home.fingerprint)
        #expect(r.resolve(place([])) == nil)
        #expect(r.resolve(place([builtIn, dell], camera: "")) == nil)
        #expect(r.activeID == home.id)
        #expect(r.current == home.fingerprint)
    }

    @Test func wifiDropKeepsTieBrokenSetup() {
        let a = setup("Office A", place([builtIn, dell], ssid: "Office"))
        let b = setup("Cowork", place([builtIn, dell], ssid: "Cowork"))
        let (r, _, store) = make([a, b])
        defer { try? FileManager.default.removeItem(at: store.directory) }
        r.resolve(place([builtIn, dell], ssid: "Cowork"))
        #expect(r.activeID == b.id)
        #expect(r.resolve(place([builtIn, dell])) == nil)
        #expect(r.activeID == b.id)
        #expect(r.current?.wifiSSID == "Cowork")
    }

    @Test func manualChoiceHoldsUntilEnvironmentChanges() {
        let (r, _, store) = make([home, office])
        defer { try? FileManager.default.removeItem(at: store.directory) }
        r.resolve(home.fingerprint)
        r.choose(office.id)
        #expect(r.activeID == office.id && r.overrideID == office.id)
        #expect(r.resolve(home.fingerprint) == nil)
        #expect(r.resolve(place([builtIn, dell], ssid: "Joined")) == nil)   // Wi-Fi joining after wake is not a move
        #expect(r.activeID == office.id)
        #expect(r.resolve(unknown) == .newPlace)
        #expect(r.overrideID == nil)
        #expect(r.resolve(home.fingerprint) == .switched(home.id, ambiguous: false))
    }

    @Test func choosingAmongLookAlikesLearnsTheWifi() throws {
        let a = setup("Desk", place([builtIn, dell]))
        let b = setup("Café", place([builtIn, dell]))
        let (r, _, store) = make([a, b])
        defer { try? FileManager.default.removeItem(at: store.directory) }
        r.resolve(place([builtIn, dell], ssid: "CafeNet"))
        #expect(r.candidates.count == 2)
        let other = try #require(r.candidates.first { $0 != r.activeID })
        r.choose(other)
        #expect(store.loadAll().first { $0.id == other }?.fingerprint.wifiSSID == "CafeNet")
        r.resolve(unknown)
        #expect(r.resolve(place([builtIn, dell], ssid: "CafeNet")) == .switched(other, ambiguous: false))
    }

    @Test func learnedClicksSurviveAwayAndBack() throws {
        let (r, e, store) = make([home, office])
        defer { try? FileManager.default.removeItem(at: store.directory) }
        r.resolve(home.fingerprint)
        let world = World(displays: [DisplayInfo(key: builtIn.key, frame: CGRect(x: 0, y: 0, width: 1512, height: 982))],
                          windows: [], focusedWindowID: nil)
        for t in [0.0, 0.1, 0.2] {
            _ = e.decide(GazeSample(time: t, raw: CGPoint(x: 0.5, y: 0.5),
                                    pose: PoseFeature(yaw: 0, pitch: 0, faceX: 0.5, faceY: 0.5), confidence: 1),
                         world: world, input: InputActivity())
        }
        #expect(e.recordClick(at: CGPoint(x: 756, y: 491), time: 0.25, world: world))
        r.resolve(office.fingerprint)
        r.resolve(home.fingerprint)
        #expect(e.calibrations[builtIn.key]?.learnedPoints.count == 1)
        #expect(store.loadAll().first { $0.id == home.id }?.calibrations[builtIn.key]?.learnedPoints.count == 1)
    }

    @Test func calibrationFinishingAfterAMoveGoesToItsOwnSetup() throws {
        let (r, e, store) = make([home])
        defer { try? FileManager.default.removeItem(at: store.directory) }
        r.resolve(home.fingerprint)
        r.resolve(place([builtIn, lg]))
        let cafe = try #require(try r.createSetup(named: "Café"))
        #expect(r.activeID == cafe.id)
        #expect(r.resolve(home.fingerprint) == .switched(home.id, ambiguous: false))
        try r.storeCalibrations([lg.key: cal(yaw: -0.35)], into: cafe.id)
        #expect(e.calibrations == home.calibrations)
        #expect(store.loadAll().first { $0.id == cafe.id }?.calibrations[lg.key] != nil)
    }

    @Test func newSetupKeepsIdenticalScreensFromLastSetup() throws {
        let (r, _, s1) = make([home])
        defer { try? FileManager.default.removeItem(at: s1.directory) }
        r.resolve(home.fingerprint)
        #expect(r.resolve(place([builtIn, dell, lg])) == .newPlace)
        let bigger = try #require(try r.createSetup(named: "Home + LG"))
        #expect(Set(bigger.calibrations.keys) == [builtIn.key, dell.key])

        let (r2, _, s2) = make([home])
        defer { try? FileManager.default.removeItem(at: s2.directory) }
        r2.resolve(home.fingerprint)
        r2.resolve(place([builtIn, dell], camera: "usb-cam"))
        #expect(try #require(try r2.createSetup(named: "USB")).calibrations.isEmpty)   // other camera: nothing carried
    }

    @Test func createSetupCarriesOverFromActiveNotStaleLast() throws {
        let (r, _, store) = make([home, office])
        defer { try? FileManager.default.removeItem(at: store.directory) }
        r.resolve(home.fingerprint)     // activeID = home, lastActiveID = nil
        r.resolve(office.fingerprint)   // activeID = office, lastActiveID = home
        r.resolve(office.fingerprint)   // idempotent: still active = office, lastActiveID stays home (stale)
        // office is the setup actually in use; lastActiveID (home) is stale. The carry-over must use office.
        let s = try #require(try r.createSetup(named: "Office Variant"))
        #expect(s.calibrations == office.calibrations)
    }

    @Test func pickingAnotherSetupWhileAtAMatchedPlaceLeavesItUnchanged() throws {
        // Same raw monitors (builtIn+dell) as `desk`, but scaled/moved and reachable only as `cafe` (unique
        // match by geometry). Picking `desk` while standing at `cafe`'s place must not import cafe's geometry
        // into desk just because the two share the same monitor keys.
        var scaledBuiltIn = builtIn; scaledBuiltIn.width = 1800; scaledBuiltIn.height = 1169
        var movedDell = dell; movedDell.originX = 1800
        let desk = setup("Desk", place([builtIn, dell]))
        let cafe = setup("Cafe", place([scaledBuiltIn, movedDell], ssid: "CafeNet"))
        let (r, _, store) = make([desk, cafe])
        defer { try? FileManager.default.removeItem(at: store.directory) }
        r.resolve(cafe.fingerprint)   // current genuinely (and uniquely) matches Cafe; nothing "new" here
        r.choose(desk.id)             // manual pick of the unrelated, non-matching Desk
        #expect(store.loadAll().first { $0.id == desk.id }?.fingerprint == desk.fingerprint)
        // Proof it wasn't corrupted: back at Desk's own (unscaled) place, it still matches on its own.
        let fresh = SetupResolver(store: store, engine: FocusEngine(calibrations: [:], settings: FocusSettings()))
        #expect(fresh.resolve(desk.fingerprint) == nil)
        #expect(fresh.activeID == desk.id)
    }

    @Test func pickingASetupAdoptsNewGeometry() throws {
        var scaledBuiltIn = builtIn; scaledBuiltIn.width = 1800; scaledBuiltIn.height = 1169
        var movedDell = dell; movedDell.originX = 1800
        let scaled = place([scaledBuiltIn, movedDell])
        let (r, _, store) = make([home])
        defer { try? FileManager.default.removeItem(at: store.directory) }
        #expect(r.resolve(scaled) == .newPlace)
        r.choose(home.id)
        #expect(r.activeID == home.id)
        let relaunched = SetupResolver(store: store, engine: FocusEngine(calibrations: [:], settings: FocusSettings()))
        #expect(relaunched.resolve(scaled) == nil)
        #expect(relaunched.activeID == home.id)
    }

    @Test func deletingTheActiveSetupFallsBackQuietly() throws {
        let (r, e, store) = make([home, office])
        defer { try? FileManager.default.removeItem(at: store.directory) }
        r.resolve(home.fingerprint)
        #expect(try r.delete(home.id) == nil)
        #expect(r.activeID == nil && e.calibrations.isEmpty)
        #expect(store.loadAll().map(\.id) == [office.id])
        try r.delete(home.id)   // already gone: no throw
    }

    @Test func deletingThePickedSetupReturnsToAutomatic() throws {
        let (r, _, store) = make([home, office])
        defer { try? FileManager.default.removeItem(at: store.directory) }
        r.resolve(home.fingerprint)
        r.choose(office.id)
        #expect(try r.delete(office.id) == .switched(home.id, ambiguous: false))
        #expect(r.overrideID == nil && r.activeID == home.id)
    }

    @Test func renameTrimsAndIgnoresBlank() throws {
        let (r, _, store) = make([home])
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try r.rename(home.id, to: "  Desk  ")
        try r.rename(home.id, to: "   ")
        #expect(store.loadAll().first?.name == "Desk")
    }
}
