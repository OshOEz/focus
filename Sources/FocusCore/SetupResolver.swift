import Foundation

/// What the app should tell the user after a resolve.
public enum SetupEvent: Equatable, Sendable {
    /// The engine now uses another setup because the place changed. `ambiguous`: several setups fit and the
    /// menu offers the others.
    case switched(UUID, ambiguous: Bool)
    /// No saved setup fits these screens and this camera: the engine has no calibration until the place is calibrated.
    case newPlace
}

/// Picks the setup the engine uses and owns the setup files (rules in docs/wiki/Setups.md and docs/wiki/Decisions.md).
///
/// In FocusCore rather than the app because these rules are the fragile part of setups and must run under
/// `swift test` and the headless bench. `@MainActor`: `FocusEngine` is deliberately not Sendable
/// and lives on whatever isolation domain its owner runs on, so this resolver calls it from the main actor.
/// - a manual pick holds until the environment changes (`isEnvironmentChange`);
/// - a Wi-Fi drop never counts as a move: the last SSID is kept while screens and camera stay the same;
/// - among look-alike setups, the one in use stays in use;
/// - what the engine learned from clicks is written back before every switch;
/// - calibrations are always keyed by `DisplayFingerprint.uniqueKeys(_:)`, the one function that turns a list
///   of displays into calibration keys, so identical monitors sharing a serial never collide.
/// Invariant: this is the only caller of `engine.load` and `SetupStore.save/delete`, so the engine's
/// calibrations always belong to `active`.
@MainActor
public final class SetupResolver {
    public private(set) var setups: [Setup]
    public private(set) var activeID: UUID?
    public private(set) var overrideID: UUID?
    /// Setups that all fit the current place (ambiguous match); empty otherwise.
    public private(set) var candidates: [UUID] = []
    /// Last usable reading of the environment (SSID carried over a Wi-Fi drop).
    public private(set) var current: Fingerprint?

    private let store: SetupStore
    private let engine: FocusEngine
    private var hasResolved = false
    private var lastActiveID: UUID?
    private var announced: [Fingerprint] = []

    public init(store: SetupStore, engine: FocusEngine) {
        self.store = store
        self.engine = engine
        setups = store.loadAll()
    }

    public var active: Setup? { setups.first { $0.id == activeID } }

    /// Call on launch and whenever screens, camera or Wi-Fi may have changed.
    @discardableResult
    public func resolve(_ reading: Fingerprint) -> SetupEvent? {
        // No screen (lid closed, mid-reconfiguration) or no camera: nothing to match, keep the current choice.
        guard !reading.displays.isEmpty, !reading.cameraID.isEmpty else { return nil }
        let moved = Self.isEnvironmentChange(from: current, to: reading)
        if moved { overrideID = nil }
        var r = reading
        if r.wifiSSID == nil, !moved { r.wifiSSID = current?.wifiSSID }
        current = r
        return apply()
    }

    /// Manual pick from the menu; holds until the environment changes.
    public func choose(_ id: UUID) {
        guard let i = setups.firstIndex(where: { $0.id == id }) else { return }
        if let current {
            var fp = setups[i].fingerprint
            // Same monitors and camera, only geometry differs (resolution, scaling, arrangement): adopt it, or the
            // pick would be reported as a new place again on every launch. Only when *nothing* recognizes the
            // current place (`SetupMatcher` says `.none`) — otherwise this is a manual override while standing
            // somewhere that already matches a setup (possibly this one, possibly another), and rewriting the
            // picked setup's fingerprint to the current one would corrupt it (picking Home while actually at a
            // matched Office must never turn Home into Office's arrangement). Compared via `uniqueKeys`, not raw
            // `.key`: two displays that legitimately share a key (identical monitors, same serial) must still be
            // told apart, or the Set comparison silently drops one of them.
            if fp.cameraID == current.cameraID, SetupMatcher.match(current, in: setups) == .none,
               DisplayFingerprint.uniqueKeys(fp.displays).sorted() == DisplayFingerprint.uniqueKeys(current.displays).sorted() {
                fp.displays = current.displays
            }
            // Picking among look-alikes while the Wi-Fi name is known teaches this setup its network, so
            // SetupMatcher's SSID rule breaks the tie by itself next time.
            if candidates.contains(id), let ssid = current.wifiSSID { fp.wifiSSID = ssid }
            if fp != setups[i].fingerprint {
                setups[i].fingerprint = fp
                try? store.save(setups[i])   // losing this only costs asking again
            }
        }
        overrideID = id
        if id != activeID { activate(id) }
    }

    /// Drops the manual pick and matches again.
    @discardableResult
    public func automatic() -> SetupEvent? {
        overrideID = nil
        return apply()
    }

    /// Starts a setup for the current place and makes it active. Screens identical (same fingerprint, hence same
    /// position) to ones of the previously used setup keep their calibration when the camera is the same:
    /// plugging a monitor in at your desk shouldn't make you recalibrate the others. Nil before any reading.
    public func createSetup(named name: String) throws -> Setup? {
        guard let current else { return nil }
        var s = Setup(id: UUID(), name: name, fingerprint: current, calibrations: [:])
        // Prefer the setup actually active right now over the merely last-active one: `lastActiveID` can be
        // stale (the setup active two switches ago) while `activeID` is still a perfectly good match.
        if let prev = setups.first(where: { $0.id == (activeID ?? lastActiveID) }), prev.fingerprint.cameraID == current.cameraID {
            let currentSet = Set(current.displays)
            let kept = zip(prev.fingerprint.displays, DisplayFingerprint.uniqueKeys(prev.fingerprint.displays))
                .filter { currentSet.contains($0.0) }.map(\.1)
            s.calibrations = prev.calibrations.filter { kept.contains($0.key) }
        }
        try store.save(s)
        setups.append(s)
        activate(s.id)
        candidates = []
        return s
    }

    /// Saves finished calibrations into `id`, the setup active when calibration *started*: a place change
    /// mid-calibration must not write one place's calibration into another's setup. Recalibrated screens lose
    /// their learned clicks (learned points were measured against the old calibration); the others keep theirs.
    public func storeCalibrations(_ calibrations: [String: DisplayCalibration], into id: UUID) throws {
        guard let i = setups.firstIndex(where: { $0.id == id }) else { return }
        if id == activeID { setups[i].calibrations = engine.calibrations }
        setups[i].calibrations.merge(calibrations) { $1 }
        try store.save(setups[i])
        if id == activeID { engine.load(setups[i].calibrations) }
    }

    public func rename(_ id: UUID, to name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let i = setups.firstIndex(where: { $0.id == id }) else { return }
        setups[i].name = name
        try store.save(setups[i])
    }

    @discardableResult
    public func delete(_ id: UUID) throws -> SetupEvent? {
        do { try store.delete(id) } catch let e as CocoaError where e.code == .fileNoSuchFile {}
        setups.removeAll { $0.id == id }
        let wasActive = activeID == id
        if wasActive {
            activeID = nil
            engine.load([:])
        }
        // The user just removed *this place's* own setup: don't also announce the place as new. Deleting some
        // other, inactive setup must not touch `announced` — it says nothing about whether `current` is new.
        if wasActive, let current { announced.append(current) }
        return apply()
    }

    /// Writes what the engine learned from clicks into the active setup. Runs before every switch; the app also
    /// calls it on sleep and quit. Memory is updated before the disk, so a failed write still survives this run.
    public func saveActive() throws {
        guard let i = setups.firstIndex(where: { $0.id == activeID }), setups[i].calibrations != engine.calibrations
        else { return }
        setups[i].calibrations = engine.calibrations
        try store.save(setups[i])
    }

    /// Screens or camera changed, or the Wi-Fi went from one known network to another. A Wi-Fi *drop* (or a first
    /// join) is not a change: networks vanish on wake and while roaming, and treating that as a move would cancel
    /// a manual pick or bounce between setups told apart by Wi-Fi.
    public static func isEnvironmentChange(from old: Fingerprint?, to new: Fingerprint) -> Bool {
        guard let old else { return true }
        if Set(old.displays) != Set(new.displays) || old.cameraID != new.cameraID { return true }
        guard let a = old.wifiSSID, let b = new.wifiSSID else { return false }
        return a != b
    }

    private func apply() -> SetupEvent? {
        guard let current else { return nil }
        if let o = overrideID, !setups.contains(where: { $0.id == o }) { overrideID = nil }
        candidates = []
        let target: UUID?
        if let o = overrideID {
            target = o
        } else {
            switch SetupMatcher.match(current, in: setups) {
            case .matched(let id): target = id
            case .ambiguous(let ids):
                candidates = ids
                // Keep the setup in use when it still fits, so a flaky Wi-Fi never flips between look-alikes.
                target = ids.contains { $0 == activeID } ? activeID : ids[0]
            case .none: target = nil
            }
        }
        let first = !hasResolved
        hasResolved = true
        guard first || target != activeID else { return nil }
        activate(target)
        if let target { return first ? nil : .switched(target, ambiguous: !candidates.isEmpty) }
        guard !setups.isEmpty, !announced.contains(where: { !Self.isEnvironmentChange(from: $0, to: current) })
        else { return nil }
        announced.append(current)
        return .newPlace
    }

    private func activate(_ id: UUID?) {
        try? saveActive()   // on failure the learned points still live in `setups` for this run
        if let activeID { lastActiveID = activeID }
        activeID = id
        engine.load(active?.calibrations ?? [:])
    }
}
