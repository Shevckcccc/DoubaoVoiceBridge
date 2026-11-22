import AppKit
import ApplicationServices
import os.log

enum LatencyDefaultsMigration {
    static let legacyPasteDelay: TimeInterval = 0.9

    static func replacementPasteDelay(for storedValue: Any?) -> TimeInterval? {
        guard let storedValue else { return UURemoteDelivery.defaultPasteDelay }

        let numericValue: Double?
        if let number = storedValue as? NSNumber {
            numericValue = number.doubleValue
        } else if let string = storedValue as? String {
            numericValue = Double(string)
        } else {
            numericValue = nil
        }

        guard let numericValue,
              abs(numericValue - legacyPasteDelay) < 0.000_1 else {
            return nil
        }
        return UURemoteDelivery.defaultPasteDelay
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let uuRemoteBundleIdentifier = "com.netease.uuremote"
    static let doubaoIMEBundleIdentifier = "com.bytedance.inputmethod.doubaoime"
    private static let latencyDefaultsMigrationKey = "didMigrateLatencyDefaultsV23"

    private let logger = Logger(subsystem: "com.lyp.DoubaoVoiceBridge", category: "app")
    private let coordinator = SessionCoordinator()
    private let screenshots = ScreenshotCoordinator()
    private var composerShortcut: ComposerShortcut?
    private var statusMenu: NSMenu?
    private var statusItem: NSStatusItem?
    private var statusText = "正在启动…"
    private var statusIsError = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            "pasteDelay": UURemoteDelivery.defaultPasteDelay,
            "restoreClipboard": true,
            "autoPasteUU": true
        ])
        UserDefaults.standard.set(true, forKey: "autoPasteUU")
        migrateLatencyDefaultsIfNeeded()

        configureStatusItem()
        coordinator.onStatusChange = { [weak self] text, isError in
            self?.setStatus(text, isError: isError)
        }

        let shortcut = ComposerShortcut { [weak self] in
            guard let self else { return }
            if self.coordinator.activateExistingSession() { return }
            guard self.currentUURemoteTarget() != nil else { return }
            self.openComposerManually()
        }
        composerShortcut = shortcut
        let shortcutStatus = shortcut.start()
        logger.notice("Composer shortcut registration status=\(shortcutStatus)")
        if shortcutStatus == 0 {
            setStatus("就绪 · 点击图标或长按左 Control 打开输入框", isError: false)
        } else {
            setStatus("Control 开框需要输入监控权限，请点击图标打开或右键检查权限", isError: true)
        }
        screenshots.canStart = { [weak self] in
            guard let self else { return false }
            return self.coordinator.state == .idle && !self.coordinator.isClipboardBusy
        }
        screenshots.onStatusChange = { [weak self] text, error in self?.setStatus(text, isError: error) }
        screenshots.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openComposerManually()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        composerShortcut?.stop()
        coordinator.prepareForTermination()
        screenshots.prepareForTermination()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "mic.and.signal.meter", accessibilityDescription: "远控听写")
            button.toolTip = "点击打开输入框 · 左 Control · 右键查看菜单"
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
        rebuildMenu()
    }

    private func migrateLatencyDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.latencyDefaultsMigrationKey) else { return }

        // Preserve deliberate custom settings. Only migrate the exact value
        // shipped by v2.2 to the faster, measured default.
        if let replacement = LatencyDefaultsMigration.replacementPasteDelay(
            for: defaults.object(forKey: "pasteDelay")
        ) {
            defaults.set(replacement, forKey: "pasteDelay")
        }
        defaults.set(true, forKey: Self.latencyDefaultsMigrationKey)
    }

    private func setStatus(_ text: String, isError: Bool) {
        statusText = text
        statusIsError = isError
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        if statusIsError {
            status.attributedTitle = NSAttributedString(
                string: statusText,
                attributes: [.foregroundColor: NSColor.systemRed]
            )
        }
        menu.addItem(status)

        let instruction = NSMenuItem(title: "打开输入框 → 豆包语音或键入 → 回车粘贴", action: nil, keyEquivalent: "")
        instruction.isEnabled = false
        menu.addItem(instruction)
        menu.addItem(.separator())

        let manual = NSMenuItem(title: "打开输入框（左 Control）", action: #selector(openComposerManually), keyEquivalent: "")
        manual.target = self
        menu.addItem(manual)

        let permissions = NSMenuItem(title: "检查 / 开启所需权限…", action: #selector(openPermissions), keyEquivalent: "")
        permissions.target = self
        menu.addItem(permissions)

        menu.addItem(.separator())
        let capture = NSMenuItem(title: "截图并粘贴到远端（⌥⇧S）", action: #selector(ScreenshotCoordinator.beginCapture), keyEquivalent: "")
        capture.target = screenshots
        menu.addItem(capture)
        let tools = NSMenuItem(title: "打开截图工具…", action: #selector(ScreenshotCoordinator.showTools), keyEquivalent: "")
        tools.target = screenshots
        menu.addItem(tools)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出远控听写", action: #selector(quitApplication), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusMenu = menu
    }

    private func currentUURemoteTarget() -> UURemoteTarget? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.bundleIdentifier == Self.uuRemoteBundleIdentifier,
              !frontmost.isTerminated else {
            return nil
        }
        return UURemoteTarget(application: frontmost)
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu()
        } else {
            openComposerManually()
        }
    }

    private func showStatusMenu() {
        guard let statusItem, let button = statusItem.button, let statusMenu else { return }
        statusItem.menu = statusMenu
        button.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openComposerManually() {
        if coordinator.activateExistingSession() { return }
        guard coordinator.canBegin, !screenshots.isBusy else {
            setStatus("正在传送内容，请稍候再打开输入框", isError: true)
            showStatusMenu()
            return
        }
        guard AXIsProcessTrusted(), let target = currentUURemoteTarget(), target.captureFocusedWindow() else {
            setStatus("请先在 UU 中点好远端输入框，再点击图标或长按左 Control", isError: true)
            showStatusMenu()
            return
        }
        logger.notice("Opening manual composer; no Control synthesis")
        coordinator.begin(target: target, mode: .manual)
    }

    @objc private func openPermissions() {
        requestRequiredPermissions(forceOpenSettings: true)
    }

    private func requestRequiredPermissions(forceOpenSettings: Bool = false) {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        let accessibilityGranted = AXIsProcessTrustedWithOptions(options)
        let inputGranted = CGRequestListenEventAccess()

        if forceOpenSettings || !accessibilityGranted {
            openSystemSettings(anchor: "Privacy_Accessibility")
        } else if !inputGranted {
            openSystemSettings(anchor: "Privacy_ListenEvent")
        }
    }

    private func openSystemSettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }
}

struct InstalledEventTap: Equatable {
    let processIdentifier: pid_t
    let location: UInt32
    let options: UInt32
    let eventMask: CGEventMask
    let isEnabled: Bool

    init(
        processIdentifier: pid_t,
        location: UInt32,
        options: UInt32,
        eventMask: CGEventMask,
        isEnabled: Bool
    ) {
        self.processIdentifier = processIdentifier
        self.location = location
        self.options = options
        self.eventMask = eventMask
        self.isEnabled = isEnabled
    }

    init(_ information: CGEventTapInformation) {
        self.init(
            processIdentifier: information.tappingProcess,
            location: information.tapPoint.rawValue,
            options: information.options.rawValue,
            eventMask: information.eventsOfInterest,
            isEnabled: information.enabled
        )
    }
}

enum UURemoteTapOrder {
    private static let keyboardMask: CGEventMask = [
        CGEventType.keyDown,
        CGEventType.keyUp,
        CGEventType.flagsChanged
    ].reduce(CGEventMask(0)) {
        $0 | (CGEventMask(1) << CGEventMask($1.rawValue))
    }

    static func needsReinstall(
        taps: [InstalledEventTap],
        bridgePID: pid_t,
        uuRemotePID: pid_t,
        inputMethodPID: pid_t? = nil
    ) -> Bool {
        let relevant = taps.enumerated().filter { _, tap in
            tap.isEnabled &&
                tap.location == CGEventTapLocation.cghidEventTap.rawValue &&
                tap.options == CGEventTapOptions.defaultTap.rawValue &&
                (tap.eventMask & keyboardMask) != 0
        }
        guard let otherIndex = relevant.first(where: {
            $0.element.processIdentifier == uuRemotePID ||
                $0.element.processIdentifier == inputMethodPID
        })?.offset else {
            return false
        }
        guard let bridgeIndex = relevant.first(where: { $0.element.processIdentifier == bridgePID })?.offset else {
            return true
        }
        return otherIndex < bridgeIndex
    }
}

enum UURemoteActivationAudit {
    static func delay(previousPID: pid_t?, activatedPID: pid_t) -> TimeInterval {
        previousPID == activatedPID ? 0.25 : 0.8
    }
}
