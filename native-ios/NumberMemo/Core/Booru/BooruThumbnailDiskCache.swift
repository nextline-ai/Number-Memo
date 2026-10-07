import Foundation
import CryptoKit

/// Device-local, regenerable previews. Filenames contain no site URLs or tags.
/// An in-memory index avoids scanning the cache directory on every thumbnail.
struct BooruThumbnailDiskCache {
    private struct Entry { var size: Int; var accessed: Date; var persisted: Date }
    let directory: URL
    let capacity: Int
    private var entries: [String: Entry] = [:]
    private var bytes = 0
    private var indexed = false
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("BooruThumbnails", isDirectory: true)
    }
    init(directory: URL = Self.defaultDirectory, capacity: Int = 256 * 1024 * 1024) {
        self.directory = directory; self.capacity = max(0, capacity)
    }
    private mutating func ensureIndex() {
        guard !indexed else { return }
        indexed = true
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? [] where file.pathExtension == "png" {
            guard let value = try? file.resourceValues(forKeys: keys), value.isRegularFile == true else { continue }
            let date = value.contentModificationDate ?? .distantPast
            let entry = Entry(size: value.fileSize ?? 0, accessed: date, persisted: date)
            entries[file.lastPathComponent] = entry; bytes += entry.size
        }
        trim()
    }
    private func name(_ key: String) -> String { SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".png" }
    mutating func read(_ key: String, now: Date = Date()) -> Data? {
        ensureIndex()
        let name = name(key), file = directory.appendingPathComponent(name)
        guard var entry = entries[name] else { return nil }
        guard let data = try? Data(contentsOf: file) else { remove(key); return nil }
        // Persist recency at most hourly; memory still tracks every cache hit.
        if now.timeIntervalSince(entry.persisted) > 3600 { try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path); entry.persisted = now }
        entry.accessed = now; entries[name] = entry
        return data
    }
    mutating func write(_ data: Data, key: String, now: Date = Date()) {
        ensureIndex()
        guard data.count <= capacity else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = name(key), file = directory.appendingPathComponent(name)
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
            bytes -= entries[name]?.size ?? 0
            entries[name] = Entry(size: data.count, accessed: now, persisted: now); bytes += data.count
            trim()
        } catch { /* A full disk must not prevent viewing a downloaded preview. */ }
    }
    mutating func remove(_ key: String) { ensureIndex(); removeName(name(key)) }
    private mutating func removeName(_ name: String) {
        if let old = entries.removeValue(forKey: name) { bytes -= old.size }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
    private mutating func trim() {
        guard bytes > capacity else { return }
        for name in entries.keys.sorted(by: { entries[$0]!.accessed < entries[$1]!.accessed }) {
            removeName(name)
            if bytes <= capacity { break }
        }
    }
    mutating func clear() {
        ensureIndex()
        for name in Array(entries.keys) { removeName(name) }
        entries = [:]; bytes = 0
    }
}
