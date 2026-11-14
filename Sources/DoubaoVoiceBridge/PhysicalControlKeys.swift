import Foundation
import CoreGraphics
import IOKit.hid
import os.log

// Quartz's keyState is part of the stream that we suppress and synthesize.
// Observe only the two physical HID usages instead; unknown is never "up".
final class PhysicalControlKeys {
    static let shared = PhysicalControlKeys()
    private let manager: IOHIDManager
    private var states: [UInt: [CGKeyCode: Bool]] = [:]
    private let logger = Logger(subsystem: "com.lyp.DoubaoVoiceBridge", category: "physical-control")
    private(set) var isAvailable = false

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard
        ] as CFDictionary)
        IOHIDManagerSetInputValueMatchingMultiple(manager, [0xE0, 0xE4].map { usage in
            [kIOHIDElementUsagePageKey: kHIDPage_KeyboardOrKeypad,
             kIOHIDElementUsageKey: usage]
        } as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, { context, result, _, value in
            guard result == kIOReturnSuccess, let context else { return }
            let source = Unmanaged<PhysicalControlKeys>.fromOpaque(context).takeUnretainedValue()
            let element = IOHIDValueGetElement(value)
            guard IOHIDElementGetUsagePage(element) == kHIDPage_KeyboardOrKeypad else { return }
            let device = IOHIDElementGetDevice(element)
            let usage = IOHIDElementGetUsage(element)
            guard usage == 0xE0 || usage == 0xE4 else { return }
            let id = UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque())
            let down = IOHIDValueGetIntegerValue(value) != 0
            source.states[id, default: [:]][usage == 0xE0 ? 59 : 62] = down
            if usage == 0xE0 {
                source.logger.notice("Hardware left Control \(down ? "down" : "up", privacy: .public) observed")
            }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let source = Unmanaged<PhysicalControlKeys>.fromOpaque(context).takeUnretainedValue()
            source.states.removeValue(forKey: UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque()))
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        isAvailable = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
    }

    deinit {
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func isDown(_ key: CGKeyCode) -> Bool? {
        guard isAvailable else { return nil }
        let known = states.values.compactMap { $0[key] }
        return known.isEmpty ? nil : known.contains(true)
    }
}
