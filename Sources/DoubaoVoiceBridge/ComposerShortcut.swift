import Carbon.HIToolbox
import AppKit
import Foundation
import IOKit.hid

// Screenshot hotkeys must not consume unrelated application hotkey events.
enum HotKeyEvent {
    static func matches(_ event: EventRef?, signature: OSType, id: UInt32) -> Bool {
        guard let event else { return false }
        var identifier = EventHotKeyID()
        let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
        return result == noErr && identifier.signature == signature && identifier.id == id
    }
}

struct StandaloneControlGesture {
    private struct Key: Hashable { let device: UInt; let usage: UInt32 }
    private var pressed: Set<Key> = []
    private var control: Key?
    private var usedInChord = false
    private var opened = false
    var isPending: Bool { control != nil && !usedInChord && !opened }

    mutating func thresholdReached() -> Bool {
        guard isPending else { return false }
        opened = true
        return true
    }

    mutating func cancelForOtherInput() { if control != nil { usedInChord = true } }

    mutating func handle(device: UInt, usage: UInt32, down: Bool) -> Bool {
        guard (0x04...0xE7).contains(usage) else { return false }
        let key = Key(device: device, usage: usage)
        if down {
            guard !pressed.contains(key) else { return false }
            if usage == 0xE0, control == nil, pressed.isEmpty {
                control = key
                usedInChord = false
                opened = false
            } else if control != nil {
                usedInChord = true
            }
            pressed.insert(key)
            return false
        }
        guard pressed.remove(key) != nil, control == key else { return false }
        control = nil
        usedInChord = false
        opened = false
        return false
    }

    mutating func removeDevice(_ device: UInt) {
        pressed = pressed.filter { $0.device != device }
        if control?.device == device { control = nil; usedInChord = false; opened = false }
    }
}

// Receive physical keyboard reports before Quartz/remote/input-method filters.
// Keep only current pressed usage IDs to distinguish a bare Control from chords;
// never suppress/post keys, decode text, or retain a keystroke history.
final class ComposerShortcut {
    static let holdDuration: TimeInterval = 0.30
    private let onPressed: () -> Void
    private var manager: IOHIDManager?
    private var gesture = StandaloneControlGesture()
    private var holdWorkItem: DispatchWorkItem?
    private var holdGeneration: UInt = 0
    private var mouseMonitor: Any?

    init(onPressed: @escaping () -> Void) { self.onPressed = onPressed }

    func start() -> OSStatus {
        guard manager == nil else { return noErr }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard
        ] as CFDictionary)
        IOHIDManagerSetInputValueMatching(manager, [kIOHIDElementUsagePageKey: kHIDPage_KeyboardOrKeypad] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, { context, result, _, value in
            guard result == kIOReturnSuccess, let context else { return }
            let owner = Unmanaged<ComposerShortcut>.fromOpaque(context).takeUnretainedValue()
            let element = IOHIDValueGetElement(value)
            guard IOHIDElementGetUsagePage(element) == kHIDPage_KeyboardOrKeypad else { return }
            let device = IOHIDElementGetDevice(element)
            let id = UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque())
            owner.handlePhysicalKey(device: id, usage: IOHIDElementGetUsage(element),
                                    down: IOHIDValueGetIntegerValue(value) != 0)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let owner = Unmanaged<ComposerShortcut>.fromOpaque(context).takeUnretainedValue()
            owner.gesture.removeDevice(UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque()))
            owner.updateHoldTimer(wasPending: true)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess { stop() }
        else {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] _ in
                guard let self else { return }
                self.gesture.cancelForOtherInput()
                self.updateHoldTimer(wasPending: true)
            }
        }
        return result
    }

    func handlePhysicalKey(device: UInt, usage: UInt32, down: Bool) {
        let wasPending = gesture.isPending
        _ = gesture.handle(device: device, usage: usage, down: down)
        updateHoldTimer(wasPending: wasPending)
    }

    private func updateHoldTimer(wasPending: Bool) {
        guard gesture.isPending else {
            holdGeneration &+= 1
            holdWorkItem?.cancel()
            holdWorkItem = nil
            return
        }
        guard !wasPending else { return }
        holdGeneration &+= 1
        let generation = holdGeneration
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.holdGeneration == generation, self.gesture.thresholdReached() else { return }
            self.holdWorkItem = nil
            self.onPressed()
        }
        holdWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDuration, execute: item)
    }

    func stop() {
        holdGeneration &+= 1
        holdWorkItem?.cancel()
        holdWorkItem = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
        gesture = StandaloneControlGesture()
    }

    deinit { stop() }
}
