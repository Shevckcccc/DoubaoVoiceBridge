import CoreGraphics
import Foundation

enum ControlModifierState {
    // NX_DEVICELCTLKEYMASK / NX_DEVICERCTLKEYMASK distinguish the two keys.
    // Reading the event state also tolerates a missed or duplicate flagsChanged.
    static func isDown(keyCode: Int64, flags: CGEventFlags) -> Bool {
        let deviceMask: UInt64 = keyCode == 62 ? 0x2000 : 0x1
        return flags.rawValue & deviceMask != 0
    }
}

struct ControlReleaseRecovery {
    static let pollingInterval: TimeInterval = 0.05
    static let releaseGrace: TimeInterval = 0.10
    private var releasedAt: Date?

    mutating func shouldRecover(phase: HoldGesturePhase, keyIsDown: Bool, now: Date) -> Bool {
        guard phase != .idle, !keyIsDown else {
            reset()
            return false
        }
        guard let releasedAt else {
            self.releasedAt = now
            return false
        }
        return now.timeIntervalSince(releasedAt) >= Self.releaseGrace
    }

    mutating func reset() {
        releasedAt = nil
    }
}
