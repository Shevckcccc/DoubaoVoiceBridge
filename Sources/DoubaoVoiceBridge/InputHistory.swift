import Foundation
import SQLite3

struct InputVersion: Equatable {
    var id: Int64
    let sessionID: UUID
    let date: Date
    let text: String
    let marked: Bool
    let reason: String
    var characterCount: Int { text.count }

    func canGrow(from previous: InputVersion) -> Bool {
        guard sessionID == previous.sessionID, text.utf8.starts(with: previous.text.utf8) else { return false }
        // An explicit restoration preserves the draft it replaces, even when
        // the selected older text happens to extend that draft.
        return reason != "app.restore" || text.utf8.elementsEqual(previous.text.utf8)
    }
}

struct InputHistoryError: LocalizedError {
    let operation: String
    var errorDescription: String? { "输入记录\(operation)失败，文字仍保留在本次运行的内存中" }
}

// Pure growth updates only the current tail using an appended suffix. Shrinking,
// rewriting, restoration, and a new nonempty session freeze the tail and create
// a checkpoint. Only the last ten checkpoints are retained.
final class InputHistoryStore {
    static let retainedVersions = 10
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DoubaoVoiceBridge/InputHistory", isDirectory: true)
            .appendingPathComponent("versions.sqlite3")
    }
    private var database: OpaquePointer?
    private var isPruning = false
    private var isGrowing = false
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let database { sqlite3_close_v2(database) }
            database = nil
            throw InputHistoryError(operation: "打开")
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            sqlite3_busy_timeout(database, 1500)
            let owner = Unmanaged.passUnretained(self).toOpaque()
            guard sqlite3_create_function_v2(database, "history_retention_allowed", 0, SQLITE_UTF8, owner, { context, _, _ in
                guard let context, let owner = sqlite3_user_data(context) else { return }
                let store = Unmanaged<InputHistoryStore>.fromOpaque(owner).takeUnretainedValue()
                sqlite3_result_int(context, store.isPruning ? 1 : 0)
            }, nil, nil, nil) == SQLITE_OK,
            sqlite3_create_function_v2(database, "history_growth_allowed", 0, SQLITE_UTF8, owner, { context, _, _ in
                guard let context, let owner = sqlite3_user_data(context) else { return }
                let store = Unmanaged<InputHistoryStore>.fromOpaque(owner).takeUnretainedValue()
                sqlite3_result_int(context, store.isGrowing ? 1 : 0)
            }, nil, nil, nil) == SQLITE_OK else { throw InputHistoryError(operation: "打开") }
            try execute("PRAGMA journal_mode=WAL;")
            try execute("PRAGMA synchronous=FULL;")
            try execute("BEGIN IMMEDIATE;")
            do {
                try execute("""
                    CREATE TABLE IF NOT EXISTS input_versions (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        session_id TEXT NOT NULL, created_at REAL NOT NULL,
                        text TEXT NOT NULL, marked INTEGER NOT NULL,
                        reason TEXT NOT NULL, character_count INTEGER NOT NULL
                    );
                    CREATE INDEX IF NOT EXISTS input_versions_session ON input_versions(session_id, id);
                    DROP TRIGGER IF EXISTS input_versions_no_update;
                    CREATE TRIGGER input_versions_no_update BEFORE UPDATE ON input_versions
                        WHEN history_growth_allowed() = 0 OR old.id != (SELECT max(id) FROM input_versions)
                        BEGIN SELECT RAISE(ABORT, 'frozen history cannot be overwritten'); END;
                    DROP TRIGGER IF EXISTS input_versions_no_delete;
                    CREATE TRIGGER input_versions_no_delete BEFORE DELETE ON input_versions
                        WHEN history_retention_allowed() = 0
                        BEGIN SELECT RAISE(ABORT, 'only bounded retention may remove old history'); END;
                    """)
                try compactLegacyHistoryIfNeeded()
                try prune()
                try execute("COMMIT;")
            } catch {
                try? execute("ROLLBACK;")
                throw error
            }
        } catch {
            sqlite3_close_v2(database)
            database = nil
            throw error
        }
    }

    deinit { if let database { sqlite3_close_v2(database) } }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw InputHistoryError(operation: "写入") }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw InputHistoryError(operation: "读取")
        }
        return statement
    }

    private func bind(_ text: String, to index: Int32, in statement: OpaquePointer) throws {
        let count = text.utf8.count
        guard count <= Int(Int32.max) else { throw InputHistoryError(operation: "写入") }
        let result = text.withCString { sqlite3_bind_text(statement, index, $0, Int32(count), transient) }
        guard result == SQLITE_OK else { throw InputHistoryError(operation: "写入") }
    }

    private func string(_ statement: OpaquePointer, column: Int32) -> String {
        guard let bytes = sqlite3_column_text(statement, column) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
    }

    func append(_ changes: [InputVersion]) throws {
        guard !changes.isEmpty else { return }
        try execute("BEGIN IMMEDIATE;")
        do {
            var previous = try versions(limit: 1).first
            for change in changes {
                if let previous, change.canGrow(from: previous) {
                    let suffix = String(decoding: change.text.utf8.dropFirst(previous.text.utf8.count), as: UTF8.self)
                    let statement = try prepare("UPDATE input_versions SET text=text||?, created_at=?, marked=?, reason=?, character_count=? WHERE id=?;")
                    defer { sqlite3_finalize(statement) }
                    try bind(suffix, to: 1, in: statement)
                    sqlite3_bind_double(statement, 2, change.date.timeIntervalSince1970)
                    sqlite3_bind_int(statement, 3, change.marked ? 1 : 0)
                    try bind(change.reason, to: 4, in: statement)
                    sqlite3_bind_int64(statement, 5, Int64(change.characterCount))
                    sqlite3_bind_int64(statement, 6, previous.id)
                    isGrowing = true
                    let result = sqlite3_step(statement)
                    isGrowing = false
                    guard result == SQLITE_DONE else { throw InputHistoryError(operation: "写入") }
                } else {
                    // Merely opening a new empty input box consumes no version.
                    if change.text.isEmpty, previous?.sessionID != change.sessionID { continue }
                    let statement = try prepare("INSERT INTO input_versions(session_id,created_at,text,marked,reason,character_count) VALUES(?,?,?,?,?,?);")
                    defer { sqlite3_finalize(statement) }
                    try bind(change.sessionID.uuidString, to: 1, in: statement)
                    sqlite3_bind_double(statement, 2, change.date.timeIntervalSince1970)
                    try bind(change.text, to: 3, in: statement)
                    sqlite3_bind_int(statement, 4, change.marked ? 1 : 0)
                    try bind(change.reason, to: 5, in: statement)
                    sqlite3_bind_int64(statement, 6, Int64(change.characterCount))
                    guard sqlite3_step(statement) == SQLITE_DONE else { throw InputHistoryError(operation: "写入") }
                }
                previous = try versions(limit: 1).first
            }
            try prune()
            try execute("COMMIT;")
        } catch {
            isGrowing = false
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func prune() throws {
        isPruning = true
        defer { isPruning = false }
        try execute("DELETE FROM input_versions WHERE id NOT IN (SELECT id FROM input_versions ORDER BY id DESC LIMIT \(Self.retainedVersions));")
    }

    private func compactLegacyHistoryIfNeeded() throws {
        let version = try prepare("PRAGMA user_version;")
        defer { sqlite3_finalize(version) }
        guard sqlite3_step(version) == SQLITE_ROW else { throw InputHistoryError(operation: "读取") }
        guard sqlite3_column_int(version, 0) < 2 else { return }
        let statement = try prepare("SELECT id,session_id,created_at,text,marked,reason FROM input_versions ORDER BY id ASC;")
        var compacted: [InputVersion] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW, let session = UUID(uuidString: string(statement, column: 1)) else {
                sqlite3_finalize(statement)
                throw InputHistoryError(operation: "整理")
            }
            let entry = InputVersion(id: sqlite3_column_int64(statement, 0), sessionID: session,
                date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)), text: string(statement, column: 3),
                marked: sqlite3_column_int(statement, 4) != 0, reason: string(statement, column: 5))
            if entry.text.isEmpty, compacted.last?.sessionID != entry.sessionID { continue }
            if let previous = compacted.last, entry.canGrow(from: previous) {
                compacted[compacted.count - 1] = entry
            } else { compacted.append(entry) }
            compacted = Array(compacted.suffix(Self.retainedVersions))
        }
        sqlite3_finalize(statement)
        // Retain the actual complete original rows. This entire migration and
        // the schema version marker commit together, or roll back together.
        let ids = compacted.map { String($0.id) }.joined(separator: ",")
        isPruning = true
        defer { isPruning = false }
        try execute(ids.isEmpty ? "DELETE FROM input_versions;" : "DELETE FROM input_versions WHERE id NOT IN (\(ids));")
        try execute("PRAGMA user_version=2;")
    }

    func count() throws -> Int {
        let statement = try prepare("SELECT count(*) FROM input_versions;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw InputHistoryError(operation: "读取") }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func versions(before: Int64? = nil, limit: Int = retainedVersions, sessionID: UUID? = nil) throws -> [InputVersion] {
        var sql = "SELECT id,session_id,created_at,text,marked,reason FROM input_versions WHERE id < ?"
        if sessionID != nil { sql += " AND session_id = ?" }
        sql += " ORDER BY id DESC LIMIT ?;"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, before ?? Int64.max)
        var index: Int32 = 2
        if let sessionID { try bind(sessionID.uuidString, to: index, in: statement); index += 1 }
        sqlite3_bind_int64(statement, index, Int64(limit))
        var result: [InputVersion] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return result }
            guard step == SQLITE_ROW, let sessionID = UUID(uuidString: string(statement, column: 1)) else { throw InputHistoryError(operation: "读取") }
            result.append(InputVersion(id: sqlite3_column_int64(statement, 0), sessionID: sessionID,
                date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                text: string(statement, column: 3), marked: sqlite3_column_int(statement, 4) != 0,
                reason: string(statement, column: 5)))
        }
    }
}

// At most ten logical checkpoints are cached, including versions awaiting a disk
// retry. Pure growth coalesces in memory too; shrinking never overwrites its base.
final class InputHistoryJournal {
    let url: URL
    private var store: InputHistoryStore?
    private var pending: [InputVersion] = []
    private var archive: [InputVersion] = [] // newest first
    private var last: InputVersion?
    private var temporaryID: Int64 = 0
    private(set) var lastError: Error?
    var count: Int { archive.count }
    var hasUnsavedVersions: Bool { !pending.isEmpty }

    init(url: URL = InputHistoryStore.defaultURL) {
        self.url = url
        flush()
    }

    @discardableResult
    func record(sessionID: UUID, text: String, marked: Bool, reason: String, force: Bool = false) -> Bool {
        if !force, let last, last.sessionID == sessionID, last.marked == marked, last.text.utf8.elementsEqual(text.utf8) {
            if !pending.isEmpty || lastError != nil { flush() }
            return false
        }
        temporaryID -= 1
        let version = InputVersion(id: temporaryID, sessionID: sessionID, date: Date(), text: text, marked: marked, reason: reason)
        last = version
        if text.isEmpty, archive.first?.sessionID != sessionID {
            flush()
            return false
        }
        if let previous = archive.first, version.canGrow(from: previous) {
            var merged = version
            merged.id = previous.id
            archive[0] = merged
        } else { archive.insert(version, at: 0) }
        archive = Array(archive.prefix(InputHistoryStore.retainedVersions))
        if let previous = pending.last, version.canGrow(from: previous) {
            var merged = version
            merged.id = previous.id
            pending[pending.count - 1] = merged
        } else { pending.append(version) }
        pending = Array(pending.suffix(InputHistoryStore.retainedVersions))
        flush()
        return true
    }

    func flush() {
        do {
            if store == nil { store = try InputHistoryStore(url: url) }
            if !pending.isEmpty, let store {
                try store.append(pending)
                pending.removeAll()
            }
            if let store { archive = try store.versions() }
            lastError = nil
        } catch { lastError = error }
    }

    func versions(before: Int64? = nil, limit: Int = InputHistoryStore.retainedVersions, sessionID: UUID? = nil) throws -> [InputVersion] {
        if archive.isEmpty, let lastError { throw lastError }
        var candidates = archive
        if let before {
            guard let index = candidates.firstIndex(where: { $0.id == before }) else { return [] }
            candidates = Array(candidates.dropFirst(index + 1))
        }
        return Array(candidates.filter { sessionID == nil || $0.sessionID == sessionID }.prefix(limit))
    }

    func previousNonempty(before: Int64? = nil, excluding text: String) throws -> InputVersion? {
        try versions(before: before).first { !$0.text.isEmpty && !$0.text.utf8.elementsEqual(text.utf8) }
    }
}
