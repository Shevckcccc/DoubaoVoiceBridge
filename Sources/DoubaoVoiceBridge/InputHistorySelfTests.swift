import AppKit
import Darwin
import SQLite3

// Synthetic text only. All databases live under a dedicated temporary directory;
// the production input-history directory is never opened by these checks.
enum InputHistorySelfTests {
    static func crashWriter(path: String) -> Never {
        let journal = InputHistoryJournal(url: URL(fileURLWithPath: path))
        let session = UUID()
        for length in 1...100 {
            journal.record(sessionID: session, text: String(repeating: "测", count: length), marked: true, reason: "test.input")
        }
        journal.record(sessionID: session, text: "", marked: false, reason: "test.empty")
        // Deliberately bypass deinit/SQLite close and AppKit termination cleanup.
        Darwin._exit(journal.hasUnsavedVersions || journal.lastError != nil ? 2 : 0)
    }

    static func run() -> [String] {
        var failures: [String] = []
        func check<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
            if actual != expected { failures.append("\(label): expected \(expected), got \(actual)") }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dvb-history-selftest-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let hundred = String(repeating: "测", count: 100)
        func url(_ name: String) -> URL { root.appendingPathComponent(name).appendingPathComponent("versions.sqlite3") }

        do {
            let path = url("versions")
            let journal = InputHistoryJournal(url: path)
            let session = UUID()
            journal.record(sessionID: session, text: hundred, marked: true, reason: "input.marked")
            journal.record(sessionID: session, text: "", marked: false, reason: "input.insert")
            check(journal.count, 2, "100-to-zero adds two durable versions")
            check(try journal.previousNonempty(excluding: "")?.text, hundred, "100 characters survive empty replacement")
            journal.record(sessionID: session, text: "", marked: false, reason: "text-change")
            check(journal.count, 2, "identical duplicate notification does not add noise")
            journal.record(sessionID: UUID(), text: "", marked: false, reason: "app.new-session")
            check(journal.count, 2, "new empty session consumes no history version")
            let reopened = InputHistoryJournal(url: path)
            check(reopened.count, 2, "empty-only opens do not retain an extra input round")
            check(try reopened.previousNonempty(excluding: "")?.text, hundred, "fresh reader restores previous text")
            let store = try InputHistoryStore(url: path)
            let texts = ["语音🙂\nsecond\u{0000}tail", "é", "e\u{0301}"]
            try store.append(texts.map { InputVersion(id: 0, sessionID: session, date: Date(), text: $0, marked: false, reason: "test.unicode") })
            let read = try store.versions(limit: 3).reversed().map { Data($0.text.utf8) }
            check(Array(read), texts.map { Data($0.utf8) }, "emoji, newline, NUL and Unicode bytes survive exactly")
            let nul = "body\u{0000}tail"
            try store.append([InputVersion(id: 0, sessionID: UUID(), date: Date(), text: nul, marked: false, reason: "test.unicode")])
            let lastSession = try store.versions(limit: 1).first!.sessionID
            try store.append([InputVersion(id: 0, sessionID: lastSession, date: Date(), text: nul + " appended", marked: false, reason: "test.growth")])
            check(try store.versions(limit: 1).map { Data($0.text.utf8) }, [Data((nul + " appended").utf8)], "incremental SQL append preserves embedded NUL")
            let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
            check((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600, "history file is owner-only")
        } catch { failures.append("history persistence checks: \(error.localizedDescription)") }

        do {
            let path = url("immutable")
            let store = try InputHistoryStore(url: path)
            try store.append([InputVersion(id: 0, sessionID: UUID(), date: Date(), text: hundred, marked: false, reason: "test")])
            var database: OpaquePointer?
            guard sqlite3_open(path.path, &database) == SQLITE_OK else { throw InputHistoryError(operation: "测试打开") }
            defer { sqlite3_close_v2(database) }
            check(sqlite3_exec(database, "DELETE FROM input_versions;", nil, nil, nil) == SQLITE_OK, false, "SQL deletion is rejected")
            check(sqlite3_exec(database, "UPDATE input_versions SET text='';", nil, nil, nil) == SQLITE_OK, false, "SQL overwrites are rejected")
            check(try store.count(), 1, "failed destructive statements preserve count")
            check(try store.versions().first?.text, hundred, "failed destructive statements preserve text")
        } catch { failures.append("append-only checks: \(error.localizedDescription)") }

        do {
            let path = url("retry")
            let journal = InputHistoryJournal(url: path)
            let session = UUID()
            journal.record(sessionID: session, text: "seed", marked: false, reason: "test.seed")
            var database: OpaquePointer?
            guard sqlite3_open(path.path, &database) == SQLITE_OK else { throw InputHistoryError(operation: "测试打开") }
            defer { sqlite3_close_v2(database) }
            sqlite3_exec(database, "CREATE TRIGGER test_write_failure BEFORE INSERT ON input_versions BEGIN SELECT RAISE(ABORT,'simulated write failure'); END;", nil, nil, nil)
            journal.record(sessionID: session, text: hundred, marked: true, reason: "test.input")
            journal.record(sessionID: session, text: "", marked: false, reason: "test.empty")
            check(journal.hasUnsavedVersions, true, "disk failure is visible rather than silently accepted")
            check(journal.count, 3, "disk failure retains each pending version in memory")
            check(try journal.previousNonempty(excluding: "")?.text, hundred, "pending 100 characters remain recoverable")
            sqlite3_exec(database, "DROP TRIGGER test_write_failure;", nil, nil, nil)
            journal.flush()
            check(journal.hasUnsavedVersions, false, "recovery persists all outstanding versions")
            check(journal.lastError == nil, true, "successful retry clears storage error")
            let reopened = InputHistoryJournal(url: path)
            check(try reopened.versions().map(\.text), ["", hundred, "seed"], "retry commits every version in order")
        } catch { failures.append("history write-retry checks: \(error.localizedDescription)") }

        do {
            let path = url("crash")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = ["--history-crash-test", path.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            check(process.terminationStatus, 0, "crash writer committed before abrupt process exit")
            let reopened = InputHistoryJournal(url: path)
            check(reopened.count, 2, "abrupt process exit retains both versions")
            check(try reopened.previousNonempty(excluding: "")?.text, hundred, "100 characters recover after process exit without cleanup")
        } catch { failures.append("crash recovery checks: \(error.localizedDescription)") }

        do {
            _ = NSApplication.shared
            let journal = InputHistoryJournal(url: url("editor"))
            // Instantiate the production editor but never present/focus a window.
            let panel = ComposerPanelController(history: journal, presentWindow: { _, _ in })
            var commits = 0
            panel.onCommit = { _ in commits += 1 }
            panel.begin(targetDescription: "test", mode: .manual)
            guard let editor = panel.window?.contentView?.subviews.compactMap({
                ($0 as? NSScrollView)?.documentView as? ComposerTextView
            }).first else { throw InputHistoryError(operation: "测试编辑器") }
            editor.string = hundred
            editor.string = ""
            let countBeforeRestore = journal.count
            check(try journal.previousNonempty(excluding: "")?.text, hundred, "production text-storage observer captures 100 before zero")
            panel.restorePreviousVersion()
            check(panel.currentText(), hundred, "production recovery button restores all 100 characters")
            check(journal.count > countBeforeRestore, true, "restoring appends a version instead of changing history")
            check(commits, 0, "restoring never pastes or submits")
            editor.string = "legitimate shorter edit"
            check(panel.currentText(), "legitimate shorter edit", "shorter edits remain allowed")
            panel.restorePreviousVersion()
            check(panel.currentText(), hundred, "shorter edit does not replace earlier complete text")
            editor.setMarkedText(hundred, selectedRange: NSRange(location: 100, length: 0),
                replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            editor.setMarkedText("", selectedRange: NSRange(location: 0, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0))
            check(try journal.versions().contains { $0.text == hundred && $0.marked }, true, "production IME marked-text snapshot is retained")
            panel.restorePreviousVersion()
            check(panel.currentText(), hundred, "empty IME replacement can be rolled back")
            panel.hide()
            panel.begin(targetDescription: "next test", mode: .manual)
            check(panel.currentText(), "", "new input starts empty")
            panel.restorePreviousVersion()
            check(panel.currentText(), hundred, "new session can recover previous session")
            panel.saveForTermination()
            check(journal.hasUnsavedVersions, false, "editor snapshots are durable before termination")
        } catch { failures.append("production editor recovery checks: \(error.localizedDescription)") }

        do {
            let store = try InputHistoryStore(url: url("ten-checkpoints"))
            let first = UUID()
            try store.append((0...100).map {
                InputVersion(id: 0, sessionID: first, date: Date(), text: String(repeating: "测", count: $0), marked: true, reason: "test.growth")
            })
            check(try store.count(), 1, "typing 100 characters creates one growing version")
            check(try store.versions().first?.text, hundred, "growing version contains all 100 characters")
            try store.append([InputVersion(id: 0, sessionID: first, date: Date(), text: hundred, marked: false, reason: "input.unmark")])
            check(try store.count(), 1, "IME confirmation does not create a redundant version")
            try store.append([InputVersion(id: 0, sessionID: first, date: Date(), text: "", marked: false, reason: "input.marked")])
            check(try store.count(), 2, "shrinking creates a separate checkpoint")
            check(try store.versions().map(\.text), ["", hundred], "shrinking never overwrites complete text")
            try store.append([InputVersion(id: 0, sessionID: first, date: Date(), text: "abc", marked: false, reason: "input.insert")])
            check(try store.count(), 2, "growth after clear extends the new version")
            try store.append([InputVersion(id: 0, sessionID: first, date: Date(), text: "xyz", marked: false, reason: "input.insert")])
            check(try store.versions().map(\.text), ["xyz", "abc", hundred], "same-length rewrite preserves original wording")
            for index in 0..<20 {
                try store.append([InputVersion(id: 0, sessionID: UUID(), date: Date(), text: "input \(index)", marked: false, reason: "test.session")])
            }
            check(try store.count(), 10, "only ten rollback versions are retained")
            check(try store.versions().map(\.text), (10..<20).reversed().map { "input \($0)" }, "retention keeps precisely the ten latest checkpoints")
            let count = try store.count()
            try store.append([InputVersion(id: 0, sessionID: UUID(), date: Date(), text: "", marked: false, reason: "app.new-session")])
            check(try store.count(), count, "empty input open cannot evict a useful version")
        } catch { failures.append("incremental ten-version checks: \(error.localizedDescription)") }
        do {
            let path = url("legacy-compaction")
            do { _ = try InputHistoryStore(url: path) }
            var database: OpaquePointer?
            guard sqlite3_open(path.path, &database) == SQLITE_OK else { throw InputHistoryError(operation: "测试打开") }
            let firstSession = UUID()
            let nextSession = UUID()
            var statement: OpaquePointer?
            sqlite3_prepare_v2(database, "INSERT INTO input_versions(session_id,created_at,text,marked,reason,character_count) VALUES(?,0,?,0,'input.marked',?);", -1, &statement, nil)
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            let samples = (0...100).map { (firstSession, String(repeating: "测", count: $0)) }
                + [(firstSession, ""), (firstSession, String(repeating: "测", count: 50))]
                + (0...50).map { (nextSession, String(repeating: "测", count: $0)) }
            for (session, text) in samples {
                sqlite3_reset(statement)
                _ = session.uuidString.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
                _ = text.withCString { sqlite3_bind_text(statement, 2, $0, -1, transient) }
                sqlite3_bind_int64(statement, 3, Int64(text.count))
                guard sqlite3_step(statement) == SQLITE_DONE else { throw InputHistoryError(operation: "测试写入") }
            }
            sqlite3_finalize(statement)
            sqlite3_exec(database, "PRAGMA user_version=0;", nil, nil, nil)
            sqlite3_close_v2(database)
            let migrated = try InputHistoryStore(url: path)
            check(try migrated.count(), 3, "legacy keystroke snapshots compact before the ten-version limit")
            check(try migrated.versions().map(\.text), [String(repeating: "测", count: 50), String(repeating: "测", count: 50), hundred], "legacy complete 100-character text survives compaction")
            check(try migrated.versions().map(\.sessionID), [nextSession, firstSession, firstSession], "compaction retains boundaries between actual inputs")
            let reopened = try InputHistoryStore(url: path)
            check(try reopened.count(), 3, "completed compaction does not repeat or discard checkpoints")
        } catch { failures.append("legacy compaction checks: \(error.localizedDescription)") }
        return failures
    }
}
