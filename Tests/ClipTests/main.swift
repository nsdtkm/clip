import Foundation

func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw NSError(domain: "ClipTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
func withStore(maxCount: Int = 100, maxBytes: Int = 1024, _ body: (HistoryStore, URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try HistoryStore(directory: directory, maxCount: maxCount, maxBytes: maxBytes)
    try body(store, directory)
}
try withStore { store, directory in
    let content = Data("日本語\n🧑‍💻".utf8)
    try store.insert(data: content, kind: "text", preview: "日本語")
    try store.insert(data: Data("second".utf8), kind: "text", preview: "second")
    try store.insert(data: content, kind: "text", preview: "日本語")
    let reopened = try HistoryStore(directory: directory)
    let items = try reopened.items()
    try check(items.count == 2, "Duplicates must collapse")
    try check(reopened.data(items[0]) == content, "Unicode must survive reopening and duplicate must move to top")
}
print("PASS: duplicate promotion and persistent Unicode")
try withStore(maxCount: 2) { store, _ in
    try store.insert(data: Data("first".utf8), kind: "text", preview: "first")
    let first = try store.items()[0]
    for text in ["second", "third"] { try store.insert(data: Data(text.utf8), kind: "text", preview: text) }
    try check(store.items().count == 2, "Count cap")
    try check(!FileManager.default.fileExists(atPath: store.file(first.id).path), "Evicted payload must be deleted")
}
print("PASS: count eviction and payload cleanup")
try withStore(maxBytes: 8) { store, _ in
    try check(store.insert(data: Data([1,2,3,4,5]), kind: "image", preview: "image"), "Insert image")
    try check(store.insert(data: Data([6,7,8,9]), kind: "image", preview: "image"), "Insert second image")
    try check(store.items().count == 1, "Byte cap")
    try check(!store.insert(data: Data(repeating: 0, count: 9), kind: "image", preview: "image"), "Reject oversized payload")
    try check(store.items().count == 1, "Oversize must not evict existing history")
    try check(store.data(store.items()[0]) == Data([6,7,8,9]), "Binary round trip")
}
print("PASS: byte limit, oversize rejection and binary round trip")
try withStore { store, directory in
    try store.insert(data: Data([1]), kind: "image", preview: "image")
    try store.insert(data: Data([2]), kind: "text", preview: "text")
    let item = try store.items()[0]
    try store.remove(item.id)
    try check(!FileManager.default.fileExists(atPath: store.file(item.id).path), "Delete payload")
    try store.clear()
    try check(store.items().isEmpty, "Clear metadata")
    let orphan = directory.appendingPathComponent("orphan.clip")
    try Data([3]).write(to: orphan)
    _ = try HistoryStore(directory: directory)
    try check(!FileManager.default.fileExists(atPath: orphan.path), "Clean orphan on restart")
}
print("PASS: individual deletion, clear and orphan recovery")
