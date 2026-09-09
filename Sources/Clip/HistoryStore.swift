import Foundation
import CryptoKit
import CSQLite

struct ClipItem {
    let id: String
    let kind: String
    let preview: String
    let size: Int
}

final class HistoryStore {
    private var db: OpaquePointer?
    let directory: URL
    let maxCount: Int
    let maxBytes: Int
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(directory: URL, maxCount: Int = 100, maxBytes: Int = 200 * 1024 * 1024) throws {
        self.directory = directory
        self.maxCount = maxCount
        self.maxBytes = maxBytes
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard sqlite3_open(directory.appendingPathComponent("history.sqlite").path, &db) == SQLITE_OK else { throw failure() }
        try execute("CREATE TABLE IF NOT EXISTS history (id TEXT PRIMARY KEY, kind TEXT NOT NULL, preview TEXT NOT NULL, size INTEGER NOT NULL, touched REAL NOT NULL)")
        // Files are written before metadata; remove files left by an interrupted write.
        let valid = Set(try items().map(\.id))
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.pathExtension == "clip" {
            if !valid.contains(url.deletingPathExtension().lastPathComponent) { try? FileManager.default.removeItem(at: url) }
        }
    }
    deinit { sqlite3_close(db) }
    private func failure() -> NSError {
        NSError(domain: "Clip.Storage", code: 1, userInfo: [NSLocalizedDescriptionKey: db.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open the history storage."])
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw failure() }
        return stmt
    }
    func items() throws -> [ClipItem] {
        let stmt = try statement("SELECT id,kind,preview,size FROM history ORDER BY touched DESC, rowid DESC")
        defer { sqlite3_finalize(stmt) }
        var result: [ClipItem] = []
        var code = sqlite3_step(stmt)
        while code == SQLITE_ROW {
            result.append(ClipItem(id: String(cString: sqlite3_column_text(stmt, 0)), kind: String(cString: sqlite3_column_text(stmt, 1)), preview: String(cString: sqlite3_column_text(stmt, 2)), size: Int(sqlite3_column_int64(stmt, 3))))
            code = sqlite3_step(stmt)
        }
        guard code == SQLITE_DONE else { throw failure() }
        return result
    }
    @discardableResult func insert(data: Data, kind: String, preview: String) throws -> Bool {
        guard !data.isEmpty, data.count <= min(maxBytes, 20 * 1024 * 1024) else { return false }
        let id = SHA256.hash(data: Data(kind.utf8) + data).map { String(format: "%02x", $0) }.joined()
        let url = file(id)
        if !FileManager.default.fileExists(atPath: url.path) { try data.write(to: url, options: .atomic) }
        let stmt = try statement("INSERT INTO history VALUES (?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET touched=excluded.touched")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, transient)
        sqlite3_bind_text(stmt, 2, kind, -1, transient)
        sqlite3_bind_text(stmt, 3, preview, -1, transient)
        sqlite3_bind_int64(stmt, 4, Int64(data.count))
        sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
        var count = 0, bytes = 0
        for item in try items() {
            count += 1; bytes += item.size
            if count > maxCount || bytes > maxBytes { try remove(item.id) }
        }
        return true
    }
    func file(_ id: String) -> URL { directory.appendingPathComponent(id + ".clip") }
    func data(_ item: ClipItem) throws -> Data { try Data(contentsOf: file(item.id)) }
    func remove(_ id: String) throws {
        let stmt = try statement("DELETE FROM history WHERE id=?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
        try? FileManager.default.removeItem(at: file(id))
    }
    func clear() throws { for item in try items() { try remove(item.id) } }
}
