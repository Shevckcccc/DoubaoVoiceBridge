import AppKit

final class InputHistoryController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    var onRestore: ((InputVersion) -> Bool)?
    var canRestore: () -> Bool = { false }
    private let journal: InputHistoryJournal
    private let table = NSTableView()
    private let preview = NSTextView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let restoreButton = NSButton(title: "恢复到输入框", target: nil, action: nil)
    private let copyButton = NSButton(title: "复制这一版全文", target: nil, action: nil)
    private var rows: [InputVersion] = []
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    init(journal: InputHistoryJournal) {
        self.journal = journal
        let window = DictationPanel(contentRect: NSRect(x: 0, y: 0, width: 850, height: 550),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "输入历史 · 最近 10 个回滚版本"
        window.level = .floating
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: window)
        buildInterface()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        reloadHistory()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        let heading = NSTextField(wrappingLabelWithString: "连续追加合并为一版；缩短、整句改写或新一轮输入时另存一版。保留最近 10 版，恢复后检查文字，再按回车粘贴。")
        let list = NSScrollView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("version"))
        column.title = "时间 · 字数 · 版本内容"
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 26
        table.delegate = self
        table.dataSource = self
        table.allowsEmptySelection = true
        table.setAccessibilityLabel("输入历史版本列表")
        list.documentView = table
        list.hasVerticalScroller = true
        list.borderType = .bezelBorder
        let detail = NSScrollView()
        preview.isEditable = false
        preview.isRichText = false
        preview.font = .systemFont(ofSize: 15)
        preview.textContainerInset = NSSize(width: 10, height: 10)
        preview.setAccessibilityLabel("历史版本全文")
        ComposerTextLayout.attach(preview, to: detail)
        detail.hasVerticalScroller = true
        detail.borderType = .bezelBorder
        let refresh = NSButton(title: "刷新", target: self, action: #selector(reloadHistory))
        restoreButton.target = self
        restoreButton.action = #selector(restoreSelected)
        copyButton.target = self
        copyButton.action = #selector(copySelected)
        let buttons = NSStackView(views: [restoreButton, copyButton, refresh])
        buttons.spacing = 10
        for view in [heading, list, detail, buttons, status] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            heading.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            list.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            list.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 12),
            list.widthAnchor.constraint(equalTo: content.widthAnchor, multiplier: 0.47),
            list.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
            detail.leadingAnchor.constraint(equalTo: list.trailingAnchor, constant: 12),
            detail.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            detail.topAnchor.constraint(equalTo: list.topAnchor),
            detail.bottomAnchor.constraint(equalTo: list.bottomAnchor),
            buttons.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            buttons.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -10),
            status.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)
        ])
    }

    @objc private func reloadHistory() {
        do {
            rows = try journal.versions()
            table.reloadData()
            if let index = rows.firstIndex(where: { !$0.text.isEmpty }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
            updateSelection()
        } catch { status.stringValue = "读取历史失败；现有记录未被清理。" }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let version = rows[row]
        let excerpt = version.text.isEmpty ? "（空白版本，之前的文字仍在历史中）"
            : String(version.text.prefix(65)).replacingOccurrences(of: "\n", with: " ⏎ ")
        let number = version.id > 0 ? "#\(version.id)" : "待保存"
        let field = NSTextField(labelWithString: "\(number) · \(dateFormatter.string(from: version.date)) · \(version.characterCount)字 · \(excerpt)")
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }

    private var selected: InputVersion? {
        rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil
    }

    private func updateSelection() {
        preview.string = selected?.text ?? ""
        if let scroll = preview.enclosingScrollView { ComposerTextLayout.synchronize(preview, with: scroll) }
        restoreButton.isEnabled = selected != nil && canRestore()
        copyButton.isEnabled = selected?.text.isEmpty == false
        updateStatus()
    }

    private func updateStatus() {
        var message = "已保留 \(journal.count)/10 个回滚版本，逐字追加不会增加版本数。"
        if journal.lastError != nil { message += " 本机保存或读取尚未成功，原有记录未被清理。" }
        if journal.hasUnsavedVersions { message += " 有版本暂存在内存，磁盘保存尚未成功。" }
        if !canRestore() { message += " 先在 UU 打开输入框即可恢复；也可直接复制全文。" }
        if let selected { message += " 当前：\(selected.marked ? "输入法组合文字" : "已提交到输入框的文字") · \(Self.reasonLabel(selected.reason))" }
        status.stringValue = message
    }

    private static func reasonLabel(_ reason: String) -> String {
        if reason == "app.restore" { return "从历史恢复" }
        if reason == "app.new-session" { return "新一轮输入" }
        if reason.hasPrefix("before.") { return "替换前保留" }
        if reason.hasPrefix("input.") { return "输入法更新" }
        if reason == "app.before-delivery" { return "粘贴前保留" }
        return "文字变化时保留"
    }

    @objc private func restoreSelected() {
        guard let selected, canRestore(), onRestore?(selected) == true else { return }
        window?.orderOut(nil)
    }

    @objc private func copySelected() {
        guard let selected, !selected.text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selected.text, forType: .string)
        status.stringValue = "已复制这一版本的全文。"
    }
}
