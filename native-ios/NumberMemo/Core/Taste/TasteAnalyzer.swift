import Foundation
import GRDB

/// Pure, deterministic statistics. No language model sees tags or computes numbers.
enum TasteAnalyzer {
    static let version = 6
    static func analyze(_ input: [TasteEvent], control: TasteControl, period: DateInterval? = nil, previous: DateInterval? = nil, savedKeys: Set<String>? = nil, mode: TasteMode = .booru) -> TasteSnapshot {
        let events = Dictionary(input.filter { $0.epoch == control.epoch }.map { ($0.id, $0) }, uniquingKeysWith: { a, b in TasteEvent.ordered(a, b) ? b : a }).values.sorted(by: TasteEvent.ordered)
        var metadataBySource: [String: Set<String>] = [:]
        for event in events { metadataBySource[event.item.source, default: []].formUnion(event.item.metadata.map(TasteTagPolicy.normalize)) }
        func eligibleTags(_ item: TasteItem) -> [String] { TasteTagPolicy.filter(item.tags, metadata: Array(metadataBySource[item.source, default: []])).filter { control.allows($0, source: item.source, mode: mode) } }
        var active: [String: TasteEvent] = [:]
        var latestMetadata: [String: TasteItem] = [:]
        var searched: Set<String> = []
        var observed: [String: TasteItem] = [:]
        var chosen: [String: TasteEvent] = [:]
        var searches: [String: Int] = [:]
        var activity: [Date: Int] = [:]
        var previousWorks = Set<String>()
        var previousTags: [String: Set<String>] = [:]
        var searchCount = 0
        var searchSessions = Set<String>()
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: control.timeZone) ?? .gmt
        func within(_ e: TasteEvent) -> Bool { period.map { e.at >= $0.start.timeIntervalSince1970 && e.at < $0.end.timeIntervalSince1970 } ?? true }
        for event in events {
            let item = event.item
            let eligible = eligibleTags(item)
            if event.kind == .search && event.context.origin == .search {
                for tag in eligible { searched.insert(TasteControl.tagKey(source: item.source, tag: tag)) }
                if within(event) {
                    if searchSessions.insert(event.context.session).inserted { searchCount += 1 }
                    for tag in eligible { searches[TasteControl.tagKey(source: item.source, tag: tag), default: 0] += 1 }
                }
            }
            if event.kind == .metadata { latestMetadata[item.key] = item }
            if event.kind == .save || event.kind == .seed || event.kind == .imported { active[item.key] = event; latestMetadata.removeValue(forKey: item.key) }
            if event.kind == .remove { active.removeValue(forKey: item.key) }
            if event.kind == .save && event.context.organic {
                for tag in eligible where event.context.included.contains(tag) {
                    searched.insert(TasteControl.tagKey(source: item.source, tag: tag))
                }
            }
            if within(event) {
                if (event.kind == .open || event.kind == .save) && event.context.organic { observed[item.key] = item }
                if event.kind == .save && chosen[item.key] == nil {
                    chosen[item.key] = event
                    activity[calendar.startOfDay(for: Date(timeIntervalSince1970: event.at)), default: 0] += 1
                }
            }
            if let previous, event.kind == .save, event.at >= previous.start.timeIntervalSince1970, event.at < previous.end.timeIntervalSince1970 {
                previousWorks.insert(item.key)
                for tag in eligible { previousTags[TasteControl.tagKey(source: item.source, tag: tag), default: []].insert(item.key) }
            }
        }
        if period == nil, let savedKeys { active = active.filter { savedKeys.contains($0.key) } }
        // Historical periods describe activity then. The live profile describes current saved items.
        var evidence = period == nil ? active : chosen
        for (key, var event) in evidence {
            if let metadata = latestMetadata[key] { event.item = metadata; evidence[key] = event }
        }
        for (key, item) in latestMetadata where observed[key] != nil { observed[key] = item }
        var tags: [String: TasteTag] = [:]
        var savedPerSource: [String: Int] = [:]
        var organicSavedTags: [String: Int] = [:]
        var openedPerSource: [String: Int] = [:]
        func allowed(_ name: String, source: String) -> Bool { !control.excluded.contains(TasteControl.tagKey(source: source, tag: name)) }
        for item in observed.values {
            openedPerSource[item.source, default: 0] += 1
            for name in eligibleTags(item) where allowed(name, source: item.source) {
                let key = TasteControl.tagKey(source: item.source, tag: name)
                var tag = tags[key] ?? TasteTag(source: item.source, name: name)
                tag.opened += 1; tags[key] = tag
            }
        }
        for event in evidence.values {
            let item = event.item
            if event.context.organic { savedPerSource[item.source, default: 0] += 1 }
            for name in eligibleTags(item) where allowed(name, source: item.source) && (!event.context.constraints.contains(name) || event.context.included.contains(name)) {
                let key = TasteControl.tagKey(source: item.source, tag: name)
                var tag = tags[key] ?? TasteTag(source: item.source, name: name)
                if event.context.preferenceAction {
                    if event.context.organic { organicSavedTags[key, default: 0] += 1 }
                    if event.context.chosenTags.contains(name) { tag.confirmed += 1 }
                    else { tag.hidden += 1; tag.sessions.insert(event.context.session) }
                } else { tag.general += 1 }
                tag.works.append(item); tags[key] = tag
            }
        }
        for (key, count) in searches {
            guard !control.excluded.contains(key), let split = key.firstIndex(of: "\n") else { continue }
            let source = String(key[..<split]), name = String(key[key.index(after: split)...])
            var tag = tags[key] ?? TasteTag(source: source, name: name)
            tag.searches = count; tags[key] = tag
        }
        for (key, var tag) in tags {
            tag.previouslySearched = searched.contains(key) || tag.confirmed > 0
            let opened = openedPerSource[tag.source, default: 0], saved = savedPerSource[tag.source, default: 0]
            if opened >= 30, saved >= 10 {
                let selectedRate = Double(organicSavedTags[key, default: 0] + 1) / Double(saved + 2)
                let baselineRate = Double(tag.opened + 1) / Double(opened + 2)
                tag.lift = selectedRate / baselineRate
            }
            tag.works.sort { $0.key < $1.key }; tags[key] = tag
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digestData = (try? encoder.encode(events)) ?? Data()
        let controlData = Data(control.analysisKey(mode).utf8)
        let signature = Data("\(version):\(TasteTagPolicy.version):\(control.timeZone):\(period?.start.timeIntervalSince1970 ?? -1):\(period?.end.timeIntervalSince1970 ?? -1):\(previous?.start.timeIntervalSince1970 ?? -1):\(previous?.end.timeIntervalSince1970 ?? -1)".utf8) + ((try? encoder.encode(evidence.keys.sorted())) ?? Data())
        return .init(tags: tags.values.filter { $0.count > 0 || $0.searches > 0 }.sorted { $0.weight == $1.weight ? $0.id < $1.id : $0.weight > $1.weight }, saves: chosen.count, opens: observed.count, searches: searchCount, activity: activity, digest: tasteDigest(digestData + controlData + signature), period: period, previousSaves: previous == nil ? nil : previousWorks.count, previousTagCounts: previousTags.mapValues(\.count))
    }
}

/// Only committed changes to analysis input invalidate decoded history. Cover
/// downloads, folder edits and sync upload flags do not change that input.
private final class TasteEventChanges: TransactionObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var changed = false
    private var committed: Int64 = 0
    var revision: Int64 { lock.withLock { committed } }

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
        guard eventKind.tableName == "taste_events" else { return false }
        if case .update(_, let columns) = eventKind { return columns.contains("payload") }
        return true
    }
    func databaseDidChange() { lock.withLock { changed = true } }
    func databaseDidChange(with event: DatabaseEvent) { databaseDidChange() }
    func databaseDidCommit(_ db: Database) {
        lock.withLock { if changed { committed &+= 1 }; changed = false }
    }
    func databaseDidRollback(_ db: Database) { lock.withLock { changed = false } }
}

actor TasteAnalysisCache {
    private struct SnapshotKey: Equatable {
        var analysis: String
        var period: DateInterval?
        var previous: DateInterval?
        var savedKeys: Set<String>?
    }
    private struct DatabaseVersion: Equatable {
        var identity: ObjectIdentifier
        var local: Int64
        var external: Int64
    }
    private struct Entry {
        var database: (any DatabaseWriter)?
        var observer: TasteEventChanges?
        var version: DatabaseVersion?
        var epoch = ""
        var events: [TasteEvent] = []
        var snapshots: [(SnapshotKey, TasteSnapshot)] = []
    }
    private var entries: [TasteMode: Entry] = [:]
    private(set) var analysisCount = 0
    private(set) var eventLoadCount = 0

    private func version(of store: TasteStore, observer: TasteEventChanges) throws -> DatabaseVersion {
        // Read the observer after pending commits on the writer connection.
        // data_version additionally catches writes through another connection.
        try store.database.writeWithoutTransaction { db in
            .init(identity: ObjectIdentifier(store.database),
                  local: observer.revision,
                  external: try Int64.fetchOne(db, sql: "PRAGMA data_version") ?? 0)
        }
    }

    func snapshot(store: TasteStore, control: TasteControl, period: DateInterval?, previous: DateInterval?, savedKeys: Set<String>? = nil) throws -> TasteSnapshot {
        try Task.checkCancellation()
        var entry = entries[store.mode] ?? Entry()
        if entry.database.map({ ObjectIdentifier($0) }) != ObjectIdentifier(store.database) {
            let observer = TasteEventChanges()
            store.database.add(transactionObserver: observer)
            entry.database = store.database
            entry.observer = observer
            entry.version = nil
        }
        guard let observer = entry.observer else { preconditionFailure("Taste observation must be registered before reading") }
        let before = try version(of: store, observer: observer)
        if entry.version != before || entry.epoch != control.epoch {
            // Row counts and max rowids cannot detect delete/reinsert operations:
            // SQLite can reuse the deleted final rowid without changing the count.
            let events = try store.database.read { db in
                try Data.fetchAll(db, sql: "SELECT payload FROM taste_events ORDER BY rowid").map { data in
                    try Task.checkCancellation()
                    return try JSONDecoder().decode(TasteEvent.self, from: data)
                }
            }
            eventLoadCount += 1
            let after = try version(of: store, observer: observer)
            if entry.events != events || entry.epoch != control.epoch || entry.version?.identity != before.identity {
                entry.snapshots.removeAll()
            }
            entry.events = events; entry.epoch = control.epoch
            // Re-read next time if a write raced the database snapshot.
            entry.version = before == after ? after : nil
        }
        let key = SnapshotKey(analysis: control.analysisKey(store.mode), period: period, previous: previous, savedKeys: period == nil ? savedKeys : nil)
        if let index = entry.snapshots.firstIndex(where: { $0.0 == key }) {
            let cached = entry.snapshots.remove(at: index)
            entry.snapshots.append(cached); entries[store.mode] = entry
            return cached.1
        }
        try Task.checkCancellation()
        let result = TasteAnalyzer.analyze(entry.events, control: control, period: period, previous: previous, savedKeys: savedKeys, mode: store.mode)
        try Task.checkCancellation()
        analysisCount += 1
        entry.snapshots.append((key, result))
        // Historical reports contain per-tag work lists; bound retained history.
        if entry.snapshots.count > 6 { entry.snapshots.removeFirst() }
        entries[store.mode] = entry
        return result
    }
    func invalidate() { entries.removeAll() }
}
