import AppKit
import os.log

final class DictationPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

enum ComposerSubmitPolicy {
    static func shouldCommit(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, hasMarkedText: Bool) -> Bool {
        let disallowed: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        return (keyCode == 36 || keyCode == 76) && modifiers.intersection(disallowed).isEmpty && !hasMarkedText
    }
}

final class ComposerTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onControlReleased: (() -> Void)?
    var onBeforeInputMutation: ((String) -> Void)?
    var onAfterInputMutation: ((String) -> Void)?

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        onBeforeInputMutation?("input.insert")
        defer { onAfterInputMutation?("input.insert") }
        super.insertText(insertString, replacementRange: replacementRange)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        onBeforeInputMutation?("input.marked")
        defer { onAfterInputMutation?("input.marked") }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func unmarkText() {
        onBeforeInputMutation?("input.unmark")
        defer { onAfterInputMutation?("input.unmark") }
        super.unmarkText()
    }

    override func keyDown(with event: NSEvent) {
        if ComposerSubmitPolicy.shouldCommit(keyCode: event.keyCode,
            modifiers: event.modifierFlags, hasMarkedText: hasMarkedText()) {
            onCommit?()
            return
        }
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        if event.keyCode == 59, !event.modifierFlags.contains(.control) {
            onControlReleased?()
        }
    }
}

enum ComposerTextLayout {
    static func attach(_ textView: NSTextView, to scrollView: NSScrollView) {
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        scrollView.documentView = textView
    }

    static func synchronize(_ textView: NSTextView, with scrollView: NSScrollView) {
        scrollView.layoutSubtreeIfNeeded()
        let contentSize = scrollView.contentSize
        guard contentSize.width > 0, contentSize.height > 0 else { return }

        var frame = textView.frame
        frame.size.width = contentSize.width
        frame.size.height = max(frame.height, contentSize.height)
        textView.frame = frame
    }
}

enum TranscriptSettlePolicy {
    static let minimumElapsedAfterRelease: TimeInterval = 0.45
    static let requiredStableDuration: TimeInterval = 0.35
    static let pollingInterval: TimeInterval = 0.05

    static func isReady(
        textIsEmpty: Bool,
        hasMarkedText: Bool,
        elapsedAfterRelease: TimeInterval,
        stableFor: TimeInterval
    ) -> Bool {
        !textIsEmpty &&
            !hasMarkedText &&
            elapsedAfterRelease >= minimumElapsedAfterRelease &&
            stableFor >= requiredStableDuration
    }
}

final class ComposerPanelController: NSWindowController, NSTextViewDelegate {
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onControlReleased: (() -> Void)?
    var onTranscriptTimeout: (() -> Void)?

    private let textView = ComposerTextView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let targetLabel = NSTextField(labelWithString: "")
    private let recoveryButton = NSButton(title: "恢复上一版", target: nil, action: nil)
    private let historyButton = NSButton(title: "输入历史", target: nil, action: nil)
    private let saveLabel = NSTextField(wrappingLabelWithString: "")
    private let history: InputHistoryJournal
    private let presentWindow: (NSWindow, NSTextView) -> Void
    private var historyController: InputHistoryController?
    private var storageObserver: NSObjectProtocol?
    private var hasSession = false
    private var mutationReasons: [String] = []
    private var lastObservedText = ""
    private var becameEmpty = false
    private var rollbackCursor: Int64?
    private var isRestoring = false
    private let logger = Logger(subsystem: "com.lyp.DoubaoVoiceBridge", category: "composer")
    private var settleWorkItem: DispatchWorkItem?
    private var settleStartedAt: Date?
    private var lastTextChangeAt = Date()
    private var sessionID = UUID()
    private var lastLoggedLength = -1
    private var lastLoggedMarkedState = false
    private var isWaitingForFinalTranscript = false
    private var acceptsTranscriptUpdates = false
    private var mode: ComposerSessionMode = .manual

    init(history: InputHistoryJournal = InputHistoryJournal(),
         presentWindow: @escaping (NSWindow, NSTextView) -> Void = { window, textView in
             NSApp.activate(ignoringOtherApps: true)
             window.makeKeyAndOrderFront(nil)
             window.makeFirstResponder(textView)
         }) {
        self.history = history
        self.presentWindow = presentWindow
        let panel = DictationPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 300),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "远控听写"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.97)
        super.init(window: panel)
        buildInterface(in: panel)
        storageObserver = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification,
            object: textView.textStorage, queue: nil) { [weak self] notification in
                guard let self, let storage = notification.object as? NSTextStorage,
                      storage.editedMask.contains(.editedCharacters) else { return }
                self.captureVersion(reason: self.mutationReasons.last ?? "text-storage")
            }
        updateSaveStatus()
    }

    deinit { if let storageObserver { NotificationCenter.default.removeObserver(storageObserver) } }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func begin(targetDescription: String, mode: ComposerSessionMode) {
        captureVersion(reason: "app.before-new-session")
        self.mode = mode
        sessionID = UUID()
        hasSession = true
        rollbackCursor = nil
        becameEmpty = false
        cancelSettleTimer()
        mutationReasons.append("app.new-session")
        textView.string = ""
        captureVersion(reason: "app.new-session")
        mutationReasons.removeLast()
        textView.undoManager?.removeAllActions()
        lastLoggedLength = -1
        lastLoggedMarkedState = false
        isWaitingForFinalTranscript = false
        acceptsTranscriptUpdates = true
        textView.isEditable = true
        updateSaveStatus()
        lastTextChangeAt = Date()
        targetLabel.stringValue = targetDescription
        statusLabel.stringValue = mode == .manual
            ? "用豆包语音键或直接输入；回车粘贴，Shift+回车换行，Esc 取消"
            : "正在启动豆包语音输入法…按住左 ⌃ 说话，松开后自动发送"
        statusLabel.textColor = .secondaryLabelColor

        guard let window else { return }
        position(window)
        presentWindow(window, textView)
        window.contentView?.layoutSubtreeIfNeeded()
        ComposerTextLayout.synchronize(textView, with: scrollView)
        logger.notice(
            "Composer ready session=\(self.shortSessionID, privacy: .public) textWidth=\(self.textView.frame.width, privacy: .public) containerWidth=\(self.textView.textContainer?.containerSize.width ?? 0, privacy: .public)"
        )
    }

    func activate() {
        if let window { presentWindow(window, textView) }
    }

    func waitForFinalTranscript() {
        guard mode == .automatic else { return }
        isWaitingForFinalTranscript = true
        statusLabel.stringValue = "正在等待豆包语音输入法完成识别…"
        statusLabel.textColor = .secondaryLabelColor
        settleStartedAt = Date()
        lastTextChangeAt = Date()
        scheduleSettleCheck(for: sessionID)
    }

    func showSending() {
        captureVersion(reason: "app.before-delivery")
        isWaitingForFinalTranscript = false
        acceptsTranscriptUpdates = false
        cancelSettleTimer()
        statusLabel.stringValue = "识别完成，正在同步到 Mac mini…"
        statusLabel.textColor = .secondaryLabelColor
        textView.isEditable = false
        updateSaveStatus()
        window?.makeFirstResponder(nil)
    }

    func showError(_ message: String) {
        isWaitingForFinalTranscript = false
        acceptsTranscriptUpdates = true
        cancelSettleTimer()
        statusLabel.stringValue = message
        statusLabel.textColor = .systemRed
        textView.isEditable = true
        updateSaveStatus()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textView)
    }

    func showWaitingForClipboard() {
        showSending()
        statusLabel.stringValue = "文字已就绪，等待上一轮粘贴完成…按 Esc 取消"
        // Keep Escape available while queued, without accepting more transcript.
        window?.makeFirstResponder(textView)
    }

    func hide() {
        captureVersion(reason: "app.hide")
        isWaitingForFinalTranscript = false
        acceptsTranscriptUpdates = false
        cancelSettleTimer()
        window?.orderOut(nil)
        updateSaveStatus()
    }

    func currentText() -> String {
        textView.string
    }

    func saveForTermination() {
        captureVersion(reason: "app.termination")
        history.flush()
    }

    @objc func showHistory() {
        captureVersion(reason: "app.open-history")
        if historyController == nil {
            let controller = InputHistoryController(journal: history)
            controller.canRestore = { [weak self] in self?.acceptsTranscriptUpdates == true }
            controller.onRestore = { [weak self] version in self?.restoreVersion(version) ?? false }
            historyController = controller
        }
        historyController?.present()
    }

    @objc func restorePreviousVersion() {
        guard acceptsTranscriptUpdates else { return }
        captureVersion(reason: "app.before-restore")
        do {
            guard let version = try history.previousNonempty(before: rollbackCursor, excluding: textView.string) else {
                statusLabel.stringValue = "没有更早的非空版本；可在输入历史中选择其他记录"
                return
            }
            _ = restoreVersion(version)
            rollbackCursor = version.id
        } catch { saveLabel.stringValue = "读取历史失败，现有记录未被清理" }
    }

    @discardableResult
    private func restoreVersion(_ version: InputVersion) -> Bool {
        guard acceptsTranscriptUpdates else { return false }
        captureVersion(reason: "app.before-restore")
        isRestoring = true
        mutationReasons.append("app.restore")
        defer { mutationReasons.removeLast(); isRestoring = false }
        textView.inputContext?.discardMarkedText()
        textView.unmarkText()
        textView.string = version.text
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        captureVersion(reason: "app.restore")
        becameEmpty = false
        statusLabel.stringValue = "已恢复 \(version.characterCount) 字。请检查文字，再按回车粘贴"
        updateSaveStatus()
        activate()
        return true
    }

    private func captureVersion(reason: String) {
        guard hasSession else { return }
        let text = textView.string
        let previousCount = lastObservedText.count
        let actualReason = isRestoring ? "app.restore" : reason
        let recorded = history.record(sessionID: sessionID, text: text, marked: textView.hasMarkedText(), reason: actualReason)
        if recorded {
            if !isRestoring { rollbackCursor = nil }
            if previousCount > 0, text.isEmpty, !actualReason.hasPrefix("app.") {
                becameEmpty = true
                logger.error("Input became empty session=\(self.shortSessionID, privacy: .public) previousCharacters=\(previousCount) origin=\(actualReason, privacy: .public)")
            } else if !text.isEmpty { becameEmpty = false }
            logger.notice("Input version captured session=\(self.shortSessionID, privacy: .public) characters=\(text.count) marked=\(self.textView.hasMarkedText()) origin=\(actualReason, privacy: .public) durable=\(!self.history.hasUnsavedVersions)")
        }
        lastObservedText = text
        updateSaveStatus()
    }

    private func updateSaveStatus() {
        let title = "输入历史（\(history.count)/10版）"
        if historyButton.title != title { historyButton.title = title }
        let enabled = acceptsTranscriptUpdates && history.count > 0
        if recoveryButton.isEnabled != enabled { recoveryButton.isEnabled = enabled }
        let color: NSColor = history.lastError == nil ? .secondaryLabelColor : .systemRed
        if saveLabel.textColor != color { saveLabel.textColor = color }
        let message: String
        if history.lastError != nil {
            message = "本机保存失败，版本暂存内存；请先复制重要文字"
        } else if becameEmpty {
            message = "清空前的版本已保存，点击“恢复上一版”可找回"
        } else {
            message = "已保留 \(history.count)/10 版 · 本次 \(textView.string.count) 字"
        }
        if saveLabel.stringValue != message { saveLabel.stringValue = message }
    }

    var isReadyForLocalDictation: Bool {
        guard let window else { return false }
        return NSApp.isActive &&
            window.isKeyWindow &&
            window.firstResponder === textView &&
            textView.frame.width > 0 &&
            (textView.textContainer?.containerSize.width ?? 0) > 0
    }

    func textDidChange(_ notification: Notification) {
        captureVersion(reason: mutationReasons.last ?? "text-change")
        lastTextChangeAt = Date()
        let length = textView.string.utf16.count
        let marked = textView.hasMarkedText()
        if length != lastLoggedLength || marked != lastLoggedMarkedState {
            lastLoggedLength = length
            lastLoggedMarkedState = marked
            let bucket = PrivacySafeTextMetrics.lengthBucket(length)
            logger.notice(
                "Transcript updated session=\(self.shortSessionID, privacy: .public) lengthBucket=\(bucket, privacy: .public) marked=\(marked, privacy: .public) textWidth=\(self.textView.frame.width, privacy: .public)"
            )
        }
        if length > 0, acceptsTranscriptUpdates {
            if mode == .manual {
                statusLabel.stringValue = marked
                    ? "正在输入…完成后按回车粘贴，Esc 取消"
                    : "可继续修改；回车粘贴到远端，Shift+回车换行"
            } else if isWaitingForFinalTranscript {
                statusLabel.stringValue = marked
                    ? "豆包语音输入法正在完成识别…"
                    : "已收到识别文字，正在准备自动发送…"
            } else {
                statusLabel.stringValue = marked
                    ? "豆包语音输入法正在识别…按住左 ⌃ 继续说话"
                    : "已收到识别文字，松开左 ⌃ 后自动发送"
            }
        }
    }

    private func buildInterface(in panel: NSPanel) {
        guard let content = panel.contentView else { return }

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "语音输入")
        icon.contentTintColor = .systemBlue
        icon.translatesAutoresizingMaskIntoConstraints = false

        targetLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        targetLabel.textColor = .labelColor
        targetLabel.lineBreakMode = .byTruncatingMiddle
        targetLabel.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        textView.delegate = self
        textView.font = .systemFont(ofSize: 18)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.isRichText = false
        textView.allowsUndo = true
        textView.setAccessibilityLabel("远端输入内容")
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.onCommit = { [weak self] in self?.commitCurrentText() }
        textView.onCancel = { [weak self] in self?.onCancel?() }
        textView.onControlReleased = { [weak self] in
            guard let self, self.mode == .automatic else { return }
            self.onControlReleased?()
        }
        textView.onBeforeInputMutation = { [weak self] reason in
            guard let self else { return }
            self.captureVersion(reason: "before.\(reason)")
            self.mutationReasons.append(reason)
        }
        textView.onAfterInputMutation = { [weak self] reason in
            guard let self else { return }
            self.captureVersion(reason: reason)
            if !self.mutationReasons.isEmpty { self.mutationReasons.removeLast() }
        }

        ComposerTextLayout.attach(textView, to: scrollView)
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(icon)
        content.addSubview(targetLabel)
        content.addSubview(statusLabel)
        content.addSubview(scrollView)
        recoveryButton.target = self
        recoveryButton.action = #selector(restorePreviousVersion)
        historyButton.target = self
        historyButton.action = #selector(showHistory)
        saveLabel.font = .systemFont(ofSize: 11)
        let footer = NSStackView(views: [recoveryButton, historyButton, saveLabel])
        footer.spacing = 10
        footer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(footer)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            icon.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            icon.widthAnchor.constraint(equalToConstant: 27),
            icon.heightAnchor.constraint(equalToConstant: 27),

            targetLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            targetLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            targetLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 17),

            statusLabel.leadingAnchor.constraint(equalTo: targetLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: targetLabel.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: targetLabel.bottomAnchor, constant: 2),

            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            scrollView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            footer.heightAnchor.constraint(greaterThanOrEqualToConstant: 28)
        ])
    }

    private func position(_ window: NSWindow) {
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            window.center()
            return
        }
        let frame = window.frame
        let origin = NSPoint(
            x: visibleFrame.midX - frame.width / 2,
            y: visibleFrame.minY + 54
        )
        window.setFrameOrigin(origin)
    }

    private func commitCurrentText() {
        let text = textView.string
        guard !text.isEmpty else {
            showError("没有识别到文字，请继续说话或按 Esc 取消")
            return
        }
        onCommit?(text)
    }

    private func scheduleSettleCheck(for expectedSessionID: UUID) {
        settleWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.checkWhetherTranscriptSettled(expectedSessionID: expectedSessionID)
        }
        settleWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + TranscriptSettlePolicy.pollingInterval,
            execute: workItem
        )
    }

    private func checkWhetherTranscriptSettled(expectedSessionID: UUID) {
        guard expectedSessionID == sessionID,
              let startedAt = settleStartedAt else { return }

        let now = Date()
        let elapsed = now.timeIntervalSince(startedAt)
        let stableFor = now.timeIntervalSince(lastTextChangeAt)
        let text = textView.string

        if TranscriptSettlePolicy.isReady(
            textIsEmpty: text.isEmpty,
            hasMarkedText: textView.hasMarkedText(),
            elapsedAfterRelease: elapsed,
            stableFor: stableFor
        ) {
            let bucket = PrivacySafeTextMetrics.lengthBucket(text.utf16.count)
            logger.notice(
                "Transcript settled session=\(self.shortSessionID, privacy: .public) lengthBucket=\(bucket, privacy: .public) elapsed=\(elapsed, privacy: .public)"
            )
            onCommit?(text)
            return
        }

        if elapsed >= 8.0 {
            if !text.isEmpty,
               !textView.hasMarkedText(),
               stableFor >= TranscriptSettlePolicy.requiredStableDuration {
                let bucket = PrivacySafeTextMetrics.lengthBucket(text.utf16.count)
                logger.notice(
                    "Transcript settled at deadline session=\(self.shortSessionID, privacy: .public) lengthBucket=\(bucket, privacy: .public)"
                )
                onCommit?(text)
            } else {
                let bucket = PrivacySafeTextMetrics.lengthBucket(text.utf16.count)
                logger.error(
                    "Transcript timeout session=\(self.shortSessionID, privacy: .public) lengthBucket=\(bucket, privacy: .public) marked=\(self.textView.hasMarkedText(), privacy: .public)"
                )
                onTranscriptTimeout?()
            }
            return
        }
        scheduleSettleCheck(for: expectedSessionID)
    }

    private func cancelSettleTimer() {
        settleWorkItem?.cancel()
        settleWorkItem = nil
        settleStartedAt = nil
    }

    private var shortSessionID: String {
        String(sessionID.uuidString.prefix(8))
    }
}
