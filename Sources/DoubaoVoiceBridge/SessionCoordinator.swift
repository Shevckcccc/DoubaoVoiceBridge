import AppKit

protocol DictationComposer: AnyObject {
    var onCommit: ((String) -> Void)? { get set }
    var onCancel: (() -> Void)? { get set }
    var onControlReleased: (() -> Void)? { get set }
    var onTranscriptTimeout: (() -> Void)? { get set }
    var isReadyForLocalDictation: Bool { get }
    func begin(targetDescription: String)
    func waitForFinalTranscript()
    func hide()
    func showSending()
    func showWaitingForClipboard()
    func showError(_ message: String)
    func currentText() -> String
}

extension ComposerPanelController: DictationComposer {}

protocol TranscriptDelivery: AnyObject {
    func deliver(text: String, to target: UURemoteTarget,
                 panelWillHide: @escaping () -> Void,
                 completion: @escaping (Result<Void, Error>) -> Void,
                 cleanupCompletion: @escaping () -> Void)
    func restoreClipboardForTermination()
}

extension UURemoteDelivery: TranscriptDelivery {}

final class SessionCoordinator {
    enum State: Equatable {
        case idle
        case listening
        case finalizing
        case waitingForClipboard
        case delivering
        case failed
    }

    var onStatusChange: ((String, Bool) -> Void)?
    var onGestureFinished: (() -> Void)?

    private let panel: DictationComposer
    private let delivery: TranscriptDelivery
    private let activateTarget: (UURemoteTarget) -> Void
    private(set) var state: State = .idle
    private var target: UURemoteTarget?
    private var deliveryAwaitingCleanup = false
    private var queuedText: String?
    var isClipboardBusy: Bool { deliveryAwaitingCleanup }

    var canBegin: Bool {
        state == .idle || state == .failed
    }

    var isLocalComposerReady: Bool {
        state == .listening && panel.isReadyForLocalDictation
    }

    init(panel: DictationComposer = ComposerPanelController(),
         delivery: TranscriptDelivery = UURemoteDelivery(),
         activateTarget: @escaping (UURemoteTarget) -> Void = { $0.activateOriginalWindow() }) {
        self.panel = panel
        self.delivery = delivery
        self.activateTarget = activateTarget
        panel.onCommit = { [weak self] text in self?.send(text: text) }
        panel.onCancel = { [weak self] in self?.cancel() }
        panel.onControlReleased = { [weak self] in self?.controlReleased() }
        panel.onTranscriptTimeout = { [weak self] in self?.handleTranscriptTimeout() }
    }

    func begin(target: UURemoteTarget) {
        guard canBegin else { return }
        self.target = target
        state = .listening
        panel.begin(targetDescription: "发送到 Mac mini · UU 远控")
        onStatusChange?("正在听写…松开左 ⌃ 自动发送", false)
    }

    func controlReleased() {
        guard state == .listening else { return }
        state = .finalizing
        onGestureFinished?()
        panel.waitForFinalTranscript()
        onStatusChange?("正在完成识别…", false)
    }

    func cancel() {
        guard state != .idle, state != .delivering else { return }
        let target = self.target
        self.target = nil
        queuedText = nil
        state = .idle
        onGestureFinished?()
        panel.hide()
        if let target { activateTarget(target) }
        onStatusChange?("就绪 · 在 UU 远控中长按左 ⌃", false)
    }

    func prepareForTermination() {
        ClipboardKeyboardPaster.finishPendingEventsBeforeTermination()
        delivery.restoreClipboardForTermination()
    }

    private func send(text: String) {
        guard state == .listening || state == .finalizing || state == .failed,
              let target else { return }
        onGestureFinished?()
        if deliveryAwaitingCleanup {
            // Listening can overlap the previous clipboard restore, but writes
            // cannot: keep the next transcript in memory until it completes.
            queuedText = text
            state = .waitingForClipboard
            panel.showWaitingForClipboard()
            onStatusChange?("文字已就绪，等待上一轮粘贴完成…", false)
            return
        }
        state = .delivering
        deliveryAwaitingCleanup = true
        panel.showSending()
        onStatusChange?("正在同步并自动粘贴…", false)

        delivery.deliver(
            text: text,
            to: target,
            panelWillHide: { [weak self] in self?.panel.hide() },
            completion: { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.target = nil
                    self.state = .idle
                    self.onStatusChange?("已向 Mac mini 发送自动粘贴指令", false)
                case .failure(let error):
                    self.deliveryAwaitingCleanup = false
                    self.state = .failed
                    let message = error.localizedDescription
                    self.panel.showError("\(message)。文字仍保留，可按回车重试")
                    self.onStatusChange?(message, true)
                }
            },
            cleanupCompletion: { [weak self] in
                guard let self else { return }
                self.deliveryAwaitingCleanup = false
                if self.state == .waitingForClipboard, let text = self.queuedText {
                    self.queuedText = nil
                    self.state = .finalizing
                    self.send(text: text)
                } else if self.state == .idle {
                    self.onStatusChange?("就绪 · 在 UU 远控中长按左 ⌃", false)
                }
            }
        )
    }

    private func handleTranscriptTimeout() {
        state = .failed
        onGestureFinished?()
        if panel.currentText().isEmpty {
            panel.showError("没有识别到文字。按 Esc 返回 UU 后可重试")
            onStatusChange?("没有识别到文字，请重试", true)
        } else {
            panel.showError("豆包语音输入法尚未完成识别，确认文字后按回车发送，或按 Esc 取消")
            onStatusChange?("识别超时，等待手动确认", true)
        }
    }
}
