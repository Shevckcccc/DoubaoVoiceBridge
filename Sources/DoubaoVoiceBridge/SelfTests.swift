import Foundation
import CoreGraphics
import AppKit

enum SelfTests {
    static func run() -> Bool {
        var failures: [String] = []

        func check<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
            if actual != expected {
                failures.append("\(label): expected \(expected), got \(actual)")
            }
        }

        do {
            var state = HoldGestureState()
            check(state.handle(.controlDown(targetAvailable: true)), [.suppress, .scheduleThreshold], "long hold down")
            check(state.phase, .pending, "long hold pending")
            check(state.handle(.thresholdReached), [.beginDictation], "long hold threshold")
            check(state.phase, .dictating, "long hold dictating")
            check(state.handle(.controlUp), [.suppress, .finishDictation], "long hold release")
            state.reset()
            check(state.phase, .idle, "long hold idle")
        }

        do {
            var state = HoldGestureState()
            _ = state.handle(.controlDown(targetAvailable: true))
            check(state.handle(.otherInput), [.synthesizeControlDown, .passThrough], "chord recovery")
            check(state.phase, .passthrough, "chord passthrough")
            check(state.handle(.controlUp), [.passThrough], "chord release")
            check(state.phase, .idle, "chord idle")
        }

        do {
            var state = HoldGestureState()
            check(state.handle(.controlDown(targetAvailable: false)), [.passThrough], "non-UU down")
            check(state.phase, .idle, "non-UU idle")
            check(state.handle(.controlUp), [.passThrough], "non-UU release")
        }

        do {
            var state = HoldGestureState()
            _ = state.handle(.controlDown(targetAvailable: true))
            check(state.handle(.controlUp), [.suppress], "quick tap")
            check(state.phase, .idle, "quick tap idle")
        }

        do {
            let left: CGEventFlags = [.maskControl, CGEventFlags(rawValue: 0x1)]
            let right: CGEventFlags = [.maskControl, CGEventFlags(rawValue: 0x2000)]
            check(ControlModifierState.isDown(keyCode: 59, flags: left), true, "left modifier down")
            check(ControlModifierState.isDown(keyCode: 59, flags: right), false, "right held does not keep left down")
            check(ControlModifierState.isDown(keyCode: 62, flags: right), true, "right modifier down")
            check(ControlModifierState.isDown(keyCode: 62, flags: left), false, "left held does not keep right down")

            var recovery = ControlReleaseRecovery()
            let now = Date()
            check(recovery.shouldRecover(phase: .dictating, keyIsDown: false, now: now), false, "release first observed")
            check(recovery.shouldRecover(phase: .dictating, keyIsDown: false, now: now.addingTimeInterval(0.05)), false, "release debounce")
            check(recovery.shouldRecover(phase: .dictating, keyIsDown: true, now: now.addingTimeInterval(0.06)), false, "held key clears recovery")
            check(recovery.shouldRecover(phase: .dictating, keyIsDown: false, now: now.addingTimeInterval(0.2)), false, "release restarts debounce")
            check(recovery.shouldRecover(phase: .dictating, keyIsDown: false, now: now.addingTimeInterval(0.31)), true, "missing release recovers")
            check(recovery.shouldRecover(phase: .idle, keyIsDown: false, now: now.addingTimeInterval(1)), false, "idle cannot release again")
        }

        do {
            // Replay successive holds through the real monitor without installing
            // a tap, recording audio, posting keyboard events, or activating apps.
            var leftIsDown = false
            var began = 0
            var released = 0
            var cancelled = 0
            var posted: [Bool] = []
            let target = UURemoteTarget(application: .current)
            let monitor = ControlHoldMonitor(
                holdThreshold: 0.18,
                targetProvider: { target },
                localComposerReady: { true },
                onBegin: { _ in began += 1 },
                onRelease: { released += 1 },
                onCancel: { cancelled += 1 },
                physicalKeyState: { $0 == 59 && leftIsDown },
                controlEventPoster: { down, _ in posted.append(down); return true }
            )

            func beginHold() {
                leftIsDown = true
                guard let down = ControlHoldMonitor.makeControlEvent(down: true, rightControlHeld: false) else {
                    failures.append("Unable to construct test Control down")
                    return
                }
                let previousCount = posted.count
                _ = monitor.handleControlFlagsChanged(down)
                let deadline = Date().addingTimeInterval(1)
                while posted.count == previousCount && Date() < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.17))
                check(monitor.isGestureIdle, false, "hold active before release")
            }

            beginHold()
            leftIsDown = false // The input method swallows the flagsChanged up.
            let firstRelease = Date()
            monitor.reconcilePhysicalControlState(now: firstRelease)
            monitor.reconcilePhysicalControlState(now: firstRelease.addingTimeInterval(0.11))
            check(monitor.isGestureIdle, true, "missing release returns monitor to idle")
            check(released, 1, "missing release finishes exactly once")
            monitor.reconcilePhysicalControlState(now: firstRelease.addingTimeInterval(1))
            check(released, 1, "repeated polling cannot finish twice")

            beginHold()
            leftIsDown = false
            guard let up = ControlHoldMonitor.makeControlEvent(down: false, rightControlHeld: false) else {
                failures.append("Unable to construct test Control up")
                return false
            }
            _ = monitor.handleControlFlagsChanged(up)
            _ = monitor.handleControlFlagsChanged(up) // Duplicate up must not look like a new down.
            check(monitor.isGestureIdle, true, "second hold and duplicate release return idle")
            check(released, 2, "second hold finishes normally")

            beginHold()
            monitor.finishSessionGesture() // Return/Esc/timeout before the monitor receives up.
            check(monitor.isGestureIdle, true, "session completion clears held gesture")
            leftIsDown = false
            _ = monitor.handleControlFlagsChanged(up)
            beginHold()
            leftIsDown = false
            _ = monitor.handleControlFlagsChanged(up)
            check(began, 4, "four successive holds open without restart")
            check(released, 3, "session cleanup does not emit a second completion")
            check(cancelled, 0, "release recovery preserves the transcript")
            check(posted, [true, false, true, false, true, false, true, false], "all synthetic downs have matching ups")
            monitor.stop()
        }

        do {
            // A suppressed Quartz down can read back as up. An unavailable
            // hardware observer must not cancel a hold before the threshold.
            var began = 0
            var released = 0
            let target = UURemoteTarget(application: .current)
            let monitor = ControlHoldMonitor(holdThreshold: 0.18,
                targetProvider: { target }, localComposerReady: { true },
                onBegin: { _ in began += 1 }, onRelease: { released += 1 },
                onCancel: {}, physicalKeyState: { _ in nil },
                controlEventPoster: { _, _ in true })
            if let down = ControlHoldMonitor.makeControlEvent(down: true, rightControlHeld: false),
               let up = ControlHoldMonitor.makeControlEvent(down: false, rightControlHeld: false) {
                _ = monitor.handleControlFlagsChanged(down)
                monitor.reconcilePhysicalControlState()
                monitor.reconcilePhysicalControlState(now: Date().addingTimeInterval(0.15))
                RunLoop.current.run(until: Date().addingTimeInterval(0.42))
                monitor.reconcilePhysicalControlState(now: Date().addingTimeInterval(1))
                check(began, 1, "unknown hardware state preserves long-press threshold")
                check(monitor.isGestureIdle, false, "unknown hardware state cannot manufacture release")
                _ = monitor.handleControlFlagsChanged(up)
                check(released, 1, "event release still works without hardware observer")
            } else { failures.append("Unable to construct unknown-hardware test events") }
            monitor.stop()
        }

        do {
            // Drive the actual coordinator with delayed delivery callbacks. No
            // real clipboard writes, keyboard posts, windows, or focus changes.
            let panel = TestDictationComposer()
            let delivery = TestTranscriptDelivery()
            let coordinator = SessionCoordinator(panel: panel, delivery: delivery, activateTarget: { _ in })
            let first = UURemoteTarget(application: .current)
            let second = UURemoteTarget(application: .current)
            coordinator.begin(target: first)
            panel.onCommit?("test one")
            check(coordinator.canBegin, false, "cannot listen while Command-V is in flight")
            delivery.requests[0].completion(.success(()))
            check(coordinator.canBegin, true, "paste success immediately permits next hold")
            check(coordinator.isClipboardBusy, true, "restore remains pending after paste")
            coordinator.begin(target: second)
            delivery.requests[0].cleanup()
            check(coordinator.state, .listening, "old cleanup cannot erase new listening session")
            coordinator.controlReleased()
            panel.onCommit?("test two")
            delivery.requests[1].completion(.success(()))
            coordinator.begin(target: first)
            coordinator.controlReleased()
            panel.onCommit?("test three")
            check(coordinator.state, .waitingForClipboard, "fast transcript waits in memory")
            check(delivery.requests.count, 2, "clipboard writes never overlap")
            delivery.requests[1].cleanup()
            check(delivery.requests.count, 3, "queued transcript drains after restore")
            check(delivery.requests[2].text, "test three", "queued transcript survives intact")
            check(delivery.requests[2].target === first, true, "queued transcript retains its own target")
            delivery.requests[2].completion(.success(()))
            coordinator.begin(target: second)
            panel.onCommit?("cancelled test")
            coordinator.cancel()
            delivery.requests[2].cleanup()
            check(delivery.requests.count, 3, "cancelled queued transcript is never delivered")
            check(coordinator.state, .idle, "cancelled queue returns idle")
            coordinator.begin(target: second)
            panel.onCommit?("retry test")
            delivery.requests[3].completion(.failure(DeliveryError.targetChanged))
            check(coordinator.state, .failed, "delivery failure preserves retry state")
            delivery.requests[3].cleanup()
            check(coordinator.state, .failed, "cleanup cannot erase delivery failure")
            panel.onCommit?("retry test")
            check(delivery.requests.count, 5, "failed delivery can retry")
            delivery.requests[4].completion(.success(()))
            delivery.requests[4].cleanup()
            check(coordinator.isClipboardBusy, false, "final cleanup releases clipboard ownership")
        }

        do {
            let flagsMask = CGEventMask(1) << CGEventMask(CGEventType.flagsChanged.rawValue)
            let uu = InstalledEventTap(
                processIdentifier: 100,
                location: CGEventTapLocation.cghidEventTap.rawValue,
                options: CGEventTapOptions.defaultTap.rawValue,
                eventMask: flagsMask,
                isEnabled: true
            )
            let bridge = InstalledEventTap(
                processIdentifier: 200,
                location: CGEventTapLocation.cghidEventTap.rawValue,
                options: CGEventTapOptions.defaultTap.rawValue,
                eventMask: flagsMask,
                isEnabled: true
            )
            check(
                UURemoteTapOrder.needsReinstall(taps: [uu, bridge], bridgePID: 200, uuRemotePID: 100),
                true,
                "UU tap ahead requires reinstall"
            )
            check(
                UURemoteTapOrder.needsReinstall(taps: [bridge, uu], bridgePID: 200, uuRemotePID: 100),
                false,
                "bridge tap ahead stays installed"
            )
            let ime = InstalledEventTap(processIdentifier: 300, location: 0,
                options: 0, eventMask: flagsMask, isEnabled: true)
            check(UURemoteTapOrder.needsReinstall(taps: [ime, bridge],
                bridgePID: 200, uuRemotePID: 100, inputMethodPID: 300), true,
                "restarted Doubao ahead must rearm even without a UU tap")
            check(UURemoteTapOrder.needsReinstall(taps: [bridge, ime],
                bridgePID: 200, uuRemotePID: 100, inputMethodPID: 300), false,
                "stable Doubao ordering must not reinstall repeatedly")
            let listener = InstalledEventTap(processIdentifier: 300, location: 0,
                options: 1, eventMask: flagsMask, isEnabled: true)
            let disabled = InstalledEventTap(processIdentifier: 300, location: 0,
                options: 0, eventMask: flagsMask, isEnabled: false)
            check(UURemoteTapOrder.needsReinstall(taps: [listener, disabled, bridge],
                bridgePID: 200, uuRemotePID: 100, inputMethodPID: 300), false,
                "passive or disabled listeners cannot steal Control")
            check(
                UURemoteActivationAudit.delay(previousPID: 100, activatedPID: 100),
                0.25,
                "same-PID UU activation is audited"
            )
            check(
                UURemoteActivationAudit.delay(previousPID: 100, activatedPID: 101),
                0.8,
                "new-PID UU launch gets settle time"
            )
        }

        do {
            check(
                SyntheticControlRoute.localHIDDictation.eventTapLocation.rawValue,
                CGEventTapLocation.cghidEventTap.rawValue,
                "local dictation reaches Doubao HID listener"
            )
            check(
                SyntheticControlRoute.remoteHIDPassthrough.eventTapLocation.rawValue,
                CGEventTapLocation.cghidEventTap.rawValue,
                "remote Control chords stay on HID path"
            )
        }

        do {
            if let down = ControlHoldMonitor.makeControlEvent(down: true, rightControlHeld: false),
               let up = ControlHoldMonitor.makeControlEvent(down: false, rightControlHeld: false),
               let rightHeld = ControlHoldMonitor.makeControlEvent(down: false, rightControlHeld: true) {
                check(down.type, .flagsChanged, "Control uses modifier event type")
                check(down.getIntegerValueField(.keyboardEventKeycode), 59, "left Control keycode")
                check(down.flags.contains(.maskControl), true, "Control down sets general flag")
                check(down.flags.rawValue & 1, 1, "Control down includes left device flag")
                check(up.flags.rawValue & 1, 0, "Control up clears left device flag")
                check(up.flags.contains(.maskControl), false, "Control up clears general flag")
                check(rightHeld.flags.contains(.maskControl), true, "right Control remains held")
                check(down.getIntegerValueField(.eventSourceUserData),
                    ControlHoldMonitor.syntheticEventMarker, "synthetic Control bypasses own interception")
            } else { failures.append("Unable to construct Control events") }
        }

        do {
            do {
                let events = try ClipboardKeyboardPaster.makeCommandVEvents()
                check(events.count, 4, "Command-V event count")
                check(
                    events.map(\.type),
                    [.flagsChanged, .keyDown, .keyUp, .flagsChanged],
                    "Command-V event types"
                )
                check(
                    events.map { $0.getIntegerValueField(.keyboardEventKeycode) },
                    [55, 9, 9, 55],
                    "Command-V event key codes"
                )
                check(events[0].flags.contains(.maskCommand), true, "Command down flag")
                check(
                    (events[0].flags.rawValue & 0x8) != 0,
                    true,
                    "left Command device flag"
                )
                check(events[1].flags, events[0].flags, "V down inherits Command state")
                check(events[2].flags, events[0].flags, "V up inherits Command state")
                check(events[3].flags.contains(.maskCommand), false, "Command up clears flag")
                check(
                    (events[3].flags.rawValue & 0x8) == 0,
                    true,
                    "Command up clears left device flag"
                )
                check(
                    events.allSatisfy {
                        $0.getIntegerValueField(.eventSourceUserData) ==
                            ControlHoldMonitor.syntheticEventMarker
                    },
                    true,
                    "Command-V events carry bridge marker"
                )
            } catch {
                failures.append("Command-V event creation: \(error)")
            }
        }

        do {
            check(PrivacySafeTextMetrics.lengthBucket(0), "empty", "empty length bucket")
            check(PrivacySafeTextMetrics.lengthBucket(4), "1-4", "short length bucket")
            check(PrivacySafeTextMetrics.lengthBucket(16), "5-16", "medium length bucket")
            check(PrivacySafeTextMetrics.lengthBucket(64), "17-64", "long length bucket")
            check(PrivacySafeTextMetrics.lengthBucket(65), "65+", "largest length bucket")
        }

        do {
            check(
                TranscriptSettlePolicy.isReady(
                    textIsEmpty: true,
                    hasMarkedText: false,
                    elapsedAfterRelease: 1.0,
                    stableFor: 1.0
                ),
                false,
                "empty transcript never settles"
            )
            check(
                TranscriptSettlePolicy.isReady(
                    textIsEmpty: false,
                    hasMarkedText: false,
                    elapsedAfterRelease: 0.45,
                    stableFor: 0.35
                ),
                true,
                "settle at optimized thresholds"
            )
            check(
                TranscriptSettlePolicy.isReady(
                    textIsEmpty: false,
                    hasMarkedText: true,
                    elapsedAfterRelease: 1.0,
                    stableFor: 1.0
                ),
                false,
                "marked transcript never settles"
            )
            check(
                TranscriptSettlePolicy.isReady(
                    textIsEmpty: false,
                    hasMarkedText: false,
                    elapsedAfterRelease: 0.44,
                    stableFor: 1.0
                ),
                false,
                "release grace is preserved"
            )
            check(
                TranscriptSettlePolicy.isReady(
                    textIsEmpty: false,
                    hasMarkedText: false,
                    elapsedAfterRelease: 1.0,
                    stableFor: 0.34
                ),
                false,
                "tail correction resets stable window"
            )
            check(
                UURemoteDelivery.defaultPasteDelay >= UURemoteDelivery.minimumPasteDelay,
                true,
                "default UU sync delay respects safety floor"
            )
            check(
                LatencyDefaultsMigration.replacementPasteDelay(for: NSNumber(value: 0.9)),
                UURemoteDelivery.defaultPasteDelay,
                "numeric v2.2 delay migrates"
            )
            check(
                LatencyDefaultsMigration.replacementPasteDelay(for: "0.9"),
                UURemoteDelivery.defaultPasteDelay,
                "string v2.2 delay migrates"
            )
            check(
                LatencyDefaultsMigration.replacementPasteDelay(for: NSNumber(value: 0.7)),
                nil,
                "custom delay is preserved"
            )
        }

        do {
            let scrollView = NSScrollView(frame: .zero)
            let textView = NSTextView()
            textView.textContainerInset = NSSize(width: 12, height: 10)
            ComposerTextLayout.attach(textView, to: scrollView)
            scrollView.hasVerticalScroller = true
            scrollView.borderType = .bezelBorder
            scrollView.frame = NSRect(x: 0, y: 0, width: 320, height: 100)
            ComposerTextLayout.synchronize(textView, with: scrollView)
            check(textView.frame.width > 0, true, "composer text view has drawable width")
            check(
                textView.frame.width,
                scrollView.contentSize.width,
                "composer text view tracks scroll width"
            )
            check(
                (textView.textContainer?.containerSize.width ?? 0) > 0,
                true,
                "composer text container has drawable width"
            )
            check(
                textView.textContainer?.widthTracksTextView,
                true,
                "composer container tracks text view width"
            )
        }

        do {
            check(ScreenshotPolicy.canPaste(sameClipboard: true, sameProcess: true, sameWindow: true), true, "image delivery stable target")
            check(ScreenshotPolicy.canPaste(sameClipboard: false, sameProcess: true, sameWindow: true), false, "user copy cancels image paste")
            check(ScreenshotPolicy.canPaste(sameClipboard: true, sameProcess: true, sameWindow: false), false, "focus change cancels image paste")
            check(ScreenshotPolicy.canPaste(sameClipboard: true, sameProcess: false, sameWindow: true), false, "closed UU cancels image paste")
            check(ScreenshotPolicy.syncDelay(bytes: 0), 10, "minimum image sync window")
            check(ScreenshotPolicy.syncDelay(bytes: 20 * 1024 * 1024), 15, "bounded image sync window")
        }

        if failures.isEmpty {
            print("SELF_TEST_OK groups=16 (repeated holds + unknown hardware + consecutive delivery + voice/image guards)")
            return true
        }
        for failure in failures {
            fputs("SELF_TEST_FAILURE \(failure)\n", stderr)
        }
        return false
    }
}

private final class TestDictationComposer: DictationComposer {
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onControlReleased: (() -> Void)?
    var onTranscriptTimeout: (() -> Void)?
    var isReadyForLocalDictation: Bool { true }
    func begin(targetDescription: String) {}
    func waitForFinalTranscript() {}
    func hide() {}
    func showSending() {}
    func showWaitingForClipboard() {}
    func showError(_ message: String) {}
    func currentText() -> String { "" }
}

private final class TestTranscriptDelivery: TranscriptDelivery {
    struct Request {
        let text: String
        let target: UURemoteTarget
        let completion: (Result<Void, Error>) -> Void
        let cleanup: () -> Void
    }
    var requests: [Request] = []
    func deliver(text: String, to target: UURemoteTarget,
                 panelWillHide: @escaping () -> Void,
                 completion: @escaping (Result<Void, Error>) -> Void,
                 cleanupCompletion: @escaping () -> Void) {
        panelWillHide()
        requests.append(Request(text: text, target: target, completion: completion, cleanup: cleanupCompletion))
    }
    func restoreClipboardForTermination() {}
}
