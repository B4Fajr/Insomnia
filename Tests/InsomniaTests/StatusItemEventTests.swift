import AppKit
import SwiftUI
import XCTest
@testable import Insomnia

/// Real mouse events, delivered in-process to the SwiftUI status view, so
/// click routing is exercised without a menu bar or the
/// Accessibility permission.
///
/// macOS 27 delivers a status item click as an instant down and up, both
/// located at the middle of the item's window whatever the pointer is over
/// and however long the button stays down. `press` reproduces that: the
/// events carry the window's centre and the up follows the down at once,
/// while the pointer's real position and the button's real state are given
/// separately, as the live app reads them (`NSEvent.mouseLocation`,
/// `NSEvent.pressedMouseButtons`).
final class StatusItemEventTests: XCTestCase {
    private final class Hits {
        var icon = 0, countdown = 0
        var summary: String { "icon=\(icon) countdown=\(countdown)" }
    }

    /// What the hardware is doing, read by the host through its injected closures.
    private final class Hardware {
        var pointerX: CGFloat = 0
        var buttonDown = false
    }

    @MainActor
    private struct Rig {
        let window: NSWindow
        let host: StatusHostingView
        let hits: Hits
        let hardware: Hardware
        var size: CGSize { host.frame.size }
        /// Window coordinates of the two targets, from the laid-out running item.
        var icon: CGFloat { 14 }
        var countdown: CGFloat { 50 }
    }

    @MainActor
    private func makeRig(_ harness: Harness, osMajorVersion: Int = 27) async -> Rig {
        _ = NSApplication.shared
        let hits = Hits()
        let hardware = Hardware()
        let manager = harness.makeManager()
        let model = MenuBarModel()
        await manager.start(duration: 3600)
        model.phase = .running
        let root = StatusRootView(
            model: model, manager: manager,
            onTapIcon: { hits.icon += 1 }, onTapPill: { _ in },
            onTapCountdown: { hits.countdown += 1 }, onWidthChange: { _ in }
        )
        let host = StatusItemController.makeHostingView(root)
        host.osMajorVersion = osMajorVersion
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        host.pointerInWindow = { _ in NSPoint(x: hardware.pointerX, y: size.height / 2) }
        host.buttonIsDown = { hardware.buttonDown }
        // Off screen: the window only needs to exist to deliver events.
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(0.5))
        return Rig(window: window, host: host, hits: hits, hardware: hardware)
    }

    @MainActor
    private func deliver(_ type: NSEvent.EventType, _ rig: Rig, number: Int, at point: NSPoint? = nil) {
        let centre = NSPoint(x: rig.size.width / 2, y: rig.size.height / 2)
        let event = NSEvent.mouseEvent(
            with: type, location: point ?? centre, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: rig.window.windowNumber,
            context: nil, eventNumber: number, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
        )!
        NSApp.sendEvent(event)
    }

    /// Put the button down over `x`; the system reports the click at once.
    @MainActor
    private func pressDown(over x: CGFloat, _ rig: Rig) {
        rig.hardware.pointerX = x
        rig.hardware.buttonDown = true
        deliver(.leftMouseDown, rig, number: 1)
        deliver(.leftMouseUp, rig, number: 2)
    }

    @MainActor
    private func letGo(_ rig: Rig) async {
        rig.hardware.buttonDown = false
        try? await Task.sleep(for: .seconds(0.15))
    }

    @MainActor
    private func press(over x: CGFloat, for seconds: TimeInterval, _ rig: Rig) async {
        pressDown(over: x, rig)
        try? await Task.sleep(for: .seconds(seconds))
        await letGo(rig)
    }

    @MainActor
    func testTheCountdownAndTheEyeStillTakeTheirOwnClicks() async {
        let harness = Harness()
        defer { harness.home.destroy() }
        let rig = await makeRig(harness)
        defer { rig.window.orderOut(nil) }
        await press(over: rig.countdown, for: 0.1, rig)
        XCTAssertEqual(rig.hits.summary, "icon=0 countdown=1")
        await press(over: rig.icon, for: 0.1, rig)
        XCTAssertEqual(rig.hits.summary, "icon=1 countdown=1")
    }

    /// An event that is not at the item's middle is accurate (macOS 26). If
    /// the pointer has moved since it was queued, it must not be moved with it.
    @MainActor
    func testAnAccurateEventIsNotMovedToWhereThePointerIsNow() async {
        let harness = Harness()
        defer { harness.home.destroy() }
        let rig = await makeRig(harness)
        defer { rig.window.orderOut(nil) }
        let y = rig.size.height / 2
        rig.hardware.buttonDown = true
        rig.hardware.pointerX = rig.icon
        deliver(.leftMouseDown, rig, number: 1, at: NSPoint(x: rig.countdown, y: y))
        try? await Task.sleep(for: .seconds(0.1))
        rig.hardware.buttonDown = false
        deliver(.leftMouseUp, rig, number: 2, at: NSPoint(x: rig.countdown, y: y))
        try? await Task.sleep(for: .seconds(0.1))
        XCTAssertEqual(rig.hits.summary, "icon=0 countdown=1", "the press stayed on the countdown")
    }

    /// macOS 26 reports every click where it happened, so an event at the
    /// item's middle is a real one. It must not follow the pointer, which has
    /// moved on to the eye while the click waited in the queue.
    @MainActor
    func testOnMacOS26AClickAtTheMiddleIsNotMovedToWhereThePointerIs() async {
        let harness = Harness()
        defer { harness.home.destroy() }
        let rig = await makeRig(harness, osMajorVersion: 26)
        defer { rig.window.orderOut(nil) }
        rig.hardware.pointerX = rig.icon
        deliver(.leftMouseDown, rig, number: 1)
        deliver(.leftMouseUp, rig, number: 2)
        try? await Task.sleep(for: .seconds(0.2))
        XCTAssertEqual(rig.hits.icon, 0, "the click stayed in the middle")
    }

}
