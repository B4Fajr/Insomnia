import XCTest
@testable import Insomnia

@MainActor
final class ChargingSessionTests: XCTestCase {
    func testOnlyKnownPowerTransitionsAreDelivered() {
        let power = PowerMonitor()
        var changes: [Bool] = []
        power.onACPowerChange = { changes.append($0) }
        for reading: Bool? in [true, true, nil, true, false, false] {
            power.observeACPower(reading)
        }
        XCTAssertEqual(changes, [false])
        for reading: Bool? in [nil, true, true, nil, true] {
            power.observeACPower(reading)
        }
        XCTAssertEqual(changes, [false, true])
        power.observeACPower(false)
        power.observeACPower(true)
        XCTAssertEqual(changes, [false, true, false, true])
    }

    func testConnectingStartsDefaultOrConfiguredDuration() async throws {
        let h = Harness()
        defer { h.home.destroy() }
        let manager = h.makeManager()
        manager.updateConfig { $0.startOnACPower = true }
        await manager.startOnACConnection { true }
        XCTAssertEqual(manager.session?.endsAt, h.clock.now.addingTimeInterval(18 * 3600))

        manager.updateConfig { $0.acSessionDuration = 90 * 60 }
        XCTAssertEqual(manager.session?.endsAt, h.clock.now.addingTimeInterval(18 * 3600))
        await manager.end(reason: .user)
        XCTAssertNil(manager.session)

        await manager.startOnACConnection { true }
        XCTAssertEqual(manager.session?.endsAt, h.clock.now.addingTimeInterval(90 * 60))
        XCTAssertEqual(try h.store.loadConfig()?.acSessionDuration, 90 * 60)
        await manager.end(reason: .user)
    }

    func testActiveManualTimerKeepsItsDeadline() async {
        let h = Harness()
        defer { h.home.destroy() }
        let manager = h.makeManager()
        manager.updateConfig { $0.startOnACPower = true }
        await manager.start(duration: 600)
        let session = manager.session
        await manager.startOnACConnection { true }
        await manager.endOnACDisconnection()
        manager.updateConfig { $0.startOnACPower = false }
        XCTAssertEqual(manager.session, session)
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1"])
        await manager.end(reason: .user)
    }

    func testIdleStaysIdleWhenDisabledOrUnplugged() async throws {
        let h = Harness()
        defer { h.home.destroy() }
        let manager = h.makeManager()
        await manager.startOnACConnection { true }
        manager.updateConfig { $0.startOnACPower = true }
        await manager.startOnACConnection { false }
        await manager.endOnACDisconnection()
        XCTAssertNil(manager.session)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertTrue(h.guardFake.calls.isEmpty)
    }

    func testUnplugWhileRecoveryIsArmingAbandonsAutomaticStart() async throws {
        let h = Harness()
        defer { h.home.destroy() }
        let manager = h.makeManager()
        manager.updateConfig { $0.startOnACPower = true }
        let gate = AsyncGate()
        h.backstop.armGate = gate
        var onAC = true
        let start = Task { await manager.startOnACConnection { onAC } }
        await gate.waitUntilStarted()
        onAC = false
        await gate.open()
        await start.value
        XCTAssertNil(manager.session)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertFalse(manager.state.isDirty)
        XCTAssertTrue(h.guardFake.calls.isEmpty)
    }

    func testUnplugEndsTheAutomaticTimerEvenAfterExtendingOrDisablingAutomation() async throws {
        let h = Harness()
        defer { h.home.destroy() }
        let manager = h.makeManager()
        manager.updateConfig { $0.startOnACPower = true }
        await manager.startOnACConnection { true }
        await manager.extend(by: 300)
        XCTAssertEqual(try h.store.loadSession()?.trigger, .charger)

        manager.updateConfig { $0.startOnACPower = false }
        await manager.endOnACDisconnection()
        XCTAssertNil(manager.session)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertFalse(manager.state.isDirty)
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1", "disablesleep 0"])
    }

    func testUnplugWhileSleepIsBeingDisabledRestoresIt() async throws {
        let h = Harness()
        defer { h.home.destroy() }
        let manager = h.makeManager()
        manager.updateConfig { $0.startOnACPower = true }
        let gate = AsyncGate()
        h.guardFake.sleepGate = gate
        var onAC = true
        let start = Task { await manager.startOnACConnection { onAC } }
        await gate.waitUntilStarted()
        onAC = false
        await manager.endOnACDisconnection()
        await gate.open()
        await start.value
        XCTAssertNil(manager.session)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1", "disablesleep 0"])
    }

    func testReconcileEndsAnAutomaticTimerOnBattery() async throws {
        let h = Harness()
        defer { h.home.destroy() }
        let session = Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(600), trigger: .charger)
        try h.store.saveSession(session)
        var state = RuntimeState.clean
        state.sleepDisabledByUs = true
        try h.store.saveState(state)
        h.guardFake.sleepDisabled = true

        let manager = h.makeManager()
        await manager.reconcile { false }
        XCTAssertNil(manager.session)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 0"])
    }

    func testReconcileKeepsLegacyTimerOnBatteryAndDoesNotGuessAtUnknownPower() async throws {
        let h = Harness()
        defer { h.home.destroy() }
        let legacy = Data(#"{"startedAt":"2027-01-15T08:00:00Z","endsAt":"2027-01-15T15:00:00Z","extensions":[]}"#.utf8)
        let session = try Store.makeDecoder().decode(Session.self, from: legacy)
        XCTAssertNil(session.trigger)
        try h.store.saveSession(session)

        let manager = h.makeManager()
        await manager.reconcile { false }
        XCTAssertEqual(manager.session, session)
        await manager.endOnACDisconnection()
        XCTAssertEqual(manager.session, session)
        await manager.end(reason: .user)

        let automatic = Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(600), trigger: .charger)
        try h.store.saveSession(automatic)
        await manager.reconcile { nil }
        XCTAssertEqual(manager.session, automatic)
        await manager.endOnACDisconnection()
        XCTAssertNil(manager.session)
    }

    func testAutomaticStartQueuedBehindAManualStartKeepsTheManualDeadline() async {
        let h = Harness()
        defer { h.home.destroy() }
        let manager = h.makeManager()
        manager.updateConfig { $0.startOnACPower = true }
        let gate = AsyncGate()
        h.backstop.armGate = gate
        let manual = Task { await manager.start(duration: 600) }
        await gate.waitUntilStarted()
        let automatic = Task { await manager.startOnACConnection { true } }
        await settleQueuedRequests()
        await gate.open()
        await manual.value
        await automatic.value
        XCTAssertEqual(manager.session?.endsAt, h.clock.now.addingTimeInterval(600))
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1"])
        await manager.end(reason: .user)
    }
}
