import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct RemoteInputSafetyTests {
    static func main() {
        // 这些测试只依赖 Foundation，可在没有启动 App 或连接遥控器时运行。
        expect(RemoteDeviceFilter.isEligible(vid: 0x2717, pid: 0x32B8, product: "小米蓝牙遥控器2 Pro"), "2 Pro should be accepted")
        expect(!RemoteDeviceFilter.isEligible(vid: 0x0000, pid: 0x0000, product: "Apple Internal Keyboard / Trackpad"), "Apple keyboard must be rejected")

        var back = BackHoldEvidence()
        back.observeDown(at: 0.00)
        back.observeDown(at: 0.03)
        expect(!back.isConfirmed(at: 0.39), "short/noisy Back pulse must not arm delete")
        back.observeDown(at: 0.06)
        expect(back.isConfirmed(at: 0.40), "real held Back with repeated reports should arm delete")

        var ring = RingScrollDecoder()
        expect(RemoteHIDReportKind.classify([0x03, 0, 0x28, 0, 0, 0, 1]) == .scrollRing,
               "ring report containing OK usage must be classified before button parsing")
        expect(RemoteHIDReportKind.classify([0x01, 0, 0, 0x28, 0, 0, 0]) == .button,
               "normal keyboard report must remain eligible for button parsing")

        expect(RemoteInputGuard.disposition(for: 0xF1) == .blockedBack,
               "Back must never enter the app action pipeline")
        expect(RemoteInputGuard.disposition(for: 0x28) == .accepted,
               "OK must remain available to the normal mapping pipeline")
        expect(RemoteInputGuard.deleteUsage == 0x35,
               "Delete must be assigned to the proven-safe TV key, never Back or OK")
        expect(RemoteInputGuard.homeLongPressDuration == 3.0,
               "Home must require a three-second hold before opening Notes")
        expect(RemoteInputGuard.confirmLongPressDuration == 2.0,
               "OK must require a two-second hold before sending confirmation")
        expect(RemoteInputGuard.menuLongPressDuration == 2.0,
               "Menu must require a two-second hold before sending its mapping")
        expect(RemoteInputGuard.directionHoldDuration == 0.08,
               "Directional keys must require an 80ms hold before moving")
        var stats = RemoteInputStatistics()
        stats.recordReport(.scrollRing)
        stats.recordReport(.scrollRing)
        stats.recordReport(.button)
        stats.recordDisposition(.blockedBack, usage: 0xF1)
        stats.recordDisposition(.accepted, usage: 0x28)
        expect(stats.reportCount(for: .scrollRing) == 2, "all raw report kinds must be counted")
        expect(stats.blockedBackCount == 1, "blocked Back events must be counted")
        expect(stats.acceptedCount(for: 0x28) == 1, "executed usages must be counted")
        expect(ring.consume([0x03, 0, 0, 0, 0, 0, 1], at: 0.00) == nil, "one ring frame is not enough")
        expect(ring.consume([0x03, 0, 4, 0, 0, 0, 1], at: 0.03) == nil, "two ring frames are not enough")
        expect(ring.consume([0x03, 0, 5, 0, 0, 0, 1], at: 0.06) == nil, "calibration frame is not emitted")
        expect(ring.consume([0x03, 0, 6, 0, 0, 0, 1], at: 0.09) == .init(lines: 6), "stable ring should scroll quickly")
        expect(ring.consume([0x03, 0, 0, 0, 0, 0, 0], at: 6.00) == nil, "idle resets ring calibration")

        print("PASS")
    }
}
